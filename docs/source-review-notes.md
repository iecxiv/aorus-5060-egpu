# Open kernel module source review notes (Lever E)

Working notes from reviewing the NVIDIA open-gpu-kernel-modules source at the
exact tag we run (`595.71.05`). Goal: localise the offending code path that
makes our `cuCtxCreate_v2`-triggers-host-freeze on Blackwell-over-Thunderbolt
on the Linux open module, given Lever G has confirmed the Windows nvlddmkm.sys
path on the same hardware works flawlessly.

Status: 2026-05-03 evening — first pass. Three hypotheses identified, one
concrete additional experimental lever (Lever H — RM-internal timeout
override) found.

## Repository

- Cloned `NVIDIA/open-gpu-kernel-modules`, checked out tag `595.71.05` (matches
  our installed driver byte-for-byte).
- Lives at `/root/nvidia-open-src/` (outside this repo, not committed).
- Two large directory trees:
  - `kernel-open/` (9.2 MB) — kernel module shim layer (nvidia.ko, nvidia-uvm.ko,
    nvidia-drm.ko, etc.)
  - `src/` (119 MB) — the Resource Manager (RM) — the meat of the driver

## Finding 1: eGPU detection has shallow penetration — *not* the bug

The `RmCheckForExternalGpu()` logic in `osinit.c` walks PCIe bridges, looks for
TB3-approved Intel bridges with HotPlug+/Surprise+ slot caps, and on success
sets `PDB_PROP_GPU_IS_EXTERNAL_GPU = TRUE`. PR #984 patches this to add
`NVreg_ForceExternalGpu` which we already enable via `NVreg_RegistryDwords`.

But even with the property set, the rest of the driver only reads it in
**four places**, and they're cosmetic:

| File:line | What it does |
|---|---|
| `osinit.c:400` | On error/RC recovery path, sets `NV_FLAG_IN_SURPRISE_REMOVAL` |
| `osinit.c:1335` | Where the property is set after detection |
| `kern_perf.c` | Skips `pfmreqhndlrStateLoad` (Platform Request Handler) on eGPU |
| `subdevice_ctrl_gpu_kernel.c` | Reports `SURPRISE_REMOVAL_POSSIBLE` to userspace |

Plus one PCI-side gating in `nv-pci.c:2324` — sanity check on device removal
with non-zero usage count, suppressed for eGPU.

**Takeaway:** the eGPU property doesn't change much. The bug is not in
"different code path on eGPU." It must be in code that's broken regardless,
that just happens to manifest on Blackwell × tunneled-PCIe.

## Finding 2: Blackwell-specific code surface is tractably small

UVM Blackwell HAL (`kernel-open/nvidia-uvm/`):

| File | Lines | Purpose |
|---|---:|---|
| `uvm_blackwell.c` | 157 | Arch init properties (TLB sizing, fault buffer params, VA layout) |
| `uvm_blackwell_ce.c` | 77 | Copy Engine validator only — not init/setup |
| `uvm_blackwell_fault_buffer.c` | 122 | Page fault buffer handling |
| `uvm_blackwell_host.c` | 381 | Host channel logic |
| `uvm_blackwell_mmu.c` | 188 | MMU + page tables |

Total Blackwell-specific UVM code: **~1000 lines**. That's a humanly-readable
surface area. Hopper has the same set plus a `uvm_hopper_sec2.c`; Blackwell
absorbs SEC2 elsewhere.

GSP host side has dedicated Blackwell file `kernel_gsp_gb100.c` for
arch-specific bootstrap and reset, plus shared `kernel_gsp.c` (4752+ lines)
and `message_queue_cpu.c` for the CPU↔GSP RPC channel.

`kernel-open/nvidia/nv-pci.c:514` has a comment that flags Blackwell-specific
BAR enumeration handling: *"Starting from Blackwell BAR1 will be the real
BAR1."* This is a known platform-specific change point.

## Finding 3: GSP-RPC default timeout — Linux is on 4s, NOT 30s

`gpu_timeout.h:40-50`:

```c
#define GPU_TIMEOUT_DEFAULT  0
// GPU_TIMEOUT_DEFAULT is different per platform and can range anywhere
// from 2 to 30 secs depending on the GPU Mode and Platform.
```

`GPU_TIMEOUT_DEFAULT = 0` is a magic value meaning "use the platform default";
the actual value lives in `pGpu->timeoutData.defaultus` (microseconds).

**The Linux value is set at `os.c:2042-2071`** (`osGetTimeoutParams`):

| Mode | Linux default | Notes |
|---|---|---|
| Graphics | **4 seconds** | (`4 * 1000000` µs) |
| Compute | 30 seconds | (`30 * 1000000` µs) |
| vGPU/VGX | 1.8 seconds | matches Windows WDDM 2s hard limit |

**But which mode are we actually in?** From `g_gpu_nvoc.h:5487`:

```c
static inline NvU32 gpuGetMode(struct OBJGPU *pGpu) {
    return pGpu->computeModeRefCount > 0 ? 2 : 1;  // COMPUTE_MODE : GRAPHICS_MODE
}
```

So `COMPUTE_MODE` is true **only when at least one CUDA process is actively
attached with compute mode**. **`nvidia-smi -c EXCLUSIVE_PROCESS` setting is a
policy, not a refcount-bump.** On our live system, `nvidia-smi` reports
`compute_mode = Default` and `computeModeRefCount = 0` until a CUDA app
attaches.

**Crucially, `osGetTimeoutParams` is called ONCE at GPU init in
`timeoutInitializeGpuDefault` (gpu_timeout.c:56)**, when no CUDA process is
attached. So `defaultus` is fixed at **4 seconds**, in graphics mode, and
every subsequent timeout calculation uses this.

**Even our compute workload on a compute-only host runs against a 4s default
timeout.** This is shorter than the Windows comparison value (1.8s WDDM) only
narrowly, and is *much* shorter than the 30s "compute mode" claim suggests.

GSP heartbeat timeouts derive from this with a 30% margin (`kernel_gsp.c:2261`):

```c
gspRmHeartbeatTimeoutMs = defaultTimeoutMs + ((defaultTimeoutMs / 10) * 3);
```

→ on Linux graphics-mode (us): **5.2s GSP heartbeat**.

**The hardcoded waits in HAL paths take `NV_MAX(scaled hardcoded, defaultus)`:**

| Wait location | Hardcoded | Linux effective |
|---|---:|---:|
| BIF GB202 BAR-firewall-disengage (D3 resume) | 500 ms | 4 s |
| FSP GB202 secure-boot-wait (cold boot) | 5 s | **5 s** |
| FSP GB100 secure-boot-wait | 4 s | 4 s |
| SEC2 GB20B init wait | 4 s | 4 s |

So on cold boot, FSP secure-boot has 5s (which is right-sized per the
`kern_fsp_gb202.c:69-75` comment: "FBFalcon training during devinit alone
takes 2 seconds, up to 3 on HBM3"). This is fine.

But all the *generic* RM waits — including any GSP-RPC wait that doesn't have
a longer hardcoded value — use the 4s default. **If a GSP-RPC during
cuCtxCreate takes longer than ~4 seconds over TB-tunneled PCIe**, the
timeout fires.

**This is the strongest evidence yet for H1.**

## Finding 4: There IS a registry override mechanism for RM-internal timeouts

In `nvrm_registry.h:105-124`:

```c
// Change all RM internal timeouts to experiment with Bug 5203024.
#define NV_REG_STR_RM_BUG5203024_OVERRIDE_TIMEOUT        "RmOverrideInternalTimeoutsMs"
//
// Bit fields:
//   Value bits 23:0   — timeout value in ms
//   Bit 31            — set RM default timeout
//   Bit 30            — set RC watchdog timeout
//   Bit 29            — set context-switch timeout
//   Bit 28            — set video-engine timeout
//   Bit 27            — set PMU internal timeout
//   Bit 26            — set FECS watchdog timeout
```

This is **a concrete additional experimental lever (Lever H)**. The mention of
"Bug 5203024" suggests NVIDIA has an internal ticket about timeout tuning.
We can set this via `NVreg_RegistryDwords` exactly the way we set
`RmForceExternalGpu`. Example to bump RM default + RC watchdog to 30s:

```
options nvidia NVreg_RegistryDwords="RmForceExternalGpu=1;RmOverrideInternalTimeoutsMs=0xC0007530"
```

Where `0xC0007530` = bits 31+30 set (`0xC0000000`) + 30000 ms (`0x7530`).

**Why this is interesting for our bug:** if the Linux open module's CUDA-context
init takes longer over TB-tunneled PCIe than the platform default expects,
RM's internal timeout fires while waiting for a GSP-RPC reply, the
recovery path tries to teardown a half-initialized context, and that
teardown deadlocks the kernel. Bumping the timeout would defer the
deadlock-trigger timeout-fire and may produce a clean failure (or even
a clean success) rather than a host hang.

## Hypotheses (ranked)

### H1 — RM/GSP-RPC 4s default timeout fires under TB latency, recovery deadlocks

Plausibility: **high**. Refined evidence after second-pass reading:

- Linux graphics-mode default is **4 s** (Linux, `os.c:2064`).
- We're in graphics mode at GPU init time because `computeModeRefCount = 0` then.
- `defaultus` is fixed at init and doesn't update when CUDA contexts later attach.
- GSP heartbeat is 1.3× default = **5.2 s**.
- Most generic RM waits use this 4s default (overridden only for FSP cold-boot at 5s, BIF firewall at 4s effective, etc).
- TB-tunneled PCIe latency on a JHL9480 is measurably higher than internal — not always by enough to fire 4s, but enough to be marginal.
- Consistent with `nvidia-smi` working (short, single-RPC paths) but `cuCtxCreate_v2` failing (long, multi-RPC sequence).
- Consistent with jciolek's "unicorn boot" pattern (#979 comment 14) — sometimes works for hours, sometimes immediate fail, suggesting a *race* / *marginal* timing rather than a hard logic bug.
- **Why Windows works at the same nominal timeout (1.8s):** Windows nvlddmkm.sys has TDR on top of the timeout — when a wait fires, the driver is reset, the GPU continues. Linux open module appears to hit a deadlock pattern (likely an uninterruptible mutex / spinlock cycle in the recovery path) instead of cleanly resetting.

**Test (Lever H):** override the default timeout via `NVreg_RegistryDwords` to ~30s. The bit-31 flag of `RmOverrideInternalTimeoutsMs` ("Set RM default timeout") covers ALL the generic 4s waits — exactly what we want.

If the freeze pattern changes (longer stable runs, or a clean error code instead of a host hang), H1 is confirmed and the next question becomes: where's the deadlock in the recovery path that Windows doesn't have?

### H2 — Blackwell-specific code path mishandles tunneled-PCIe BAR1 size

Plausibility: **medium**. `nv-pci.c` flags Blackwell-specific BAR layout
changes. Several #979 reporters have BAR1 capped at 256 MB on consumer-BIOS
Linux setups despite the GPU supporting 16 GB resize. CUDA's DMA-map could
have an assumption that breaks when BAR1 is smaller than expected on
Blackwell.

**Test:** read `uvm_blackwell_mmu.c` for BAR1 / DMA-map assumptions. Compare
against `uvm_hopper_mmu.c`. Trace what happens when DMA-map fails on the
context-create path. (Read-only.)

### H3 — Pre-existing close-path bug from Lever B/C/D era is the actual trigger

Plausibility: **low-medium, but cheap to rule out**. We already document
in `architecture.md` that `/dev/nvidia0` and `/dev/nvidia-uvm` close-paths
cause kernel hangs; we mitigate with persistenced + UVM keep-alive. If
the close-path inside the kernel fires DURING `cuCtxCreate_v2`'s error/
retry path, we'd see exactly the silent hang we observe.

**Test:** instrument `osinit.c:400` (the SURPRISE_REMOVAL flag set). If
that path is being hit during normal init (not error), our error-path
hypothesis would localise the trigger. (Read-only first; instrumentation
later.)

## Hypotheses considered and downranked

- **eGPU-gated code paths:** ruled out (Finding 1, only 4 cosmetic read sites).
- **Copy Engine init:** `uvm_blackwell_ce.c` is just an arg validator; CE
  init is shared. Not Blackwell-specific in a way that suggests a bug.
- **GSP firmware bug:** Lever G ruled this out — Windows driver uses the
  same GSP firmware blob on the same GPU, runs cleanly through 27B model
  loads.
- **Blackwell MMU:** `uvm_blackwell_mmu.c` (188 lines, fully read) is purely
  page-table layout. Inherits from Hopper MMU mode and only overrides
  `page_table_depth` to add 256G/512M huge-page support. No DMA-map or
  BAR1 logic. Bug is not in this file.
- **LTR-disabled-in-hierarchy warning** (matches jciolek's #979 dmesg):
  `kbifInitLtr_GB202` (kernel_bif_gb202.c:154) only writes the LTR-enable
  bit if the upstream chipset has `PDB_PROP_CL_UPSTREAM_LTR_SUPPORTED`.
  TB hierarchies frequently disable LTR upstream. The "warning" path just
  skips writing the LTR enable — it does not fail or change other code.
  Cosmetic. Probably not the trigger but worth noting it correlates with
  TB-attached GPUs.

## Recommended next steps (after second-pass reading)

1. **Lever H — runtime experiment.** Now the highest-value next step. Set
   `RmOverrideInternalTimeoutsMs` to 30 s with the SET_RM_DEFAULT_TIMEOUT
   flag (bit 31). The hex value: `0x80007530` = bit 31 + 30000 ms. Or
   `0xC0007530` = bits 31+30 (RM default + RC watchdog) + 30000 ms.
   Apply via `NVreg_RegistryDwords` alongside the existing
   `RmForceExternalGpu=1`. Reboot, re-run ollama lite test.
   - Outcome A — freeze gone: H1 confirmed; the bug is timeout-fire +
     deadlocking-recovery; next investigation is the recovery path.
   - Outcome B — freeze identical: H1 ruled out; bug is a deadlock with
     no timeout involved; next investigation is the lock/wait pattern.
   - Outcome C — different failure (clean error code, partial work, etc.):
     interesting middle ground; suggests timeout was firing but now we
     hit a different code path further in.
2. **Continued source review (deferred until Lever H).** Read
   `kgspBootstrap_HAL` dispatch and the cuCtxCreate GSP handshake to
   understand what waits exist in that path — useful regardless of Lever H
   outcome.
3. **`gpuScaleTimeout` on Blackwell.** Check if Blackwell HAL scales the
   default timeout differently than other arches. ~30 min, read-only.
4. **Compare 595.71.05 vs newer driver branches (596+).** Check
   `git log -- src/nvidia/src/kernel/gpu/gsp/` and `git log -- kernel-open/
   nvidia-uvm/uvm_blackwell*` between 595 and HEAD for any Blackwell × TB
   fixes that haven't landed in our branch yet. ~30 min.

## Source-review coverage gaps (parked reads)

Honest inventory of what was NOT read end-to-end, in priority order. The
"recommended next steps" section above lists actions; this section names the
specific files/regions whose content has not yet been digested. If Lever H
returns outcome B (no change) or C (different failure mode), this list is
where the next reads come from.

### Tier 1 — most likely to contain the freeze locus

These are the highest-leverage reads if Lever H does not resolve.

- **`src/nvidia/src/kernel/core/thread_state.c` (full file).** Identified
  at lines 1151/1156 as where `gpuGetMode` is consulted. Almost certainly
  contains the actual timeout-fire and recovery sequencing. If the
  hypothesis "fired timeout deadlocks the kernel" is right, the deadlock
  is in here or its immediate callers. Have not opened.
- **`src/nvidia/src/kernel/gpu/gsp/message_queue_cpu.c` receive/cleanup
  half.** Read only `GspMsgQueueSendCommand` (lines 460–510). Did NOT read
  the corresponding receive half, the timeout-handling, or the
  failure-cleanup code. The RPC failure path is exactly where a deadlock
  would manifest.
- **`src/nvidia/src/kernel/gpu/gsp/kernel_gsp.c` RPC-issue sections** (file
  is 4752 lines total, only grepped). Specifically the `kgspBootstrap_HAL`
  dispatch and any `kgspExecuteRpc`-equivalent call sites. The cuCtxCreate
  GSP handshake threads through here.

### Tier 2 — supporting context

- **`kernel-open/nvidia-uvm/uvm_blackwell_host.c` (381 lines).** Host
  channel logic on Blackwell. The channel is what carries GSP RPCs.
  Completely unread.
- **`kernel-open/nvidia-uvm/uvm_blackwell.c` (157 lines).** Only the first
  ~50 lines (`arch_init_properties`). Rest unread.
- **`kernel-open/nvidia-uvm/uvm_blackwell_fault_buffer.c` (122 lines).**
  Completely unread.
- **UVM channel setup in general** — `uvm_channel.c`, `uvm_va_block.c`,
  `uvm_pmm_*`. The cuCtxCreate path threads through these. Never grepped.

### Tier 3 — DMA mapping path (H2 territory)

If Lever H rules out the timeout hypothesis (outcome B), the DMA-mapping
path becomes the next strongest candidate.

- **DMA-map code generally** — anywhere `dma_map_*` / IOMMU calls happen
  from kernel-side. Never grepped.
- **`kernel-open/nvidia/nv-pci.c`** beyond lines 490–580 + 2300–2350 (2400+
  lines total, mostly unread). Bridge enumeration, BAR sizing, MSI rearm,
  IRQ routing.
- **The IOCTL surface** — `kernel-open/nvidia/nv.c`, `nv-control.c`,
  `nv-frontend.c`. User→kernel handoff for CUDA. Never grepped.

### Tier 4 — single-function reads, low priority

- **`gpuScaleTimeout`** (gpu_timeout.c:83 caller, function defined
  elsewhere). Could in principle scale `defaultus` differently per arch.
  ~15 minutes to settle.
- **`gpuGetMode_IMPL` and `computeModeRefCount`** — never read where the
  refcount is incremented. Confirms our claim that compute mode is per-
  CUDA-process, not per-host-policy.
- **`chipset_pcie.c:488/513`** — where `PDB_PROP_CL_UPSTREAM_LTR_SUPPORTED`
  is set or cleared based on chipset detection. Cosmetic; LTR-disabled is
  not the freeze trigger.

### Tier 5 — beyond this branch

- **Driver branches 596.x and later.** Have not done `git log -- ...` to
  find Blackwell × TB fixes that may have landed after 595.71.05. Could
  change the picture if a fix exists upstream that we'd just need to
  cherry-pick or upgrade to. ~30 minutes.

### What we have NOT done at all

Direct trace from `cuCtxCreate_v2` IOCTL entry → kernel module dispatch →
RM IOCTL handler → context allocation → DMA map → GSP-RPC. We've explored
*around* the path (timeouts, eGPU gating, MMU layout) but never *along*
the path itself. That trace would localise where the wait actually happens
to be.

## Cross-references in this repo

- `freeze-investigation-plan.md` — top-level investigation plan; Lever E
  (this notes file) is now in-progress. Lever H should be added to the
  plan once we decide whether to run it.
- `architecture.md` — original close-path bug characterization (relevant
  to H3).

## File-and-line index of interesting locations

For future cold-pickup. All paths relative to the cloned repo root.

| Location | What lives here |
|---|---|
| `src/nvidia/arch/nvalloc/unix/src/osinit.c:425-528` | `RmCheckForExternalGpu()` — eGPU detection logic |
| `src/nvidia/arch/nvalloc/unix/src/osinit.c:1335` | Where `PDB_PROP_GPU_IS_EXTERNAL_GPU` is set |
| `src/nvidia/src/kernel/gpu/perf/kern_perf.c` | Platform Request Handler skip-on-eGPU |
| `src/nvidia/inc/kernel/gpu/gpu_timeout.h:40` | `GPU_TIMEOUT_DEFAULT` definition + 2-30s comment |
| `src/nvidia/src/kernel/gpu/gpu_timeout.c:44` | `timeoutInitializeGpuDefault()` |
| `src/nvidia/src/kernel/gpu/gpu_timeout.c:111` | `timeoutRegistryOverride()` |
| `src/nvidia/src/kernel/gpu/gsp/kernel_gsp.c:2261` | GSP heartbeat timeout derivation |
| `src/nvidia/src/kernel/gpu/gsp/message_queue_cpu.c:461` | `GspMsgQueueSendCommand()` — RPC TX with timeout |
| `src/nvidia/interface/nvrm_registry.h:105-124` | `RmOverrideInternalTimeoutsMs` registry key + bit fields |
| `src/nvidia/src/kernel/gpu/gsp/arch/blackwell/kernel_gsp_gb100.c` | Blackwell GSP bootstrap + reset |
| `kernel-open/nvidia-uvm/uvm_blackwell*.c` | Blackwell UVM HAL (~1000 lines total) |
| `kernel-open/nvidia/nv-pci.c:514` | Blackwell-specific BAR layout comment |
