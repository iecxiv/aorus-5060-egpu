# Lever M-recover Commit 3 — hardening design (Patch 0020)

**Status:** DESIGN
**Builds on:** [`lever-M-recover-design.md`](./lever-M-recover-design.md) (canonical 28K design doc)
**Empirical foundation for hardening:** `archive/commit3-recovery-loop-2026-05-06-161429/` (the 21-attempt recovery storm)
**Hypothesis:** [H15](./reliability-hypothesis-ledger.md#h15) — Commit 3 mechanism correct; failure modes are 4 hardening bugs
**Tasks:** #62 (Phase 4 / Lever M-recover), #103 (Patch 0020 hardening)
**Last updated:** 2026-05-08

## Context — what this is + isn't

**Original Commit 3 (patch 0019, LANDED 2026-05-06 16:09):**
- ✅ **Mechanism CORRECT**: detect WPR2-stuck → workqueue → `pci_stop_and_remove_bus_device` + `pci_rescan_bus` + `pci_reset_function`
- ❌ **4 hardening bugs** caused a 21-attempt recovery storm in <4 minutes
- Was reverted; not in the patches/ tree today

**Patch 0020 (this design):** re-implement Commit 3 with all 4 hardening fixes baked in from line 1. Plus the **sharpened trigger** identified post-storm (post-rmInit-FAIL with WPR2≠0, NOT probe-time).

**Note:** Since 2026-05-06, several precondition issues that contributed to the storm have been mitigated:
- `iommu=off` cmdline (eliminates DMAR fault flood per `project_iommu_dmar_finding_2026_05_06`)
- H9a retired (eliminates the BAR1-sizing-related rmInit FAIL trigger)
- UncMaskClear deployed (matches Windows AER config)
- Mode B telemetry patch 0023 (S1 capture on AER fire)

So the WPR2-stuck condition that Commit 3 recovers from may be *rare* on current production. But the recovery path must still work robustly when it does fire.

## The 4 H15 hardening fixes

### H1: MaxAttempts enforcement

**Original bug:** `attempt_count` was incremented but never compared against `MaxAttempts` before scheduling another reset → attempts ran until external intervention (~21 in the storm).

**Fix:**
```c
if (atomic_inc_return(&lm->attempt_count) > NVreg_AorusLeverMMaxAttempts) {
    atomic_inc(&lm->surrender_count);
    NV_DEV_PRINTF(NV_DBG_ERRORS, nv,
        "Lever M-recover: surrender after %u attempts; emit PERMANENT_FAIL\n",
        atomic_read(&lm->attempt_count));
    aorus_lever_m_emit_uevent(pdev, "PERMANENT_FAIL");
    return PCI_ERS_RESULT_DISCONNECT;   /* fall back to M-base behavior */
}
```

`attempt_count` resets to 0 ONLY on successful recovery (`slot_reset` + verify GSP boots). NOT on probe-end alone, NOT on workqueue completion.

### H2: Rate-limit between attempts

**Original bug:** Attempts fired back-to-back as fast as the workqueue could schedule them; no settling time for hardware to stabilise → cascading failures.

**Fix:** Track `last_fire_jiffies`; refuse to schedule if last attempt was <`NVreg_AorusLeverMMinAttemptIntervalMs` ago (default **30 seconds**).

```c
unsigned long elapsed_ms = jiffies_to_msecs(jiffies - lm->last_fire_jiffies);
if (lm->last_fire_jiffies != 0 && elapsed_ms < NVreg_AorusLeverMMinAttemptIntervalMs) {
    NV_DEV_PRINTF(NV_DBG_ERRORS, nv,
        "Lever M-recover: rate-limit (last attempt %lums ago, min %ums)\n",
        elapsed_ms, NVreg_AorusLeverMMinAttemptIntervalMs);
    return PCI_ERS_RESULT_DISCONNECT;   /* defer to next AER fire */
}
lm->last_fire_jiffies = jiffies;
```

Rate-limit is the FIRST gate; MaxAttempts is the SECOND. Both must pass.

### H3: Kill-switch persistence

**Original bug:** `NVreg_AorusLeverMRecoverEnable=0` set via `echo 0 > /sys/module/nvidia/parameters/...` was reset to 1 when the L4 helper ran `modprobe -r nvidia` and the module reloaded.

**Fix (two-layer):**

**Layer A — runtime persistent state file** at `/var/lib/aorus-egpu/lever-m-killswitch`:
- File present + content `0` → kill switch ENGAGED (override module param to 0)
- File absent OR content `1` → use module param value (default 1 = enabled)

In `aorus_lever_m_recover_init()`:
```c
/* Override module param if persistent kill-switch file is present and 0. */
if (aorus_lever_m_read_killswitch_file() == 0) {
    nv_printf(NV_DBG_ERRORS,
        "Lever M-recover: kill-switch file engaged (/var/lib/aorus-egpu/lever-m-killswitch=0); disabling\n");
    NVreg_AorusLeverMRecoverEnable = 0;
}
```

This requires kernel-side file read in module-load context (use `kernel_read_file_from_path()` with size limit).

**Layer B — udev rule** that re-applies the module param at every module load (defense in depth):
```
# /etc/udev/rules.d/82-aorus-egpu-lever-m-killswitch.rules
ACTION=="add", SUBSYSTEM=="module", KERNEL=="nvidia", \
    RUN+="/usr/local/sbin/aorus-egpu-lever-m-killswitch-restore"
```

The `aorus-egpu-lever-m-killswitch-restore` script reads the persistent file and writes to `/sys/module/nvidia/parameters/NVreg_AorusLeverMRecoverEnable`.

**Kill-switch toggle CLI:**
```bash
sudo aorus-egpu-lever-m disable    # writes 0 to /var/lib/aorus-egpu/lever-m-killswitch + /sys/module/...
sudo aorus-egpu-lever-m enable     # removes file + writes 1
sudo aorus-egpu-lever-m status     # reads both file and runtime param
```

### H4: Smarter error_handler

**Original bug:** `error_detected` returned `DISCONNECT` even when `Enable=1`, then the kernel started teardown which conflicted with our own `pci_reset_bus` from workqueue.

**Fix:** error_detected return value depends on enable + state:

| `Enable` | `attempt_count < Max` | Rate-limit OK | error_detected returns |
|---|---|---|---|
| 0 | — | — | `DISCONNECT` (M-base fallback) |
| 1 | YES | YES | `NEED_RESET` (kernel does bus reset; we get slot_reset/resume callbacks) |
| 1 | NO (exhausted) | — | `DISCONNECT` (we surrender; emit PERMANENT_FAIL uevent) |
| 1 | YES | NO (rate-limited) | `DISCONNECT` (defer to next fire; don't storm) |

Implementing slot_reset + resume callbacks (currently absent in M-base):
```c
static pci_ers_result_t nv_pci_slot_reset(struct pci_dev *pdev) {
    /* Bus reset complete. Verify the GPU is alive on bus. */
    u32 pmc_boot_0 = read_pmc_boot_0_via_temporary_ioremap(pdev);
    if (pmc_boot_0 == 0xffffffff) return PCI_ERS_RESULT_DISCONNECT;
    return PCI_ERS_RESULT_RECOVERED;
}
static void nv_pci_resume(struct pci_dev *pdev) {
    /* Reset attempt counter — successful recovery */
    nv_linux_state_t *nvl = pci_get_drvdata(pdev);
    if (nvl && nvl->lever_m) {
        atomic_inc(&nvl->lever_m->success_count);
        atomic_set(&nvl->lever_m->attempt_count, 0);
        aorus_lever_m_emit_uevent(pdev, "READY");
    }
}
```

## Sharpened trigger (post-storm clarification)

**Old (Commit 2 in patch 0017, FALSIFIED):** WPR2 non-zero at probe time.
**Result:** WPR2 is 0 at clean cold-boot probe. The 0x07f4a000 value appears DURING the failed `rm_init_adapter` call.

**New (Commit 3 in this patch):** post-rmInit-FAIL with WPR2 ≠ 0.

**Detection point:** Hook into `nv_start_device()` (kernel-open/nvidia/nv.c) just AFTER `rm_init_adapter` returns failure. Check WPR2; if ≠ 0, schedule recovery work.

Keep probe-time check (Commit 2 patch 0017) IN PLACE as no-op-detection-only sanity check (it'll always read 0 at fresh probe; the assertion is value documentation).

## Module parameters — final list

| Parameter | Default | Purpose |
|---|---|---|
| `NVreg_AorusLeverMRecoverEnable` | 1 | Master kill switch |
| `NVreg_AorusLeverMMaxAttempts` | 3 | Per-burst attempt cap |
| `NVreg_AorusLeverMResetSettleMs` | 500 | Sleep after bus reset before verify |
| `NVreg_AorusLeverMMinAttemptIntervalMs` | **30000** (NEW) | Rate-limit gate (30s default) |
| `NVreg_AorusLeverMSurrenderResetSec` | **300** (NEW) | Reset attempt_count to 0 after this much idle (5 min) |

`SurrenderResetSec` is for the case where AER fires once, then 5 min of clean operation, then AER fires again — that's a NEW burst, not part of the previous one, so `attempt_count` should reset.

## Code surface

| File | Change | Approx. LoC |
|---|---|---|
| `kernel-open/nvidia/nv-lever-m-recover.h` | Add new struct fields (`last_attempt_jiffies`, `pdev_for_work`); new prototypes | ~10 |
| `kernel-open/nvidia/nv-lever-m-recover.c` | Add 2 new module params; rewrite work handler with full recovery sequence; killswitch file read; uevent emission | ~150 |
| `kernel-open/nvidia/nv-pci.c` | Implement `slot_reset` + `resume` callbacks; rewrite `error_detected` per H4 table; add to `nv_pci_err_handlers` struct | ~50 |
| `kernel-open/nvidia/nv.c` | Add hook in `nv_start_device()` post-rmInit-FAIL; check WPR2; trigger recovery | ~30 |
| **Total in driver** | | **~240 LoC C** |
| `usr/local/sbin/aorus-egpu-lever-m` | NEW kill-switch CLI script | ~80 (bash) |
| `usr/local/sbin/aorus-egpu-lever-m-killswitch-restore` | NEW udev-triggered helper | ~20 (bash) |
| `etc/udev/rules.d/82-aorus-egpu-lever-m-killswitch.rules` | NEW udev rule | ~5 |
| **Total userspace + udev** | | **~105 LoC bash + udev** |

## Test plan

Per `feedback_targeted_comprehensive_patches`: ship as ONE patch, verify in stages.

### Phase 1 — Build verification
- DKMS rebuild succeeds
- `modinfo nvidia` shows new params
- Boot with `NVreg_AorusLeverMRecoverEnable=0` (cmdline override) → behaviour matches today (M-base)

### Phase 2 — Cold-boot baseline
- Cold-cold-boot Port A with `Enable=0` → confirm L4 helper still triggers (regression baseline)
- Cold-cold-boot Port A with `Enable=1` → if WPR2-stuck does not occur (likely on current stack), `aorus_lever_m_fires=0`; healthy boot
- Repeat n=5 cold-cold-boots, confirm 0 fires (or all fires recover successfully if any)

### Phase 3 — Manual trigger (test the recovery path)
The hardest part is **deliberately inducing WPR2-stuck**. Options:
- (a) Force-fail rm_init via fault injection module-param (NEW: `NVreg_AorusLeverMTestForceTrigger=1` for test-only)
- (b) Wait for natural occurrence (rare on current stack)

Option (a) preferred for n≥10 PROVEN graduation.

### Phase 4 — H15 hardening verification
For each of the 4 H15 fixes, write a discrete test:
- **H1 MaxAttempts:** force-trigger 5 times in a row; verify 3 attempts then surrender + PERMANENT_FAIL uevent
- **H2 Rate-limit:** force-trigger twice in <10s; verify second is rate-limited (logged); third 60s later succeeds
- **H3 Kill-switch persistence:** disable via CLI, modprobe -r + reload nvidia, verify still disabled; enable via CLI, verify works
- **H4 error_handler:** trigger AER, verify error_detected returns NEED_RESET, slot_reset fires, attempt_count resets to 0 on resume

### Phase 5 — Service retirement
After n≥10 PROVEN cold-cold-boot recoveries via in-driver path, disable `aorus-egpu-wpr2-recovery.service` per `service-retirement-roadmap.md`.

## Risks (updated since 2026-05-06)

| Risk | Status | Mitigation |
|---|---|---|
| pci_reset_bus from workqueue races kernel PCI scan | OPEN | `pci_lock_rescan_remove()` around reset |
| Bus reset times out | LOW (validated 2026-05-06) | Conservative `ResetSettleMs` |
| Bus reset propagates to audio function | EXPECTED | Audio function rebinds with GPU |
| Recovery storm (the 2026-05-06 incident) | **FIXED by H1+H2+H3+H4 hardening** | Three-layer defense |
| AER doesn't fire on TB-tunneled GPU | OPEN | Probe-time path independent of AER; AER path is bonus |
| **NEW: kill-switch file read at module init** | NEW | Use `kernel_read_file_from_path` with hard size limit; default to enabled if read fails |
| **NEW: kobject_uevent_env at unbind context** | LOW | Standard pattern; pdev still valid in slot_reset/resume |

## Cross-references

- Canonical design: `docs/lever-M-recover-design.md` (28K)
- Empirical storm: `archive/commit3-recovery-loop-2026-05-06-161429/`
- Hypothesis: `docs/reliability-hypothesis-ledger.md` H15 (the storm) + H13 (recovery reliability)
- L4 reference: `usr/local/sbin/aorus-egpu-wpr2-recovery` (the proven sequence to port in-driver)
- Service retirement: `docs/service-retirement-roadmap.md` (`aorus-egpu-wpr2-recovery.service` retires after PROVEN)
- Tasks: #62 (Phase 4 in_progress), #103 (this patch)

## What this design doc does NOT cover

- Userspace event subscriber implementation (separate work; udev rules + service hooks)
- AER subsystem behavior on TB-tunneled paths (orthogonal investigation; covered by Mode B telemetry patch 0023)
- H10 IOMMU policy variation (separate hypothesis ledger entry; mitigated by `iommu=off` cmdline today)
- Lever R Tier 3 convergence — handled by retiring the L4 helper after this lands

## Open design questions

1. **Should the kill-switch file path be configurable?** (`/var/lib/aorus-egpu/lever-m-killswitch` is hardcoded). Suggest: yes, via cmdline param `aorus_lever_m_killswitch_path=...`
2. **uevent string standardization** — does NVIDIA upstream have a similar pattern? Worth checking before standardizing on `AORUS_GPU_STATE=READY/RECOVERING/PERMANENT_FAIL`.
3. **Should we retire patch 0017** (Commit 2 falsified probe-time detection)? Suggest: yes, fold the falsified-but-illustrative code into design doc, drop the patch.
