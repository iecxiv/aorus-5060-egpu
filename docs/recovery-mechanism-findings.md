# Recovery mechanism findings — 2026-05-04 evening

> Empirical results from probing what mechanisms can recover a "lost"
> GPU on this hardware (post-Lever-Q test, GPU in
> `pci_channel_io_perm_failure` state).
>
> **2026-05-06 09:14 — IMPORTANT CORRECTION.** The original claim that
> bare FLR alone clears WPR2 is REJECTED for the cold-boot WPR2-stuck
> case. Today's evidence:
>
> - `pcie_reset_flr` (NVIDIA's `os_pci_trigger_flr`): forced through
>   pending transactions, returned "PCI FLR might have failed", WPR2
>   still up.
> - `pci_reset_function` (this doc's claim): returns `-ENOTTY` from
>   probe context (`reset_fn=0` per kernel's pci_reset_supported check).
>   **The "echo 1 > /sys/.../reset works" claim below describes the
>   case where the GPU was bound and working when reset triggered.
>   It does NOT cover the cold-boot WPR2-stuck case.**
> - **What DOES work**: full sequence `remove + rescan + reset`
>   (sysfs). The remove+rescan refreshes the kernel's reset-method
>   detection; subsequent reset succeeds.
>
> **Updated outcome:** FLR alone is a recovery mechanism for the
> "GPU bound + working" case (covered by Phase 4 M-recover). For
> cold-boot WPR2-stuck, the full remove+rescan+reset is required
> (covered by Lever R Tier 1 v3 — L4 userspace helper). See
> [`lever-R-design.md`](./lever-R-design.md) and
> [`reliability-hypothesis-ledger.md`](./reliability-hypothesis-ledger.md) H13.

---

## Original 2026-05-04 outcome (preserved for context)

The original outcome below was correct for its specific test context
(GPU was working, deliberate reset to validate recovery path). The
correction above captures findings from a DIFFERENT scenario
(cold-boot WPR2-stuck-from-prior-session) where the simpler mechanism
is insufficient.

> Function Level Reset (FLR) via sysfs is a reliable recovery mechanism
> on this hardware FOR THE GPU-BOUND-AND-WORKING CASE. This dramatically
> simplifies Phase 4 (M-recover) design vs the original assumption that
> we'd need to write the full PEX Reset and Recovery state machine from
> scratch.

---

## Test context

Test `lite-2026-05-04-181844` had just completed, with Lever Q-active
having fired and set the GPU to `pci_channel_io_perm_failure` state:

- `nvidia-smi`: "Unable to determine the device handle ... Unknown Error"
- Driver internally: `PDB_PROP_GPU_IS_LOST=1`
- Kernel: `pci_dev_is_disconnected(pdev) == true`
- Q-passive short-circuiting all subsequent MMIO reads with `0xFFFFFFFF`
- ollama runner had panicked cleanly, host fully responsive

The eGPU's PCIe link was still electrically present (lspci -s 04:00.0
showed the device existed), but software-state was "permanently failed"
from the kernel's view.

We were about to begin Step A (back-to-back inference iterations) and
realised: **between iterations, how do we re-init?** Cold boot is too
slow. The user asked whether the system could be re-initialised without
a reboot.

---

## Experiment 1: PCI remove + rescan

**Hypothesis:** if the failure is purely software-state, removing the
device from the kernel's PCI tree and rescanning would let us re-init
with a fresh `pci_dev`.

**Procedure:**
```bash
echo 1 > /sys/bus/pci/devices/0000:04:00.0/remove
echo 1 > /sys/bus/pci/rescan
```

### What worked

- ✅ Device removed cleanly (sysfs entry gone, lspci no longer lists)
- ✅ Cleanup path ran (Lever O fired in `_issueRpcAndWait` short-circuit;
  `iovaspaceDestruct` complaint about 2 left-over IOVA mappings)
- ✅ Rescan re-discovered the device
- ✅ Driver re-bound (`/sys/bus/pci/devices/.../driver` → nvidia)
- ✅ BARs re-assigned cleanly (BAR0 16 MiB, BAR1 32 GiB)
- ✅ Linux PCI subsystem state fresh (`pci_dev_is_disconnected` cleared)

### What failed

```
[921.622] NVRM: GPU0 _kgspBootGspRm: unexpected WPR2 already up,
                cannot proceed with booting GSP
[921.622] NVRM: GPU0 _kgspBootGspRm: (the GPU is likely in a bad state
                and may need to be reset)
[921.622] NVRM: GPU0 RmInitAdapter: Cannot initialize GSP firmware RM
[921.623] NVRM: GPU 0000:04:00.0: RmInitAdapter failed! (0x62:0x40:2192)
```

**WPR2 = "Write Protected Region 2"** — a memory region the GPU's GSP
firmware locks against further writes once configured. It survives
PCI-layer remove+rescan because GSP's internal state is preserved on
the GPU silicon, not in driver memory.

`RmInitAdapter` is the higher-level NVIDIA driver init function. It
tries to upload a fresh GSP firmware image, but GSP refuses because
WPR2 is "already up" from the PRIOR boot's GSP. Without a clean GSP
load, no driver-internal state can be initialised. `nvidia-smi` reports
"No devices were found".

### Conclusion of Experiment 1

PCI remove+rescan is **insufficient** for re-init on this stack. The
GPU's silicon-level state needs an actual hardware reset, not just
kernel-level state reset. The driver itself acknowledged this in the
log: *"the GPU is likely in a bad state and may need to be reset."*

---

## Experiment 2: Function Level Reset (FLR) via sysfs

**Hypothesis:** if Linux's PCI subsystem can drive an FLR on the GPU,
that's a hardware-level reset — should clear GSP's WPR2 state.

**Pre-check:**
```bash
$ cat /sys/bus/pci/devices/0000:04:00.0/reset_method
flr
```

The kernel knows the device supports FLR.

**Procedure:**
```bash
echo 1 > /sys/bus/pci/devices/0000:04:00.0/reset
```

### What worked — everything

```
[995.755] nvidia 0000:04:00.0: resetting
[995.863] nvidia 0000:04:00.0: reset done   (~100ms total)
```

After ~3 seconds:
```
$ sudo nvidia-smi
+-----------------------------------------------------------------+
| NVIDIA-SMI 595.71.05    Driver Version: 595.71.05    CUDA: 13.2 |
+-----------------------------------------------------------------+
|   0  NVIDIA GeForce RTX 5090        On  |   00000000:04:00.0    |
| 30%   36C    P0    60W /  575W      |   0MiB /  32607MiB        |
+-----------------------------------------------------------------+
```

**The GPU came back fully functional.** Full BAR1 (32607 MiB), driver
operational, lspci clean (no UE flags).

### Side-effects observed

```
[999.155] NVRM: !rmapiLockIsOwner() @ rmapi.c:563 (×8)
```

Some assertion warnings fired during the post-reset re-init, related
to lock ownership of the RM API. These appear to be benign — they
represent stale lock contexts from the pre-reset thread state, but
nvidia-smi succeeded immediately after.

### Conclusion of Experiment 2

**FLR via sysfs reset is a complete recovery path.** Single shell
command, ~100ms reset, GPU fully restored. No reboot needed. No
manual driver reload needed.

---

## Implications for Phase 4 (M-recover) design

The original framing of Phase 4 assumed we'd write the full
`pci_error_handlers` state machine from scratch — `mmio_enabled`,
`slot_reset`, `resume` — including driving the actual hardware reset
ourselves. That was multi-week engineering.

**The experiments above show a much simpler path.** Linux's PCI
subsystem already has reset infrastructure that works on this hardware.
M-recover becomes:

```c
// In nv-pci.c (M-base + M-recover):

static pci_ers_result_t nv_pci_error_detected(struct pci_dev *pdev,
                                              pci_channel_state_t state)
{
    // CHANGE FROM M-base: return NEED_RESET instead of DISCONNECT
    // The kernel will then call our slot_reset callback after FLR.
    return PCI_ERS_RESULT_NEED_RESET;
}

static pci_ers_result_t nv_pci_slot_reset(struct pci_dev *pdev)
{
    // Kernel has already triggered the FLR via pci_reset_function()
    // before calling us. The GPU is now in fresh hardware state.
    
    // Re-run the parts of probe that bring the GPU back to operational:
    pci_restore_state(pdev);
    
    // Drive the equivalent of RmInitAdapter so the driver state
    // matches the freshly-reset GPU.
    // (specifics TBD during implementation)
    
    return PCI_ERS_RESULT_RECOVERED;
}

static void nv_pci_resume(struct pci_dev *pdev)
{
    nv_state_t *nv = pci_get_drvdata(pdev);
    OBJGPU *pGpu = ...;
    
    // Clear the loss state — Q-passive will stop short-circuiting
    pGpu->setProperty(pGpu, PDB_PROP_GPU_IS_LOST, NV_FALSE);
    pGpu->setProperty(pGpu, PDB_PROP_GPU_IS_CONNECTED, NV_TRUE);
    
    // Notify userspace via uevent (Phase 6 enhancement)
}
```

Plus the `error_handlers` struct gains the new callbacks:
```c
static const struct pci_error_handlers nv_pci_err_handlers = {
    .error_detected = nv_pci_error_detected,
    .slot_reset     = nv_pci_slot_reset,    // NEW
    .resume         = nv_pci_resume,        // NEW
};
```

**Estimated engineering: 1-3 days** (instead of the 2-3 weeks I
originally projected). The hardest piece is driving "the equivalent of
RmInitAdapter" cleanly from `slot_reset`'s context — but the existing
init paths exist; we just need to call them in the right order.

### Concerns to address during implementation

1. **Locking:** `slot_reset` is called by the kernel with the device
   lock held. The `!rmapiLockIsOwner()` warnings observed in the FLR
   experiment suggest the driver expects to acquire RM locks fresh.
   Need to confirm RM init can run cleanly in this context.

2. **GSP firmware re-upload from slot_reset:** the existing
   `RmInitAdapter` includes GSP boot. Need to verify it can run from
   the slot_reset callback context (kthread vs ioctl context).

3. **Stale driver state cleanup:** before slot_reset, the GPU was
   declared lost. Various objects (channels, allocations, contexts)
   are in zombie state. Slot_reset needs to clean them up before
   re-init, OR resume needs to invalidate them so user-space re-creates.

4. **Userspace coordination:** when M-recover succeeds, in-flight
   ioctls return errors. Should we emit a uevent so apps know to retry?
   Phase 6 polish, not critical for M-recover MVP.

---

## Implications for Step A (extended testing)

**Step A is now practical.** With FLR-between-iterations, we can run:

```bash
for i in $(seq 1 N); do
    /root/ollama/tools/run-with-telemetry.sh
    # If Q-active fired, do FLR
    if dmesg | grep -q 'AORUS Lever Q-active'; then
        sudo bash -c 'echo 1 > /sys/bus/pci/devices/0000:04:00.0/reset'
        sleep 5
    fi
    sleep 3
done
```

Total cycle time ~30s per iteration (10s test + 5s reset + 15s reload).
N=20 iterations in ~10 minutes.

**Step A's purpose** — measuring inference success-rate variance —
becomes definitively answerable.

---

## Implications for the broader hypothesis

> "If CUDA init fails 100% of the time, recovery just gives us another
> failure"

The user posed this concern. The experiments above clarify the answer:

- **The GPU itself is fully functional after FLR.** WPR2 is cleared,
  GSP boots cleanly, BARs are healthy, registers respond.
- **What we don't know:** whether a fresh GPU state will ALSO fail
  CUDA init, or whether some state-dependent variance lets occasional
  attempts succeed.

Step A answers this directly. The result will be one of:

1. **0% success after N FLR cycles** — failure is deterministic on
   this Linux/driver combination → M-recover delivers no value;
   pivot fully to L1 trigger investigation.
2. **Some success rate (1%-99%)** — variance exists. M-recover converts
   the failure pattern from "0% success forever" to "X% per attempt
   with auto-retry," delivering real value.

Either result is informative and shapes the rest of the roadmap.

---

## What we've also learned about the bug class

The "WPR2 already up" message after a soft re-init is a STRONG signal
about the failure mechanism:

- GSP firmware **booted successfully** at original probe (because we
  saw all our patches operating, GPU was responsive)
- During CUDA workload, something caused the bus failure
- After Q-active declared loss, kernel's view of the device was reset
- BUT GSP's silicon-level state was preserved (WPR2 still configured)

This implies the **GPU silicon survived the failure event** — it was
the kernel/driver/PCIe-link state that broke, not the GPU itself. A
hardware-level reset (FLR) clears the silicon back to a known state
where re-init works.

This is consistent with the WSL2 control: the same hardware works
under Windows. Whatever Linux is doing during CUDA workload triggers
the failure, but the failure is *recoverable* with a reset — not
catastrophic damage.

This raises hope for Phase 4 having genuine value. If the GPU silicon
recovers reliably from FLR, even if every workload eventually triggers
the bug, an inference workload could complete *between failures* if:
- the bug-trigger threshold is timed (e.g., minutes of CUDA work) — workload finishes first
- the bug-trigger is rare on small workloads but common on large
- recovery is fast enough that retry is invisible to the user

Step A measures these. Phase 4 acts on the result.

---

## Production validation (2026-05-04 night)

The `remove + rescan + FLR` sequence was wired into
`loop-with-flr.sh::trigger_flr()` and used for inter-iteration
recovery during the staged Step A test. Sequence execution:

```bash
# trigger_flr() body:
echo 1 > /sys/bus/pci/devices/0000:04:00.0/remove
sleep 2
echo 1 > /sys/bus/pci/rescan
sleep 3
echo 1 > /sys/bus/pci/devices/0000:04:00.0/reset
sleep 5
# verify nvidia-smi works
```

In tonight's 13-iteration test, FLR was not actually needed (no
failures in any iter). But the sequence was validated earlier in
the day (test `loop-2026-05-04-194338`) where it successfully
recovered the GPU after Lever Q-active fired and declared the
device lost.

Confirmed working in production:
- ✅ Pre-FLR state captured (lspci, AER counters, dev nodes)
- ✅ Remove triggers nv_pci_remove cleanly
- ✅ Rescan re-discovers, nv_pci_probe runs, BARs assigned
- ✅ FLR clears GSP WPR2 stuck state
- ✅ Post-FLR nvidia-smi works
- ✅ Subsequent inferences work normally

**Phase 4 (M-recover)** is now well-scoped: just wire this same
sequence into `pci_error_handlers` callbacks. Estimated 1-3 days
engineering.

## Cross-references

- `stability-roadmap.md` — Phase 4 description (now reflects simplified scope)
- `performance-investigation.md` — Phase 7 design with WSL2 parity context
- `lever-Q-design.md` — Phase 1b design (verified working when bug fires)
- Test artifacts:
  - `archive/lite-2026-05-04-181844/` — test that triggered this investigation
  - `archive/loop-2026-05-04-203729..204701/` — staged test using FLR sequence
    (no FLR needed in 13/13 iters; sequence still wired and tested earlier)
