# Lever M-recover — design document

> **2026-05-06 15:47 UPDATE — mechanism understanding REWRITTEN:** Diagnostic
> telemetry (`archive/diag-telemetry-2026-05-06-154732/`) falsified the
> original "WPR2 stuck across boots" hypothesis. The actual mechanism is
> "WPR2 set during failed first rm_init_adapter, blocks subsequent retries."
> The trigger location for Commit 3 has moved from `nv_pci_probe` to
> `nv_start_device` post-rmInit-FAIL. See [Mechanism (corrected)](#mechanism-corrected) below.

> **Goal:** Move GPU recovery from a userspace orchestration race
> (`aorus-egpu-wpr2-recovery` Tier 1 v3) into the driver itself, using the
> kernel's `pci_error_handlers` framework and an upstream-bridge bus reset
> as the recovery primitive. This is **the architectural destination for
> Lever R**, not a parallel piece of work — they converge.
>
> **Status:** DESIGN. Implementation pending.
>
> **Catalogue entries:**
> - [`lever-catalog.md` — Lever M-recover](./lever-catalog.md) (to add)
> - [`lever-R-design.md` — Tier 3](./lever-R-design.md#tier-3--native-in-driver-async-recovery-the-destination)
> - [`service-retirement-roadmap.md`](./service-retirement-roadmap.md) — retires `aorus-egpu-wpr2-recovery.service`
>
> **Empirical foundation:** [`archive/boot-recovery-fail-2026-05-06-125648/`](../archive/boot-recovery-fail-2026-05-06-125648/) demonstrating that the L4 helper races userspace bind-retriers (`nvidia-persistenced`); recovery succeeds reliably ONLY when no other authority concurrently accesses `/dev/nvidia0`. Single-arbiter requirement is unavoidable — and the only authority that has unconditional priority is the driver itself.
>
> **Hypothesis tested by this work:** [H13](./reliability-hypothesis-ledger.md#h13) at full scope — recovery reliability under all observed failure modes, no race exposure, n≥10 cold-cold-boots PROVEN.
>
> **Last updated:** 2026-05-06 13:30

---

## Why this is the right layer

Today's evidence (2026-05-06 12:56:48 boot): the L4 helper is structurally
race-prone with any other userspace component that holds an authority over
GPU bind state.

| Authority | Action | Effect during recovery |
|---|---|---|
| `aorus-egpu-wpr2-recovery` | PCI remove + rescan + reset + modprobe + verify | Performs the recovery |
| `nvidia-persistenced` | opens `/dev/nvidia0` every ~10s, retries on failure | Each open during recovery triggers `_kgspBootGspRm`, can re-assert WPR2 |
| `compute-load-nvidia.service` | one-shot modprobe | Fires async; verify can race the bind-completion |
| `aorus-egpu-uvm-keepalive` | holds `/dev/nvidia-uvm` fd | Prevents clean module unload during recovery's modprobe -r step |

The only way to have a single-arbiter guarantee is to **own the recovery
inside the driver**, before any userspace process has had the opportunity
to open the chardev. This is exactly the model the closed Windows driver
follows.

The kernel's `pci_error_handlers` framework is the standard interface for
this. Lever M-base (patch 0007) registered the callback struct with a
no-op `error_detected` returning DISCONNECT. M-recover replaces that with
a real recovery implementation.

## Mechanism (corrected)

**Per diagnostic telemetry 2026-05-06 15:47, the original "WPR2 stuck
from previous boot" hypothesis is FALSIFIED.** The actual failure
mechanism is:

```
Cold boot → WPR2 register = 0
   ↓
nv_pci_probe completes successfully (WPR2=0 throughout)
   ↓
First /dev/nvidia0 open → nv_start_device → rm_init_adapter
   ↓
GSP boot SETS WPR2 = 0x07f4a000 in hardware (secure region setup)
   ↓
GSP boot then FAILS for some other reason (root cause TBD; see
investigation hypothesis below — PMC_BOOT_0 transiently reads 0)
   ↓
WPR2 register is now SET, but GSP isn't actually running
   ↓
rm_init_adapter retry: kgspIsWpr2Up_HAL reads 0x07f4a000 = "already up"
   → returns NV_ERR_INVALID_STATE → "WPR2 already up, cannot proceed"
   ↓
Loops forever until something does a PCI reset to clear WPR2
```

**Critical insight:** `0x07f4a000` is the *normal* WPR2 value when GSP
is running successfully (validated by `post-rmInit-OK` reading at
15:48:22). Non-zero alone is not a stuck indicator. The stuck condition
is "WPR2 set, but rm_init_adapter just returned failure" — a
state-mismatch from the failed first init.

**Implication for trigger placement:**

| Where | Detection works? | Why |
|---|---|---|
| `nv_pci_probe` (Commit 2 attempted here) | NO | WPR2 is correctly clear at probe; nothing to detect |
| `nv_start_device` entry | NO (clean boots) | WPR2 only set after first rm_init_adapter |
| `nv_start_device` pre-rmInit | NO (clean boots) | Same — only set DURING rm_init_adapter |
| **`nv_start_device` post-rmInit-FAIL** | **YES — definitive** | If rm_init_adapter just failed AND WPR2 is non-zero, recovery is needed |

**Sharpened detection criterion** (Commit 3): post-rmInit-FAIL with
WPR2 ≠ 0. Not "is WPR2 non-zero?" alone — that's the steady state
during normal operation. The combination "rm_init_adapter just failed
AND WPR2 is set" is the unambiguous trigger.

## Mechanism (the recovery primitive)

**`pci_reset_bus(parent_bridge->bus)`** — secondary bus reset on the
immediate upstream PCI-PCI bridge.

### Hardware topology

```
0000:00:07.0  Root port (Arrow Lake CPU)
  └── 0000:02:00.0   Thunderbolt switch (upstream port)
        └── 0000:03:00.0   Thunderbolt switch (downstream port to eGPU enclosure)
                            ← reset_method=bus  ← THIS is our reset target
              └── 0000:04:00.0   GeForce RTX 5090 (function 0)   ← reset_method=flr
              └── 0000:04:00.1   HD Audio Controller (function 1)
```

Bus reset on `0000:03:00.0`'s secondary bus propagates a hot reset to
every device on that segment. The only devices on that segment are GPU
function 0 and 1. After reset:
- WPR2 in GSP is cleared (poweroff-equivalent for GSP secure region)
- Conf-compute state cleared
- All GPU state cleared
- PCI core re-enumerates the device, calls `slot_reset` then `resume`
  callbacks on the registered driver

This is **why the helper sequence works**: `echo 1 > /sys/.../reset`
ultimately calls `pci_reset_function()` which uses the available reset
methods. The GPU's FLR alone has been empirically insufficient (Tier 1 v1
evidence) — but the bus reset on the parent bridge is more invasive and
clears state the FLR doesn't touch.

### Why not call the bridge reset from `nv_pci_probe` directly?

Tier 1 v2 attempted `pci_reset_function()` from `_kgspBootGspRm` (probe
context) and got `-ENOTTY` because `dev->reset_fn=0` at that probe-context
state — kernel hadn't populated the reset methods yet for the bound
device. Same constraint applies to bridge reset from probe context, plus:

- We can't synchronously block in probe waiting for a bus reset (probe is
  called from the kernel's PCI scan, holds locks)
- After bus reset, the kernel re-enumerates the device — our probe stack
  unwinds anyway

So the right shape is:

1. probe detects WPR2-stuck (or AER fires error_detected at runtime)
2. driver schedules a workqueue job that performs the reset
3. probe returns -EPROBE_DEFER (boot path) OR error_detected returns NEED_RESET (runtime)
4. workqueue (or kernel's AER handler) calls `pci_reset_bus()` on parent
5. kernel re-binds the device; `slot_reset` callback fires; driver re-inits

## Two trigger paths, one recovery state machine

| Path | Trigger | Detection site |
|---|---|---|
| **Boot-time** | Cold-cold-boot WPR2-stuck | `nv_pci_probe` (or early in `_kgspBootGspRm`) reads GSP register |
| **Runtime** | AER error / link drop / DPC | Kernel calls `error_detected` callback |

Both feed the same recovery state machine:

```
                ┌──── recovery_in_progress flag (atomic, per-pdev) ────┐
                │                                                      │
[BOOT WPR2 detected]                                                   │
        │                                                              │
        v                                                              │
schedule_work(reset_work) ──────┐                                      │
        │                       │                                      │
        v                       v                                      │
[probe returns -EPROBE_DEFER]   reset_work():                          │
                                  pci_reset_bus(parent->bus)           │
                                  emit AORUS_GPU_STATE=RECOVERING uevent│
                                                                       │
[RUNTIME AER fires] ────► error_detected() ───────────────────────► returns NEED_RESET
                                                                       │
                                                                       v
                                                              kernel issues bus reset
                                                                       │
                                                                       v
                                                              slot_reset() callback fires
                                                                       │
                                                                       v
                                                              re-init GSP, verify WPR2 cleared
                                                                       │
                                                                       v
                                                              resume() callback fires
                                                                       │
                                                                       v
                                                              emit AORUS_GPU_STATE=READY uevent
                                                                       │
                                                                       v
                                                              recovery_in_progress=0
```

## Code surface

| File | Change | Lines |
|---|---|---|
| `kernel-open/nvidia/nv-pci.c` | Replace M-base callbacks with M-recover state machine: `error_detected` returns NEED_RESET; add `mmio_enabled`, `slot_reset`, `resume` | +120 |
| `kernel-open/nvidia/nv-pci.c` | New: probe-time WPR2 detection + workqueue scheduling | +60 |
| `kernel-open/common/inc/nv-linux.h` | New: `aorus_lever_m_recover` struct on `nv_linux_state_t` (recovery_in_progress atomic, work_struct, retry counter, last_recovery_jiffies) | +15 |
| `kernel-open/nvidia/nv-qwatchdog.c` | sysfs counters for fire_count, success_count, surrender_count (similar pattern to existing qwatchdog counters) | +60 |
| **Total** | | **~255 lines, single new patch `0016-Lever-M-recover.patch`** |

Note: this is a SINGLE comprehensive patch covering both probe-time
(boot) and AER-runtime trigger paths. Per `feedback_targeted_comprehensive_patches`
discipline.

## Module parameters (kill switches + tuning)

```c
static unsigned int NVreg_AorusLeverMRecoverEnable = 1;
module_param(NVreg_AorusLeverMRecoverEnable, uint, 0644);
MODULE_PARM_DESC(NVreg_AorusLeverMRecoverEnable,
    "AORUS Lever M-recover: enable in-driver recovery (1=on, 0=fall back to old DISCONNECT behavior)");

static unsigned int NVreg_AorusLeverMMaxAttempts = 3;
module_param(NVreg_AorusLeverMMaxAttempts, uint, 0644);
MODULE_PARM_DESC(NVreg_AorusLeverMMaxAttempts,
    "AORUS Lever M-recover: max bus-reset attempts before giving up (default 3)");

static unsigned int NVreg_AorusLeverMResetSettleMs = 500;
module_param(NVreg_AorusLeverMResetSettleMs, uint, 0644);
MODULE_PARM_DESC(NVreg_AorusLeverMResetSettleMs,
    "AORUS Lever M-recover: settle delay after bus reset before verifying WPR2 cleared (default 500ms)");
```

## State machine details

### Boot-time path

1. `nv_pci_probe(pdev, id)` called by kernel
2. Driver does pre-GSP-boot WPR2 check (read GSP_LOCKDOWN_NOTICE register or equivalent — TBD which is the cheapest way to check WPR2 status without a full GSP boot attempt)
3. If WPR2 is up AND `NVreg_AorusLeverMRecoverEnable=1`:
   - increment `lever_m.fire_count`
   - check `lever_m.attempt_count < NVreg_AorusLeverMMaxAttempts` — if exceeded, log surrender, fall through to normal probe (which fails) → kernel marks device dead
   - schedule_work(&lever_m.reset_work)
   - return -EPROBE_DEFER (kernel will retry probe later, but only after our work runs the reset)
4. `reset_work` runs:
   - `pci_reset_bus(pdev->bus)` (which is the parent bridge's secondary bus)
   - msleep(`NVreg_AorusLeverMResetSettleMs`)
   - emit `kobject_uevent_env(&pdev->dev.kobj, KOBJ_CHANGE, AORUS_GPU_STATE=RECOVERING/READY)`
5. After reset, kernel re-enumerates and calls probe again
6. Probe sees WPR2 cleared, completes normally
7. `lever_m.attempt_count` reset to 0 on successful probe

### Runtime AER path

1. AER fires → kernel calls `nv_pci_error_detected(pdev, channel_state)`
2. If `NVreg_AorusLeverMRecoverEnable=0`: return DISCONNECT (M-base behaviour, fallback)
3. Else:
   - increment `lever_m.fire_count`
   - check `lever_m.attempt_count < NVreg_AorusLeverMMaxAttempts` — if exceeded, return DISCONNECT
   - return PCI_ERS_RESULT_NEED_RESET
4. Kernel performs the bus reset
5. Kernel calls `nv_pci_slot_reset(pdev)` after reset:
   - re-init driver state for the device
   - verify GSP boot succeeds (WPR2 cleared)
   - emit AORUS_GPU_STATE=READY uevent
   - return PCI_ERS_RESULT_RECOVERED
6. Kernel calls `nv_pci_resume(pdev)`:
   - normal post-recovery cleanup
   - reset attempt_count to 0

## Sysfs surface

`/sys/bus/pci/devices/0000:04:00.0/aorus_lever_m_fires` — total fire events this boot
`/sys/bus/pci/devices/0000:04:00.0/aorus_lever_m_successes` — recoveries that completed successfully
`/sys/bus/pci/devices/0000:04:00.0/aorus_lever_m_surrenders` — times we exhausted MaxAttempts
`/sys/bus/pci/devices/0000:04:00.0/aorus_lever_m_last_fire_jiffies` — for "is recovery happening NOW" checks

## Userspace events (subscriber model)

`kobject_uevent_env(KOBJ_CHANGE, "AORUS_GPU_STATE=READY")` and analogous
RECOVERING / PERMANENT_FAIL transitions. udev rules in the platform repo
can pick these up for:

- `nvidia-persistenced` — wait for READY before opening the chardev (retires its retry loop)
- ollama / user services — wait for READY before starting CUDA work
- observability — log every state transition for the ledger

This is the **mechanism that retires the userspace race**. Once the
driver is the sole source of truth for "GPU is bindable," there is no
more competition.

## Test plan

| Step | Action | Pass criterion |
|---|---|---|
| 1 | Cold-cold-boot with `NVreg_AorusLeverMRecoverEnable=0` | Behaviour matches today: WPR2-stuck causes probe failure (M-base DISCONNECT path); L4 helper picks up; helper succeeds. Regression baseline. |
| 2 | Cold-cold-boot with `NVreg_AorusLeverMRecoverEnable=1` (default) | Probe detects WPR2, schedules workqueue, kernel re-probes after reset, GPU comes up cleanly without L4 helper firing. Marker: `AORUS Lever M-recover: WPR2 detected at probe — scheduling bus reset` in dmesg, followed by successful probe within ~3s. |
| 3 | Cold-cold-boot, repeat n=10 | n=10 boots succeed via in-driver recovery. ≥9/10 success → PROVEN. |
| 4 | Trigger AER manually (write to `/sys/bus/pci/devices/.../aer_dev_nonfatal`) | error_detected fires, returns NEED_RESET, slot_reset called, GPU recovers without unbind. nvidia-smi never reports "No devices found" externally. |
| 5 | Stress: induce WPR2-stuck via deliberate process kill during GSP init, repeat boot/recover cycle 5× | All 5 recover cleanly. fire_count counter tracks; successes counter increments. |
| 6 | Surrender path: set MaxAttempts=1, force a hardware that doesn't recover (test by introducing a forced second-fail) | After 1 attempt, recovery surrenders, emits PERMANENT_FAIL uevent, returns DISCONNECT. L4 helper or operator can take over. |
| 7 | Disable test: NVreg_AorusLeverMRecoverEnable=0 + cold-cold-boot WPR2 → confirm full revert to today's behavior | M-base DISCONNECT path; L4 helper picks up; baseline reproduced. |

## Risks and mitigations

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| `pci_reset_bus` from workqueue races with kernel's own PCI scan | Med | High — could deadlock | Use `pci_lock_rescan_remove()` around the reset |
| Bus reset takes longer than expected, kernel times out | Low | Med | `NVreg_AorusLeverMResetSettleMs` tunable; default conservative |
| WPR2 detection at probe is non-trivial (need to read a register without touching GSP) | High | High — could break boot | Stage incrementally: M-recover-aer FIRST (runtime path only), THEN M-recover-probe (boot path) |
| Bus reset propagates to the audio function (04:00.1) | Cert | Low — audio function lives or dies with GPU anyway | None needed; this is correct behaviour |
| If retry exhausted, kernel marks device dead — no recovery path | Med | High | Surrender path emits PERMANENT_FAIL uevent; L4 helper still installed as last-resort fallback (retired only after PROVEN at n≥10) |
| AER doesn't fire on link drops on Thunderbolt PCIe (issue #979 root cause) | High | High — runtime path may never trigger | Probe-time path is independent of AER, still works for boot-WPR2; AER path is bonus when it does fire |

## Staging — how this lands in pieces

To match `feedback_targeted_comprehensive_patches` discipline (one
complete patch covering identified sites, not incremental partials), the
implementation is:

| Commit | Scope | Status | Validation |
|---|---|---|---|
| **1** | **Scaffolding: per-pdev struct, module params, sysfs counters, workqueue plumbing. NO behaviour change** | **LANDED + VALIDATED ON HARDWARE 2026-05-06 14:42** (patch `0016-Lever-M-recover-scaffolding.patch`) | Built, installed, rebooted. Module symbols + sysfs files + module params confirmed present. Counters all 0 (correct for no-op stub). Q-watchdog still works. No probe regression. **Side-finding:** module's `version:` string read aorus.5 instead of aorus.6 due to cached `_out/Linux_x86_64/version.h` surviving `git checkout --`. Build script updated to force-regenerate. |
| **2** | **Probe-time WPR2-stuck detection-only** (patch `0017-Lever-M-recover-probe-time-WPR2-detection.patch`) | **LANDED 2026-05-06 15:12, FALSIFIED BY DIAGNOSTIC 2026-05-06 15:47.** Read at BAR0+0x88a828 returns 0 at probe — correctly, because WPR2 isn't actually stuck across boots. Original premise was wrong. Patch 0017 remains in tree as historical record of the wrong hypothesis being concretely falsified. Will be REPLACED (not just removed) by Commit 3's correct trigger. | n/a — falsified. Diagnostic patch 0018 superseded the question. |
| **diag** | **4-point lifecycle telemetry: PMC_BOOT_0 + WPR2_ADDR_HI at probe-end, startdev-entry, pre-rmInit, post-rmInit-{OK,FAIL}** (patch `0018-Lever-M-recover-diagnostic-telemetry.patch`) | **LANDED + DELIVERED CONCLUSIVE TELEMETRY 2026-05-06 15:47** (`archive/diag-telemetry-2026-05-06-154732/`). Showed: WPR2=0 at cold boot probe AND pre-rmInit. WPR2 transitions to 0x07f4a000 *during* failed rm_init_adapter. 0x07f4a000 is the normal-running value, not a stuck indicator. Will be REMOVED (or gated under a kill-switch) once Commit 3 lands. | RESULT: Commit 3 trigger location confirmed = post-rmInit-FAIL with WPR2≠0. |
| **3** | **In-driver recovery action**: detect post-rmInit-FAIL with WPR2≠0; from work-queue context: `pci_stop_and_remove_bus_device(pdev)` + `pci_rescan_bus(parent_bus)` + `pci_reset_function(new_pdev)` + reset attempt counter. Refcount-managed pdev across nvl-free. Replace work_handler stub. Sharpened trigger eliminates false positives on healthy-running GPUs. | **LANDED 2026-05-06 16:09** (patch `0019-Lever-M-recover-action-Commit3.patch`). **VALIDATED ON HARDWARE 2026-05-06 16:14 — DETECTION + ACTION MECHANISM CORRECT, but four hardening bugs revealed** (see [H15](./reliability-hypothesis-ledger.md#h15)): no MaxAttempts enforcement → 21-attempt recovery storm; no rate-limit between attempts (10s cycle prevented natural settling); kill-switch reset by L4 helper modprobe-r; `error_handler` returning DISCONNECT may interfere with reset. **Also exposed H14 root cause: 524 DMAR/IOMMU fault entries** — H10 IOMMU policy investigation strongly elevated. Commit 3 must NOT be re-deployed in default-on config without the H15 fixes (patch 0020 planned). | RESULT: action mechanism CORRECT, hardening REQUIRED. Forensic dossier at `archive/commit3-recovery-loop-2026-05-06-161429/`. |
| **3-hardening (planned)** | **Production-quality Commit 3** with MaxAttempts gate, rate-limit, kill-switch persistence, and smarter error_handler. Patch 0020. Should be paired with H10 IOMMU investigation (which may eliminate the trigger entirely). | DESIGN | Cold-cold-boot recovery bounded at 3 attempts; healthy boots produce 0 fires; kill-switch persists across L4 helper modprobe cycles. |

Total: 3 commits, single deliverable (`patches/0016-*.patch`). The kill
switch (`NVreg_AorusLeverMRecoverEnable=0`) provides immediate revert if
any stage causes regression.

**Commit 1 deliverable summary (LANDED 2026-05-06):**

- `kernel-open/nvidia/nv-lever-m-recover.h` (62 lines, NEW): opaque struct + lifecycle prototypes
- `kernel-open/nvidia/nv-lever-m-recover.c` (252 lines, NEW): module params + work_struct + sysfs counters + lifecycle
- `kernel-open/common/inc/nv-linux.h`: forward-declared `struct aorus_lever_m_recover *lever_m;` field on `nv_linux_state_t`
- `kernel-open/nvidia/nv-pci.c`: include + init/stop calls next to existing Q-watchdog calls
- `kernel-open/nvidia/nvidia-sources.Kbuild`: registers new .c
- `version.mk`: bumped 595.71.05-aorus.5 → aorus.6
- Module params visible: `NVreg_AorusLeverMRecoverEnable`, `NVreg_AorusLeverMMaxAttempts`, `NVreg_AorusLeverMResetSettleMs`
- sysfs counters when bound: `aorus_lever_m_{fires,successes,surrenders,last_fire_jiffies}` at `/sys/bus/pci/devices/0000:04:00.0/`
- Work handler is a no-op stub. error_detected still returns DISCONNECT (M-base behaviour). Probe path unmodified.

**Next: Commit 2** — probe-time WPR2 detection + workqueue-scheduled `pci_reset_bus()` recovery action.

## Relationship to other levers

| Lever | Relationship |
|---|---|
| **Lever R Tier 3** | Lever M-recover IS Lever R Tier 3 — the same engineering, viewed from probe-time vs runtime AER triggers. They share state machine, code surface, retire the same userspace service. Renaming the work to a single name on landing. |
| **Lever M-base** (patch 0007, landed) | Replaced by M-recover. M-base remains in patch 0007 as the no-op DISCONNECT fallback when `NVreg_AorusLeverMRecoverEnable=0`. |
| **Lever M-preserve** (Phase 5, future) | After M-recover lands and is PROVEN, M-preserve adds state preservation — saving in-flight CUDA context across slot_reset so userspace doesn't see "GPU briefly disappeared." Closed Windows driver supposedly does this; NVIDIA's open-source roadmap mentions "PEX Reset and Recovery." |
| **Lever S** (#100, future) | Independent — close-path fix retires `nvidia-persistenced` directly. Combined with M-recover's uevent emission, the persistenced-listening-for-events-instead-of-polling pattern emerges naturally. |
| **Lever R Tier 1 v3** (helper, landed) | RETIRES upon M-recover validation at n≥10. Helper remains in `usr/local/sbin/` as documented archive of the workaround era; systemd unit disabled by post-install hook in driver package. |

## Upstream-readiness

- **High** — recovery via `pci_error_handlers` is the standard kernel pattern. Many vendor drivers implement it (intel ethernet, AMD GPU, etc.). NVIDIA is conspicuously absent.
- The probe-time WPR2 detection + scheduled reset is more bespoke; would need NVIDIA-internal review for whether the WPR2 register read is safe at that point in probe.
- Module parameters and sysfs counters are similar to many existing NVIDIA module parameters (good landing pattern).
- The `AORUS_*` uevent envelope is unique to us; upstream might rename to `NVIDIA_GPU_STATE` or use existing kernel state mechanisms.
- Realistic upstream timeline: 6-12 months after PROVEN at n≥10 here, with NVIDIA-engineering co-development.

## Pre-requisites for landing

- Lever R Tier 1 v3 helper SUPPORTED (n≥1) — DONE 2026-05-06
- Empirical evidence that recovery races userspace — DONE (this dossier)
- L4 helper baseline retained as fallback during M-recover stabilization
- Build + test methodology proven (build-patched-driver.sh works for adding new patches) — DONE
- Q-watchdog + observability-watchdog sysrq capture in place — DONE (gives crash forensics for this work)

All prerequisites met. Implementation can start immediately.

## Open design questions

1. ~~**Cheapest WPR2 read at probe**~~ — **OBSOLETE 2026-05-06.** Resolved (offset = `BAR0+0x88a828`, mask `0xFFFFFFF0`) but the question itself was falsified — WPR2 is NOT stuck at probe time. Detection moved to post-rmInit-FAIL site per [Mechanism (corrected)](#mechanism-corrected). The same read offset is still used, just at a later point. Implementation:

   ```c
   // After pci_iomap of BAR0 in nv_pci_probe, before RmInitAdapter is called:
   // Read NV_HUBMMU_PRI_MMU_WPR2_ADDR_HI directly from BAR0 via ioread32.
   // Bits [31:4] = WPR2 ADDR HI VAL; non-zero means WPR2 is up.
   #define AORUS_WPR2_REG_OFFSET   (0x880000 + 0xa828)  // Blackwell GB100/GB202
   #define AORUS_WPR2_VAL_MASK     0xFFFFFFF0u           // bits 31:4
   u32 wpr2_raw = ioread32(bar0_ptr + AORUS_WPR2_REG_OFFSET);
   bool wpr2_up = (wpr2_raw & AORUS_WPR2_VAL_MASK) != 0;
   ```

   Note: skip the conf-compute branch (which the GB100 implementation has) — we know from observed boot-time failure mode that conf-compute isn't enabled on consumer 5090 hardware (`CPU does not support confidential compute` is logged immediately).

2. **Single-pdev vs all-GPUs** — module-level state vs per-pdev state. Per-pdev is right (multi-GPU systems), but our context is single-GPU; KISS for now and structure for future expansion. (UNCHANGED.)

3. **Workqueue choice** — system_wq vs dedicated WQ. Dedicated is cleaner; allocate at module init, free at unload. (UNCHANGED.)

4. **Probe defer vs synchronous** — `schedule_work + EPROBE_DEFER` is the right pattern. `pci_reset_bus()` from probe context is unsafe (probe holds rescan-remove lock; reset would deadlock). Workqueue runs after probe returns, then the bus reset triggers kernel re-probe. Validation: confirm `-EPROBE_DEFER` from `nv_pci_probe` actually causes kernel to re-add the device after our `pci_reset_bus()` call (it should — kernel's deferred probe machinery picks up reset events).

5. **What if bus reset itself fails?** — `pci_reset_bus()` returns int; on non-zero, emit `PERMANENT_FAIL` uevent + log + leave device unbound. L4 helper still installed as last-resort fallback during M-recover stabilization period (until n≥10 PROVEN). Operator can also issue manual `echo 1 > /sys/bus/pci/devices/.../reset` as final fallback.

6. **NEW (2026-05-06 15:47): WHY does the first `rm_init_adapter` call fail on cold-cold-boot?** — Diagnostic shows PMC_BOOT_0 transiently reads `0x00000000` immediately after the first failure (vs `0x1b2000a1` at every other read site). This points to a **bus state transient during initial GSP boot** — not WPR2 itself. Solving this would PREVENT the WPR2-stuck cycle entirely (preventive lever) vs Commit 3 which is reactive. Tracked as **H14** in the hypothesis ledger. Not a blocker for Commit 3 — recovery is still needed even if prevention is added later (different failure modes will eventually trigger it). Investigate once Commit 3 is PROVEN.

7. **NEW — slot_reset complexity for runtime AER path** — re-initialising RM after a kernel-driven bus reset requires re-running parts of `RmInitAdapter`, which is heavyweight RM-side code. The simplest stage-1 implementation:
   - error_detected returns NEED_RESET (when enable=1)
   - mmio_enabled: read `NV_PMC_BOOT_0`, verify it's not 0xFFFFFFFF
   - slot_reset: trigger an unbind/rebind cycle via `device_release_driver` + scheduled re-add (kernel re-runs probe normally, picking up where probe-time path leaves off)
   - resume: clear `PDB_PROP_GPU_IS_LOST`, return success
   This means the runtime AER path REUSES the probe-time path's recovery code by triggering a re-probe. Both paths converge on the same probe-time code that will (post-implementation) include WPR2 detection + auto-recovery — so any state leftover from a runtime fault gets handled identically to a boot-time WPR2 stuck.
