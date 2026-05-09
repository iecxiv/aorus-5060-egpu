# Freeze 2026-05-05 16:50 — Mode B silent freeze + telemetry/stabilisation investigation plan

> **Trigger:** First CUDA workload (qwen2.5:0.5b model load via ollama)
> after a cold boot. Froze ~14 seconds in, mid model upload (between
> tensor `blk.23.attn_v.bias` and the next tensor's load).
>
> **Artifacts:** `/root/ollama/archive/loop-2026-05-05-165029/`
> (only iter-01/, with empty master.csv/flr.csv/markers.csv — see
> Telemetry gaps below).
>
> **Significance:** This is the first **post-Lever-Q** Mode B freeze.
> Q-active was supposed to convert Mode B → Mode A on this hardware.
> It did not fire. This document is the forensic dossier and the
> methodical plan to close the gap.
>
> **Last updated:** 2026-05-05 17:00

---

## Timeline (real wall-clock)

| Time | Event |
|---|---|
| ~16:47:43 | Cold-boot starts; user post-power-cycle return to working session |
| 16:50:29.767 | Wrapper kicked off: `loop-2026-05-05-165029`, ITERATIONS=1, MODEL=qwen2.5:0.5b |
| 16:50:30.152 | AORUS LOOP iter=1 start marker logged |
| 16:50:31 | Harness phase=start |
| 16:50:33 | Phase=idle-pre (10s baseline sampling) |
| 16:50:33-43 | 10 clean idle samples: GPU P8, 19-21W, 26°C, mem=4476-4555 MiB |
| 16:50:43 | Phase=test, prompt sent to ollama API |
| 16:50:43 | First decode-phase sample: cpu=2.5%, gpu=0% — request just sent |
| 16:50:44 | cpu=9.3%, mem=4811 MiB (+283 MiB jump), gpu=0% — model load in progress; ollama service log showing tensor `blk.23.attn_v.bias` (last tensor name flushed before freeze) |
| **16:50:44+x** | **SILENT FREEZE — no further kernel or userspace log output until next boot** |
| 16:54:30 | Manual power-cycle → boot 0 (current) starts |
| ~16:55-57 | This investigation session |

**Time CUDA-start → freeze:** ≤ 1 second (confirms Mode B per
`stability-roadmap.md` taxonomy).

**Time freeze → user power-cycle:** ~3-4 minutes (host fully wedged;
no SSH responsive, mouse/keyboard frozen).

---

## Pre-state at 16:50:30 (was the system healthy?)

| Check | Value | Healthy? |
|---|---|---|
| GPU pstate | P8 | ✅ |
| GPU power | 18W | ✅ idle |
| GPU temp | 26°C | ✅ |
| GPU mem | 0 MiB used | ✅ |
| GPU processes | none | ✅ |
| PCIe link | Speed 2.5GT/s, Width x4, ASPM Disabled | ✅ TB Gen1 normal |
| AER correctable counters | all 0 | ✅ |
| AER non-fatal counters | all 0 | ✅ |
| services | ollama / persistenced / uvm-keepalive / load-nvidia all active | ✅ |
| nvidia-smi smoke | `exit_code=0` | ✅ |

**No pre-freeze warning signal.** System looked completely healthy at
iter start. This is consistent with prior Mode B observations.

---

## What our existing telemetry CAUGHT

- Pre-state snapshot (lspci, AER, link, nvidia-smi, dev nodes, modules, ollama procs) — complete
- Iter-start kernel marker via `logger`
- 10 idle-baseline samples (system.csv, gpu.csv) — clean
- 1-second resolution showing CPU spike at request time, RAM jump as model load began
- ollama service log captured tensor names through `blk.23.attn_v.bias`
- perf-kprobes attached (no events fired before freeze beyond attach)

## What our existing telemetry MISSED — the load-bearing gaps

| Gap | What we lost | Severity |
|---|---|---|
| Per-iter CSVs (`master.csv`, `flr.csv`, `markers.csv`) not flushed mid-iter | All structured per-iter metrics | CRITICAL |
| No in-kernel marker for "DMA submitted, awaiting completion" | Can't distinguish DMA-path from kernel-launch-path freeze | HIGH |
| No host-side hardlockup detection (no NMI watchdog, no kdump) | No vmcore captured during the 3-min wedge | HIGH |
| No external watchdog | Host stayed wedged until manual power-cycle | MEDIUM |
| perf-kprobes log not flushed (in-kernel BPF buffer) | Last-known-good ioctl not preserved | MEDIUM |
| **No active heartbeat MMIO** (Q-watchdog deferred from Phase 1b) | A kthread doing periodic NV_PMC_BOOT_0 reads would have caught the bus drop | HIGH |
| No DMA in-flight state | Don't know which tensor's upload was the trigger | LOW |

---

## Why didn't Lever Q fire?

The load-bearing question of this investigation.

**Q-active wraps `osDevReadReg{8,16,32}`** — the kernel-side **MMIO
read** path. It triggers when reads return `0xFFFFFFFF` after the
post-read PMC_BOOT_0 verify, and propagates GPU-lost state.

**The freeze occurred mid model upload** — `cuMemcpyHtoD` chain
streaming tensor weights. That code path is dominated by:
- DMA setup (descriptor allocation, IOMMU mapping)
- DMA submission (write to GPU's submission queue via doorbell)
- Wait for DMA completion (interrupt or polled status)

**MMIO reads via `osDevReadReg32`** are infrequent on the upload hot
path. The bus likely dropped during DMA and the kernel hung waiting
for completion — at which point Q-active had no MMIO read to evaluate.

**Conclusion:** Q-active is necessary but not sufficient. It protects
the MMIO read path. Mode B can wedge through DMA, IRQ, or page-fault
paths where no MMIO read fires. We need complementary mechanisms:

1. **Active probing** (Q-watchdog kthread) — periodic MMIO reads
   independent of ioctl path
2. **DMA-completion timeout** — bounds the DMA wait so the kernel
   doesn't hang forever
3. **External hardlockup detection** — kernel-side panic + kdump
4. **External health watchdog** — userspace daemon triggers FLR

---

## Methodical investigation plan

Tracked as tasks in this session. Each step has a layer assignment per
[`architecture-and-modularity.md`](./architecture-and-modularity.md).

### Phase A — Deepen forensic analysis of *this* freeze

| Task | Step | Output |
|---|---|---|
| #78 | A1: pre-state diff this freeze vs yesterday's 13/13 successful | Identify cold-boot-specific anomaly |
| #79 | A2: pinpoint freeze trigger to specific CUDA call | Specific cuMemcpyHtoD or cuMemAlloc trigger |
| #80 | A3: lspci -vvv diff clean-now vs frozen-pre-state | Topology / link state difference |

### Phase B — Close the telemetry gaps

| Task | Step | Layer |
|---|---|---|
| #81 | B1: incremental fsync of master.csv / flr.csv / markers.csv during iter | L6 (test harness) |
| #82 | B2: hardlockup detector + kdump for crash dump on freeze | L5 (cmdline + systemd) |
| #83 | B3: aorus-egpu-watchdog — external health-check + auto-FLR helper | L4 (shell helper) + L5 (systemd unit) |
| #84 | B4 / C1: Lever Q-watchdog — kthread heartbeat MMIO read | L1 (NVIDIA fork — justified) |
| #85 | B5: passive cuda-trace on warm-up workload (not during real test) | L6 (separate harness) |

### Phase C — Stabilisation mechanisms

| Task | Step | Why |
|---|---|---|
| #84 | C1: Q-watchdog kthread (same as B4) | Active probing covers DMA-path freeze gap |
| #86 | C2: DMA-completion timeout — source review | Read-only review first; bound DMA waits |
| #87 | C3: pre-test cold-boot warm-up routine | Isolate cold-boot-first-CUDA from model-load-bandwidth |
| #88 | C4: hardware watchdog (iTCO_wdt) for last-resort recovery | Avoid manual power-cycle on host wedge |

### Phase D — Re-test cadence

| Task | Step | Gate |
|---|---|---|
| #89 | D1: re-test single iter with B1+B2+B4 in place | Blocked by #81, #82, #84 |

---

## Recommended first concrete actions (highest value, lowest risk)

1. **B1 (#81) — incremental CSV fsync.** ~1 hour, wrapper-only, no
   reboot. Means next freeze leaves on-disk evidence not header-only
   files.
2. **B2 (#82) — hardlockup detector + kdump.** ~1 hour, cmdline +
   systemd, one reboot. Means next freeze produces a vmcore on next
   boot.
3. **B4 / C1 (#84) — Q-watchdog kthread.** ~1 day, single L1 patch,
   one DKMS rebuild. The biggest stabilisation win — closes the gap
   Q-active leaves on DMA-path freezes.

After 1-3, **D1 (#89) re-test** with full new telemetry in place.

---

## Cross-references

- [`stability-roadmap.md`](./stability-roadmap.md) — overall reliability
  framework + lever inventory
- [`architecture-and-modularity.md`](./architecture-and-modularity.md) —
  sovereign-module layer assignments
- [`lever-Q-design.md`](./lever-Q-design.md) — Phase 1b (the existing
  Q-passive + Q-active patches that did NOT fire on this freeze)
- [`recovery-mechanism-findings.md`](./recovery-mechanism-findings.md) —
  FLR experiment data
- `/root/ollama/archive/loop-2026-05-05-165029/` — forensic snapshot
  of this freeze
- Project memory `feedback_observability_perturbs_bug.md` — why we keep
  cuda-trace off during real tests

---

## Update log

- **2026-05-05 17:00** — initial publication. Captures freeze forensics
  + Phase A-D investigation plan. Tasks #78-#89 created and wired with
  dependencies (#89 D1 re-test gated on #81 B1 + #82 B2 + #84 B4).
