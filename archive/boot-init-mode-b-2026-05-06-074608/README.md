# Boot-init failure — 2026-05-06 07:46:14 forensic dossier

> **Captured 2026-05-06 07:54** while system was in degraded post-failure state.
> Dossier created BEFORE any reboot to preserve maximum forensic data.
> Cross-references: `docs/reliability-hypothesis-ledger.md` H13;
> `docs/freeze-2026-05-05-investigation.md`.

## TL;DR

**This is not a fresh boot failure — it is the persistent consequence of yesterday's
session leaving the GPU's GSP firmware secure region (WPR2) stuck.** Today's
nvidia.ko bind found WPR2 already up, couldn't re-initialise GSP, and bailed
out with `RmInitAdapter failed`. Subsequent retry attempts hit the same wall.

## The chain of events at 07:46:14

```
07:46:13  nvidia 0000:04:00.0: enabling device (0000 -> 0003)
07:46:13  NVRM: loading NVIDIA UNIX Open Kernel Module 595.71.05
07:46:14  NVRM: AORUS Lever Q-active: dead-bus DETECTED via post-read sanity check
07:46:14  NVRM: AORUS Lever Q-passive: dead-bus state detected, short-circuiting MMIO
07:46:14  NVRM: nvAssertFailed: expectedFunc == pHistoryEntry->function @ kernel_gsp.c:2447
07:46:14  NVRM: _kgspLogRpcSanityCheckFailure: GPU0 sanity check failed 0xf
            waiting for RPC response from GSP.
            Expected function 4097 (GSP_INIT_DONE) sequence 0.
            GSP RPC buffer contains function 4124 (GSP_LOCKDOWN_NOTICE) sequence 0.
07:46:14  NVRM: GPU0 RPC history (CPU -> GSP): 73 (SET_REGISTRY), 72 (GSP_SET_SYSTEM_INFO)
07:46:14  NVRM: GPU0 RPC event history (CPU <- GSP): 8× GSP_LOCKDOWN_NOTICE (function 4124)
07:46:14  NVRM: nvCheckOkFailed: GPU lost from the bus [NV_ERR_GPU_IS_LOST]
            from rpcRecvPoll(GSP_INIT_DONE) @ kernel_gsp.c:6104
07:46:14  NVRM: nvAssertOkFailed: from kgspWaitForRmInitDone @ kernel_gsp_gh100.c:1107
07:46:14  NVRM: _kgspBootGspRm: unexpected WPR2 already up, cannot proceed with booting GSP
07:46:14  NVRM: _kgspBootGspRm: (the GPU is likely in a bad state and may need to be reset)
07:46:14  NVRM: RmInitAdapter: Cannot initialize GSP firmware RM
07:46:14  NVRM: GPU0 iovaspaceDestruct_IMPL: 1 left-over mappings in IOVAS 0x400
07:46:14  NVRM: GPU 0000:04:00.0: RmInitAdapter failed! (0x62:0x40:2192)
```

Subsequent retries (07:46:20, 07:49:49, 07:50:51) all hit the same WPR2-stuck wall.

## What worked

- **Q-active fired correctly** — our patch caught the bus drop during init MMIO traffic
- **Q-passive short-circuited** subsequent MMIO reads
- **Cleanup levers (N, O) ran cleanly** — no host wedge despite the failure
- **System remained alive** — fully usable except for nvidia-smi which can't see the GPU
- **AER counters all zero** — no PCIe AER fired (the failure was at GSP RPC layer, not bus-error layer)

## What didn't help

- **Q-watchdog kthread** wasn't yet spawned at the moment of failure (it spawns at the END of `nv_pci_probe`, after `rm_enable_dynamic_power_management`). Real design gap.
- **CTV=2** had no effect on this failure (CTV is applied AFTER driver bind via systemd unit; failure happened at bind time)
- **Lever O** would have short-circuited GSP RPCs after PDB_PROP_GPU_IS_LOST was set, but the first GSP_INIT_DONE RPC ran natively before any lost-state was set. This is "first failure goes through, subsequent calls are fast-fail" — Lever O did fire on subsequent retries.

## Root cause analysis

`_kgspBootGspRm`'s "unexpected WPR2 already up" is the load-bearing diagnosis. WPR2 is the GSP firmware's secure operating region. Per `recovery-mechanism-findings.md`, it persists across:
- Reboots (today proved this)
- PCI remove+rescan (without explicit FLR)
- Driver unload+reload

WPR2 only clears via:
- Function Level Reset (FLR) via `/sys/.../reset` — empirically reliable
- Hardware power cycle (full eGPU AC unplug + 60s wait)

**Today's boot found WPR2 left over from yesterday's session.** The shutdown sequence didn't clear it. Driver can't re-init GSP without reset.

## Why didn't yesterday's poweroff clear WPR2?

This is the deeper question. Hypotheses:
- The eGPU box has its own power management — unplugging the host-side TB cable may not power-cycle the GPU
- Yesterday's session left the GPU in declared-lost state at shutdown; cleanup sequence may have skipped WPR2 teardown
- BIOS/firmware doesn't FLR at POST on TB-attached devices
- The "warm reboot" preserves PCIe device state (which it sometimes does on TB)

## The fix

**Direct actionable change**: detect WPR2-stuck at probe entry, FLR, retry. Concretely:

1. In `nv_pci_probe` (or wherever the early GSP probe happens), read the GSP WPR2 status register
2. If WPR2 is already up:
   - Log a marker (`AORUS Lever R: WPR2-stuck detected at probe — triggering FLR`)
   - Call `pci_reset_function(pci_dev)` (kernel-managed FLR)
   - Retry GSP init
3. If WPR2 is still stuck after FLR, fall back to current failure path

This is **Lever R** — a new patch in the same family as I/N/O. L1 sovereign, focused, ~30 lines.

Alternative: a userspace boot-time helper (L4) that reads WPR2 status and FLRs the GPU before nvidia-persistenced runs. Easier to implement, lower fork debt, but less robust.

## Cross-references in this dossier

| File | Contents |
|---|---|
| `00-meta.txt` | Boot/uptime/driver versions/capture timestamp |
| `01-dmesg-full.txt` | Kernel ring buffer (mostly empty — rotated) |
| `02-journalctl-kernel-b0.txt` | Full kernel journal this boot — **THE primary forensic source** |
| `02-journalctl-all-b0.txt` | Full journal including userspace |
| `03-nvrm-aer-aorus-lines.txt` | NVRM-filtered lines — easier reading |
| `04-pcie-*.txt` | Per-device PCIe state (lspci -vvv, AER counters, link state) |
| `05-nvidia-driver-state.txt` | Module info, lsmod, /sys/module/nvidia/parameters |
| `06-process-and-systemd-state.txt` | Q-watchdog kthread, persistenced, ollama state |
| `07-nvidia-smi-failure.txt` | nvidia-smi failure mode |
| `08-boot-timing.txt` | Service activation timestamps + NVRM timing |
| `09-status-sh.txt` | Full status.sh output (DEGRADED) |
| `10-system-context.txt` | cmdline + sysctls + dmidecode + boltctl |

## Implications for the reliability roadmap

This finding shifts the priority of Phase 4 (M-recover) and adds a new Lever R:

- **Lever R (new)**: Boot-time WPR2-stuck detection + auto-FLR. This is THE
  fix for this specific failure class. Captured as new hypothesis in ledger.
- **Phase 4 M-recover**: Already in scope; this discovery validates that
  in-driver recovery is the right destination — same pci_reset_function call
  that solves runtime Mode A also solves boot-init WPR2-stuck.
- **Lever Q-watchdog spawn timing**: Should be moved earlier in nv_pci_probe
  if we want it to catch boot-init failures.
- **Yesterday's "5/5 reliability" was indeed a hot-stack illusion** — once
  the GPU has had a clean session, subsequent iters in the same boot succeed
  because the GSP is already happily running. Cold-cold-boot reveals the
  yesterday-haunting-today bug.
