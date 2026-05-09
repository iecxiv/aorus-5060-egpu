# Lever Q — MMIO read protection (Phase 1b design)

> Design document for the Phase 1b deliverable from
> [`stability-roadmap.md`](./stability-roadmap.md).
>
> **Goal:** convert Mode B (silent catastrophic freeze) to Mode A
> (graceful degradation with full diagnostics) deterministically.
>
> **Status:** DESIGN COMPLETE, audit complete, ready for implementation.
>
> **Version target:** bump to `595.71.05-aorus.2` (clear differentiation
> from the .1 build that ships Levers I, J-2, M-base, N, O, P-probe).
>
> **Updates:**
> - 2026-05-04 initial — design draft with 3 open questions
> - 2026-05-04 (later) — extensive source-code audit completed; all
>   open questions resolved; patch surface finalised; implementation
>   plan revised to 5 incremental patches.

---

## Problem recap

In Mode B failures (3 of 5 lite-test runs on 2026-05-04), the host wedges
within ~250 ms of CUDA workload start, with **zero AER messages**, **zero
NVRM activity** beyond the module-load message, and **zero AORUS markers**
firing. Ollama's runner shows ~100% CPU on a single core in pidstat right
before the freeze — busy-spinning in some loop.

The hypothesis: **a driver thread is stuck in an MMIO register read on a
collapsed PCIe link.** The TB tunnel went down at the link layer (not the
transaction layer), so AER never fires, completion timeout may take
seconds-to-never, and the calling thread stalls indefinitely. Other
threads can't preempt it cleanly because the stalled CPU isn't executing
schedulable code.

Our existing Mode-A patches (Levers I, J-2, N, O) are gated on
`PDB_PROP_GPU_IS_LOST` being set, which requires the driver to detect the
loss via a sanity check, which requires the sanity check thread to *run*,
which requires the kernel scheduler to make forward progress, which
requires no thread to be CPU-stalled on a hung MMIO. That chain breaks in
Mode B.

---

## What we found in source review

### The MMIO read chokepoint

`osDevReadReg032` in `src/nvidia/arch/nvalloc/unix/src/os.c:1909` is the
**single funnel** for almost all CPU-side MMIO register reads in the
NVIDIA open module. The high-level macros (`GPU_REG_RD32`,
`REG_INST_RD32`, etc.) all call into this function.

```c
NvU32 osDevReadReg032(OBJGPU *pGpu, DEVICE_MAPPING *pMapping, NvU32 thisAddress)
{
    NvU32 retval = 0;
    NvBool vgpuHandled = NV_FALSE;

    retval = vgpuDevReadReg032(pGpu, thisAddress, &vgpuHandled);
    if (vgpuHandled) return retval;

    if (thisAddress >= pMapping->gpuNvLength) {
        NV_ASSERT(thisAddress < pMapping->gpuNvLength);
    } else {
        retval = NV_PRIV_REG_RD32(pMapping->gpuNvAddr, thisAddress);
    }

    return retval;
}
```

The bottom-level `NV_PRIV_REG_RD32` is defined in
`src/nvidia/arch/nvalloc/unix/include/nv-priv.h:39`:

```c
#define NV_PRIV_REG_RD32(b,o)     ((b)->Reg032[(o)/4])
```

Where `Reg032` is `volatile NvV32 Reg032[1]` — a flexible-array member
that points at the ioremap'd MMIO region for the GPU's BAR0.

### The 11 direct callsites of `NV_PRIV_REG_RD32` — full classification

These bypass `osDevReadReg032` and read MMIO directly. Audit
classified each:

| # | File:Line | Context | Lever Q action |
|---|---|---|---|
| 1 | `os.c:1929` | inside `osDevReadReg032` itself | **WRAP** (this IS the chokepoint) |
| 2 | `osapi.c:417` | `RmLogGpuCrash` — revalidation probe (intentionally reads even when GPU lost, to support EEH recovery on Power) | LEAVE — must read past Q-passive |
| 3-5 | `osapi.c:3654-3656` | `nvGpuInfo`-style boot probe; reads PMC_BOOT_0/1/42 | LEAVE — already has explicit `0xFFFFFFFF` check, returns `NV_ERR_GPU_IS_LOST` |
| 6-7 | `osapi.c:5018-5019` | `rm_get_is_gsp_capable_vgpu` — vGPU detection in HVM guests only | LEAVE — boot-time, hypervisor-only path, irrelevant to discrete GPU |
| 8 | `osinit.c:367` | `osHandleGpuLost` retry loop body | LEAVE — already retried by Lever I (10×100µs) |
| 9-11 | `osinit.c:1629-1631` | `RmInitPrivateState` — boot-time chip identification | LEAVE — runs before pGpu exists, no `PDB_PROP_GPU_IS_LOST` to check |

**Conclusion:** only 1 of 11 sites needs Q-passive treatment. The
other 10 are correctly handled by their existing logic or are
irrelevant to the bug path.

### All read variants need wrapping

`osDevReadReg{008,016,032}` all sit in `os.c` with the same structure
(direct `NV_PRIV_REG_RD{08,16,32}` to MMIO). All three are reachable
from the high-level `regRead{008,016,032}` funnel in
`gpu_access.c:524-530, 642-648`. The 8/16-bit variants don't even have
the `vgpuDevReadReg*` short-circuit — they go straight to MMIO, so
they're equally vulnerable to hanging.

Comprehensive coverage requires wrapping all three read variants.

### Hardware constraint

**A single MMIO read instruction (`(b)->Reg032[(o)/4]`) is
uninterruptible at the C level.** The CPU stalls until the chipset
returns a value or the hardware completion timeout fires. Software has
no way to bound this from outside the read.

The PCIe completion timeout is configured per-device:
- GPU `04:00.0` DevCtl2 shows: `Completion Timeout: 50us to 50ms`,
  `TimeoutDis: not set`

So in *theory* a hung read returns all-Fs after at most 50 ms. In
practice, on TB-tunneled PCIe the timeout behaviour may be different —
TB encapsulation can extend or hide transaction-level timeouts. We
don't have ground truth on the actual stall duration.

### The Linux kernel disconnect API

`include/linux/pci.h:2640`:

```c
static inline bool pci_dev_is_disconnected(const struct pci_dev *dev)
{
    return READ_ONCE(dev->error_state) == pci_channel_io_perm_failure;
}
```

Set automatically when:
- AER recovery escalates to permanent failure
- Our `nv_pci_error_detected` returns `PCI_ERS_RESULT_DISCONNECT` (M-base)
- PCIe DPC fires
- Surprise hot-removal

**Key insight:** `pci_dev_is_disconnected()` returning true is a
*persistent* state we can use to short-circuit subsequent reads, but it
needs to be *set* before our read — which means we need an upstream
trigger (AER, DPC, etc.) to set it. In Mode B, AER doesn't fire, so
this check alone is insufficient.

---

## Why "MMIO read with timeout" can't be implemented as advertised

The phrase from the roadmap implied wrapping the macro with
`read_poll_timeout`-style semantics. **That doesn't actually work for
the bare-metal MMIO case** — `read_poll_timeout` works by polling a
condition repeatedly, but a single MMIO read in C is one instruction
that can't be polled around. The CPU stalls inside the load.

The roadmap term should be retired in favour of a more accurate name:
**"MMIO read protection"** — using kernel-state checks and post-read
sanity checks to detect and short-circuit hung reads, without actually
timing out the single instruction.

---

## Proposed design — Lever Q

Three sub-levers, staged like Lever M was:

### Q-passive (always-on guard)

**Sites:** `osDevReadReg032`, `osDevReadReg016`, `osDevReadReg008`
in `os.c` (lines 1909, 1891, 1873). All three need the same wrap.

**Required helpers (new):** Two thin OS-abstractions, since RM-side
code in `os.c` shouldn't include `<linux/pci.h>` (layering violation).
Following the existing `os_pci_*` pattern in
`kernel-open/nvidia/os-pci.c`:

```c
// kernel-open/nvidia/os-pci.c (NEW)

// Check kernel-side disconnect state (read by Q-passive)
NvBool NV_API_CALL os_pci_is_disconnected(void *handle)
{
    struct pci_dev *pdev = (struct pci_dev *)handle;
    if (!pdev) return NV_FALSE;
    return pci_dev_is_disconnected(pdev) ? NV_TRUE : NV_FALSE;
}

// Propagate disconnect state kernel-wide (called by Q-active).
// Linux 6.19 has pci_dev_set_io_state() as a private function in
// drivers/pci/pci.c — not exported. We achieve the same effect via
// WRITE_ONCE on dev->error_state; this matches the kernel's own
// pattern (xchg/cmpxchg for atomic transitions, WRITE_ONCE for
// final unconditional sink state). pci_channel_io_perm_failure is
// a sink state — once set, no transitions out — so a non-atomic
// WRITE is race-safe even if AER is concurrently processing.
void NV_API_CALL os_pci_set_disconnected(void *handle)
{
    struct pci_dev *pdev = (struct pci_dev *)handle;
    if (!pdev) return;
    WRITE_ONCE(pdev->error_state, pci_channel_io_perm_failure);
}
```

The handle pattern is established (`nv_state_t->handle` is set to
`pci_dev` during `nv_pci_probe` at `nv-pci.c:1928`; passed as `void *`
through `os_pci_remove`, `os_pci_trigger_flr`, etc.).

After Q-active calls `os_pci_set_disconnected`, ALL kernel code paths
checking `pci_dev_is_disconnected()` see the failure state — not just
our driver. AER recovery workqueue, sysfs readers, other kernel
subsystems all fail fast on the dead device.

**Behaviour:** before issuing the MMIO read, check two state variables:

1. `os_pci_is_disconnected(nv->handle)` — wraps the kernel's PCIe
   disconnect state, set by AER/DPC/our M-base
2. `PDB_PROP_GPU_IS_LOST` — the driver's GPU-lost state, set by
   `gpuSetDisconnectedProperties` after osHandleGpuLost retry exhaustion

If **either** is set, return `0xFFFFFFFF` (or `0xFFFF`/`0xFF` for
narrower variants) immediately without reading. This makes every
subsequent MMIO read after a loss event return fast, draining locks,
allowing the kernel scheduler to make progress, allowing the AER
recovery workqueue to dispatch (which might finally let M-base fire),
and allowing other threads' detection paths to run.

```c
// kernel-open/common/inc/os/os.h (NEW prototype):
NvBool NV_API_CALL os_pci_is_disconnected(void *handle);

// src/nvidia/arch/nvalloc/unix/src/os.c (MODIFIED 32-bit reader):
NvU32 osDevReadReg032(OBJGPU *pGpu, DEVICE_MAPPING *pMapping, NvU32 thisAddress)
{
    NvU32 retval = 0;
    NvBool vgpuHandled = NV_FALSE;

    retval = vgpuDevReadReg032(pGpu, thisAddress, &vgpuHandled);
    if (vgpuHandled) return retval;

    // AORUS Lever Q-passive: if device is already known-disconnected at
    // the kernel level, OR the driver has already declared GPU lost,
    // skip the actual MMIO read. Returning ~0 mimics what a dead bus
    // would eventually return after hardware completion timeout, and
    // matches the value used by every existing "is the GPU there?" check.
    if (pGpu)
    {
        nv_state_t *nv = NV_GET_NV_STATE(pGpu);
        if (nv && os_pci_is_disconnected(nv->handle))
            return 0xFFFFFFFFU;
        if (pGpu->getProperty(pGpu, PDB_PROP_GPU_IS_LOST))
            return 0xFFFFFFFFU;
    }

    if (thisAddress >= pMapping->gpuNvLength) {
        NV_ASSERT(thisAddress < pMapping->gpuNvLength);
    } else {
        retval = NV_PRIV_REG_RD32(pMapping->gpuNvAddr, thisAddress);
    }

    return retval;
}
```

The 8/16-bit variants get the same protection structure with
`0xFF`/`0xFFFF` returns.

**Cost:** 1 indirect call (to `os_pci_is_disconnected`) + 1 inline
function-pointer call (`getProperty`) per MMIO read in the sane path.
Both very fast (low nanoseconds vs MMIO's ~100ns). Negligible overhead
in normal operation. Not in atomic context since `osDevReadReg*`
already runs in process/IRQ context that allows function calls.

**Effect:** addresses Mode A perfectly. In Mode B, only effective AFTER
some upstream code path has set `pci_dev_is_disconnected` or
`PDB_PROP_GPU_IS_LOST`. The first hung read still occurs, but
subsequent reads short-circuit. Q-active (next) handles "the first
hung read" case.

### Q-active (post-read sanity check)

**Site:** also `osDevReadReg032`, immediately after the read.

**Behaviour:** if the read returned `0xFFFFFFFF`, validate by reading
`NV_PMC_BOOT_0` and comparing to the saved boot ID. If that's also
all-Fs, the GPU is gone — proactively set `PDB_PROP_GPU_IS_LOST` and
log a marker. This propagates the loss-state quickly to all subsequent
reads (which then short-circuit via Q-passive).

This re-uses NVIDIA's existing detection logic (the
`gpuMarkAsDeadAndRefresh` pattern) but applies it at the read
chokepoint rather than only at periodic sanity checks. Makes detection
~5x faster (immediate after first bad read, not on the next sanity-check
tick).

```c
// Existing read happens above
if (retval == 0xFFFFFFFFU && pGpu && nv) {
    // Validate by re-reading the canonical boot-ID register.
    nv_priv_t *nvp = NV_GET_NV_PRIV(nv);
    NvU32 pmc_boot_0 = NV_PRIV_REG_RD32(nv->regs->map_u, NV_PMC_BOOT_0);
    if (pmc_boot_0 != nvp->pmc_boot_0) {
        // GPU is genuinely gone. Set the property so subsequent reads
        // (including the next caller's) short-circuit via Q-passive.
        gpuSetDisconnectedProperties(pGpu);
        // Log once per loss event
        static int s_aorus_lever_q_active_logged = 0;
        if (!s_aorus_lever_q_active_logged) {
            s_aorus_lever_q_active_logged = 1;
            NV_PRINTF(LEVEL_ERROR,
                "AORUS Lever Q-active: detected dead bus at offset 0x%x; "
                "GPU declared lost early-detection path\n", thisAddress);
        }
    }
}
```

**Cost:** in normal operation (read returns valid data), zero overhead
beyond a comparison to `0xFFFFFFFF`. In failure case, one extra MMIO
read to PMC_BOOT_0 (which itself is short-circuited by Q-passive once
`PDB_PROP_GPU_IS_LOST` is set). Net cost on the FIRST bad read: 2 MMIO
reads instead of 1.

**Effect:** in Mode B, the first hung read still occurs (we can't avoid
it), but as soon as it returns (via hardware completion timeout, ~50ms),
we proactively set GPU_IS_LOST. All subsequent threads short-circuit
immediately. The driver-internal detection path (osHandleGpuLost
sanity check) becomes redundant — the chokepoint sets the state first.

### Q-watchdog (future, optional)

**Site:** new kthread.

**Behaviour:** periodic check of `nv->pci_dev->error_state` and
in-flight read counters. If a read counter hasn't advanced for >N ms,
forcibly set `PDB_PROP_GPU_IS_LOST` even without a value-based signal.
Kicks Q-passive into effect for any other threads.

**Status:** deferred. Not needed if Q-active works as expected. Listed
for completeness.

### Logging plan (verbose where it aids investigation)

**Q-passive marker** — fires on FIRST short-circuit per failure event
(static counter), tells us how the loss was detected:

```
AORUS Lever Q-passive: dead-bus state detected at offset 0x%08x
  source:           os_pci_disconnected=%d, gpu_is_lost=%d
  short-circuiting subsequent MMIO reads with 0xFFFFFFFF
```

The `source` field reveals the chain-of-detection: was it kernel-side
(M-base or AER set the disconnect state), or was it driver-side
(Q-active or osHandleGpuLost set GPU_IS_LOST)?

**Q-active marker** — fires on the FIRST detection per failure event,
the diagnostic-rich one we want for investigation:

```
AORUS Lever Q-active: dead-bus DETECTED via post-read sanity check
  trigger_offset:   0x%08x         (the register that read all-Fs)
  trigger_value:    0x%08x         (always 0xFFFFFFFF here, logged for sanity)
  pmc_boot_0_read:  0x%08x         (verification read — 0xFF confirms GPU gone)
  pmc_boot_0_expected: 0x%08x      (saved boot ID nvp->pmc_boot_0)
  pre_state:        os_pci_disconnected=%d, gpu_is_lost=%d
  actions:          gpuSetDisconnectedProperties() + os_pci_set_disconnected() called
  PDB_PROP_GPU_IS_LOST is now TRUE; pci_dev->error_state is now perm_failure
  All subsequent reads will short-circuit via Q-passive
```

This single log line tells future-investigation everything: which
register triggered the detection, what the GPU returned, whether
verification confirmed loss, and what state was set as a result.

---

## Direct `NV_PRIV_REG_RD32` callsites — audit complete

All 11 sites enumerated and classified (table earlier in this doc).
**Outcome: only 1 site needs Q-passive treatment** — the one inside
`osDevReadReg032` itself (which is the chokepoint we're wrapping
anyway). The other 10 are already correctly handled or irrelevant to
the bug path.

This is much narrower than originally feared. No additional
per-callsite patches needed beyond the chokepoint wrap.

## MMIO writes — out of scope (audit confirmed)

Linux MMIO writes are POSTED — they return immediately, the actual
transaction completes asynchronously. A dead bus cannot stall a write.
`osDevWriteReg{008,016,032}` therefore do NOT need Q-passive
protection. Confirmed by reading `os.c:1817-1872`.

## Other MMIO read primitives — surveyed

Outside the `osDevReadReg*` chokepoint, the only direct
kernel-MMIO reads are:

| Site | Used for | Relevance |
|---|---|---|
| `nv-pci.c:1116` `readl(bar0_map + offset)` | Tegra/SoC fuse status read at probe | Boot-time only, Tegra-only — not on our path |
| `uvm_ats_sva.c:125,137,168,216` `ioread32(...)` | ARM SMMU CMDQ Virtualisation | Tegra ARM SMMU only — not on x86 |

Neither is reachable on our discrete-GPU-on-x86 stack. No additional
wrapping needed.

---

## Effect matrix

| Scenario | Before Lever Q | After Lever Q |
|---|---|---|
| Mode A — driver detects loss via sanity check | Works (Levers I/J-2/N fire) | Works faster (Q-active sets GPU_IS_LOST sooner) |
| Mode A — many threads queue MMIO reads after loss | Each read takes hardware completion timeout (~50 ms) | Each read short-circuits in <1 µs via Q-passive |
| Mode B — TB tunnel drops, no AER, thread spinning in MMIO | Host wedges, no markers, no recovery | First hung read takes ~50 ms; Q-active immediately sets GPU_IS_LOST; all subsequent reads short-circuit; existing recovery chain (J-2, N, O) fires |
| Mode B + post-cleanup wedge (lite-153940) | Cleanup runs but post-cleanup freeze | Cleanup runs; subsequent ollama/nvidia-smi reads fail fast; system stays responsive |

---

## Risks and mitigations (post-audit)

| Risk | Likelihood | Mitigation / audit result |
|---|---|---|
| `pci_dev_is_disconnected` not callable from RM-side code | **resolved** | OS-helper pattern: new `os_pci_is_disconnected(void *handle)` in `os-pci.c`; matches existing `os_pci_*` helpers; uses `nv->handle` (set during probe at `nv-pci.c:1928`) |
| Performance regression in normal operation | very low | Confirmed: 1 indirect call + 1 inline getProperty per MMIO read, both ≪ 100ns MMIO cost |
| `gpuSetDisconnectedProperties` from non-standard caller breaks invariants | **resolved** | Function comment at `gpu.c:5282` explicitly states "can be called at raised (device) IRQL"; sets properties (no MMIO, no locking); queues deferred work item (`osQueueWorkItem` returns immediately) |
| Re-entrant call to `gpuSetDisconnectedProperties` causing infinite recursion | **resolved** | The function does no MMIO. Worker (`_gpuSetDisconnectedPropertiesWorker`) runs asynchronously after our caller has returned; even if it does MMIO later, Q-passive will short-circuit (property is now set). No recursion. |
| Q-active causes false positives (mis-declares GPU lost on a transient) | low | Verification read of PMC_BOOT_0 mitigates; only declares lost when BOTH reads return `0xFFFFFFFF`. Lever I retains the 1ms transient-tolerance retry. |
| Direct `NV_PRIV_REG_RD32` callsite missed → still hangs | **resolved** | Comprehensive enumeration of all 11 sites complete; classified; only 1 needs wrapping (the chokepoint itself). Future kernel updates would require re-audit, documented in runbook. |
| `vgpuDevReadReg032` (called first inside chokepoint) hangs on dead bus | **resolved** | Returns immediately with `vgpuHandled = NV_FALSE` for non-virtual, non-hypervisor systems (`os_init.c:333-338`). No MMIO. |
| MMIO writes can also hang | **resolved** | Architecturally false: Linux MMIO writes are POSTED (return immediately). Only non-posted reads can stall. Confirmed in `os.c:1817-1872`. |
| 8/16-bit read variants need separate handling | **identified** | All three variants (`osDevReadReg008/016/032`) have the same vulnerability and need the same wrap. Patches 0011 (32-bit) and 0012 (8/16-bit) cover this. |

---

## Implementation plan (revised post-audit)

Five small patches, each independently buildable and reviewable:

| Patch | Files touched | Purpose |
|---|---|---|
| **0010** | `kernel-open/nvidia/os-pci.c` + appropriate prototype header | Add `os_pci_is_disconnected` and `os_pci_set_disconnected` helpers |
| **0011** | `src/nvidia/arch/nvalloc/unix/src/os.c` (`osDevReadReg032` only) | Q-passive 32-bit + first-fire log |
| **0012** | `src/nvidia/arch/nvalloc/unix/src/os.c` (`osDevReadReg008/016`) | Q-passive 8/16-bit |
| **0013** | `src/nvidia/arch/nvalloc/unix/src/os.c` (`osDevReadReg032`) | Q-active: post-read PMC_BOOT_0 verification + `gpuSetDisconnectedProperties` + `os_pci_set_disconnected` + verbose marker |
| **0005 (UPDATE)** | `version.mk` + `kernel-open/Kbuild` | Bump version mark from `595.71.05-aorus.1` to `595.71.05-aorus.2` (modify existing patch in place rather than adding 0014) |

This sequencing means after each patch, we can build and verify:
- After 0010: helper symbol present in nvidia.ko
- After 0011: smoke test (status check, nvidia-smi works)
- After 0012: same; 8/16-bit reads exercised on probe
- After 0013: full Lever Q functionality; lite test should now produce
  Mode-A-style data on every run (deterministic Mode B → A conversion)
- After 0014: build identifies as `595.71.05-aorus.2`

### Validation criteria

- **Boot:** system boots cleanly, nvidia.ko loads, nvidia-smi succeeds
  at idle (proves Q-passive isn't breaking healthy operation)
- **Mode A test (post-Phase-1b):** same patches as before fire (J-2, N,
  ollama panic), but cleanup is faster (subsequent RPCs short-circuit
  via Q-passive)
- **Mode B test (post-Phase-1b, the critical case):** AORUS Lever
  Q-active marker fires; Xid 79 logged; J-2/N markers fire; ollama
  gets cudaMalloc error and panics cleanly; system stays responsive;
  no iwlwifi cascade

If validation passes: Phase 1b complete, move to Phase 2
(P-comprehensive based on P-probe data).

If Mode B *still* freezes silently (Q-active marker never logged),
there's a deeper failure path we haven't found — escalate to
investigation rather than another patch.

---

## Version bump

Builds containing Lever Q ship as `595.71.05-aorus.2`.

Implemented by modifying the existing `0005-version-mark-aorus-build.patch`
in place — change `595.71.05-aorus.1` → `595.71.05-aorus.2` in both
`version.mk` and `kernel-open/Kbuild`. This avoids adding a separate
patch just for the version string and keeps the version bump
co-located with the version-mark patch.

`.1` builds become historic — anyone who applies the current patch
series gets `.2`. The patch series is the source of truth.

## Follow-up experiments (post-Phase-1b)

After Lever Q lands and the test loop is stable, two small experiments
worth running:

1. **Completion timeout tuning** — narrow the GPU's PCIe completion
   timeout from "Range AB" (50us-50ms) to "Range A" (50us-10ms) via
   `pcie_capability_clear_and_set_word(pdev, PCI_EXP_DEVCTL2,
   PCI_EXP_DEVCTL2_COMP_TIMEOUT, ...)`. Could let Q-active fire 5x
   faster on the dying-bus path. Risk: medium — TB tunneling adds
   latency, tighter timeout might cause spurious failures on
   slow-but-valid transactions. Worth a controlled A/B comparison.

2. **AER status clear after Lever Q-active fires** — actively call
   `pci_aer_clear_uncorrect_error_status()` (or moral equivalent) when
   we declare the GPU lost. Reduces the AER interrupt rate during the
   degrading-bus phase, lowers risk of interrupt storm overwhelming
   the kernel. Cheap, low risk.

Both are deferred until Lever Q's effects can be measured cleanly.

---

## Open questions — resolved by audit

| Q | Status | Answer |
|---|---|---|
| **Q1.** Is `nv->pci_dev` populated when `osDevReadReg032` runs? | RESOLVED | YES. Set as `nv->handle` during `nv_pci_probe` at `nv-pci.c:1928`. Always populated by the time MMIO reads happen (post-probe). Accessible from RM-side via `NV_GET_NV_STATE(pGpu)->handle`. |
| **Q2.** Lock-ordering safety for `gpuSetDisconnectedProperties` from `osDevReadReg032`? | RESOLVED | SAFE. Function comment at `gpu.c:5282` says "can be called at raised (device) IRQL". Sets properties only (no MMIO, no locking), queues deferred work item via `osQueueWorkItem` (returns immediately). |
| **Q3.** Retain vs replace Lever I? | RESOLVED | RETAIN. Lever I provides 1ms transient tolerance (10×100µs retry) — useful for noisy buses. Q-active provides permanent loss declaration after first all-Fs (with PMC_BOOT_0 verification). Different purposes, complementary. |
| **Q4.** Need to wrap `osDevReadReg008` and `osDevReadReg016` too? | RESOLVED | YES. All three variants funnel from `regRead{008,016,032}` (`gpu_access.c:524-530, 642-648`). The 8/16-bit variants don't even have `vgpuDevReadReg*` short-circuit — go straight to MMIO. Patch 0012 covers them. |
| **Q5.** Need to wrap MMIO writes? | RESOLVED | NO. POSTED writes return immediately, can't hang on dead bus. Confirmed in `os.c:1817-1872`. |
| **Q6.** Other MMIO read primitives bypass the chokepoint? | RESOLVED | Only `nv-pci.c:1116` (Tegra fuse, not on x86) and `uvm_ats_sva.c` (ARM SMMU, not on x86). Neither relevant. |
| **Q7.** Recursion risk Q-active → MMIO → Q-active? | RESOLVED | None. Q-active does ONE direct (unwrapped) `NV_PRIV_REG_RD32` for verification then sets property + queues async work. No callback into MMIO before returning. |

---

## Cross-references

- `stability-roadmap.md` — Phase 1b context
- `freeze-investigation-plan.md` — historical Lever I context (relevant
  for retain-vs-replace decision)
- Test artifacts:
  - `lite-2026-05-04-145232/` — Mode A reference (J-2 + N fired)
  - `lite-2026-05-04-153940/` — best Mode A run (ollama panic'd cleanly)
  - `lite-2026-05-04-152514/`, `lite-161759/` — Mode B reference
    (silent freezes Lever Q targets)
