# Architecture and modularity — sovereign module map

> **Authoritative reference** for *where* each piece of the AORUS eGPU
> stack lives, *why* that home was chosen, and the rules for adding new
> code. Companion to [`architecture.md`](./architecture.md) (which
> explains *what* each piece does) and [`stability-roadmap.md`](./stability-roadmap.md)
> (which explains *what's planned*).
>
> **Last updated:** 2026-05-04
>
> **Origin:** during the perf-investigation discussion on 2026-05-04 the
> user framed performance work in terms of "intelligent things in
> native + driver that we control." Operationalising that framing
> requires a clear contract for which code goes where so that the
> stack remains pluggable, removable, and not a runaway NVIDIA fork.

---

## The problem this doc solves

Without this contract, every new lever has a tendency to land as another
patch in the NVIDIA fork. Two years later that fork is unmaintainable:
every NVIDIA driver release means rebasing N hand-written patches across
moved code, and removing a single feature is non-trivial.

The right answer is to keep each lever in the smallest, most independent
home that can host it — and to push as much logic as possible *out* of
the NVIDIA fork.

---

## Sovereign layers (highest fork-cost to lowest)

```
┌─────────────────────────────────────────────────────────────────┐
│ L1: NVIDIA open KMD fork  (patches/0001-NNNN-*.patch)           │  HIGHEST cost
│     — touches NVIDIA-internal state, RPC dispatch, GSP path     │
├─────────────────────────────────────────────────────────────────┤
│ L2: Companion kernel module  (aorus-egpu-helper.ko, future)     │
│     — independent kmod, exported-symbols + kprobes only         │
├─────────────────────────────────────────────────────────────────┤
│ L3: Userspace daemon  (systemd service, root)                   │
│     — orchestration, uevent handling, recovery state machine    │
├─────────────────────────────────────────────────────────────────┤
│ L4: Userspace shell helpers  (usr/local/sbin/aorus-egpu-*)      │
│     — one-shot at boot, tuning, recovery commands               │
├─────────────────────────────────────────────────────────────────┤
│ L5: Pure config  (cmdline, modprobe.d, systemd unit, udev,      │
│     sysctl, sysfs writes via udev RUN+=)                        │
├─────────────────────────────────────────────────────────────────┤
│ L6: Inference engine  (ggml-cuda / ollama / llama.cpp patches)  │
│     — workload-side optimisations, upstreamable                 │
├─────────────────────────────────────────────────────────────────┤
│ L7: External integration  (NVIDIA GDS / nvidia-fs / DKMS)       │  LOWEST cost
│     — pull in existing components rather than build our own     │
└─────────────────────────────────────────────────────────────────┘
```

Each layer below describes its purpose, when it's justified, current
contents, and rebase/maintenance cost.

---

### L1 — NVIDIA open KMD fork

**Path:** `/root/aorus-5090-egpu/patches/0001-NNNN-*.patch`
**Cost:** HIGH — every NVIDIA driver release means rebasing every patch.
**Output artifact:** patched DKMS-built `nvidia.ko` (`595.71.05-aorus.N`).

**When justified — and *only* when:**

1. The change is on a hot path inside NVIDIA-internal code (e.g. the
   register-read macro, RPC dispatch, GSP-call wrappers).
2. The change needs access to NVIDIA-internal struct fields,
   `PDB_PROP_*` flags, or RM-side state that isn't exported.
3. There is no public interface (sysfs, exported symbol, kernel
   tracepoint) that would let the same intervention live in a lower
   layer.

If the change can be done from L2 or above, do it there.

**Currently hosts:**

| Patch | Lever | Justification for L1 home |
|---|---|---|
| 0001 | I (osHandleGpuLost retry) | hot path inside `osHandleGpuLost`; touches NV-internal retry logic |
| 0002-0004 | J-2 (rcdbAddRmGpuDump shortcircuit + 3 sites) | reaches into NV crash-dump path, NV-internal struct access |
| 0005 | version mark | string only, no logic — necessary in fork to track which patches are present |
| 0006 | N (rpcRmApiFree_GSP shortcircuit) | RPC dispatch path, GSP-internal |
| 0007 | M-base (pci_error_handlers) | registers via `pci_driver` struct in `nv-pci.c` — must be inside the driver |
| 0008 | O (_issueRpcAndWait shortcircuit) | RPC dispatch hot path |
| 0009 | P-probe (UVM destroy markers) | UVM-internal cleanup paths |
| 0010 | Q (os_pci_is_disconnected helpers) | adds NV-internal helpers visible to RM-side `os.c` |
| 0011-0012 | Q-passive (osDevReadReg{8,16,32}) | wraps NV-internal MMIO macros — every register read in the driver |
| 0013 | Q-active (post-read PMC_BOOT_0 verify) | same wrapper, with active probe |

All current L1 patches have justification 1 or 2 above. **Rule of thumb:
if an L1 patch is being added that touches `os-*.c` or `os-interface.h`
only (i.e. NV's OS abstraction layer with no RM-internal references), it
should be evaluated for L2 viability first.**

---

### L2 — Companion kernel module

**Path:** *not yet built* — would live at `/root/aorus-5090-egpu/kmod/aorus-egpu-helper/`.
**Cost:** MEDIUM — tracks kernel API changes (smaller surface than NVIDIA's), independent versioning.
**Output artifact:** `aorus-egpu-helper.ko` (DKMS-managed, separate from nvidia.ko).

**When justified:**

1. Hot-path kernel-side intervention but *doesn't* require NVIDIA-internal
   access — only exported symbols, sysfs, kprobes, or tracepoints.
2. Logic that should be loadable/unloadable independently of `nvidia.ko`.
3. Logic that benefits from being upstreamable to mainline as a
   PCIe / Thunderbolt topology helper.

**Future home for:**

| Lever | Why L2 |
|---|---|
| **J-1: L1 bus-hardening companion** (#49) | NVIDIA-agnostic; uses PCIe core APIs to harden upstream bridges. Should not depend on `nvidia.ko`. |
| **PCIe link tuner companion** | If we move beyond one-shot setpci helpers and need active monitoring (e.g. re-applying MaxPayload after a hot-replug), a kmod is the right home. |
| **Recovery uevent emitter** (alternative to L1 patch) | Instead of patching nvidia.ko to emit uevents, a companion module could observe via tracepoint and emit. Reduces fork debt. |
| **Batched-submit shim** | Future thinking only — would require nvidia.ko exporting an interface, which it doesn't today. Probably L1+L6 instead. |

**Rule:** check the nvidia.ko exported-symbols list (`grep -E '^EXPORT_SYMBOL' open-gpu-kernel-modules/`)
and the kprobe-able function set before designing an L2 module. If the
right hooks aren't exposed, either request export upstream or accept the
intervention belongs in L1.

---

### L3 — Userspace daemon

**Path:** *not yet built* — would be a Python or shell daemon under
`/root/aorus-5090-egpu/usr/local/sbin/` plus a systemd service.
**Cost:** LOW.
**Output artifact:** `aorus-egpu-monitor.service` (illustrative name).

**When justified:**

1. Orchestration logic that responds to events (uevents, sysfs change,
   timer ticks) and takes actions through documented kernel interfaces.
2. State machines that don't need to live in the kernel.
3. Telemetry collection / aggregation for production use.

**Future home for:**

| Use case | Why L3 |
|---|---|
| **Recovery state machine** (above the M-recover slot_reset callback) | The driver's `pci_error_handlers` is one tier; the user-visible "what to do when GPU is recovered" decisions can live in userspace, observing uevents from L1 and orchestrating ollama restart, model-reload, etc. |
| **Telemetry / sysfs counter aggregation** (Phase 6 polish) | Aggregate per-driver-instance error counters, expose Prometheus metrics, etc. Pure userspace. |
| **GPUDirect Storage glue** | If we go after `nvidia-fs` integration, the daemon side of that ecosystem is userspace. |
| **Watchdog / liveness checks** | Periodic `nvidia-smi -q` style probes; reacts via uevent or systemd-trigger. |

---

### L4 — Userspace shell helpers

**Path:** `/root/aorus-5090-egpu/usr/local/sbin/aorus-egpu-*`
**Cost:** VERY LOW — bash, no DKMS, no kernel API tracking.

**When justified:**

1. One-shot operations: apply a setting at boot, perform a recovery
   action, dump diagnostic state.
2. Things that match the established `aorus-egpu-*` shell-helper pattern
   (per `feedback_shell_over_c.md`: prefer shell over C for platform helpers).

**Currently hosts:**

| Helper | Purpose | Status |
|---|---|---|
| `aorus-egpu-compute-load-nvidia` | Boot-time driver bind orchestration | Active |
| `aorus-egpu-disable-audio` | Unbind HDA from the eGPU audio function | Active |
| `aorus-egpu-status` | Comprehensive verification | Active |
| `aorus-egpu-bridge-link-cap` | Gen3+bit5 link cap helper | Active |
| `aorus-egpu-observability-watchdog` | Mode B passive sysfs detection | Active (passive-redesign 2026-05-07) |
| `aorus-egpu-lever-m`, `aorus-egpu-lever-m-killswitch-restore`, `aorus-egpu-lever-m-phase5-snapshot` | Lever M-recover CLI / udev / Phase 5 snapshot | Active (added 2026-05-08) |
| `aorus-egpu-uvm-keepalive` | Hold UVM device file fds (Problem 4 mitigation) | **RETIRED 2026-05-08** — empirical evidence (Patch 0030 + n=6 UVM probes) confirms UVM close-path is benign on current driver stack |
| `aorus-egpu-link-monitor` | Forensic Mode B observability | **RETIRED 2026-05-07** — replaced by passive sysfs reads |
| `aorus-egpu-pcie-tune` | DevCtl2 Range B tightening | **RETIRED 2026-05-08** — was actively harmful (Lever H9a Port A boot-failure root cause) |
| `aorus-egpu-wpr2-recovery` | L4 Lever R Tier 1 v3 helper | Pending Phase 5 retirement gate (5/10) |

**Future home for:**

| Lever | Why L4 |
|---|---|
| **PCIe MaxPayload / MaxReadReq tuner** | One `setpci` invocation per device on the eGPU path at boot. Reversible by omitting the helper. |
| **ASPM force-off helper** | sysfs writes `policy=performance` per device. |
| **CPU IRQ affinity setter for nvidia IRQ** | one-shot `echo` to `/proc/irq/N/smp_affinity_list` after driver bind. |
| **PCIe completion-timeout tuner** | per-device sysfs write, runs after driver bind. |
| **Recovery one-shot: `aorus-egpu-flr`** | wraps the remove+rescan+FLR sequence as a single command for manual recovery (already a snippet in tools/, could be promoted). |

---

### L5 — Pure config

**Paths:**
- `/root/aorus-5090-egpu/etc/kernel/cmdline.txt` — boot args
- `/root/aorus-5090-egpu/etc/modprobe.d/*.conf` — module options
- `/root/aorus-5090-egpu/etc/systemd/**/*.{service,conf}` — units
- `/root/aorus-5090-egpu/etc/udev/rules.d/*.rules` — udev rules
- `/root/aorus-5090-egpu/etc/sysctl.d/*.conf` *(future)* — kernel tunables

**Cost:** NEAR-ZERO — pure declarative config, no code to maintain.

**When justified:**

1. The kernel or userspace already exposes a tunable that does the right thing.
2. The setting is stable across kernel versions (or breakage is loud).
3. Reversibility is by file removal.

**Currently hosts:** see `architecture.md` "How the configuration enforces this" section.

**Future home for:**

| Lever | Why L5 |
|---|---|
| **Hugepages reservation** | `default_hugepagesz=1G hugepagesz=1G hugepages=N` in cmdline, or `vm.nr_hugepages` in sysctl. Pure config. |
| **CPU governor = performance** | systemd unit + `/etc/systemd/system.conf.d/` or sysfs writes via udev RUN+=. |
| **Energy-Perf Bias** | sysfs write per CPU at boot. |
| **SCHED_FIFO / nice for ollama threads** | systemd unit slice with `CPUSchedulingPolicy=fifo` or `Nice=-20`. |
| **Transparent hugepages = always for ollama cgroup** | systemd unit `MemoryHigh=` + transparent_hugepage sysfs. |
| **NUMA pinning** | `Numa*=` directives in systemd unit (NUC is single-NUMA, so usually n/a, but documented). |

---

### L6 — Inference engine

**Path:** `/root/ollama/` (vendored ollama + ggml-cuda) or upstream patches.
**Cost:** LOW (upstream-able), MEDIUM if vendored fork.

**When justified:**

1. The change belongs in the workload, not the driver.
2. Optimisations specific to LLM inference patterns (CUDA Graphs, async
   pipelining, custom kernels).
3. Anything that uses CUDA Driver API or CUDA Runtime API without
   needing kernel-side cooperation.

**Future home for:**

| Lever | Why L6 |
|---|---|
| **CUDA Graphs verification / enablement** | ggml-cuda decision; ollama config. Likely already supported, may just need flag tuning. |
| **Async cuMemcpyHtoD pipelining** | model upload path lives in ggml-cuda backend. |
| **`madvise(MADV_WILLNEED)` for model file** | ollama-side; pure userspace syscall. |
| **`io_uring` for model file reads** | ollama-side; tightens upload pipeline. |
| **GPUDirect Storage upload path** | ggml-cuda integration with `cuFileRead` API. |
| **Custom kernels for hot ops** | ggml-cuda kernel set; usually upstream-able. |
| **`cudaMemAdvise` for read-mostly weights** | ollama or ggml-cuda runtime hint. |

---

### L7 — External integration

**Cost:** depends on external project lifecycle.

**When justified:**

1. There's an existing NVIDIA / kernel / distro component that already
   does the right thing — consume it rather than reimplement.
2. Long-term ecosystem alignment matters more than short-term control.

**Currently hosts:**

| Component | Purpose |
|---|---|
| **DKMS** | Builds `nvidia.ko` (with our fork patches applied) per kernel update. |
| **bolt** | Thunderbolt authorization (we depend on it for tunnel up). |
| **systemd-udevd** | Device lifecycle. |
| **Fedora `nvidia-driver` RPM family** | Userspace bits (libnvidia-*, nvidia-smi, nvidia-persistenced) consumed as-is. |

**Future home for:**

| Lever | Why L7 |
|---|---|
| **NVIDIA GPUDirect Storage / `nvidia-fs`** | Pull in the existing daemon ecosystem rather than build our own DMA-from-file path. |
| **`nvidia-persistenced` configuration** | Already L7 — we drop in `nvidia-persistenced.service.d/aorus-egpu.conf` rather than fork persistenced. |
| **upstream mainline kernel improvements** | Where our companion module work is upstreamable to `drivers/pci/*`, push there rather than vendor here. |

---

## Decision flowchart for a new lever

When designing a new lever:

```
   ┌────────────────────────────────────────────────────┐
   │ Does the change touch NVIDIA-internal struct       │
   │ fields, RPC dispatch, GSP-call wrappers, or hot    │
   │ paths inside RM-side code?                         │
   └─────────────┬─────────────────┬────────────────────┘
                 │ yes              │ no
                 ▼                  ▼
        L1 (NVIDIA fork)   ┌────────────────────────────┐
                           │ Is it kernel-side hot path │
                           │ but uses only public/      │
                           │ exported interfaces?       │
                           └──────┬───────────┬─────────┘
                              yes │           │ no
                                  ▼           ▼
                            L2 (companion)   ┌──────────────────────┐
                                             │ Is it orchestration / │
                                             │ event response /      │
                                             │ telemetry?            │
                                             └──┬──────────────┬─────┘
                                            yes │              │ no
                                                ▼              ▼
                                           L3 (daemon)  ┌─────────────────┐
                                                        │ Is it one-shot   │
                                                        │ at boot or       │
                                                        │ recovery? Shell  │
                                                        │ idiomatic?       │
                                                        └─┬───────────┬────┘
                                                      yes │           │ no
                                                          ▼           ▼
                                                      L4 (shell)  ┌────────────────────┐
                                                                  │ Tunable already     │
                                                                  │ exposed by kernel   │
                                                                  │ or userspace?       │
                                                                  └─┬─────────────┬─────┘
                                                                yes │             │ no
                                                                    ▼             ▼
                                                                L5 (config)   ┌──────────────┐
                                                                              │ In the       │
                                                                              │ inference    │
                                                                              │ engine?      │
                                                                              └─┬────────┬───┘
                                                                            yes │        │ no
                                                                                ▼        ▼
                                                                            L6 (ggml)  L7 (external)
```

The check in each box is "would this layer cleanly host this change?"
The first "yes" wins. Going up a layer for convenience adds maintenance
cost without benefit.

---

## Cross-layer interfaces (contracts)

To keep layers pluggable, the boundaries between them must use stable
interfaces. The contract:

| From → To | Interface |
|---|---|
| L1 → L3/L4 (state exposure) | sysfs nodes, dmesg markers (`AORUS Lever X`), uevents |
| L1 → L2 (kernel-to-kernel) | exported symbols + kprobes/tracepoints (NOT NV-internal struct access) |
| L3/L4 → L1 (driver control) | sysfs writes, `/sys/.../reset`, ioctls only via supported paths |
| L5 → L1 (configuration) | module parameters (`NVreg_*`), kernel cmdline |
| L6 → L1 (workload submission) | CUDA Driver API only (never bypass libcuda for our code) |
| L7 → all | maintained external interfaces (DKMS hooks, systemd unit deps, NVIDIA APIs) |

**Anti-pattern:** L3 daemon directly poking `/sys/module/nvidia/parameters/*`
to override an internal flag. If the flag isn't exposed as a stable
parameter, expose it properly via L1 work — don't reach in.

---

## Lever map — current and planned

The complete set of levers (existing + roadmap), with their assigned
sovereign home. New levers added to the roadmap should be entered
here with their layer.

### Reliability levers

| Lever | Layer | Status | Notes |
|---|---|---|---|
| K (cmdline params) | L5 | DONE | Pure config — boot args |
| Persistenced workaround (Problem 2) | L7 | DONE | Consumes existing daemon |
| UVM keepalive (Problem 4) | L4 | DONE | Shell helper holding fds |
| modprobe blacklist + install /bin/false | L5 | DONE | modprobe.d config |
| compute-load-nvidia loader | L4 | DONE | Shell, called from systemd unit |
| I (osHandleGpuLost retry) | L1 | DONE | Justified: NV-internal retry path |
| J-2 (rcdb shortcircuit) | L1 | DONE | Justified: NV crash-dump internals |
| N (rpc free shortcircuit) | L1 | DONE | Justified: RPC dispatch hot path |
| O (_issueRpcAndWait) | L1 | DONE | Justified: RPC dispatch hot path |
| M-base (err handlers struct) | L1 | DONE | Justified: registers via `pci_driver` |
| Q-passive | L1 | DONE | Justified: wraps NV MMIO macro hot path |
| Q-active | L1 | DONE | Justified: same hot path, active probe |
| **J-1 (bus hardening companion)** | **L2** | TODO #49 | NVIDIA-agnostic, no RM-internal access |
| **M-recover (slot_reset+resume)** | **L1** | TODO #62 | Hot-path callbacks; must be inside driver |
| **M-preserve (state preservation)** | L1 | TODO #56 | NV-internal channel/context state |
| **Recovery uevent emitter** | **L1 or L2** | Phase 6 polish | If L1 (in nv-pci.c) is small, prefer L2 (observe via tracepoint) |
| **Recovery orchestration (above slot_reset)** | **L3** | Phase 6 polish | Userspace daemon watching uevents |
| **Sysfs error counters** | L1 (writers) + L3 (reader/aggregator) | Phase 6 polish | Driver writes counters; daemon aggregates |

### Performance levers (native-advantage)

These are the levers Windows + closed driver fundamentally cannot
match — they exploit Linux-only and open-source-only optimisation
surfaces. Each is mapped to its sovereign home.

| Lever | Layer | Phase | Why this layer |
|---|---|---|---|
| **PCIe MaxPayload / MaxReadReq tune** | **L4** | 7-native-A | One-shot setpci/sysfs writes after driver bind. Reversible by removing helper. |
| **ASPM force-off (per device)** | **L4 + L5** | 7-native-A | udev rule for sysfs `power/control` + helper for `aspm_policy`. |
| **PCIe completion-timeout tune** | **L4** | 7-native-A | Per-device sysfs write at boot. |
| **TB controller link-mode lock** | **L4 + L5** | 7-native-A | Boltctl + sysfs; pure config + helper. |
| **CPU IRQ affinity for nvidia IRQ** | **L4 + L5** | 7-native-A | systemd unit + helper writing `/proc/irq/N/smp_affinity_list`. |
| **CPU governor + EPB** | **L5** | 7-native-A | systemd unit + sysctl, no code. |
| **Hugepages reservation** | **L5** | 7-native-E | cmdline `default_hugepagesz=1G hugepages=N`. |
| **SCHED_FIFO / nice for ollama** | **L5** | 7-native-E | systemd unit slice with `CPUSchedulingPolicy=fifo`. |
| **CUDA Graphs verify + enable** | **L6** | 7-native-B | ggml-cuda config / runtime flag. |
| **Async cuMemcpyHtoD pipelining** | **L6** | 7-native-C | ggml-cuda model upload path. |
| **madvise / io_uring for model file** | **L6** | 7-native-E | ollama userspace; syscall config. |
| **GPUDirect Storage upload** | **L6 + L7** | 7-native-D | ggml integration with `cuFileRead`; `nvidia-fs` daemon as L7. |
| **DMA descriptor coalescing** | **L1** | 7-native-C-stretch | If we can't get parity from L6 alone, this is the fork-side fallback — single ioctl carries multi-descriptor DMA. **High fork debt; only if L6 won't reach the goal.** |
| **Custom batched-submit ioctl** | **L1 + L6** | future research | Adds new ioctl to nvidia.ko (L1), uses it from ggml-cuda (L6). Last resort. |
| **Bypass GSP for known-safe MMIO** | **L1** | future research | Hot path; must be in the driver. Only after Lever Q's safety story is fully proven. |

---

## Rules for adding new code

When proposing a new lever, the design must answer:

1. **What's the lowest layer that can cleanly host this?** Justify any
   answer above L4.
2. **What stable interface will this lever produce or consume?** (Avoid
   adding new ad-hoc cross-layer dependencies.)
3. **How do you remove this lever?** (Removability is part of the
   design.)
4. **What's the rebase cost if this lives in L1?** Quantify in terms
   of: "next NVIDIA driver release will require N hours of rebase work
   for this patch alone."

For L1 work specifically, also answer:

5. **Has the upstream NVIDIA repo been checked for a similar fix?**
   File a GitHub issue / PR upstream so the fork debt is bounded.
6. **What does the patch series look like if it grows?** (Single patch
   that grows by 50% per lever vs N small isolated patches matters for
   future review.)

---

## Cross-references

- [`architecture.md`](./architecture.md) — what each currently-installed
  piece does (the *what*, this doc is the *where*)
- [`stability-roadmap.md`](./stability-roadmap.md) — phased plan and
  status of every lever
- [`lever-catalog.md`](./lever-catalog.md) — canonical specification of
  every lever (motivation, mechanism, test plan, reproducibility,
  upstream-readiness). Each new lever proposed in this modularity
  framework gets a corresponding entry in the catalog.
- [`service-retirement-roadmap.md`](./service-retirement-roadmap.md) —
  the modularity layer principle has a NUANCE: while we prefer L4-L6
  over L1 for NEW capability levers (less rebase debt), the
  architectural DESTINATION for hardening/recovery levers is L1
  (in-driver). Userspace services for hardening are pragmatic stopgaps
  on the path to in-driver parity with NVIDIA's closed Windows driver.
  The retirement roadmap tracks each workaround service to its driver-
  side replacement.
- [`performance-investigation.md`](./performance-investigation.md) —
  Phase 7 design including the native-advantage section that this doc
  catalogues
- [`patched-driver-runbook.md`](./patched-driver-runbook.md) — how to
  build, install, rollback the L1 patch series
- [`recommended-install-path.md`](./recommended-install-path.md) — how
  the whole stack lands on a fresh system

---

## Update log

- **2026-05-04 night** — initial publication. Establishes the L1-L7
  taxonomy, catalogues current levers by layer, defines the rules for
  adding new code. Triggered by the perf-investigation work shifting
  the project goal from "match WSL2" to "exceed WSL2 by exploiting
  Linux-only optimisation surfaces" — that pivot makes the modularity
  contract load-bearing because most of the new optimisation work
  belongs at L4-L6, not L1.
