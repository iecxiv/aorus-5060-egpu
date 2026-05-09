# CUDA-workload freeze investigation plan

> **Status: HISTORICAL (2026-05-08).** This document captures the
> investigation arc from 2026-05-03 through 2026-05-08, including Lever
> taxonomy A–K, three-layer reliability model, source-review passes, and
> the evidence catalogue from upstream issue #979. **The investigation
> has converged.** The CUDA-workload host freeze is empirically mitigated
> on the current driver stack (see [H22 ledger entry](./reliability-hypothesis-ledger.md#h22)).
> Decode at WSL2 parity for llama3.1:8b; no host wedge under realistic
> load (verified via cold-cold-boot loop tests + close-path probes 2026-05-08).
>
> For current state, read in this order:
> 1. [`architecture.md`](./architecture.md)
> 2. [`lever-catalog.md`](./lever-catalog.md)
> 3. [`service-retirement-roadmap.md`](./service-retirement-roadmap.md)
> 4. [`reliability-hypothesis-ledger.md`](./reliability-hypothesis-ledger.md)
>
> This document remains valuable as: (a) the methodology record showing
> how the investigation was structured, (b) the evidence catalogue for
> upstream issue #979, (c) a context-restore handoff for future regression
> work if the bug class ever reproduces.

> **Original framing 2026-05-04.** As of 2026-05-04, the canonical roadmap (layer
> model, phase plan, lever status, completion criteria) lives in
> [`stability-roadmap.md`](./stability-roadmap.md). This document remains
> the **historical investigation log** — origins of each lever, source
> review passes, evidence catalogue. Use the roadmap to plan the next
> step; use this doc to understand how we got here.

Working document for the active investigation into the silent host hang on
first CUDA write op (e.g. `cuCtxCreate_v2`, ollama inference, PyTorch
`torch.zeros(.., device='cuda')`) on this stack:

- **Host:** Intel NUC 15 Pro+ (Arrow Lake-H, Core Ultra 9 285H)
- **eGPU enclosure:** GIGABYTE AORUS RTX 5090 AI BOX (Thunderbolt 5 / USB4,
  JHL9480 controller)
- **GPU:** NVIDIA RTX 5090 (GB202, Blackwell)
- **Connection:** Thunderbolt 4 (host limit; box is TB5-capable)
- **OS:** Fedora 43, kernel 6.19.14, NVIDIA open kernel module 595.71.05 from
  the official NVIDIA-CUDA repo, compute-only install

This document is not a postmortem — the bug is live. It's the running plan
that lets us pick up where we left off without re-deriving context.

For the architecture of the platform itself, see `architecture.md`. For
historical bug filings (Bugs A/B/C/D), see `future-investigations.md`.

## 1. Bug characterization

**Fingerprint:** silent hard host lock-up triggered on the first CUDA op that
writes to the GPU. nvidia-smi works at idle; `cuCtxCreate_v2` (or any caller of
it) wedges the kernel within seconds. No Xid logged in our journal (kernel
writeback dies before flush). `journalctl --boot=-1` after the freeze shows
the journal stops mid-stream with no precursor. Only recovery is a power
cycle.

**When the journal survives long enough**, others on the same bug class have
captured the kernel-side error sequence:

```
NVRM: Xid (PCI:...): 79, GPU has fallen off the bus.
NVRM: nvGpuOpsReportFatalError: uvm encountered global fatal error 0x60,
      requiring os reboot to recover.
NVRM: Xid (PCI:...): 154, GPU recovery action changed from 0x0 (None)
      to 0x2 (Node Reboot Required)
```

We have not seen this sequence in our own journal because our freezes are
faster than the kernel writeback interval; we have observed Xid 79 on this
hardware once during deliberate physical disconnect of the eGPU.

**This is not a hardware fault on our unit:** the same hardware runs
3DMark Nomad cleanly on Windows 11 — full benchmark, sustained graphics load.

## 2. Evidence catalogue

### Upstream issue: NVIDIA/open-gpu-kernel-modules#979

Open since 2025-12-04, no NVIDIA staff response as of 2026-05-03. 15 comments,
multiple cross-platform / cross-vendor / cross-driver-branch reports of the
same fingerprint. Key data points:

- **Comment 5 (mihau81):** **same NUC 15 Pro+ + same AORUS RTX 5090 AI BOX as
  ours.** Tested on Proxmox 9.1.5. Tried 590.48.01 open (with and without PR
  #984's `NVreg_ForceExternalGpu` patch), **580.142 closed**, 570.x.
  All crash on any write op. This is the single highest-signal datapoint we
  have: it eliminates several theories without us having to test them, including
  the closed-driver A/B (originally Lever D, now dropped).

- **Comment 9 (bilikaz):** the only widely-confirmed *working* config. RTX 5080
  + Razer Core X V2 (TB5) + **Dell Latitude 5540** + Ubuntu 24.04 + 590.48.01
  open. Two notable Linux deltas vs. the failing configs:
  - `pci=realloc=off` instead of `pci=assign-busses,realloc` — citing HPE
    advisory a00151736en_us about `pci=realloc` removing BIOS-assigned BARs
    without reassigning.
  - `NVreg_DynamicPowerManagement=0x00`.
  - **BIOS pre-boot Thunderbolt PCIe enumeration enabled.**

- **Comment 12 (fanfanmgz):** synthesised the BIOS-level hypothesis after
  failing to reproduce bilikaz's recipe on ASUS ROG (consumer BIOS, no TB
  pre-boot toggle). Concluded: working hosts are business-class BIOSes
  (Dell Latitude, HPE) that allocate BARs at POST via TB pre-boot ACPI;
  failing hosts are consumer/gaming BIOSes that allocate at hot-plug after
  the kernel is up. NUC 15 Pro+ falls in the failing bucket — its BIOS only
  exposes Thunderbolt enable/disable, no pre-boot toggle.

- **Comment 14 (jciolek, 2026-05-01):** Dell XPS 17 + AORUS 5090 AI BOX +
  Manjaro + 590.48.01 open. Reports one "unicorn" boot lasting 3 hours running
  Blender + ollama on the 5090, then never again on materially identical
  cmdline / driver / kernel. Suggests "hidden initialization state — possibly
  NVIDIA/GSP, Thunderbolt/USB4 tunnel, retimer/link training, runtime PM/LTR,
  or enclosure warm/cold state." We have observed similar — short-lived stable
  windows early in our history that we couldn't reproduce.

- **Comment 8 (gerpervaz):** Windows + USB4 + RTX 5080 (different host /
  enclosure but same chipset family). Reports VIDEO_TDR_FAILURE bugchecks
  and `nvlddmkm` Event ID 14/153 under sustained heavy CUDA load.
  Demonstrates Windows is *not* immune; the difference is that Windows
  recovers via TDR while Linux freezes hard. Light/moderate CUDA holds.

### Our own data points

- **Lever A negative result (2026-05-02):** applied `pci=realloc=off` and
  `NVreg_RegistryDwords="RmForceExternalGpu=1"` (the unpatched-build
  equivalent of PR #984's `NVreg_ForceExternalGpu`). Confirmed both live in
  /proc/cmdline and /proc/driver/nvidia/params after cold boot. Ran the lite
  ollama test (qwen2.5:0.5b, "Write one sentence about Paris."). Host froze
  within ~1 minute. Telemetry CSVs all 0 bytes (writes never made it through
  page-cache flush before the freeze — methodology gap; the script writes via
  `tee` + `awk fflush()` but does not fsync). Same silent fingerprint as
  prior freezes.

- **Predicted by mihau81's data:** ~9% predicted success rate; 0% observed.
  Consistent with prediction. Confirms our config is in lockstep with the
  upstream failing class.

- **3DMark Nomad on Windows works on this exact hardware** — establishing
  that the GPU and the Thunderbolt path can deliver sustained graphics load
  end-to-end. The bug is somewhere in the Linux compute path or the
  Linux-driver-specific GSP-RPC sequence above the GPU.

## 3. Architectural understanding

### Why Windows works (for graphics) where Linux fails (for compute)

| Layer | Linux failing path | Windows working path (3DMark Nomad) |
|---|---|---|
| Application | ollama → libcuda.so | 3DMark → DirectX 12 / Vulkan |
| API | CUDA (compute) | D3D12 / Vulkan (graphics) |
| Userspace lib | libcuda.so (closed) | nvcuda.dll / d3d12.dll (closed) |
| Kernel driver | nvidia.ko (open module) | nvlddmkm.sys (closed, WDDM) |
| Driver↔GPU comms | host driver's GSP-RPC sequence | host driver's GSP-RPC sequence |
| GPU firmware | gsp_*.bin (same binary) | gsp_*.bin (same binary) |
| Recovery on stall | none (kernel deadlock → host freeze) | TDR (driver reset, app gets error, system continues) |

The **shared layers** (GSP firmware, GPU, hardware) cannot fully explain a
clean Windows / freezing Linux split. The **divergent layers** that can:

1. **Different kernel driver code base entirely.** The Linux open module is
   recent code (Blackwell consumer support is fresh in 580+). The Windows
   closed driver has had Blackwell paths longer in dev. Different bugs in
   each.
2. **Different API / command path.** 3DMark uses graphics; ollama uses
   compute. The CUDA `cuCtxCreate_v2` → UVM → DMA-map sequence is a
   different code path than the D3D command queue path. Failure may be
   localised to the compute path.
3. **TDR vs. no TDR.** Windows can recover from GPU stalls; Linux cannot.
   Even if Windows hits the same edge case, it survives.
4. **Different PCIe enumeration.** Windows ACPI/PnP allocates BARs in
   different sequencing than Linux's `pci=...` heuristics. BAR1 frequently
   caps at 256 MB on consumer-BIOS Linux setups while Windows gets 16 GB on
   the same hardware.

### Where WSL2 sits — and why it's a strong gate

WSL2 is not the Linux GPU stack. It's a Linux userspace running on top of
Microsoft's GPU paravirtualization (GPU-PV):

```
WSL2 Linux app
  │
  ▼  libcuda.so (special WSL build)
  │
  ▼  /dev/dxg (Linux side of GPU-PV)
  │
  ▼  DxgKRNL (Windows kernel, GPU virtualization)
  │
  ▼  Windows nvlddmkm.sys (the Windows NVIDIA driver)
  │
  ▼  GPU
```

**WSL2 does NOT load nvidia.ko, nvidia-uvm.ko, or any Linux open module.**
The Linux open module — the prime suspect for our bug — is bypassed
entirely. CUDA in WSL2 exercises the Windows driver path with a Linux
frontend.

This makes WSL2 a clean diagnostic gate (Lever G):

- **Compute clean in WSL2** → bug is in the Linux open module's CUDA
  path. Windows driver path handles the same hardware fine. Strongly
  isolates the failing surface to a code base we can read and test.
- **Compute crashes in WSL2** → bug is below the host driver — GSP firmware
  or hardware-level Blackwell × TB interaction. Linux open module wouldn't
  be uniquely at fault; the Windows driver hits the same edge.
- **Windows TDR / app-only crash without host freeze** → confirms the
  "Linux can't recover from what Windows just resets" hypothesis. Bug is
  triggerable on both, but Linux's monolithic-driver-in-kernel design
  amplifies the consequence.

## 4. Lever taxonomy

Levers are concrete experimental moves. Status as of 2026-05-03 morning.

### Lever A — Layer-2 cmdline + module options (DONE, NEGATIVE)

`pci=realloc=off` + `NVreg_RegistryDwords="RmForceExternalGpu=1"`. Tested
2026-05-02 evening, host froze on first ollama inference. Predicted by
mihau81's exact-hardware data. Eliminates one variable; provides one
confirmed datapoint for #979 filing.

### Lever B — BIOS IFR hunt (PENDING, read-only first pass)

NUC 15 Pro+ BIOS only exposes "Thunderbolt enable/disable" — no pre-boot
ACPI / PCIe pre-boot toggle as on Dell Latitude. But OEMs frequently
*hide* options that exist in the underlying IFR. Workflow:

1. Dump current BIOS (`chipsec_util spi dump`)
2. Extract IFR with UEFITool + IFRExtractor-RS
3. Search IFR text for `Thunderbolt`, `pre-boot`, `TB Pre-Boot ACPI`,
   `PCI Boot resources`, `Above 4G`
4. If hidden variable exists → use Grub2 `setup_var` to flip NVRAM byte
   (does NOT reflash; reversible via CMOS reset / NUC security jumper)

Read-only investigation through step 3 is zero-risk. NVRAM modification
through step 4 is recoverable. Modified BIOS image + reflash is almost
certainly blocked by Intel Boot Guard on Arrow Lake — not attempting.

Realistic probability of fixing the freeze: ~9% (chained probabilities of
hidden variable existing, gating code being compiled in, BIOS-allocated
BARs being sufficient).

Diagnostic value high regardless. Negative result is also useful for
upstream filing.

### Lever C — File datapoint on issue #979 (HELD)

User holding pending Levers G/E/B outcomes. Higher-quality filing if we
have:

- Confirmed Linux-only failure (Lever G result)
- Driver source review findings (Lever E)
- BIOS investigation outcome (Lever B)

Can be filed cheaply at any time as a basic "another data point with this
hardware" comment, but worth waiting if the other levers materially
strengthen it.

### Lever D — Closed RM kernel module A/B (DROPPED)

Was originally proposed before reading issue #979 thread end-to-end. mihau81
tested 580.142 closed module on our exact hardware combination — same crash.
Plus newer driver branches refuse closed modules on consumer Blackwell.
Already-tested negative; do not repeat.

### Lever E — Open-gpu-kernel-modules source review (PENDING)

Clone `NVIDIA/open-gpu-kernel-modules` at the 595.71.05 tag (or closest).
Read the eGPU detection / Thunderbolt / GSP-RPC / context-create paths.
Map the call graph from `cuCtxCreate_v2` (libcuda) through the Linux
kernel module's IOCTL handler down into UVM and the GSP-RPC layer.

Looking specifically for:

- `RmCheckForExternalGpu()` and the bridge-detection logic (PR #984
  rewrites this; understand what it changes)
- Platform Request Handler entry points
- GSP firmware bootstrap sequence
- DMA mapping / context-create code in the Blackwell path

Output: notes file `docs/source-review-notes.md`. Pairs with Lever B and
G — all are read-only.

Value depends on Lever G outcome. If Lever G shows compute-clean in WSL2,
Lever E becomes prime: we'd be reading code that contains the bug, and
patching becomes thinkable. If Lever G shows compute-fails in WSL2, the
bug is below this code base and Lever E is mostly informational.

### Lever F — Firmware survey + update path (NARROWED)

Of the four firmware surfaces:

1. **GSP firmware** — bundled with NVIDIA driver. ACTIONABLE: identify
   driver branches that ship newer GSP than 595.71.05. Diff release notes
   for relevant fixes.
2. **RTX 5090 VBIOS** — DEAD LEVER. NVIDIA does not distribute consumer GPU
   VBIOS updates; AORUS does not ship one.
3. **AORUS RTX 5090 AI Box firmware (TB controller + enclosure)** — DEAD
   LEVER. Confirmed via Gigabyte support page audit
   (https://www.gigabyte.com/Graphics-Card/GV-N5090IXEB-32GD/support):
   page lists only GIGABYTE Control Center (Win), AI TOP Utility
   (Ubuntu/Win, application layer not firmware), AI BOX GPU Selector
   (Win). No TB firmware updater. No enclosure firmware updater.
4. **NUC 15 Pro+ host firmware** — system BIOS + Intel ME + integrated
   TBT controller firmware. ACTIONABLE: identify current versions, check
   for updates, review release notes for TB / eGPU / Blackwell mentions.

Reduced to surfaces 1 and 4. Mostly housekeeping; pairs with Lever B
(both touch host-firmware investigation).

### Three-layer reliability framework (added 2026-05-03 evening)

Bus reliability is genuinely a three-layer problem; previous lever
descriptions conflated them. See `source-review-notes.md` "Pass 4" for
the full enumeration with file:line citations of where each layer is
weak in the open Linux module.

| Layer | Goal | Linux open module gap |
|---|---|---|
| **L1 — Prevention** | Keep the bus stable so transients don't happen | LTR not enforced GPU-side, ASPM policy not pinned, TB CLx not disabled, runtime PM partially suppressed |
| **L2 — Recovery** | When a transient happens, recover gracefully | No multi-retry, no PCI link retrain, no AER hook, no GSP-state resync |
| **L3 — Graceful failure** | When recovery fails, fail cleanly without taking the host down | Cleanup cascades assert on `NV_ERR_GPU_IS_LOST`, `RmLogGpuCrash` reads dead-GPU registers, no TDR-equivalent state reset |

Mapping levers to layers:

| Lever | L1 | L2 | L3 | NVIDIA touch? | Status |
|---|:-:|:-:|:-:|:-:|---|
| A | partial | — | — | yes (modprobe) | done, negative |
| H | — | — | — | yes | predicted negative; bug bypasses timeout path |
| I | — | partial (multi-retry only) | — | **yes (driver rebuild)** | proposed; ~10-line MVP |
| K | direct | — | — | no — pure cmdline | proposed |
| J-1 | direct | — | — | **no — standalone kmod** | proposed; NVIDIA-agnostic |
| J-2 | — | direct | direct | yes | proposed; gated on I + J-1 outcome |

Note the key architectural insight: **L1 work has no NVIDIA dependency**.
Levers K (cmdline only) and J-1 (companion kmod) can both deliver L1
prevention without rebuilding nvidia.ko or even understanding NVIDIA
internals — just standard PCIe / Thunderbolt configuration.

Lever I's honest scope: ~1/3 of the Windows feature set, the cheapest
slice. It addresses the dominant failure mode if transients are the
trigger, but does not implement AER-style link retrain or TDR-style
state reset.

### Lever K — Layer-1 cmdline + module-option experiments

Cheap, pure-userspace L1 attempts to keep the bus stable. No driver
rebuild required.

- Boot args additions (one cmdline change, one reboot per test):
  - `pcie_aspm.policy=performance` (per bilikaz #979 comment 9)
  - `thunderbolt.clx=0` (per bilikaz)
- NVreg additions via `NVreg_RegistryDwords`: TBD, requires another
  grep over `nvrm_registry.h` for LTR-force keys etc.
- udev power-state pins: mostly already done.

Expected to be partial mitigations at most — they reduce trigger
likelihood but don't address what happens when a transient does occur.
Worth running before Lever I to remove known-cheap variables.

### Lever J — Sovereign module (split into J-1 and J-2 — 2026-05-03 evening refactor)

Originally framed as a single "fork nvidia.ko, fix everything" effort.
User insight: **L1 is a platform problem, not an NVIDIA problem.** All
L1 work is generic PCIe / Thunderbolt config (LTR enable bit, ASPM
policy, CLx state, runtime PM, link width pin) — addressable for any
TB-attached PCIe endpoint without touching NVIDIA-internal code. Only
L2 and L3 require code inside `nvidia.ko`'s address space. Splitting
the lever cleanly separates the engineering and decouples maintenance.

#### Lever J-1 — L1 bus-hardening companion module (NVIDIA-agnostic)

A standalone Linux kernel module that hardens TB-tunneled PCIe state
for the GPU's PCI device. Pure pluggable: zero changes to nvidia.ko,
no understanding of NVIDIA internals required.

Scope:

- `pci_get_device(0x10de, 0x2C02, ...)` to find the GPU (or broader
  filter for any TB-attached endpoint as a research mode)
- Write the GPU's PCI Device Control 2 register to force LTR_ENABLE
  regardless of upstream chipset advertising
- Pin link width / max speed via PCI config writes
- Coordinate with Linux PCI core / `thunderbolt` kmod / runtime PM
  via standard kernel APIs
- Periodic re-assertion via timer (some settings get clobbered on
  power-state transitions)
- Build via standard `Kbuild` Makefile + `dkms.conf`
- Maintenance against Linux kernel versions, NOT NVIDIA driver versions
- Testable in isolation against the freeze trigger
- Bonus: testable against non-NVIDIA TB devices (NVMe, capture card)
  to validate that the fix is genuinely bus-level rather than an
  NVIDIA-driver-quirk-in-disguise

Prior art search worth doing before building from scratch — egpu.io
community + Linux upstream may have existing tools for TB-PCIe
endpoint hardening.

#### Lever J-2 — L2 + L3 NVIDIA-driver recovery (NVIDIA-internal)

The driver-internal portion of the original Lever J. Targets
`nvidia.ko` directly via one of three mechanisms:

- **Inline patches** — fork the open module, maintain patch series,
  `make modules_install` to `/lib/modules/.../extra/`. Heavy
  maintenance; maximum control.
- **Hooks + companion** — small upstream patch (~30-50 lines) adds
  `EXPORT_SYMBOL_GPL` for key recovery primitives + a
  `register_external_recovery_handler` callback API. Companion
  module implements the heavy logic. Minimal upstream churn,
  manageable maintenance.
- **kprobe-based interception** — zero patches to nvidia.ko;
  companion module places kprobes on `osHandleGpuLost` and the
  rsserv assert sites. Fragile across kernel/driver versions but
  fine for *research*.

Per-layer patch surface (L2 recovery + L3 graceful failure) and
file:line targets: see `source-review-notes.md` "Lever J" subsection.

Critically, the recovery primitives **already exist in the source**:

- `kbifResetFromTimeoutFullChip_IMPL` (`kernel_bif.c:2006`) — full-chip
  reset is implemented but has **zero callers**
- `kbifWaitForConfigAccessAfterReset_IMPL` (`kernel_bif.c:2053`) —
  post-reset polling implemented
- BIF HAL hooks per-arch — Blackwell has Reset/PrepareForReset HAL
  implementations
- RC subsystem dedicated, has its own watchdog
- `nv_pci_driver` struct (nv-pci.c:2750) — empty `.err_handler` slot
  ready for AER wire-up

The bug is missing **wiring**, not missing **modules**. J-2 patches
are mostly a few targeted call-site additions plus the AER hook
struct, not new logic.

#### Decision tree

```
Run Lever I (10-line retry in osHandleGpuLost)
   │
   ├── Sufficient? → done. No J needed.
   │
   ├── Partial fix? → Lever J-1 first (L1 prevention),
   │                   then evaluate if J-2 still needed.
   │
   └── No fix? → Lever J-1 first (L1 prevention).
                  If J-1 fixes alone: done.
                  If not: Lever J-2 (L2/L3 driver work).
```

J-1 sits cleanly between Lever I and Lever J-2. It's the
NVIDIA-agnostic prevention layer; if it works alone we never need
to touch nvidia.ko's recovery internals.

### PCIe cmdline flag reference

For the catalogue of `pci=` sub-options and `pcie_*` top-level kernel
parameters, available Tier-1/2/3 escalation flags, and the
investigation method that derived them, see
[`pcie-kernel-cmdline-options.md`](./pcie-kernel-cmdline-options.md).

Currently applied: none from the AER-suppression family.

**Lever L (`pci=...,noaer`) was tried and reverted on 2026-05-04**
after one test cycle. The flag worked at the kernel level (verified
via _OSC negotiation losing AER from the OS-controlled service list)
but produced a strictly worse, fully-silent failure mode where the
PCIe-error signal never reached the NVIDIA driver. As a result,
`PDB_PROP_GPU_IS_LOST` was never set, our Lever I/J-2/N recovery
patches never engaged, and the freeze left zero diagnostic trace.
See `pcie-kernel-cmdline-options.md` "Why Lever L was reverted" for
the comparison table and rationale.

Tier-2 escalation `pcie_ports=compat` is also off the table for the
same reason — both flags suppress the error signal our patches need
to fire. The path forward is Lever M (register `pci_error_handlers`
in `nv-pci.c`) so the AER signal has a structured place to land.

Other escalations from the catalogue (`pcie_aspm=off`, `pcie_pme=off`,
`pci=...,nomsi`) remain *available* but should each be motivated by a
specific dmesg signal, not added preemptively.

### Lever-by-lever empirical results (2026-05-03 late update)

| Lever | Status | Result |
|---|---|---|
| A | DONE | confirmed negative; freeze identical on Lever-A-only |
| G | DONE | confirmed positive (control); WSL2 = 45-iteration ladder up to 27B clean |
| H | **DONE — confirmed negative + reverted** | RmOverrideInternalTimeoutsMs caused a 39 s heartbeat wait that produced MCE broadcast panic; reverted on 2026-05-04 |
| K | **DONE — not statistically distinguishable** | freeze still occurs; single-sample, can't claim rate change either way |
| L | **DONE — confirmed negative + reverted** | `pci=...,noaer` worked at kernel level but produced a worse, silent freeze where our patches couldn't engage (no GPU-lost path entered, no AORUS markers, no NVRM activity); reverted on 2026-05-04 |
| I | EXECUTED + VERIFIED RAN 2026-05-04 | osHandleGpuLost retry with 10x100us; in test lite-2026-05-04-153940 the retry exhausted (all 10 reads returned bad value, GPU genuinely down) and fall-through to gpuSetDisconnectedProperties worked correctly (Xid 79 fired). No marker print on retry-exhaustion path (only prints on retry-success). |
| J-1 | not yet executed | gated on Lever I outcome |
| J-2 | EXECUTED + VERIFIED FIRED 2026-05-04 | rcdbAddRmGpuDump shortcircuit fired in lite-2026-05-04-145232 and lite-2026-05-04-153940; deadlock locus successfully avoided |
| N | EXECUTED + VERIFIED FIRED 2026-05-04 | rpcRmApiFree_GSP shortcircuit; collapses 107-assertion cleanup surface; AORUS marker fired in tests lite-2026-05-04-145232 and lite-2026-05-04-153940 |
| O | EXECUTED 2026-05-04, NOT YET FIRED | _issueRpcAndWait shortcircuit on PDB_PROP_GPU_IS_LOST. In test lite-2026-05-04-153940 the cleanup completed within 250ms after Xid 79 and the system died <50ms later — no second wave of RPCs was attempted, so Lever O had no work to short-circuit. Correctly placed but pre-empted by the new freeze locus. |
| M-base | EXECUTED 2026-05-04, NOT YET FIRED | patch 0007 built/installed; registers pci_error_handlers with error_detected returning DISCONNECT. Hypothesis was that Lever O would unblock the AER recovery dispatch, but post-cleanup freeze hits before AER subsystem can dispatch. Possibility: should change return to PCI_ERS_RESULT_NONE to avoid kernel-level disconnect that may itself contribute to wedge. |
| M-recover | pending | next stage: implement `mmio_enabled` / `slot_reset` / `resume`; gated on M-base test results |
| M-preserve | pending | future stage: state preservation across slot reset (the actual "PEX Reset and Recovery" NVIDIA's roadmap calls out) |
| P (proposed) | pending | UVM-side _issueRpcAndWait analogue; UVM has its own RPC infrastructure that may not funnel through Lever O; needs investigation if c (ollama respawn) doesn't fully resolve |

### 2026-05-04 evening: cleanup chain works end-to-end (test lite-153940)

**Major milestone.** For the first time, a CUDA workload failed *gracefully*
on this hardware:

1. AER fires (Multiple Uncorrectable Non-Fatal from 0000:04:00.0)
2. Driver detects GPU lost via sanity check → Xid 79 logged
3. `gpuSetDisconnectedProperties` sets `PDB_PROP_GPU_IS_LOST = TRUE`
4. AORUS Lever J-2 fires — `rcdbAddRmGpuDump` skipped (deadlock locus avoided)
5. Xid 154 — "GPU recovery action: Node Reboot Required"
6. AORUS Lever N fires — `rpcRmApiFree_GSP` returns NV_OK silently for cleanup
7. **`cudaMalloc` returns proper error to userspace**:
   `"CUDA-capable device(s) is/are busy or unavailable"`
8. ollama propagates the error up through llama_model_load
9. **ollama panics with a stack trace** instead of hanging in the poll loop

This is the architectural goal of Levers I/J-2/N realised. The driver
fail-fast path returns proper errors. The workload exits cleanly with a
diagnostic stack trace. Three months of diagnostic / source-review work
made this possible.

### Remaining issue: post-cleanup host wedge (50ms after panic)

Despite the clean failure path:
- Cleanup completed in 250ms (Xid 79 → Lever N)
- ollama got CUDA error and started panicking
- **Within ~50ms of ollama's last journal line, the kernel stops logging entirely**
- No panic, oops, BUG, RCU stall — just abrupt silence
- System remained frozen until manual power-cycle 2:17 later

Hypotheses for the new freeze locus, in order of likelihood:

1. ~~**ollama serve respawns the runner in a tight loop** after panic.~~
   **REFUTED 2026-05-04** by inspection of test lite-153940's
   pidstat-ollama.csv: only 2 PIDs across the whole test (ollama serve
   1393, runner 9514). No new runner PID appeared post-panic. Single
   panic, single exit, no respawn loop.
2. **UVM cleanup deadlock on process exit.** When ollama runner dies,
   the kernel runs `__exit_files` which calls UVM's release fop. UVM
   was already in fatal state ("global fatal error 0x60") and may hang
   in this path. Would need a Lever P (UVM-side fail-fast). **NOW
   PROMOTED TO #1 candidate.**
3. **`nv_pci_remove` triggered by Lever M-base DISCONNECT runs and
   hangs on an unpatched cleanup site.** Mitigation: change M-base to
   return `PCI_ERS_RESULT_NONE` to avoid kernel-level disconnect, OR
   patch the unpatched site. **Promoted to #2 candidate.**
4. **AER continues firing below logging rate-limit threshold**, and
   the AER irq handler keeps consuming CPU. Eventually wedges system.
   Mitigation: post-Xid-79, programmatically clear AER status from the
   driver.

Investigation order: pivot to (2) UVM-side investigation. Pull the
UVM release-fop call chain from the open-gpu-kernel-modules source,
identify any GPU-communication paths that lack a `GPU_IS_LOST` early
exit. Likely lever P will be a small patch in `uvm_va_space_destroy`
or a similar exit-time release path.

The lite test on 2026-05-03 evening (Lever A+H+K stacked) captured a
new deadlock locus: kernel hangs at `journal.c:2239` after a 14-iteration
fn 78 cascade through `nvdEngineDumpCallbackHelper` (`nv_debug_dump.c:273`).
This is the `RmLogGpuCrash` path — different from the previous freeze
which deadlocked in channel cleanup at `rs_client.c:844`. Both paths run
from `osHandleGpuLost`; which one deadlocks first appears non-deterministic
(workitem scheduling / lock acquisition order). The L3 patch surface for
Lever J-2 has been expanded to cover both. See `source-review-notes.md`
Pass 5 for the full analysis.

### Lever I — Patch driver + DKMS rebuild (NEW, derived from Lever E pass 3)

Source review pass 3 (2026-05-03 evening) localised the bug to a single
function: `osHandleGpuLost` in `src/nvidia/arch/nvalloc/unix/src/osinit.c`.
The function reads `NV_PMC_BOOT_0` exactly once and commits to permanent
"GPU lost" state if the read returns wrong value. NVIDIA themselves
document the gap in the comment block: *"This doesn't support PEX Reset
and Recovery yet."* See `source-review-notes.md` §"Pass 3" for the full
failure model with kernel-log evidence.

The patch surface is a ~10-line retry loop in `osHandleGpuLost` (and
optionally similar in `gpuSanityCheckRegRead_IMPL`):

```c
// Pseudocode
for (retry = 0; retry < N_RETRIES; retry++) {
    pmc_boot_0 = NV_PRIV_REG_RD32(...NV_PMC_BOOT_0);
    if (pmc_boot_0 == nvp->pmc_boot_0)
        return NV_OK;  // transient cleared, GPU is fine
    osDelayUs(100);
}
// only NOW do we commit to gpu-lost
```

Cost on success path: zero (no retries needed). Cost on TB transient: ~1ms
of patience instead of ~minutes of RPC failure cascade + cold boot.

Implementation steps:
1. Clone `NVIDIA/open-gpu-kernel-modules` at our exact tag (already done at
   `/root/nvidia-open-src/`)
2. Apply the retry patch
3. Build via DKMS: `make modules ; sudo make modules_install`
4. Set up the build to override the dnf-managed kmod-nvidia-open-dkms
   (specifically: `update-initramfs` or equivalent + module priority)
5. Reboot, verify the patched module loads (check version via modinfo or
   custom string in NVRM init message)
6. Run the lite test
7. If it works, longer soak; if it doesn't, gather more data

Risk surface:
- Need to manage dnf-managed dkms package vs hand-built module — easiest is
  to install to `/lib/modules/$(uname -r)/extra/` which supersedes the
  default location
- Driver upgrades will overwrite our patch unless we maintain the patch
  in a build script
- Patched driver may need re-applying after every kernel upgrade

This is the first lever that has a real shot at *fixing* (not just
mitigating) the bug. It's also the lever closest to being a credible
upstream PR if it works.

#### Implementation artifacts (Lever I + J-2 bundle, staged 2026-05-03)

Lever I and Lever J-2 are now bundled as a single patch series. The
build harness `tools/build-patched-driver.sh` iterates over all four
patch files in lexical order, so deploying I + J-2 is a single build
invocation. Selective skipping is possible by moving individual patch
files out of `patches/`.

| Patch | Lever | Purpose |
|---|---|---|
| `patches/0001-osHandleGpuLost-retry-on-transient-pcie-failure.patch` | I | Multi-retry on `NV_PMC_BOOT_0` to prevent declaring lost on transients |
| `patches/0002-rcdbAddRmGpuDump-shortcircuit-on-gpu-lost.patch` | J-2 | Primary deadlock-prevention — short-circuit dump on `PDB_PROP_GPU_IS_LOST` |
| `patches/0003-nvDumpAllEngines-break-on-gpu-lost.patch` | J-2 | Defence-in-depth — per-iteration guard in dump loop |
| `patches/0004-cleanup-asserts-accept-gpu-lost.patch` | J-2 | Relax cleanup-path asserts to accept `NV_ERR_GPU_IS_LOST` |

| Artifact | Path |
|---|---|
| Build/install harness | `tools/build-patched-driver.sh` |
| Operator runbook | `docs/patched-driver-runbook.md` |
| Source-level analysis | `docs/source-review-notes.md` Pass 7 (Lever I) + Pass 8 (Lever J-2) |

Total patch footprint: **6 sites across 4 files, ~52 lines of code
change** (not counting comments). All defensive. All conditional on
`PDB_PROP_GPU_IS_LOST` / `PDB_PROP_GPU_INACCESSIBLE` /
`NV_ERR_GPU_IS_LOST` — zero behaviour change on a healthy GPU.

To run the build-and-test pass when ready:

```bash
sudo /root/aorus-5090-egpu/tools/build-patched-driver.sh
sudo reboot
# verify per docs/patched-driver-runbook.md
```

Build is idempotent. Rollback is documented (script saves stock module
backups with `.dnf-stock-<timestamp>` suffix). Restoring a single
backup deactivates all four patches at once.

#### Behaviour matrix with bundle deployed

| Scenario | Behaviour |
|---|---|
| Healthy reads | identical to stock |
| Transient ≤ 1 ms | **Lever I catches it.** Workload continues transparently. dmesg: `AORUS Lever I:` |
| Transient > 1 ms | Lever I exhausts; **Lever J-2 prevents deadlock.** Workload errors out cleanly via cuMemAlloc failure. Host stays alive. dmesg: `AORUS Lever J-2:` |
| Real disconnect | Same as transient > 1 ms. Host alive, workload errored. eGPU dead until reboot. |

This matches Windows nvlddmkm.sys robustness in two of its three layers
(multi-retry + TDR-equivalent graceful failure), minus the AER link
retrain layer (which would auto-recover the GPU after a transient — Lever
J-1's territory).

### Lever H — RmOverrideInternalTimeoutsMs (DERIVED FROM LEVER E)

Source review (Lever E pass 2) found that Linux open module locks
`defaultus` at **4 seconds** at GPU init time (graphics mode default,
because `computeModeRefCount = 0` then). Most generic RM waits use
this. Hypothesis (H1): a GSP-RPC during cuCtxCreate exceeds 4s on
TB-tunneled PCIe, the timeout fires, the recovery path deadlocks
(no TDR equivalent in the Linux open module). See
`source-review-notes.md` for the full trace.

`nvrm_registry.h:105-124` exposes `RmOverrideInternalTimeoutsMs` —
a 32-bit registry value with bit-field flags for which timeout
class to override. The string form is `RmOverrideInternalTimeoutsMs`;
we set it via the `NVreg_RegistryDwords` mechanism the way we set
`RmForceExternalGpu`.

Value: `0xC0007530`
- Bits 31+30 (`0xC0000000`): `SET_RM_DEFAULT_TIMEOUT` + `SET_RC_WATCHDOG_TIMEOUT`
- Bits 23:0 (`0x00007530`): 30,000 ms = 30 seconds

Three outcomes are possible, each informative:

| Outcome | Means |
|---|---|
| **A** Freeze gone | H1 confirmed; bug is timeout-fire + recovery deadlock; next investigation is the recovery-path deadlock locus (probably in `thread_state.c` and `message_queue_cpu.c` receive half — both currently unread per source-review-notes Tier 1). |
| **B** Freeze identical | H1 ruled out; bug is a deadlock with no timeout involved. Pivots back to source-review Tier 1 reads (recovery + RPC half) AND into Tier 3 (DMA-map path). |
| **C** Different failure mode (clean error code, partial work, longer survival) | Timeout was firing but a deeper code path is now exposed. Whatever the new failure mode points at becomes the next read. |

### Lever G — WSL2 CUDA reproduction (PENDING, GATE)

User-proposed 2026-05-03 morning. The diagnostic gate that determines the
value of every other lever. Procedure:

1. Boot Windows 11 on NUC 15 Pro+ with eGPU connected.
2. Verify 3DMark Nomad still passes (baseline).
3. Install/enable WSL2 + Ubuntu (`wsl --install -d Ubuntu`).
4. Install NVIDIA's CUDA-on-WSL toolkit per
   https://docs.nvidia.com/cuda/wsl-user-guide/.
5. Verify nvidia-smi runs (low bar, expected).
6. **CRITICAL TEST:** install ollama in WSL2, pull qwen2.5:0.5b, send
   the same prompt as the failing Linux test ("Write one sentence about
   Paris."). Apples-to-apples.
7. If it works, run a longer soak (~5 min) to confirm stability.

Caveats:
- WSL2 nvidia-smi has reduced functionality (no `-pm` / `-lgc` / `-pl`).
- Driver branch differs slightly (WSL CUDA driver shipped via Windows
  host driver — likely 595.x).
- Both are fine for the gate question (does CUDA compute work or not).

## 5. Decision tree pivoting on Lever G

```
                ┌─────────────────────────────────┐
                │ Lever G result                  │
                └─────────────────────────────────┘
                              │
       ┌──────────────────────┼──────────────────────┐
       │                      │                      │
       ▼                      ▼                      ▼
┌──────────────┐       ┌──────────────┐       ┌──────────────┐
│ Compute      │       │ Host         │       │ TDR / app    │
│ clean        │       │ hard-locks   │       │ -only crash  │
└──────────────┘       └──────────────┘       └──────────────┘
       │                      │                      │
       │                      │                      │
       ▼                      ▼                      ▼

Bug is in Linux open    Bug is below host        Bug exists on both
module's CUDA path.     driver — GSP firmware    paths; Linux's
                        or Blackwell × TB        design amplifies.
                        hardware interaction.

Lever E: PRIME.         Lever E: deprioritized   Lever E: still useful
Reading code that       (the source we'd be      (Linux side has
contains the bug;       reading doesn't contain  recovery-path gaps
patching is realistic.  the bug).                even if it shares
                                                  trigger with Win).
Lever B: medium.        Lever B: prime           Lever B: medium.
Possible BIOS lever     (only remaining          Reduce trigger
to mitigate, but        reachable lever to       likelihood.
fix is in driver.       potentially mitigate).
                                                  Lever C: file with
Lever C: file with      Lever C: file with       both-paths-fail
strong evidence         GSP/hw evidence;         framing; advocate
("Win path same         likely escalation        kernel-side recovery
hw works → Linux        beyond user-visible      improvements.
open module bug").      surface.

Lever F: housekeeping.  Lever F: GSP via         Lever F: as in
                        driver branch is the     "compute clean".
                        only remaining surface
                        below the host driver
                        we can update.
```

## 6. Working order (recommended for next session)

1. **Lever G** — user runs WSL2 test; Claude runs Lever E in parallel
   (clone repo, map paths). Independent work, no conflict.
2. **Branch on G outcome** per decision tree above.
3. **Lever B** — read-only first pass (BIOS dump + IFR extract). Can run
   alongside G/E.
4. **Lever F** — GSP-via-driver-branch comparison + NUC firmware versions.
   Mostly housekeeping; useful regardless of G.
5. **Lever C** — file on #979 once we have at least Lever G's outcome.

## 7a. External paths referenced from this repo

Artifacts that live outside the platform repo but are essential context:

| Path | What | Maintained by |
|---|---|---|
| `/root/nvidia-open-src/` | Cloned `NVIDIA/open-gpu-kernel-modules` at exact tag `595.71.05` (matches our installed driver). All file:line citations in `source-review-notes.md` resolve here. | Fetched 2026-05-03; refetch on driver upgrade |
| `/root/llm-bench/wsl-fedora43-2026-05-03/` | Lever G WSL2 benchmark report. 45-iteration ladder across 5 models (1B → 27B) authored by a separate agent. Canonical control datapoint proving the bug is Linux-side. | Read-only archive |
| `/root/ollama/` | Working ollama serving stack. `tools/run-with-telemetry.sh` is the lite-test harness; default workload qwen2.5:0.5b + "Write one sentence about Paris." Has fsync'd progress markers (added 2026-05-03). | Sibling repo |
| `/root/ollama/archive/lite-2026-05-03-192806/` | First freeze with telemetry survival. Captured Xid 79 + fn 10 cleanup cascade at `rs_client.c:844`. Cited in source-review Pass 3. | Archive |
| `/root/ollama/archive/lite-2026-05-03-211751/` | Second freeze with telemetry survival. Captured fn 78 engine-dump cascade at `nv_debug_dump.c:273` + `journal.c:2239`. Cited in source-review Pass 5/6. | Archive |
| `/root/vllm/` | Parked vLLM evidence archive (older work). Not active. | Sibling repo, historical |

## 7. Methodology gaps to address

These don't block the investigation but should be fixed when convenient:

- **`ollama/tools/run-with-telemetry.sh` does not fsync.** Writes via
  `tee` + `awk fflush()`. On the host freeze, page cache is lost and CSVs
  come back 0-byte. The freeze-risk template with fsync'd progress
  markers exists per project memory; this script predates it. Retrofit
  if we want post-mortem data from any future freeze run.
- **No automatic capture of `/proc/cmdline` + `/proc/driver/nvidia/params`
  + `dmesg` snapshot at test start.** We rely on shell history. Not
  blocking, but a persistent test-context dump under each
  `archive/lite-<ts>/` would be useful.

## 8. Cross-references

- Issue #979: https://github.com/NVIDIA/open-gpu-kernel-modules/issues/979
- Issue #900: https://github.com/NVIDIA/open-gpu-kernel-modules/issues/900
  (RTX 5090 + OCuLink, related class)
- PR #984: https://github.com/NVIDIA/open-gpu-kernel-modules/pull/984
  (`NVreg_ForceExternalGpu` patch — fixes detection, not crash)
- bilikaz working config:
  https://forums.developer.nvidia.com/t/working-configuration-rtx-5080-razer-core-x-v2-thunderbolt-5-on-ubuntu-24-04-kernel-6-17-driver-590-48-01-open/366919
- HPE advisory a00151736en_us — `pci=realloc` BAR-loss documentation
- AORUS RTX 5090 AI BOX support page:
  https://www.gigabyte.com/Graphics-Card/GV-N5090IXEB-32GD/support
- CUDA on WSL: https://docs.nvidia.com/cuda/wsl-user-guide/
