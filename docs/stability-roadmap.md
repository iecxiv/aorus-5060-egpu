# AORUS RTX 5090 eGPU — Stability Roadmap

> **Authoritative reference** for the layered approach to stable CUDA workloads
> on this hardware. Every code patch, every test cycle, and every diagnostic
> artifact maps to a phase below. This doc supersedes the lever-list portion of
> `freeze-investigation-plan.md` and is the canonical place to track progress.
>
> **Last updated:** 2026-05-08
>
> **Status as of 2026-05-08:** reliability frontier converged. Phase 4
> (Lever M-recover) PROVEN at n=3 manual trigger + n=3 churn probes, plus
> Phase 5 evidence collection running automatically per boot (5/10 toward
> wpr2-recovery service retirement gate). H22 ledger entry documents the
> close-path bug class as empirically mitigated. Three userspace
> workaround services retired this week. Decode at WSL2 parity for
> llama3.1:8b. Cold-load gap (~3.95s vs ~30ms WSL2, ~130×) is the only
> remaining Path A non-parity item; perf investigation deferred to vLLM
> repo (see `/root/vllm/docs/perf-roadmap.md`).

---

## Project goal

Run stable LLM inference (ollama, qwen2.5:0.5b → llama3.1:8b validated) on:

- AORUS RTX 5090 AI Box (GB202 / Blackwell, GPU `0000:04:00.0`)
- Connected via Thunderbolt 4 (40 Gb/s) to
- Intel NUC 15 Pro+ (Arrow Lake-H, Core Ultra 9 285H)
- Fedora 43, kernel 6.19.14-200.fc43.x86_64
- NVIDIA open kernel module 595.71.05, patched to 595.71.05-aorus.12 via
  the 30-patch series in `patches/` (build via `tools/build-patched-driver.sh`)

---

## Bug class (established)

The PCIe link between the GPU and the host fails under sustained CUDA workload
pressure — generates uncorrectable AER errors and/or stops responding entirely.
This is the upstream class tracked at NVIDIA/open-gpu-kernel-modules#979.

### What WSL2 (Lever G) ruled out

The same hardware running Windows 11 with WSL2 + CUDA executes 45 successive
inference iterations up to 27B parameter models cleanly. This control is
load-bearing for every strategic choice in this roadmap:

| Hypothesis | Status |
|---|---|
| Defective hardware | **Ruled out** — Windows works with this exact silicon |
| Broken firmware (JHL9480, GPU VBIOS, NUC TB host controller) | **Effectively ruled out** — Windows works with the same firmware versions |
| Marginal cable / connector | **Effectively ruled out** — same cable works under Windows |
| Linux's interaction with the hardware (kernel, open driver, AER stack) | **Confirmed proximate cause** |

The bug is in **how Linux interacts with the hardware** — a software-side
problem. Firmware/hardware-replacement levers therefore offer little expected
value and are de-prioritised below cheap software interventions.

---

## Investigation methodology

> **Added 2026-05-05** in response to flailing test cycles where each
> attempt changed multiple variables simultaneously, making it impossible
> to draw conclusions. Going forward this discipline applies to every
> reliability test.

The reliability problem space is large and each test has high cost
(typically ~1 freeze + 1 reboot, ~5-10 min lost). Without discipline,
results don't accumulate into knowledge. The methodology:

### Per-test discipline

1. **One variable**. Every test changes ONE thing vs the previous one.
   If isolation isn't possible, multiple tests are run sequentially with
   one variable each.
2. **Stated hypothesis**. Written down before the test:
   "if X happens, we conclude A; if Y happens, B."
3. **Pass/fail criterion**. No ambiguity post hoc.
4. **Cheaper experiments first**. Source review, log replay, A/B without
   reboot-cost before any reboot-cost tests.
5. **Conclusion logged**. The result lands in the
   [hypothesis ledger](./reliability-hypothesis-ledger.md) before
   the next test runs.
6. **n≥3 minimum** before declaring a hypothesis PROVEN or REJECTED.
   Single data points do not draw conclusions.

### Hypothesis ledger

[`reliability-hypothesis-ledger.md`](./reliability-hypothesis-ledger.md)
is the living tracker. Each open hypothesis has:

- What it claims
- Evidence FOR (with n)
- Evidence AGAINST (with n)
- The test that would resolve it
- What we'd do if SUPPORTED vs REJECTED

### The "march" — march toward 100% reliability

A disciplined progression of phase-level work, with each phase narrowing
hypothesis space before the next:

| Phase | Focus | Cost per test | Hypotheses resolved |
|---|---|---|---|
| **0** | Wrapper hygiene (FLR off as default; instrument trigger_flr) | 0 | infrastructure |
| **1** | L1 prevention sweep (DPC enable, PCIe tuning, IOMMU policy) | low — boot config + one iter each | H8, H9, H10 |
| **2** | Q-watchdog A/B (H1) with clean wrapper | low — n=3 each side | H1 |
| **3** | Bare FLR test (H6) and trigger_flr instrumentation (H2) | medium — likely still wedges, isolated | H2, H6 |
| **4** | M-recover implementation (H11) | high — multi-day driver work | H11 — gateway to in-driver recovery |
| **5** | Stochasticity audit (H3) | passive — accumulate iters across all phases | H3 |

Phase 4 is the gateway to the project's reliability destination:
**in-driver recovery via `pci_error_handlers` slot_reset + resume**.
Wrapper-driven FLR (current Phase 1c B3 / B4) is interim; today's
freeze (2026-05-05 18:26) showed the wrapper-FLR path itself wedges
the host when persistenced and uvm-keepalive hold device fds. That
class of bug is intrinsic to userspace-driven recovery on this stack
and cannot be fixed without moving recovery into the kernel.

### Two facts already established (PROVEN, see ledger)

1. **NMI watchdog cannot catch this freeze class** — both 2026-05-05
   freezes were kernel deadlocks (no CPU loop), `hardlockup_panic=1` did
   not fire. Hardware watchdog (Phase C4 task #88, iTCO_wdt) is the only
   reliable last-resort recovery for this class.
2. **Phase 1b stack (Q-active + Q-passive + N + O) works correctly when
   it gets to fire** — Test 2 at 18:26 fired all 4 markers, captured 50
   AER events, logged Xid 154, host stayed alive 90+ seconds for
   wrapper to complete clean post-state telemetry. Mode A graceful
   failure is a solved problem for detection. Open work is on
   Mode B (silent) detection and on recovery.

---

## Three-layer reliability framework

```
            +------------------------------------------+
   L1       |  PREVENTION — stop the bug from triggering   |
            |  (cmdline params, PCIe parameters, link cap)  |
            +------------------------------------------+
                              ↓ if L1 fails
            +------------------------------------------+
   L2       |  SIGNALING — detect failures fast and route  |
            |  them to the driver (PCI error handlers,     |
            |  MMIO timeout, AER infrastructure)           |
            +------------------------------------------+
                              ↓ if L2 fires
            +------------------------------------------+
   L3       |  RECOVERY — survive the failure cleanly,     |
            |  then optionally resume the workload         |
            |  (GPU-lost short-circuits, slot reset)       |
            +------------------------------------------+
```

The user-visible outcome is the **product** of all three layers:

- L1 alone: failure rate × catastrophic = bad
- L1 + L3: lower failure rate × survivable = "stable degraded" (acceptable)
- L1 + L2 + L3 + recovery: low failure rate × survivable + auto-recovery = workable
- All layers + state-preservation: failures invisible to workload = ideal

---

## Project vision — "perfect driver"

The destination is an open module that **matches or exceeds the Windows
closed driver** for compute workloads on this hardware — in BOTH
reliability AND performance.

**Updated 2026-05-04 night:** the goal on the performance axis is
explicitly to *exceed* WSL2, not just match it. Native Linux + the
open KMD eliminates virtualisation overhead WSL2 carries (Hyper-V
mediation, paravirtualised GPU bus, Windows scheduler indirection)
and exposes optimisation surfaces Windows cannot reach (PCIe/TB
config-space tuning, kernel scheduler control, hugepages, GPUDirect
Storage, custom KMD interventions). Per
[`architecture-and-modularity.md`](./architecture-and-modularity.md),
the discipline is to land most of this work outside the NVIDIA fork
(L4-L6) so the fork stays minimal and rebaseable.

### Reliability axis

- The host never wedges on a PCIe link disturbance — failures always
  produce diagnostics and userspace error returns.
- Workloads recover automatically without host reboot, ideally without
  re-uploading the model.
- All `pci_error_handlers` callbacks are wired and exercised.
- AER recovery state machine is complete and testable.
- Driver behaviour under TB hot-plug, hot-remove, D-state transitions,
  surprise-down, and ECC events is well-defined.
- Userspace gets timely uevent notifications for GPU lifecycle events.

### Performance axis

- LLM decode tokens-per-second on equivalent models matches or exceeds
  Windows closed-driver baselines (see WSL2 reference numbers below).
- Per-kernel-launch overhead is competitive with Windows closed driver.
- GPU utilisation during sustained decode is comparable.
- Power efficiency (W per token) is comparable.
- Cold-load times for first inference request are comparable.

### Reference: WSL2 (Lever G) baseline numbers on this exact hardware

These are the bar to clear (Windows + closed driver):

| Model | Decode tok/s | GPU util % | Peak W |
|---|---:|---:|---:|
| `llama3.2:1b`   | **533.5** | 18% | 168 |
| `llama3.1:8b`   | 219.4 | 46% | 320 |
| `qwen2.5:14b`   | 130.8 | 52% | 421 |
| `gpt-oss:20b`   | 232.5 | 43% | 267 |
| `gemma2:27b`    | 78.9  | 74% | 420 |

(Source: `/root/llm-bench/wsl-fedora43-2026-05-03/results.md`.)

### Current native-Linux state (post-Phase-1b, 2026-05-04 evening)

- **Reliability**: Lever Q (Phase 1b) delivered. 13/13 successful
  inferences across 3 model sizes in tonight's staged test. Zero
  freezes, zero FLRs needed. Earlier today the bug DID fire on
  separate tests and Lever Q caught it (Q-active marker fired,
  host stayed alive). Phase 4 (auto-recover) and Phase 2 (UVM
  fail-fast) still pending but not gating MVP.
- **Performance**: **AT WSL2 PARITY.** Direct measurement on
  2026-05-04 evening:

  | Model | Native median | WSL2 baseline | Ratio |
  |---|---:|---:|---:|
  | llama3.2:1b | 525 tok/s | 533 tok/s | **98%** |
  | llama3.1:8b | 229 tok/s | 219 tok/s | **105%** |

  Note: an earlier "~1000× gap" estimate was a measurement error
  (conflated total wall-clock including model load with decode rate).
  Actual decode performance was at parity all along once measured
  correctly via ollama's API metrics. See
  `performance-investigation.md` for the corrected analysis.

The WSL2 control proves both bars are reachable on this exact silicon —
no fundamental hardware barrier. Performance gap is essentially closed.
Reliability gap has Lever Q in place, with Phase 4-6 items remaining for
production-quality polish.

## Lever inventory (with current status)

### L1 — Prevention

| Lever | Status | Empirical result | Cost |
|---|---|---|---|
| K — cmdline `pcie_aspm.policy=performance, thunderbolt.clx=0, pcie_port_pm=off` | DONE | Applied baseline; no statistically distinguishable effect alone | already paid |
| L1-ecrc — enable PCIe ECRC (TLP CRC checking) | **RULED OUT 2026-05-04** | Hardware chain doesn't support: every device upstream of GPU shows `ECRCGenCap-`. ECRC is end-to-end and unavailable on this TB chain regardless of OS. | n/a |
| L1-linkcap — cap PCIe link speed at Gen2 or Gen3 | **RULED OUT 2026-05-04** | Link is already at floor (`00:07.0` and `02:00.0` LnkCap = 2.5GT/s). TB4 PCIe encapsulation forces Gen1; nothing lower exists. | n/a |
| LTR disable, completion timeout tuning | speculative | not tested; no data to predict effect | low |
| Match Windows transaction patterns | RESEARCH | unrealistic without WPP/ETW capture from Windows driver | high |
| Firmware updates (JHL9480, VBIOS, NUC FW) | DROPPED | WSL2 control rules out as productive | n/a |
| Hardware swaps (cable, enclosure) | DROPPED | same | n/a |

### L2 — Signaling

| Lever | Status | Empirical result | Cost |
|---|---|---|---|
| M-base — register `pci_error_handlers` (struct + `error_detected` returning DISCONNECT) | INSTALLED 2026-05-04 (patch 0007) | Marker has not fired in any test; AER recovery dispatch likely blocked by lock contention during cleanup | done |
| Q-passive — `osDevReadReg{008,016,032}` short-circuit when device known disconnected | INSTALLED 2026-05-04 (patches 0010-0012) | Phase 1b first half | done |
| Q-active — post-read PMC_BOOT_0 verification + propagate disconnect kernel-wide | INSTALLED 2026-05-04 (patch 0013) | Phase 1b second half; converts Mode B → Mode A deterministically | done |
| M-recover — wire kernel's PCI reset (FLR) into our `error_handlers` via `slot_reset` + `resume` | TODO Phase 4 | scope simplified 2026-05-04: FLR via `/sys/.../reset` empirically clears the GSP WPR2 stuck state in ~100ms; M-recover is now "wire kernel reset into our handlers" not "implement reset from scratch"; see [`recovery-mechanism-findings.md`](./recovery-mechanism-findings.md) | low-medium (1-3 days) |
| AER status clear after Xid 79 | TODO Phase 4 (folded in) | reduces post-failure interrupt storm; called via `pci_aer_clear_uncorrect_error_status()` from M-recover's `error_detected` | low |
| Recovery-action policy override (Xid 154 currently hardcoded "Node Reboot Required") | TODO Phase 4 | closed driver makes this configurable per failure class; should be "Drain/Reset" once M-recover is in place | low-medium |

#### Complete AER wiring — open-module gaps inventory

NVIDIA's open-module comment at `osinit.c:384-388` admits:

> *"This doesn't support PEX Reset and Recovery yet. This will help to
> prevent accessing registers of a GPU which has fallen off the bus."*

The closed Windows driver implements the full PCIe AER state machine.
This table enumerates each piece, comparing closed vs open vs our work:

| AER wiring component | Closed (Windows) | Open module (stock) | Open + our patches | Future destination |
|---|---|---|---|---|
| `pci_driver.err_handler` registered | ✅ | ❌ | ✅ M-base | (reached) |
| `error_detected()` callback | ✅ saves state, returns CAN_RECOVER | ❌ | ✅ M-base (returns DISCONNECT) | Phase 4: change return to CAN_RECOVER |
| `mmio_enabled()` callback | ✅ verifies device after kernel re-enables MMIO | ❌ | ❌ | **Phase 4 M-recover** |
| `slot_reset()` callback | ✅ accepts SBR, re-inits hardware, re-uploads GSP | ❌ | ❌ | **Phase 4 M-recover** |
| `resume()` callback | ✅ restores driver state, re-arms IRQs | ❌ | ❌ | **Phase 4 M-recover** |
| AER uncorrectable status clear | ✅ post-recovery | ❌ | ❌ | Phase 4 (folded into `error_detected`) |
| GSP firmware re-upload on reset | ✅ | n/a (no slot_reset path) | n/a | Phase 4 M-recover (depends on existing init paths) |
| Channel/context re-establish | ✅ | n/a | n/a | **Phase 5 M-preserve** |
| In-flight DMA fence-out | ✅ | ❌ | ❌ | Phase 5 M-preserve |
| Userspace `CUDA_ERROR_DEVICE_INVALIDATED` uevent | ✅ via kernel→user uevent | ❌ (apps only learn via per-call errors) | ❌ | **Phase 6 polish** |
| UVM-side AER hooks (VMA invalidate, fault buffer drain) | ✅ | partial (via `nvGpuOpsReportFatalError` after-the-fact) | partial (P-probe instruments; P-comprehensive will harden) | Phase 2 (cleanup safety) + Phase 6 (proactive) |
| TB hotplug surprise-down handling | ✅ | partial (depends on bolt + udev) | n/a | Phase 6 polish |
| D-state transitions during error recovery | ✅ | ? — uninvestigated | ? | Phase 6 polish |
| Per-driver-instance error counter exposed via sysfs | ✅ | ❌ | ❌ | Phase 6 polish (telemetry) |

### L3 — Recovery

| Lever | Status | Empirical | Cost |
|---|---|---|---|
| I — osHandleGpuLost retry (10×100µs on `NV_PMC_BOOT_0`) | DONE 2026-05-03 (patch 0001) | Retry-exhausted path verified ran (correct fall-through to `gpuSetDisconnectedProperties` → Xid 79) in test lite-153940 | done |
| J-2 — rcdbAddRmGpuDump shortcircuit + 3 companion sites | DONE 2026-05-04 (patches 0002-0004) | Marker fired in tests lite-145232 and lite-153940; verified fixes the previously-observed deadlock locus | done |
| N — rpcRmApiFree_GSP shortcircuit | DONE 2026-05-04 (patch 0006) | Marker fired in tests lite-145232 and lite-153940; collapses 107 cleanup-path assertions | done |
| O — _issueRpcAndWait shortcircuit | DONE 2026-05-04 (patch 0008) | Marker has not yet been observed firing — cleanup completes before second wave of RPCs reaches the funnel | done |
| P-probe — UVM destroy diagnostic markers (18 sites) | DONE 2026-05-04 (patch 0009) | Awaiting Mode A test cycle to capture the post-cleanup freeze locus | done |
| **P-comprehensive** — UVM destroy fail-fast covering all identified sites | **TODO** | Gated on P-probe data from a Mode A test | medium engineering, 1 day |
| M-recover (also fits here) | TODO | enables actual GPU recovery | dual-listed under L2 |
| M-preserve — state preservation across reset (the "real" PEX Reset and Recovery) | TODO (Phase 5) | ambitious; mostly relevant if M-recover proves stable | high |

### L1 prevention coverage — explicit gap analysis

> **Added 2026-05-05.** Most reliability work to date has been at L2
> (signaling) and L3 (recovery). L1 prevention is thinly explored;
> several levers remain unexamined and may be the most fertile ground
> for catching the hardest failure mode (Mode B silent).

| L1 lever | Status | Hypothesis | Notes |
|---|---|---|---|
| K — cmdline pcie_aspm/clx/port_pm | DONE | n/a | Applied; no statistically distinguishable effect alone |
| Phase 1a ECRC enable | RULED OUT | n/a | Hardware chain doesn't support; every device upstream of GPU shows `ECRCGenCap-` |
| Phase 1a link speed cap | RULED OUT | n/a | Already at TB Gen1 floor (2.5GT/s); nothing lower exists |
| L (`pci=noaer`) | REVERTED | n/a | Silenced AER signal that recovery patches depend on |
| Persistenced workaround | DONE | n/a | L7 reuse — load-bearing for Problem 2 |
| **DPC (Downstream Port Containment)** | **NOT INVESTIGATED** | **H8** | Kernel has `_OSC` control per boot; DPC could catch Mode B PCIe errors that today produce silent freezes |
| **PCIe completion timeout per-port** | **NOT INVESTIGATED** | **H9** | Sysfs tunable per bridge; default ~50ms |
| **PCIe MaxPayload / MaxReadReq** | **NOT INVESTIGATED** | **H9** | Often suboptimal default on TB; 7-native-A overlap |
| **LTR (Latency Tolerance Reporting)** | **NOT INVESTIGATED** | **H9** | Affects host arbitration; per-device sysfs |
| **IOMMU policy variation** (beyond `iommu=pt`) | **NOT INVESTIGATED** | **H10** | Strict vs lazy vs passthrough — different DMA fault containment |
| **DMA scatter-gather chunk size** | NOT INVESTIGATED | (no hypothesis yet) | Driver-internal; would be L1 sovereign work |
| **TB credit allocation** | NOT INVESTIGATED | (no hypothesis yet) | Vendor-specific TB controller knob |
| **J-1 — L1 bus-hardening companion module** | TODO #49 | spans H8/H9/H10 | NVIDIA-agnostic kmod; would consolidate per-device tuning |

The unexplored L1 levers are catalogued as hypotheses H8 (DPC), H9
(PCIe tuning), H10 (IOMMU policy) in the
[hypothesis ledger](./reliability-hypothesis-ledger.md). Phase 1 of the
"march" (per the methodology section above) sweeps these. Most are pure
config (sovereign L4 + L5 — boot-time helper + sysctl) and so are the
cheapest reliability work remaining.

### Levers reverted

| Lever | Reason for revert |
|---|---|
| H — `RmOverrideInternalTimeoutsMs=39000` | Caused MCE broadcast panic (39s heartbeat wait); reverted 2026-05-04 |
| L — `pci=...,noaer` | Suppressed the AER signal our recovery patches depend on, producing silent freezes; reverted 2026-05-04 |

---

## The two failure modes (empirically observed)

| | **Mode A — graceful degradation** | **Mode B — silent catastrophic** |
|---|---|---|
| Trigger | partial bus failure, AER reports errors | total bus drop, no AER reaches kernel |
| Time CUDA-start → freeze | ~14 s | <1 s |
| AER fires before freeze | yes (3-5 events over ~1 s) | no |
| Driver detects via sanity check | yes (Xid 79) | no |
| `PDB_PROP_GPU_IS_LOST` set | yes | no |
| Cleanup chain runs (J-2, N) | yes | no |
| ollama gets clean CUDA error | yes (lite-153940) | no — hangs in mmap |
| Diagnostic data captured | abundant | minimal |
| Tests observed: lite-145232, lite-153940 | (Mode A) | lite-142154, lite-152514, lite-161759 (Mode B) |

**Today's testing distribution: ~40% Mode A, ~60% Mode B** — random per test.
This randomness is the single biggest blocker on iteration speed.

---

## Phased plan

### Phase 1 — Make every test deterministically informative

> **Exit criterion:** every freeze produces a Mode-A-style log trace
> (Xid 79 + AORUS markers); no more mystery silent freezes.

#### Phase 1a — Cheap L1 software experiments

Two cmdline / sysfs experiments, run as separate test cycles.

1. **L1-ecrc:** enable PCIe End-to-End CRC (`pci_set_ecrc=1` cmdline or
   per-device sysfs write).
   - Goal: closer parity with Windows' PCIe behaviour
   - Expected: may reduce error-escalation rate; may eliminate Mode B; may
     have no effect
   - Cost: 1 cmdline change + 1 test cycle

2. **L1-linkcap:** force GPU PCIe link to Gen2 or Gen3 (cap via
   `LnkCtl2.TgtLinkSpeed` sysfs write at boot).
   - Goal: less signal-integrity stress, may match what Windows negotiates
     internally
   - Expected: lower bandwidth ceiling but more stable bus
   - Cost: small boot-time helper script + 1 test cycle per speed

If either experiment substantially reduces the freeze rate, the project may
not need Phase 1b at all.

#### Phase 1b — Option 2: MMIO read timeout

> Only undertaken if Phase 1a doesn't sufficiently improve outcomes.

Wrap `NV_PRIV_REG_RD32` (the open module's register-read macro) with a
`read_poll_timeout`-style helper that bounds any single read at ~100 ms.
On timeout, return `0xFFFFFFFF` — the same value a dead bus produces — and
let the existing osHandleGpuLost detection (Lever I) act on it.

- Effect: deterministic Mode B → Mode A conversion. Every freeze becomes
  a logged, AORUS-marker-firing, ollama-fail-cleanly event.
- Engineering: review every call site of `NV_PRIV_REG_RD32`, write helper,
  validate hot-path performance impact is negligible (timeout never fires
  in healthy operation; only matters when bus is dying).
- Cost: 1-2 days engineering + 2-3 test cycles to validate.
- **This is the highest-impact single piece of engineering remaining
  in the project.**

### Phase 1c — Telemetry hardening + Q-watchdog (post-freeze 2026-05-05)

> **Scope added 2026-05-05** in response to a Mode B silent freeze on
> first cold-boot CUDA workload. **Lever Q (Phase 1b) did not fire** —
> Q-active wraps the MMIO read path, but the freeze occurred mid model
> upload (DMA path) where no MMIO read had a chance to evaluate.
> Forensic dossier + plan: [`freeze-2026-05-05-investigation.md`](./freeze-2026-05-05-investigation.md).
>
> **Exit criterion:** next Mode B freeze either (a) does not happen
> (Q-watchdog converts it to Mode A before kernel wedges), OR (b) is
> survivable on the host side (hardlockup detector + kdump + external
> watchdog + populated CSVs all produce useful artifacts).

| Lever | Layer | Task | Notes |
|---|---|---|---|
| B1 — incremental CSV fsync during iter | L6 (test harness) | #81 | Empty CSVs on freeze are the highest-frequency telemetry loss |
| B2 — hardlockup detector + kdump | L5 (cmdline + systemd) | #82 | Captures vmcore on next boot after kernel-detectable lockup |
| B3 — aorus-egpu-watchdog (external health + auto-FLR) | L4 + L5 | #83 | Soft-freeze recovery without manual power-cycle |
| **B4 / C1 — Lever Q-watchdog kthread** | L1 (NVIDIA fork — justified) | #84 | Promotes the deferred-from-Phase-1b kthread; closes the gap Q-active leaves on DMA-path freezes |
| B5 — passive cuda-trace on warm-up workload | L6 (separate harness) | #85 | Identifies ggml-cuda call pattern without perturbing real test (per `feedback_observability_perturbs_bug`) |
| C2 — DMA-completion timeout (source review) | L1 (NVIDIA fork) | #86 | Read-only review now; implementation deferred until design is sound |
| C3 — pre-test cold-boot warm-up | L6 (test wrapper) | #87 | Isolates "first CUDA after cold boot" risk surface from "model load bandwidth" |
| C4 — iTCO_wdt hardware watchdog | L5 (modprobe.d + systemd) | #88 | Last-resort recovery; lower priority than B1-B4 |

Recommended sequence: **B1 → B2 → B4** (highest-value lowest-risk path
to better signal on the next freeze), then **D1 (#89) re-test**, then
A-phase forensic deepening + remaining stabilisation work in parallel.

### Phase 2 — Make Mode A perfectly survivable

> **Exit criterion:** every Mode A failure leaves the host fully responsive
> after ollama exits cleanly. No more post-cleanup wedges, no more iwlwifi
> cascades.

1. **Run a lite test** in the post-Phase-1 environment. Now guaranteed to be
   Mode A.
2. **Capture P-probe data**: read AORUS Lever P-probe markers from the
   resulting dmesg. The last marker that fires identifies the deadlock locus
   inside `uvm_va_space_destroy`.
3. **Design P-comprehensive**: source review of every site analogous to the
   identified locus. Per the user's preference, ship ONE patch that covers all
   sites with a uniform `uvm_global_get_status()` early-skip pattern.
4. **Build, install, validate** with 2 test cycles.

### Phase 3 — Stable degraded mode

> **Exit criterion:** failures consistently produce a clean error to ollama,
> host stays up, can re-run without rebooting.

This is the natural state once Phases 1-2 are complete. Use it to:

- Run extended testing (longer prompts, larger models, repeat cycles)
- Collect ground-truth data on failure rate vs workload size
- Identify any remaining edge-case patches (Lever Q, R, etc.)

### Phase 4 — M-recover: actual GPU recovery

> **Scope simplified 2026-05-04 evening** based on the FLR experiment
> documented in [`recovery-mechanism-findings.md`](./recovery-mechanism-findings.md).
> Originally projected as 2-3 weeks of engineering (writing the full
> reset state machine from scratch). Empirically verified on this hardware:
> Linux's existing `pci_reset_function()` / sysfs FLR mechanism resets
> the GPU cleanly in ~100ms, including clearing the GSP firmware's
> WPR2 state. Phase 4 becomes "wire the kernel's existing reset path
> into our `pci_error_handlers`" — estimated 1-3 days.

Concretely:

- Change `nv_pci_error_detected` (currently in M-base) to return
  `PCI_ERS_RESULT_NEED_RESET` instead of `PCI_ERS_RESULT_DISCONNECT`
- Add `slot_reset` callback that re-runs the relevant parts of probe
  after the kernel has done the FLR
- Add `resume` callback that clears `PDB_PROP_GPU_IS_LOST` and arms
  the device for normal operation
- Optionally emit a uevent so userspace knows recovery happened
  (folded with Phase 6's `CUDA_ERROR_DEVICE_INVALIDATED` work)

After Phase 4 lands:
- Workloads recover automatically without host reboot
- CUDA contexts become invalid; libcuda returns
  `CUDA_ERROR_DEVICE_INVALIDATED`; apps that handle this (ollama,
  PyTorch with proper exception handling) re-load and retry transparently
- Hardware confirmed alive — only kernel/driver/CUDA state needs reset

> **Exit criterion:** workloads recover automatically without host reboot.
> Acceptable mode for serving production inference.

### Phase 5 — M-preserve: in-flight state preservation

> The "real" PEX Reset and Recovery NVIDIA's open-module comment foreshadows.

Save GPU register state, channel descriptors, and (where possible) GSP
context before reset; restore after. Tractable for sequential inference
workloads where in-flight model loads can be replayed; less tractable for
graphics workloads.

> **Exit criterion:** failures are invisible to the workload — automatic
> resume mid-inference.

### Phase 7 — Performance: exceed Windows + WSL2

> Per-axis sibling to Phases 1-6 (which address reliability). Detailed
> design and data captured in
> [`performance-investigation.md`](./performance-investigation.md);
> sovereign-module home for each lever in
> [`architecture-and-modularity.md`](./architecture-and-modularity.md).
>
> **Status update 2026-05-04 night:** decode performance is at WSL2
> parity (98% on llama3.2:1b, 105% on llama3.1:8b). The earlier
> "~1000× gap" claim was a measurement error. **Project goal updated
> to *exceed* WSL2, not just match.**

**Phase 7a — Characterise the gap (DONE).**
Decode at parity confirmed for 0.5b/1b/8b. Per-ioctl latency calibrated
at ~6-8 ms (TB+GSP transport floor; pipelined-away by async streams).
See `performance-investigation.md` for the corrected analysis.

**Phase 7-validate — Steady-state and larger-model measurement (NEXT).**
- Add `KEEP_RUNNER=1` mode to test wrapper (skip inter-iter pkill);
  iters 2+ should report `load_duration ≈ 0`. Apples-to-apples vs WSL2.
- Extend native baseline to 14b/20b/27b.
- True cold-load measurement vs WSL2's reported 81 ms (likely a warm hit).

**Phase 7-native — Exploit Linux-only optimisation surfaces.**
The native-advantage thesis: WSL2 carries unavoidable virtualisation
overhead and inherits Windows defaults; native + open driver gives us
levers Windows cannot match. Each lever targeted at its sovereign home.

| Lever | Layer | Target |
|---|---|---|
| **7-native-A**: PCIe/TB link tune (MaxPayload, ASPM, completion timeout, LTR) | L4 + L5 | reduce per-ioctl latency floor |
| **7-native-B**: CUDA Graphs verify + enable | L6 | reduce ioctls per token |
| **7-native-C**: Async cuMemcpyHtoD pipelining for cold-load | L6 (L1 stretch) | close cold-load gap |
| **7-native-D**: GPUDirect Storage feasibility | L6 + L7 | direct file → GPU upload |
| **7-native-E**: System tuning (hugepages, SCHED_FIFO, IRQ affinity, governor) | L5 + L6 | tail-latency and pipeline saturation |
| **7-native-F** (research): custom batched-submit ioctl | L1 + L6 | last resort; high fork debt |

> **Exit criterion (revised):** decode tok/s on native Linux open module
> exceeds the WSL2 baseline across the 1b → 27b model ladder.
> Stretch goal: cold-load within 2× of WSL2's reported number for
> llama3.2:1b.

### Phase 6 — Polish: match Windows feature parity

> The destination phase. Closes every remaining gap between the open
> module's behaviour on this hardware and the closed Windows driver's
> behaviour. Items here are not on the critical path for "stable LLM
> inference" but together complete the "perfect driver" vision.

Each item below has a one-line scope. Detailed designs deferred until
the item is actively worked on.

**Userspace integration:**
- **CUDA_ERROR_DEVICE_INVALIDATED uevent**: kernel→user notification on
  GPU lifecycle events (loss, reset, recovery) so apps can pre-emptively
  rebuild contexts instead of learning via per-call errors. Closed driver
  emits these via `kobject_uevent`.
- **Sysfs error-counter exposure**: per-driver-instance counters for AER
  events, Xid events, recovery actions taken, recovery successes/failures.
  Closed driver exposes via NVCtrl extension; equivalent on Linux would be
  `/sys/bus/pci/devices/.../nvidia_*` files.
- **udev hooks for recovery state**: emit udev events on
  `recovery=in-progress`, `recovery=success`, `recovery=failed` so
  systemd-managed services can react (e.g. ollama could pause requests
  during recovery).

**Hot-add / hot-remove path completeness:**
- **TB hotplug surprise-down**: when the TB cable is yanked, currently
  recovery is via bolt + udev re-enumeration. Should match closed
  driver's graceful handling: drain in-flight, detach cleanly, allow
  later re-attach without reboot.
- **D-state transition correctness during AER**: investigate D0/D3hot/D3cold
  paths during error recovery. Closed driver handles these; open module
  behaviour is uninvestigated.
- **Cold-add (boot without GPU connected, attach later)**: closed
  driver supports this; open module's bind path is currently
  manual via aorus-egpu-compute-load-nvidia.service.

**UVM-side polish:**
- **Proactive UVM AER hooks** (beyond Phase 2 reactive cleanup): UVM
  participates in AER recovery actively, draining fault buffers and
  invalidating VMAs synchronously rather than discovering loss via
  `nvGpuOpsReportFatalError` after the fact.
- **VMA reattach after recovery**: when M-recover succeeds, UVM should
  reattach VMAs to the recovered GPU rather than requiring app restart.

**Diagnostic / observability:**
- **AER event tracepoints**: `tracepoint(nvidia_aer_event, ...)` for
  ftrace/perf consumption. Useful for production telemetry.
- **`nvidia-bug-report.sh` integration**: currently we patch around
  `rcdbAddRmGpuDump` (Lever J-2) which prevents crash dumps in the
  GPU-lost path. Long-term should support a partial dump (skip GPU-side
  registers, capture host-side state) so bug-reports remain useful.

**Robustness against repeated failures:**
- **Backoff policy**: if recovery fails N times in a row, escalate to
  permanent-failure state and notify userspace via uevent.
- **Watchdog kthread (Lever Q-watchdog)**: deferred from Phase 1b.
  Periodic check that detects hung MMIO before Q-active fires; useful
  for failure modes where Q-active's value-based detection misses.

> **Exit criterion:** the open module's behaviour for compute workloads
> on TB-attached consumer Blackwell is **indistinguishable from the
> Windows closed driver** in fault-tolerance and recovery behaviour.
> The "PEX Reset and Recovery yet" comment in `osinit.c:384` becomes
> a historical artefact rather than an active TODO.

---

## Test methodology

Each test cycle uses `/root/ollama/tools/run-with-telemetry.sh` (lite
harness) with default model `qwen2.5:0.5b`. Default prompt
`"Write one sentence about Paris."`. Output goes to
`/root/ollama/archive/lite-<timestamp>/`.

Standard checks after a test:

```bash
# Boot history
journalctl --list-boots | tail -5

# Markers fired
journalctl -k -b -1 --no-pager | grep -E 'AORUS Lever' | sort -u

# Mode classification
journalctl -k -b -1 --no-pager | grep -cE 'Xid \(PCI'  # > 0 = Mode A

# Test outcome
cat /root/ollama/archive/$(ls -t /root/ollama/archive/ | head -1)/timeline.txt
ls -la /root/ollama/archive/$(ls -t /root/ollama/archive/ | head -1)/inference.json  # 0 bytes = freeze
```

Cold-boot recovery between tests is required when host wedges. Full eGPU
power-cycle (unplug TB cable + AC, wait 60 s) recommended every 3-4
test cycles to reset JHL9480 controller state.

---

## Cross-cutting telemetry (always-on)

| Asset | Status |
|---|---|
| Test harness with fsync'd timeline + telemetry CSVs | DONE |
| AORUS markers throughout patched code | DONE — Levers I, J-2 (×4), N, O, M-base, P-probe (×18) |
| pidstat / system / GPU CSVs per test | DONE |
| dmesg-pre.txt snapshot per test | DONE |
| Pre-freeze register dump | NOT YET — could add as harness improvement |
| NMI watchdog / kdump (capture state during freeze) | NOT YET — kernel-level work |

---

## Project completion criteria

Two completion bars: **MVP** (the user-visible goal) and **perfect-driver**
(the destination of Phase 6).

### MVP — "stable LLM inference on this hardware"

The project hits this bar when **all of these** are true:

- [ ] Lite test cycle runs to completion (returns inference response) under
      sustained ollama load with `qwen2.5:0.5b` model
- [ ] If a failure occurs, the host stays fully responsive (Phase 3)
- [ ] Workload can be retried without reboot (Phase 4)
- [ ] Failure rate per workload-hour is documented and acceptable for
      intended use case
- [ ] `aorus-5090-egpu/status.sh` continues to report HEALTHY
- [ ] All patches preserved as an applicable series
- [ ] DKMS or equivalent integration so kernel updates don't require
      manual rebuild

This is delivered by Phases 1-4. Phase 5 (state preservation) makes
recovery invisible to the workload but isn't strictly needed for MVP.

### Perfect-driver — feature parity with Windows closed driver

The project hits this bar when **all of these are also** true:

- [ ] Every `pci_error_handlers` callback that the closed driver
      implements is also implemented in the open module on this
      stack (M-base, M-recover, M-preserve all landed)
- [ ] Every entry in the "Complete AER wiring — open-module gaps
      inventory" table reads `(reached)` in the "Future destination"
      column
- [ ] Userspace receives `CUDA_ERROR_DEVICE_INVALIDATED` uevents matching
      Windows' GPU-lifecycle event semantics
- [ ] Sysfs exposes per-driver error counters
- [ ] TB hot-add and hot-remove paths are bug-free (no manual recovery
      needed for surprise-down or warm-detach)
- [ ] D-state transitions during AER recovery are tested and correct
- [ ] AER event tracepoints land for production telemetry
- [ ] `osinit.c:384` PEX Reset and Recovery comment becomes a
      historical artefact rather than an active TODO

Delivered by Phase 6 on top of Phases 1-5.

---

## Cross-references

- `freeze-investigation-plan.md` — historical investigation log; lever
  origins and source-review passes
- `pcie-kernel-cmdline-options.md` — full catalogue of `pci=` and
  `pcie_*` parameters (relevant for Phase 1a)
- `lever-Q-design.md` — Phase 1b design doc (delivered 2026-05-04)
- `recovery-mechanism-findings.md` — FLR experiment results (2026-05-04
  evening); load-bearing for Phase 4 design
- `performance-investigation.md` — Phase 7 design doc; baseline measured
  2026-05-04 evening, KPIs and investigation plan
- `source-review-notes.md` — passes 1-11 of the open driver source review
- `patched-driver-runbook.md` — how to build, install, rollback patched
  modules
- `architecture.md` — broader stack overview (the *what* of installed config)
- `architecture-and-modularity.md` — sovereign-module map (the *where*
  of each lever); rules for adding new code; lever-to-layer assignments
- **`lever-catalog.md` — canonical specification of every reliability
  lever (the *why* and *how*); each entry is explainable, testable,
  reproducible, upstream-ready**
- **`service-retirement-roadmap.md` — INVERSE of the catalog: tracks
  every userspace workaround service with the driver work that would
  let each retire. Reflects the project's architectural philosophy
  that the perfect end state is zero workaround services — every
  recovery happens inside the driver.**
- `reliability-hypothesis-ledger.md` — living tracker of every open
  hypothesis, evidence FOR/AGAINST, resolution test, decision rule
- `freeze-2026-05-05-investigation.md` — forensic dossier for the
  cold-boot Mode B freeze that triggered Phase 1c + the methodology pivot
- `recovery.md` — operational recovery procedures

---

## Update log

- **2026-05-04 night** — staged Step A (3 model sizes) confirmed
  100% reliability AND WSL2 parity in performance:
  - 13/13 successful inferences (qwen2.5:0.5b ×5, llama3.2:1b ×5,
    llama3.1:8b ×3)
  - Native llama3.2:1b: 525 tok/s vs WSL2 533 → 98% parity
  - Native llama3.1:8b: 229 tok/s vs WSL2 219 → 105% (slight beat)
  - The "~1000× perf gap" claim from earlier in the evening was a
    measurement error; corrected via ollama API metrics extraction.
  - Per-ioctl latency calibrated: ~6-8 ms floor (TB+GSP transport).
    Pipelining via async streams hides this for compute-dense workloads.
  - Loop archives: `loop-2026-05-04-203729`, `204224`, `204701`.
- **2026-05-04** — initial publication. Captures state through patch 0009
  (P-probe). Phase 1 not yet started; Phase 2 awaiting Mode A test data;
  Phases 3-5 future.
- **2026-05-04 (later)** — added Phase 6 (Polish — Windows feature
  parity), "Project vision — perfect driver" section, complete AER
  wiring gaps inventory, two-tier completion criteria (MVP +
  perfect-driver).
- **2026-05-04 (evening)** — Phase 1b delivered. Patches 0010-0013
  installed as `595.71.05-aorus.2`. Test `lite-2026-05-04-181844`
  confirms Mode B → Mode A conversion: Q-active fired, Q-passive fired,
  N + O fired in cleanup, ollama got clean error, host stayed responsive.
  Workload still failed (didn't produce inference output) — that's
  Phase 4 territory.
- **2026-05-04 (later evening)** — recovery mechanism experiments. PCI
  remove+rescan insufficient (GSP WPR2 stuck). FLR via sysfs
  (`echo 1 > /sys/.../reset`) reliably recovers the GPU in ~100ms with
  full functionality. Phase 4 scope simplified accordingly:
  M-recover is now "wire kernel FLR into pci_error_handlers" not
  "implement reset state machine from scratch." See
  `recovery-mechanism-findings.md`.
- **2026-05-04 (night, post-staged-Step-A)** — perf goal updated from
  "match WSL2" to "exceed WSL2." Phase 7 re-laid as 7-validate +
  7-native (A through F). Modularity contract published as
  [`architecture-and-modularity.md`](./architecture-and-modularity.md):
  L1-L7 sovereign-module taxonomy; rule that new optimisation levers
  must justify any layer above L4; explicit lever-to-layer assignments
  for both reliability (existing) and performance (planned) work.
- **2026-05-05 17:00** — Mode B silent freeze on first cold-boot CUDA
  workload (qwen2.5:0.5b, ~14s in, mid model upload). Lever Q did not
  fire — freeze locus was DMA-path, not MMIO-read path. Phase 1c added
  to roadmap: telemetry hardening (B1-B3, B5) + Lever Q-watchdog
  (B4/C1, promoted from deferred-from-Phase-1b status) + supporting
  stabilisation (C2-C4). Forensic dossier + tasks #78-#89 captured
  in [`freeze-2026-05-05-investigation.md`](./freeze-2026-05-05-investigation.md).
- **2026-05-05 evening** — Phase 1c B1+B2+B4 delivered (CSV fsync,
  hardlockup+kdump, Q-watchdog kthread). Two D1 re-tests both froze
  but produced rich data:
  - Test 1 (Q-watchdog Enable=1): Mode B silent host wedge, no markers
  - Test 2 (Q-watchdog Enable=0): **Mode A graceful failure with all 4
    reliability markers firing** + 50 AER events captured + Xid 154 +
    full wrapper post-state telemetry — then host wedged when wrapper
    triggered remove+rescan+FLR with persistenced/uvm-keepalive holding fds
  - Two facts established (PROVEN): NMI watchdog cannot catch this
    deadlock-class freeze; Phase 1b stack works correctly when fired
  - Methodology pivot: the
    [`reliability-hypothesis-ledger.md`](./reliability-hypothesis-ledger.md)
    becomes a living tracker, n=3 minimum to resolve, one variable per
    test. L1 prevention (DPC, PCIe tuning, IOMMU policy — H8/H9/H10)
    catalogued as the largest unexplored lever set.
