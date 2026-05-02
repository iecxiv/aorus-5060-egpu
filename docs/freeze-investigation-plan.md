# CUDA-workload freeze investigation plan

Working document for the active investigation into the silent host hang on
first CUDA write op (e.g. `cuCtxCreate_v2`, ollama inference, PyTorch
`torch.zeros(.., device='cuda')`) on this stack:

- **Host:** Intel NUC 15 Pro+ (Arrow Lake, Core Ultra 9 288V)
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
