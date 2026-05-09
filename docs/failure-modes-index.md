# Failure modes ↔ resolutions index

This is the **executive summary** for someone who finds this project and asks "what problems does it solve, and how?". Every failure mode observed on this hardware (NUC 15 Pro+ + AORUS RTX 5090 over Thunderbolt 4 + Fedora 43) is catalogued here with its root cause, resolution, and pointers to deeper reading.

If your symptom matches one of these and you're on similar hardware, the resolution column tells you what to install/configure to fix it. If your symptom doesn't match anything here, the project's mitigations may not apply directly — but the methodology and tooling (state-capture, event-capture, probes, hypothesis ledger) still transfer.

> **Empirical scope:** every entry below was reproduced and resolved on the test hardware. Resolutions are not theoretical — they're what's running today.

## Quick-reference table

| # | Failure mode | Symptom | Root cause | Resolution status |
|---|---|---|---|---|
| 1 | Cold-cold-boot WPR2-stuck | Driver fails to initialise; GPU never comes up | Multi-cause (IOMMU rejection of GSP DMA + PCIe link instability at GSP boot) | **MITIGATED** — Lever T cmdline + 30-patch driver + retired H9a service |
| 2 | Host freeze on first CUDA op (Mode B silent) | Host wedges on `cuCtxCreate_v2`, ollama / vLLM / PyTorch first compute call | Open-driver commits to permanent GPU-lost on transient PCIe failures (upstream issue #979) | **RESOLVED** — Lever I, J-2, N, O patches + Lever Q-watchdog + Lever M-recover |
| 3 | `/dev/nvidia0` close-path bug (Problem 2) | Second `open(/dev/nvidia0)` hangs in syscall, locks host | Multiple cumulative causes (H9a + GSP boot dynamics + close-path teardown) | **MITIGATED** — empirically does not reproduce on current driver build (H22) |
| 4 | `/dev/nvidia-uvm` close-path bug (Problem 4) | Last close of UVM by CUDA process exit causes future-open host hang | Was attributed to UVM teardown; empirically NOT the same as Problem 2 | **RESOLVED** — UVM `va_space_destroy` is internal-state-only on current build; benign |
| 5 | `cuInit` failure → delayed kernel panic (Problem 3) | `cuInit()` returns 999, partial GPU state left, host panics minutes later | `cuInit` internal `modprobe nvidia_uvm` blocked by compute-only `install /bin/false` | **RESOLVED** — pre-stage `nvidia_uvm` at boot via loader script |
| 6 | GSP_LOCKDOWN cascade at boot | GSP firmware sends `GSP_LOCKDOWN_NOTICE` repeatedly, `rm_init_adapter` fails | Multi-cause: IOMMU rejecting DMA + PCIe link Gen3↔Gen4 retraining instability | **MITIGATED** — Lever T (`iommu=off`) + bridge-link-cap (LnkCtl2 bit 5) |
| 7 | Port A 100% boot failure (H9a) | Every Port A boot fails; Port B works | `aorus-egpu-pcie-tune.service` tightening DevCtl2 Range B caused TB-tunneled config-read timeouts | **RESOLVED** — service retired 2026-05-08; was actively harmful |
| 8 | Recovery storm (2026-05-06 incident) | First Lever M-recover Commit 3 attempted recovery 21 times in ~9 minutes, drove GPU into worse state | Recovery code lacked rate-limiting + MaxAttempts gate + kill-switch persistence + smarter error_handler | **RESOLVED** — patches 0024 + 0026 + 0027 + 0028 (H1/H2/H3/H4 hardening) |
| 9 | `thunderbolt.host_reset=true` breaks BAR1 | BAR1 sized incorrectly on cold-cold-boot, GPU init fails | TB host_reset clears device state in a way that breaks PCIe BAR enumeration on this AORUS hub topology | **RESOLVED** — explicit `thunderbolt.host_reset=false` in cmdline |
| 10 | `/dev/nvidia-uvm-tools` not created at boot | UVM-tools device file missing; downstream services skip via `ConditionPathExists` | `modprobe nvidia_uvm` only creates `/dev/nvidia-uvm` via devtmpfs; `-tools` is lazy-created on first `nvidia-modprobe -u -c 0` | **RESOLVED** — explicit `nvidia-modprobe -u -c 0` in loader script |
| 11 | `nvidia-smi` triggers ~17 s recovery cycle | Each `nvidia-smi` invocation opens/closes `/dev/nvidia0`; close-path destabilises link, Q-watchdog detects + Lever M re-inits | Close-path + monitoring polling created a feedback loop | **MITIGATED** — `aorus-egpu-observability-watchdog` redesigned to use only sysfs reads (no `/dev/nvidia*` open) |

---

## Detailed failure mode entries

### 1. Cold-cold-boot WPR2-stuck

**Symptom:** After power-cycling the eGPU enclosure, the NVIDIA driver fails to initialise. `nvidia-smi -L` returns "No devices found" or hangs. dmesg shows `_kgspBootGspRm: unexpected WPR2 already up`. The GPU enumerates on PCI but `rm_init_adapter` fails repeatedly.

**Root cause (multi-component):**
- The WPR2 register (NV_HUBMMU_PRI_MMU_WPR2_ADDR_HI at BAR0+0x88a828) reaches a "stuck-up" state during the failed first `rm_init_adapter`, blocking subsequent retries
- Originally attributed to "WPR2 persists across boots" — falsified 2026-05-06 via diagnostic telemetry; actual mechanism is **WPR2 set during failed first rm_init**, not across boots
- The first `rm_init_adapter` fails for two confirmed reasons:
  1. **IOMMU rejection of GSP DMA** — kernel TB security policy marks TB-attached devices "untrusted"; IOMMU keeps translation enabled even with `iommu=pt` cmdline
  2. **PCIe link instability at GSP boot** — Gen3↔Gen4 autonomous retraining at the wrong moment confuses GSP firmware

**Resolution:**
- **Lever T (cmdline):** `iommu=off intel_iommu=off` — eliminates IOMMU as a cause
- **Lever H17 (bridge-link-cap):** caps TB switch downstream port LnkCtl2 with bit 5 (Hardware Autonomous Speed Disable) before nvidia.ko binds — eliminates Gen4 retraining as a cause
- **Lever R (`aorus-egpu-wpr2-recovery.service`):** L4 userspace fallback (PCI remove + rescan + reset) — currently active as belt-and-braces, retiring after Phase 5 evidence (5/10 collected)
- **Lever M-recover (in-driver, patches 0024-0028):** post-rmInit-FAIL trigger → bus reset → slot_reset/resume — handles residual cases without userspace race

**Evidence:** docs/iommu-gsp-lockdown-analysis.md, archive/iommu-off-test-2026-05-07-145453/, archive/diag-telemetry-2026-05-06-154732/, H13/H14/H22 in reliability-hypothesis-ledger.md.

---

### 2. Mode B silent host freeze on first CUDA op

**Symptom:** `cuCtxCreate_v2`, ollama inference start, PyTorch `torch.zeros(.., device='cuda')` — the first CUDA op that writes to the GPU silently wedges the entire host. No Xid logged in journal, no oops, no panic — kernel writeback dies before flush. Only recovery is power cycle.

**Root cause (upstream issue #979):**
NVIDIA open driver commits to *permanent* GPU-lost state on a *single transient* PCIe register-read failure. The failure mode is documented in NVIDIA's own source comment: *"This doesn't support PEX Reset and Recovery yet."* On Blackwell over Thunderbolt, PCIe transients during high-throughput compute trigger the unrecoverable path.

**Resolution (driver-layer; ~13 LoC across 5 sites originally; ~300 LoC at current build):**
- **Lever I** (patch 0001): retry on transient PCIe failure in `osHandleGpuLost`
- **Lever J-2** (patches 0002-0004): cleanup-chain robustness — `rcdbAddRmGpuDump`, `nvDumpAllEngines`, resserv asserts
- **Lever N** (patch 0006): `rpcRmApiFree_GSP` short-circuit on gpu-lost
- **Lever O** (patch 0008): `_issueRpcAndWait` short-circuit on gpu-lost
- **Lever Q** (patches 0010-0015): three-stage MMIO health (passive + active + watchdog kthread) — converts undetected Mode B into deterministic Mode A then catches it
- **Lever M-base** (patch 0007): registers `pci_error_handlers` so AER notifications reach the driver
- **Lever M-recover** (patches 0024-0028): in-driver recovery state machine — bus reset on post-rmInit-FAIL or AER NEED_RESET → slot_reset → resume

**Evidence:** docs/freeze-investigation-plan.md (HISTORICAL); H1, H5, H11, H22; production-validated 2026-05-08 via Q2 (first real-world M-recover fire).

---

### 3. `/dev/nvidia0` close-path bug (Problem 2)

**Symptom (historical):** First open+close of `/dev/nvidia0` works. Second open hangs in `open()` syscall, locks host. Persists across `modprobe -r` — wedge state lives in firmware/per-PCI-device kernel structure.

**Status now:** **MITIGATED** — `tools/close-path-probe.sh` ran the exact "stop persistenced, open via `nvidia-smi -L`, close, observe next open" sequence n=3 on 2026-05-08. **Identical outcome each run: second open succeeds in ~1.3s, no host wedge, fires=0.** The close-path mutates real state (WPR2 cleared, link Gen3→Gen1, ~629ms teardown) but the next open recovers cleanly via standard `rm_init_adapter`.

**Root cause:** multi-cause; cumulatively eliminated via H9a retirement (was the dominant Port A trigger), Lever T cmdline, recovery levers I/J-2/N/O, G3-H UncMaskClear, Lever M-recover safety net.

**Mitigation in place:** `nvidia-persistenced` reclassified from "load-bearing for stability" to "load-bearing for warmup latency" — keeps `/dev/nvidia0` open count >0 to save the ~1.3s GSP-boot tax that would otherwise apply on every consumer warmup. Not strictly required for stability anymore.

**Evidence:** archive/close-path-probes/2026-05-08T18-57-32+10-00/ (and 2 more); H22 ledger entry; docs/services/nvidia-persistenced.md.

---

### 4. `/dev/nvidia-uvm` close-path bug (Problem 4)

**Symptom (historical, 2026-05-02):** CUDA process exit closes `/dev/nvidia-uvm`. If it was the last opener, a future open (potentially minutes later, by an unrelated process like PackageKit) silently hangs the host.

**Status now:** **RESOLVED** — Patch 0030 instrumentation + n=3 single-shot probes + n=3 churn probes (mimicking 2026-05-02 ollama-runner-churn pattern) — **6 reproductions, all benign**. UVM `uvm_va_space_destroy` does internal cleanup only (page tables, channels, mappings); does not touch GSP, WPR2, or PCIe link state.

**Root cause:** the original Problem 4 framing was a pattern-matched inference from Problem 2 that **did not match what UVM's close-path actually does**. UVM's teardown is qualitatively different from /dev/nvidia0's.

**Resolution:** `aorus-egpu-uvm-keepalive.service` retired 2026-05-08 evening. Binary preserved as historical archive.

**Evidence:** archive/uvm-close-path-probes/2026-05-08T*+10-00/, archive/uvm-churn-probes/, H22 ledger entry, docs/services/uvm-keepalive.md.

---

### 5. `cuInit` panic (Problem 3)

**Symptom:** `cuInit()` returns `CUDA_ERROR_UNKNOWN` (999). 1 MiB GPU memory allocated and never freed. Host kernel-panics minutes later — silent, no flushed logs.

**Root cause:** Compute-only mode blocks `nvidia*` modules from auto-loading via `install /bin/false` lines in modprobe.d. When `cuInit()` runs its internal `modprobe nvidia_uvm`, the install command runs `/bin/false` instead, returns 1, and `cuInit` returns 999. The partial GPU state set up before the modprobe call is never unwound; that's what causes the delayed panic.

**Resolution:** loader script `aorus-egpu-compute-load-nvidia` pre-stages `nvidia_uvm` via `modprobe --ignore-install nvidia_uvm` immediately after binding the GPU. With `nvidia_uvm` already loaded, no later `cuInit` call ever needs to invoke modprobe.

**Evidence:** Validated 2026-05-01 — archive/cuda-validation-2026-05-01/. docs/architecture.md Problem 3.

---

### 6. GSP_LOCKDOWN cascade at boot

**Symptom:** dmesg shows multiple `NVRM: ... GSP_LOCKDOWN_NOTICE` events during early boot, leading to `rm_init_adapter` failure. The firmware itself has tripped its lockdown.

**Root cause (multi-component):**
- **Cause 1 — IOMMU DMA rejection:** kernel TB security marks TB-attached devices "untrusted"; IOMMU rejects GSP firmware's DMA setup; GSP enters lockdown
- **Cause 2 — PCIe link instability:** hardware-autonomous Gen3↔Gen4 retraining at GSP boot disturbs the firmware
- **Cause 3 (initially attributed):** Port A H9a service tightening DevCtl2 Range B → TB config-read timeouts → driver classifies GPU as PCI not PCIe → rm_init fails → GSP firmware sees host-side communication failure → lockdown

**Resolution (cumulative):**
- Cause 1: Lever T cmdline (`iommu=off`)
- Cause 2: bridge-link-cap LnkCtl2 bit 5 (Hardware Autonomous Speed Disable)
- Cause 3: H9a retirement 2026-05-08

**Verification:** 11+ consecutive clean boots since H9a retirement, zero GSP_LOCKDOWN events. Q2 (deliberate cap removal 2026-05-08 evening) reproduced the failure at n=1 — confirms cap is load-bearing.

**Evidence:** docs/iommu-gsp-lockdown-analysis.md, archive/gen3-fail-2026-05-07-165158/, H10/H16/H17 ledger entries.

---

### 7. Port A 100% boot failure (H9a)

**Symptom:** Every cold-cold-boot on TB Port A fails; Port B works. `nvidia-smi -L` returns "No devices found"; dmesg shows GSP_LOCKDOWN cascade.

**Root cause:** `aorus-egpu-pcie-tune.service` (Lever H9a) tightened DevCtl2 to Range B (1ms-10ms) on Port A only. Tight timeout caused TB-tunneled config reads to time out → driver classified the GPU as PCI not PCIe → `rm_init_adapter` failed because the PCIe-aware init paths assumed PCIe.

**Resolution:** service retired 2026-05-08 morning. Was actively harmful, not just unnecessary. **Important:** resurrection of this service is NOT recommended — it caused the failure. See docs/services/pcie-tune.md.

**Evidence:** matched-pair forensic dossier 2026-05-08, memory `project_port_a_h9a_root_cause_2026_05_08.md`.

---

### 8. Recovery storm (2026-05-06 incident)

**Symptom:** First attempt at Lever M-recover Commit 3 (patch 0019). Recovery fired, attempted, fired again, attempted again — 21 times in ~9 minutes. Each attempt drove the GPU into a worse stuck state. Manual intervention required.

**Root cause:** original Commit 3 lacked four hardening fixes:
- H1: MaxAttempts gate (no upper bound on retries)
- H2: Rate-limit (no minimum interval between attempts)
- H3: Kill-switch persistence (`echo 0 > /sys/module/.../Enable` reset by L4 helper's modprobe -r)
- H4: Smarter error_detected (returned DISCONNECT during recovery, conflicting with the recovery itself)

**Resolution:** patch 0019 reverted; replaced with patches 0024 + 0026 + 0027 + 0028 implementing all four H15 fixes. Phase 4 testing (n=4 force-fires for H1; back-to-back for H2; modprobe-r round-trip for H3) PASSED. Production-validated 2026-05-08 via Q2's natural fire.

**Evidence:** archive/commit3-recovery-loop-2026-05-06-161429/, H15 ledger entry (RESOLVED), docs/services/wpr2-recovery.md.

---

### 9. `thunderbolt.host_reset=true` breaks BAR1 sizing

**Symptom:** Cold-cold-boot, GPU enumerates with wrong BAR1 size. nvidia.ko bind fails or behaves erratically.

**Root cause:** TB host_reset clears device state in a way that breaks PCIe BAR enumeration on this specific AORUS hub topology. The PCIe enumeration sequence races against device readiness.

**Resolution:** `thunderbolt.host_reset=false` explicit in kernel cmdline. The default sometimes flips between values across kernel/firmware updates — pinning it explicitly is safer.

**Evidence:** memory `feedback_check_existing_guards_before_cmdline_experiments.md`.

---

### 10. `/dev/nvidia-uvm-tools` not created at boot

**Symptom:** `aorus-egpu-uvm-keepalive.service` and other services that `ConditionPathExists=/dev/nvidia-uvm-tools` skip silently because the device file doesn't exist yet.

**Root cause:** `modprobe nvidia_uvm` only creates `/dev/nvidia-uvm` via devtmpfs. The `-tools` device file is lazy-created on the first `nvidia-modprobe -u -c 0` call.

**Resolution:** loader script `aorus-egpu-compute-load-nvidia` invokes `nvidia-modprobe -u -c 0` immediately after `modprobe nvidia_uvm`. **Important caveats:** the bare invocation `nvidia-modprobe -u` (without `-c 0`) is a no-op; `nvidia-modprobe -u -c 0 -c 1` is destructive (creates extra UVM devices at minors 1 and 2 that overwrite the canonical files). Only `-u -c 0` is correct.

---

### 11. `nvidia-smi` triggering ~17s recovery cycle

**Symptom (historical, pre-2026-05-07):** Each `nvidia-smi` invocation triggered a periodic ~17s recovery cycle. Q-watchdog detects, Lever M re-inits, GPU stable for ~10s, repeat.

**Root cause:** the original `aorus-egpu-observability-watchdog` polled `nvidia-smi -L` every 10s for liveness. Each poll opened+closed `/dev/nvidia0`; the close-path destabilised the link; Q-watchdog detected the loss; Lever M-recover (or its predecessor) re-inited the GPU. Net effect: the monitoring tool was creating the failures it was supposed to detect.

**Resolution:** observability-watchdog redesigned 2026-05-07 to use only passive sysfs reads:
- `/sys/bus/pci/devices/<bdf>/vendor` + `device` (PCI enumeration)
- `/sys/bus/pci/devices/<bdf>/driver` (binding check)
- `/sys/bus/pci/devices/<bdf>/aorus_lever_m_*` and `aorus_qwatchdog_*` (recovery counters)

None touch `/dev/nvidia*`; no close-path triggered. Mode B silent freezes still detectable via "GPU unbound + active iter progress.csv stale" combination.

**Evidence:** memory `feedback_avoid_nvidia_smi_for_state_checks.md`, docs/services/observability-watchdog.md.

---

## The full mitigation stack

For someone replicating this setup, the resolution requires multiple co-operative components:

### Kernel cmdline (`etc/kernel/cmdline.txt`)
```
iommu=off intel_iommu=off                                # Lever T
thunderbolt.host_reset=false                             # Failure mode 9
pci=realloc=off,pcie_bus_perf,hpmmioprefsize=256M,resource_alignment=35@<bridge_bdf>
pcie_aspm.policy=performance thunderbolt.clx=0 pcie_port_pm=off
module_blacklist=nouveau,nova_core (×3 forms)
```

### Driver patches (`patches/`, applied via `tools/build-patched-driver.sh`)
30 patches against NVIDIA-open-gpu-kernel-modules 595.71.05. Categories:
- 0001-0008: gpu-lost retry + cleanup chain (Mode B mitigation)
- 0010-0015: Lever Q MMIO health
- 0016-0023: Lever M scaffolding + DIAG telemetry + UncMaskClear
- 0024-0028: Lever M-recover hardened
- 0029-0030: close-path DIAG instrumentation
- 0025: standalone Kbuild fix (clean upstream candidate)

### Userspace services (`etc/systemd/system/` + `usr/local/sbin/`)
| Service | Purpose | Status |
|---|---|---|
| `aorus-egpu-compute-load-nvidia` | Boot-time bind orchestration (compute-only mode) | Active |
| `aorus-egpu-bridge-link-cap` | LnkCtl2 bit 5 cap on TB bridge (failure mode 6) | Active |
| `aorus-egpu-observability-watchdog` | Passive Mode B detector (failure mode 11 redesign) | Active |
| `aorus-egpu-lever-m-phase5-snapshot` | Per-boot M-recover evidence collection | Active |
| `nvidia-persistenced` (vendor) | `/dev/nvidia0` open-count maintenance (warmup latency optimisation) | Active |
| `aorus-egpu-wpr2-recovery` | L4 belt-and-braces recovery (failure mode 1) | Pending retirement (5/10 evidence) |
| `aorus-egpu-uvm-keepalive` | (failure mode 4 historical) | RETIRED 2026-05-08 |
| `aorus-egpu-pcie-tune` | (failure mode 7 root cause; was active mitigation pre-discovery) | RETIRED 2026-05-08 |
| `aorus-egpu-link-monitor` | (forensic — historical Mode B investigation) | RETIRED 2026-05-07 |

### Configuration files
- `etc/udev/rules.d/79-aorus-egpu-no-autoload.rules` — driver_override + MODALIAS clearing (compute-only)
- `etc/udev/rules.d/81-aorus-egpu-compute-power.rules` — PM policy (no autosuspend, no D3cold)
- `etc/udev/rules.d/82-aorus-egpu-nvidia-permissions.rules` — `/dev/nvidia*` 0660 root:ollama
- `etc/udev/rules.d/82-aorus-egpu-lever-m-killswitch.rules` — Lever M kill-switch udev hook
- `etc/modprobe.d/aorus-egpu-compute-only.conf` — block autoload + DPM=0 + blacklists
- `etc/modprobe.d/aorus-egpu-lever-m.conf` — Enable Lever M-recover at module load
- `etc/modprobe.d/nvidia.conf` — drop softdep nvidia-drm (failure mode preventer)
- `etc/aorus-egpu/config.env` (auto-generated by `aorus-egpu-detect-config`) — per-host topology

---

## What this project does NOT solve

For honesty / setting expectations:

- **Cold-load perf gap.** Path A scope says BOTH reliability AND performance parity with WSL2. Decode is at parity (105% on llama3.1:8b). First model load is ~3.95s vs WSL2's ~30ms — 130× slower. Not a reliability issue; different problem class. vLLM-specific perf investigation tracked at `/root/vllm/docs/perf-roadmap.md`.
- **Suspend / resume cycles.** Untested. `pcie_port_pm=off` + udev `power/control=on` are conservative defaults for compute use; behaviour with the lid closed / system sleep may need additional work.
- **Multi-GPU configs.** Project assumes the eGPU is the *only* NVIDIA device on PCI. udev rules that target the GPU specifically would need refinement on a system with both internal and external NVIDIA.
- **Other TB enclosures.** Project tested on the AORUS RTX 5090 AI Box specifically. Other enclosures (Razer Core X, OWC Mercury, etc.) have different bridge topologies and may need adjusted `resource_alignment` cmdline + udev matching.
- **Other host CPU families.** Tested on Intel NUC 15 Pro+ (Arrow Lake-H). Other Intel TB controllers should work; AMD TB controllers may need different vendor:device IDs in udev rules and different host-port BDFs.
- **Display / graphics use.** Compute-only mode by design — no `nvidia_drm` module, no `/dev/dri/cardN` for the eGPU. To use the GPU as a display device requires reverting most of the project's mitigations.

---

## Reading order for new readers

1. This document — overview of what's solved
2. [`docs/architecture.md`](./architecture.md) — the structural model
3. [`docs/lever-catalog.md`](./lever-catalog.md) — every lever with mechanism + status
4. [`docs/services/`](./services/) — per-service operational detail
5. [`docs/reliability-hypothesis-ledger.md`](./reliability-hypothesis-ledger.md) — every hypothesis with verdict
6. [`docs/service-retirement-roadmap.md`](./service-retirement-roadmap.md) — the "perfect end state is zero workaround services" arc
7. Specific investigation dossiers (`docs/iommu-gsp-lockdown-analysis.md`, `docs/freeze-investigation-plan.md`, etc.) — when you need depth on a specific failure
