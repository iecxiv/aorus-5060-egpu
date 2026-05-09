# Lever M-recover Commit 3 hardening — implementation handover

**For:** Future-self (or anyone) resuming Patch 0024 implementation
**Created:** 2026-05-08
**Status:** DESIGN COMPLETE; IMPLEMENTATION NOT STARTED (clean baseline)
**Related:** Task #62 (Phase 4 in_progress), Task #103 (Patch 0020 hardening pending)

## TL;DR

The design is complete. The source tree is clean (post-0023). To resume:
1. Read `docs/lever-m-recover-commit3-hardening-design.md` (the design)
2. Implement against §Code surface table (~240 LoC C across 4 files + ~105 LoC bash + udev)
3. Build via `tools/build-patched-driver.sh`
4. Run test plan §Phase 1-5 from the design

## What's already done (no need to redo)

| Item | Location |
|---|---|
| Canonical 28K design doc | `docs/lever-M-recover-design.md` |
| **Hardening-specific design** (this implementation's blueprint) | `docs/lever-m-recover-commit3-hardening-design.md` |
| Scaffolding (Commit 1) — struct, module params, sysfs counters, no-op work handler | Patch `0016-Lever-M-recover-scaffolding.patch` already applied |
| Probe-time WPR2 detection (Commit 2 — FALSIFIED but kept) | Patch `0017-Lever-M-recover-probe-time-WPR2-detection.patch` already applied |
| 4-point DIAG telemetry (probe-end / startdev-entry / pre-rmInit / post-rmInit-{OK,FAIL}) | Patch `0018-Lever-M-recover-diagnostic-telemetry.patch` already applied |
| The proven L4 recovery sequence (reference for in-driver port) | `usr/local/sbin/aorus-egpu-wpr2-recovery` |
| Forensic dossier of the 2026-05-06 storm (the H15 hardening evidence) | `archive/commit3-recovery-loop-2026-05-06-161429/` |

## Source tree state on handover (confirmed 2026-05-08)

| File | State |
|---|---|
| `kernel-open/nvidia/nv-lever-m-recover.h` | **Clean post-0023.** No Patch 0024 changes. (Earlier session attempted struct-field additions but reverted because changing `attempt_count` from `unsigned int` → `atomic_t` broke an existing assignment at line 718 of nv-lever-m-recover.c.) |
| `kernel-open/nvidia/nv-lever-m-recover.c` | Clean post-0023. |
| `kernel-open/nvidia/nv-pci.c` | Clean post-0023. Mode B telemetry S1 trigger call already in `nv_pci_error_detected()` from patch 0023. |
| `kernel-open/nvidia/nv.c` | Clean post-0023. Lever M DIAG calls in `nv_start_device()` from existing patches; the post-rmInit-FAIL DIAG site at line ~1546 is where the new trigger hook goes. |
| `make modules` | **Builds clean.** Verified 2026-05-08 after revert. |

## Resolved design questions (don't re-ask)

From the design doc §Open design questions:

| Q | Resolution |
|---|---|
| Should kill-switch file path be configurable? | **No** — hardcode `/var/lib/aorus-egpu/lever-m-killswitch` for v1. Add cmdline knob later only if needed. |
| uevent string standardization | **Use our own namespace:** `AORUS_GPU_STATE=READY/RECOVERING/PERMANENT_FAIL`. Subscribers can match on the `AORUS_GPU_STATE` key. |
| Retire patch 0017 (falsified Commit 2)? | **Keep in tree** — falsified-but-documented historical record (per project convention with falsified hypotheses; matches `feedback_check_existing_guards_before_cmdline_experiments`). |

## Critical knowledge — DO NOT REPEAT THESE MISTAKES

### Mistake 1 (2026-05-06 16:14): Recovery storm
The original Commit 3 (patch 0019, since reverted) caused a 21-attempt recovery storm. **The 4 H15 hardening fixes are mandatory before any default-on deployment:**
- H1: MaxAttempts gate (compare BEFORE scheduling)
- H2: Rate-limit (min 30s between attempts)
- H3: Kill-switch persistence (file + udev rule, survives modprobe -r)
- H4: Smarter error_detected (don't return DISCONNECT when in recovery)

### Mistake 2 (today): Struct field type change
Changing `attempt_count` from `unsigned int` to `atomic_t` requires updating ALL callsites. The existing scaffolding (patch 0016, line 718 of nv-lever-m-recover.c) does scalar `lm->attempt_count = 0;` which doesn't compile against atomic_t.
**Mitigation:** when changing struct field types, grep + update ALL callers in the same edit cycle. Don't ship a header change without the .c changes that go with it.

### Default-on safety
Per the storm postmortem: **default `NVreg_AorusLeverMRecoverEnable=0` for the first build of patch 0024.** Validate with `cmdline NVreg_AorusLeverMRecoverEnable=1` overrides BEFORE flipping the default to 1. Per design doc Phase 5: only enable by default after n≥10 PROVEN cold-cold-boot recoveries.

## Implementation order — concrete steps

This sequence minimizes risk by separating low-risk plumbing from high-risk PCI-subsystem code:

### Step 1 — header changes (low risk; pure declarations)
**File:** `kernel-open/nvidia/nv-lever-m-recover.h`
- Change `attempt_count` from `unsigned int` to `atomic_t`
- Add new fields: `pdev_for_work`, possibly `last_attempt_jiffies` if separate from `last_fire_jiffies`
- Add prototypes for `aorus_lever_m_trigger_post_rminit_fail()`, `aorus_lever_m_emit_uevent()`, `aorus_lever_m_slot_reset()`, `aorus_lever_m_slot_reset_resume()`

**Concurrent edit required (don't ship header alone):**
- Grep nv-lever-m-recover.c for `attempt_count` and update assignments to `atomic_set(&...)`/`atomic_inc(&...)`/`atomic_read(&...)`

### Step 2 — module params (low risk; declarations + parsing)
**File:** `kernel-open/nvidia/nv-lever-m-recover.c`
- Add 2 new module params with `module_param` + `MODULE_PARM_DESC`:
  - `NVreg_AorusLeverMMinAttemptIntervalMs` default 30000
  - `NVreg_AorusLeverMSurrenderResetSec` default 300
- **CRITICAL:** flip `NVreg_AorusLeverMRecoverEnable` default from 1 to 0 for v1

### Step 3 — kill-switch file read (medium risk; FS interaction at module init)
**File:** `kernel-open/nvidia/nv-lever-m-recover.c`
- Add static helper `aorus_lever_m_read_killswitch_file()` using `kernel_read_file_from_path()` with hard size limit (e.g., 16 bytes)
- Path: `/var/lib/aorus-egpu/lever-m-killswitch`
- Returns: 0 (engaged), 1 (released), -1 (read error/absent)
- Call from `aorus_lever_m_recover_init()` and override `NVreg_AorusLeverMRecoverEnable=0` if file content is "0\n"

### Step 4 — uevent helper (low risk; well-defined kernel API)
**File:** `kernel-open/nvidia/nv-lever-m-recover.c`
- Add `aorus_lever_m_emit_uevent(struct pci_dev *pdev, const char *state)` using `kobject_uevent_env(&pdev->dev.kobj, KOBJ_CHANGE, env)` with env array: `["AORUS_GPU_STATE=<state>", NULL]`

### Step 5 — work handler (HIGH RISK; PCI subsystem)
**File:** `kernel-open/nvidia/nv-lever-m-recover.c`
- Replace the no-op stub `aorus_lever_m_reset_work_handler` with the real recovery action:
  ```
  acquire pci_lock_rescan_remove
  pci_reset_bus(pci_upstream_bridge(pdev))   // bus reset on parent's secondary bus
  release pci_lock_rescan_remove
  msleep(NVreg_AorusLeverMResetSettleMs)
  emit uevent: AORUS_GPU_STATE=RECOVERING (kernel will rebind via slot_reset/resume callbacks)
  ```
- Use `pci_dev_get(pdev)` at trigger, `pci_dev_put(pdev)` at handler completion (refcount management)
- Must handle the case where bus reset fails (log, emit PERMANENT_FAIL, increment surrender_count)

### Step 6 — post-rmInit-FAIL trigger (medium risk; in-driver hook point)
**File:** `kernel-open/nvidia/nv.c` line ~1546
**Site:** Right after `aorus_lever_m_diag_dump(nvl, "post-rmInit-FAIL");` and before `rc = -EIO`.
- Add new `aorus_lever_m_trigger_post_rminit_fail(nvl)` call
- That function:
  - Reads WPR2 register (use existing helper from patch 0017)
  - If WPR2 == 0: return 0 (not stuck, fall through to normal error path)
  - Else: enable check + rate-limit gate + MaxAttempts gate + schedule_work + return 0
- Caller continues to `rc = -EIO; goto failed_release_irq;` regardless — recovery happens async

### Step 7 — slot_reset + resume callbacks (medium risk; well-defined API)
**File:** `kernel-open/nvidia/nv-pci.c`
- Implement `nv_pci_slot_reset(pdev)`: read PMC_BOOT_0 via temporary ioremap; if 0xffffffff → DISCONNECT; else RECOVERED
- Implement `nv_pci_resume(pdev)`: increment success_count; reset attempt_count to 0; emit AORUS_GPU_STATE=READY uevent
- Add both to `nv_pci_err_handlers` struct

### Step 8 — smarter error_detected (medium risk; replaces existing return)
**File:** `kernel-open/nvidia/nv-pci.c` `nv_pci_error_detected()` function
- Implement the H4 truth table:
  - Enable=0 → DISCONNECT (M-base)
  - Enable=1 + attempts < Max + rate-limit OK → NEED_RESET
  - Enable=1 + attempts >= Max → DISCONNECT + PERMANENT_FAIL uevent + surrender_count++
  - Enable=1 + rate-limited → DISCONNECT (defer to next fire)

### Step 9 — userspace CLI + udev rule (low risk; bash + sysfs)
**Files (in repo, not in driver):**
- `usr/local/sbin/aorus-egpu-lever-m` — CLI: `enable`, `disable`, `status` subcommands
- `usr/local/sbin/aorus-egpu-lever-m-killswitch-restore` — udev RUN+= helper
- `etc/udev/rules.d/82-aorus-egpu-lever-m-killswitch.rules` — triggers restore on nvidia module add

### Step 10 — snapshot + regen patch + build + install
- Snapshot all 4 modified driver files to `/tmp/0024-snapshot/`
- Reset source via `git checkout -- . && git clean -fd kernel-open/ src/`
- Reapply patches 0001-0023
- `diff -u` snapshot vs source → generate `patches/0024-Lever-M-recover-Commit3-hardening.patch`
- `git apply --check` then `git apply`
- `tools/build-patched-driver.sh`
- Reboot to test

## Test plan (from design doc, recap)

| Phase | What | Pass criterion |
|---|---|---|
| 1 | Build verification | DKMS rebuild OK; modinfo shows new params |
| 2 | Cold-boot baseline | Boot with Enable=0; behaviour matches today (M-base + L4 helper) |
| 3 | Manual trigger | Use NVreg_AorusLeverMTestForceTrigger=1 (NEW for test) to deliberately invoke recovery |
| 4 | H15 hardening verification | One discrete test per fix (H1/H2/H3/H4) |
| 5 | n≥10 PROVEN | Required before retiring `aorus-egpu-wpr2-recovery.service` |

## Rollback path

If patch 0024 introduces issues:
1. **Per-boot disable:** add `NVreg_AorusLeverMRecoverEnable=0` to cmdline
2. **Module-level revert:** `cp /lib/modules/$(uname -r)/extra/nvidia.ko.xz.dnf-stock-* /lib/modules/$(uname -r)/extra/nvidia.ko.xz; depmod -a; reboot`
3. **Source-tree revert:** remove patch from `patches/0024-*.patch`, rerun `tools/build-patched-driver.sh`
4. **Persistent disable:** `aorus-egpu-lever-m disable` (writes file)

## Cross-references

- Hardening design (the blueprint): `docs/lever-m-recover-commit3-hardening-design.md`
- Canonical M-recover design: `docs/lever-M-recover-design.md`
- L4 helper reference: `usr/local/sbin/aorus-egpu-wpr2-recovery`
- Storm forensic: `archive/commit3-recovery-loop-2026-05-06-161429/`
- Hypothesis ledger: H13 (recovery reliability), H15 (storm)
- Service retirement queue: `docs/service-retirement-roadmap.md` (`wpr2-recovery.service` retires on n≥10 PROVEN)
- Memory feedback: `feedback_targeted_comprehensive_patches.md`, `feedback_native_in_driver_hardening.md`
- Tasks: #62 in_progress, #103 pending

## Estimated remaining effort

| Phase | Effort |
|---|---|
| Steps 1-9 implementation | ~1.5-2 hours focused C + bash |
| Step 10 snapshot/build/install cycle | ~10 min (well-rehearsed pattern) |
| Phase 1 build verification | ~5 min |
| Phase 2 cold-boot baseline (n=2-3) | ~10 min (multiple reboots) |
| Phase 3 manual trigger (after `TestForceTrigger` flag added) | ~30 min |
| Phase 4 H15 hardening verification | ~30 min (4 separate small tests) |
| Phase 5 n≥10 PROVEN cold-cold-boots | Multi-session (~hour each) |

**Total to PROVEN:** several focused sessions. Implementation alone (steps 1-10) is ~2-3 hours fresh.
