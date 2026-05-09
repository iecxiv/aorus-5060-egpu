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

## Pass 3: complete failure model identified (2026-05-03 evening)

Triggered by a captured kernel-log sequence on our hardware (first time we
have one — `archive/lite-2026-05-03-192806/` — fsync changes worked).
The journal captured the full cause/effect chain:

```
NVRM: Xid (PCI:0000:04:00): 79, GPU has fallen off the bus.
NVRM: GPU 0000:04:00.0: GPU has fallen off the bus.
NVRM: GPU 0000:04:00.0: GPU serial number is 0.
[run nvidia-bug-report.sh ... message]
NVRM: Xid (PCI:0000:04:00): 154, GPU recovery action changed from 0x0 (None) to 0x2 (Node Reboot Required)
NVRM: _issueRpcAndWait: rpcSendMessage failed with status 0x0000000f for fn 78 sequence 1091!
[... 8 more failures, fn 10 (rpcRmApiFree_GSP), sequences 1133-1140 ...]
NVRM: nvGpuOpsReportFatalError: uvm encountered global fatal error 0x60, requiring os reboot to recover.
```

### The chain of events on our hardware

1. **Trigger:** a TB-tunneled PCIe transaction returns `0xFFFFFFFF` (the
   standard "no device on bus" pattern). This can happen for many reasons
   on a Thunderbolt link: a momentary power-state transition, a retimer
   drop, an LTR re-negotiation, or just transient noise. Internal PCIe
   has the same failure modes but at much lower probability.
2. **Detection:** `gpuSanityCheckRegRead_IMPL` (`src/nvidia/src/kernel/gpu/
   gpu_access.c:1245`) is called for every register read. When the value
   reads as all-1s, it does a confirmation read on `NV_PMC_BOOT_0`. If
   that *also* returns `GPU_REG_VALUE_INVALID`, it calls
   `osHandleGpuLost(pGpu, NV_TRUE)`.

   Alternative entry: `gpuVerifyExistence_IMPL`
   (`gpu_access.c:1215-1233`) reads `NV_PMC_BOOT_0` directly, compares
   to cached `pGpu->chipId0`, and calls `osHandleGpuLost(pGpu, NV_TRUE)`
   on mismatch. Single-retry then `NV_ERR_GPU_IS_LOST`.
3. **Declaration:** `osHandleGpuLost`
   (`src/nvidia/arch/nvalloc/unix/src/osinit.c:340-409`) re-reads
   `NV_PMC_BOOT_0` once more. If the value still differs from the cached
   `nvp->pmc_boot_0`, it:
   - Emits Xid 79 (`ROBUST_CHANNEL_GPU_HAS_FALLEN_OFF_THE_BUS`) via
     `nvErrorLog_va`
   - Calls `gpuSetDisconnectedProperties` →
     `pGpu->setProperty(pGpu, PDB_PROP_GPU_IS_LOST, NV_TRUE)` (and clears
     `PDB_PROP_GPU_IS_CONNECTED`)
   - Calls `krcRcAndNotifyAllChannels` to notify all CUDA channels
   - Calls `RmLogGpuCrash`
   - Sets `NV_FLAG_IN_SURPRISE_REMOVAL` (gated on
     `PDB_PROP_GPU_IS_EXTERNAL_GPU` — i.e., this is the only meaningful
     code path that uses our forced-eGPU property)
4. **Sanity-gate-everything:** `_kgspRpcSanityCheck`
   (`kernel_gsp.c:290-335`) is called at the top of every GSP-RPC.
   With `PDB_PROP_GPU_IS_LOST=NV_TRUE`, it returns `NV_ERR_GPU_IS_LOST`
   immediately, **without sending the RPC**.
5. **Cleanup cascade:** UVM tries to clean up via `rpcRmApiFree_GSP`
   (`vgpu/rpc.c:11483`, function code `fn 10`). Every call hits the
   sanity-gate, returns `NV_ERR_GPU_IS_LOST`. The assertion at
   `rs_client.c:844`:

   ```c
   status = serverFreeResourceRpcUnderLock(pServer, pParams);
   NV_ASSERT((status == NV_OK) || (status == NV_ERR_GPU_IN_FULLCHIP_RESET));
   ```

   fires repeatedly because `NV_ERR_GPU_IS_LOST` is *not* in the
   acceptable set. Same at `rs_server.c:259`. We see ~8 iterations
   (sequences 1133-1140) of cleanup attempts, each failing identically.
6. **UVM fatal:** Eventually UVM declares
   `nvGpuOpsReportFatalError` with global fatal error `0x60`,
   "requiring os reboot to recover".
7. **Host hang:** Some subsequent code path (probably in
   `krcRcAndNotifyAllChannels`, `RmLogGpuCrash`, or the workitem queued
   by `gpuSetDisconnectedProperties`) deadlocks the kernel. Exact
   mechanism not yet pinned, but Xid 79 + the RPC cascade was logged
   *before* the freeze, so the deadlock is in the post-detection
   recovery work.

### The smoking-gun comment from NVIDIA

In `osinit.c:361-364` (`osHandleGpuLost`):

```c
//
// This doesn't support PEX Reset and Recovery yet.
// This will help to prevent accessing registers of a GPU
// which has fallen off the bus.
//
```

**NVIDIA documents that the open Linux module does not implement PCIe
error recovery.** A single transient register-read failure makes a
permanent decision: GPU is lost, no second chances, reboot required.

This is the structural difference vs. Windows. Windows nvlddmkm.sys has:
- Native PCIe AER recovery (link can retrain after a transient drop)
- WHQL-mandated multi-retry register-read paths
- TDR — driver reset on stall, system continues

The Linux open module has none of these on this code path. One bad read
→ permanent device loss → reboot.

### Why TB-tunneled PCIe trips this where internal PCIe doesn't

Two contributors:

1. **TB transaction failure rate is non-zero.** Internal PCIe has
   essentially zero transient failures under normal operation. TB has
   measurably higher rates due to retimers, power management, link
   retraining, LTR negotiation, etc. Even a 1-in-10⁹ failure rate gets
   exercised quickly when ollama issues thousands of register reads
   during cuCtxCreate.
2. **The detection-and-decide is too aggressive for TB.** With only
   2-3 reads (the suspicious read + 1-2 confirmations on
   `NV_PMC_BOOT_0`), the TB tunnel has far less opportunity to
   recover from a transient than the driver has to declare loss.
   Windows likely retries on a longer cadence (or uses AER as the
   authoritative signal rather than register reads).

### Why Lever H (timeout override) WILL NOT help

Source review pass 2 hypothesised that the GSP-RPC default timeout (4s
in graphics mode) was firing during cuCtxCreate and triggering a
deadlock-on-recovery. **That hypothesis is wrong.** The captured
journal shows:

- `rpcSendMessage` failures, NOT `gpuTimeoutCondWait` failures
- Failures with `NV_ERR_GPU_IS_LOST`, NOT `NV_ERR_TIMEOUT`
- Xid 79 fires *before* any RPC actually times out
- The `_kgspRpcSanityCheck` at the *top* of the RPC path returns
  `NV_ERR_GPU_IS_LOST` synchronously, never reaching the timeout-
  bounded wait

`RmOverrideInternalTimeoutsMs` only controls the *wait* timeout. It
cannot help when the failure is in the synchronous sanity-check at the
RPC entry. We can still run the Lever H test as a clean control to
confirm zero impact, but the predicted outcome is **B (freeze
identical)**.

### The actual fixable surface

Three layers where a Linux-side patch could meaningfully help:

#### Layer 1: retry policy in `osHandleGpuLost` (lowest-risk patch)

Currently reads `NV_PMC_BOOT_0` exactly once. If the read is wrong,
it commits to GPU-lost. A simple change:

```c
// Hypothetical patch
for (retry = 0; retry < 10; retry++) {
    pmc_boot_0 = NV_PRIV_REG_RD32(nv->regs->map_u, NV_PMC_BOOT_0);
    if (pmc_boot_0 == nvp->pmc_boot_0) {
        return NV_OK;  // false alarm, GPU is fine
    }
    osDelayUs(100);  // wait for TB transient to clear
}
```

10 × 100µs = 1ms total retry budget. Trivial cost on success path
(no retries needed). On failure path we currently lose multiple
seconds (RPC retries) plus a reboot, so 1ms of patience is well
worth it.

#### Layer 2: similar retry in `gpuSanityCheckRegRead_IMPL`

The all-1s detection at `gpu_access.c:1264, 1281, 1298` could retry
the original read several times before tripping the
`osHandleGpuLost` cascade.

#### Layer 3: PEX Reset and Recovery (the proper fix)

Per NVIDIA's own comment, this is the missing piece. Implementing it
is a much bigger lift — coordinates with Linux PCI core, AER subsystem,
and likely requires GSP firmware cooperation. Not feasible as a
hand-rolled patch.

### Status code reference

| Hex | Symbol | Meaning |
|---|---|---|
| `0x0000000f` | `NV_ERR_GPU_IS_LOST` | What we saw in our journal |
| `0x0000003e` | `NV_ERR_GPU_IN_FULLCHIP_RESET` | Acceptable in the assert |
| `0x60` | UVM `GLOBAL_ERROR_xxx` | Need to look up specific name |

### What this changes for the investigation

| Lever | Status |
|---|---|
| **A** Layer-2 cmdline | Already negative; explained — doesn't address the trigger |
| **B** BIOS IFR hunt | Lower priority — even if BIOS pre-boot were enabled, transient TB failures still happen |
| **C** File on #979 | Now MUCH stronger — we have the complete failure model with file:line citations |
| **E** Source review | Substantially complete; this section is the synthesis |
| **F** Firmware survey | Lower priority — bug isn't firmware-resident |
| **G** WSL2 reproduction | Already positive; explained — Windows driver path has retries that Linux doesn't |
| **H** Timeout override | **Predicted negative** before testing. Still worth running as a control to falsify the hypothesis cleanly. |
| **NEW: I — driver patch + dkms rebuild** | Layer 1 retry patch in `osHandleGpuLost`. ~10 lines of C. ~hour to write + rebuild + test. **This is now the most promising lever.** |

## Pass 4: Three-layer reliability model (2026-05-03 evening)

Pass 3's framing was incomplete. It focused on layer 2 (recovery) because
that's where NVIDIA's smoking-gun comment lives, but bus reliability is
genuinely a three-layer concern. Each layer has a Linux-side gap relative
to Windows nvlddmkm.sys, and each is potentially addressable.

### Layer 1 — Prevention: keep the bus stable so transients are rare

**Architecturally important: L1 is a platform problem, not an NVIDIA
problem.** Every L1 lever — LTR enable bit, ASPM policy, TB CLx state,
link width/speed pin, runtime PM coordination — is generic PCIe /
Thunderbolt configuration. The fact that NVIDIA has L1 functions like
`kbifInitLtr_GB202` is because they're configuring the GPU's role as a
PCIe endpoint, but the broader concern (link state, power management,
bus stability) is platform-level and applies equally to any TB-attached
high-bandwidth peripheral: NVMe, capture cards, other GPUs.

The mature Windows TB stack does decade+ of laptop-eGPU hardening here.
WHQL certification mandates aggressive bus-stability behaviours. The
Linux open module has the NVIDIA-side building blocks but tunes them
loosely; the broader Linux PCI / TB subsystems also tune loosely. Both
contribute to the gap.

This means L1 work is **NVIDIA-agnostic** — it can be implemented as a
standalone Linux kernel module that just configures the bus correctly,
without touching `nvidia.ko` at all. See "Lever J-1" in
`freeze-investigation-plan.md` for the companion-module design.

**Concrete L1 deficiencies on our stack:**

- **LTR is not enforced.** `kbifInitLtr_GB202`
  (`src/nvidia/src/kernel/gpu/bif/arch/blackwell/kernel_bif_gb202.c:154`)
  reads `pCl->getProperty(pCl, PDB_PROP_CL_UPSTREAM_LTR_SUPPORTED)` and
  *only* writes the GPU's `LTR_ENABLE` bit if the upstream chipset
  supports LTR. TB hierarchies typically don't propagate LTR — we see
  the "LTR is disabled in the hierarchy" warning. The GPU-side LTR
  could be enabled regardless; the upstream-required check is a
  defensive default that hurts us.
- **ASPM policy not pinned.** Userspace cmdline option
  `pcie_aspm.policy=performance` exists (it's in bilikaz's working
  recipe at #979 comment 9) but we have not applied it. Without it,
  the kernel may transition the bus into low-power states under
  marginal load.
- **TB CLx not disabled.** `thunderbolt.clx=0` exists, also in
  bilikaz's recipe. CLx is TB's low-power link-state mechanism.
  A CLx wake event happening concurrently with a PCIe transaction
  is a candidate trigger for the all-1s reads we see.
- **D-state transitions not fully suppressed.** We have
  `d3cold_allowed=0` at the udev layer and
  `NVreg_DynamicPowerManagement=0x00` at the driver layer, but the
  in-driver runtime PM may still attempt soft transitions. There's
  no driver-internal "external GPU" gate that disables PM more
  aggressively beyond what we've already set.

### Layer 2 — Recovery: when a transient happens, recover gracefully

Where Pass 3's analysis lives. NVIDIA's source comment at
`osinit.c:361-364` documents that the open module **does not implement
PEX Reset and Recovery**. A single all-1s register read commits to
permanent GPU-lost.

**Concrete L2 deficiencies:**

- **No multi-retry on the read-failure path.** `gpuVerifyExistence_IMPL`
  re-reads `NV_PMC_BOOT_0` *once* before committing
  (`gpu_access.c:1215-1233`). `osHandleGpuLost` does the same
  (`osinit.c:357-358`). On a TB tunnel, the transient often clears
  within milliseconds — but the driver doesn't wait.
- **No PCI link retrain.** No use of Linux's `pci_reset_function()` or
  `pci_reset_secondary_bus()`. AER subsystem callbacks not hooked. If
  the link is in a recoverable bad state, no recovery is attempted.
- **No GSP-side recovery.** Once `PDB_PROP_GPU_IS_LOST` is set, GSP's
  view is never resynced even if the link comes back.

### Layer 3 — Graceful failure: when recovery fails, fail cleanly

Windows TDR resets the driver state, returns clean errors to apps,
and keeps the system running. Linux open module instead deadlocks
the kernel.

**Concrete L3 deficiencies:**

- **Cleanup cascade asserts on `NV_ERR_GPU_IS_LOST`.** `rs_client.c:844`
  asserts `(status == NV_OK) || (status == NV_ERR_GPU_IN_FULLCHIP_RESET)`
  after `serverFreeResourceRpcUnderLock`. With status `NV_ERR_GPU_IS_LOST`,
  the assert fires repeatedly across the cleanup loop. Same at
  `rs_server.c:259`.
- **`krcRcAndNotifyAllChannels` may not be GPU-lost-safe.**
  Notification code may walk channel state and read registers, which
  can re-trigger the all-1s detection and recurse into
  `osHandleGpuLost`.
- **`RmLogGpuCrash` reads GPU state for crash dumping.** If the GPU
  is genuinely unreachable, the dump itself can stall. No timeout
  on the dump path.
- **Workitem queued by `gpuSetDisconnectedProperties` may deadlock.**
  `osQueueWorkItem` for `_gpuSetDisconnectedPropertiesWorker` runs
  on a worker thread. If it tries to acquire the same locks as the
  failing path, deadlock.
- **No mechanism to mark contexts as failed and resume.** Even if the
  GPU recovered, the open module has no way to tell userspace "the
  CUDA context died; please re-create it." The process must die and
  the host must reboot.

### Mapping levers to layers

| Lever | L1 (Prevent) | L2 (Recover) | L3 (Graceful) | NVIDIA touch? | Status |
|---|:-:|:-:|:-:|:-:|---|
| **A** Layer-2 cmdline (pci=realloc=off + RmForceExternalGpu) | partial | — | — | yes (modprobe options) | done, negative |
| **G** WSL2 reproduction | n/a | n/a | n/a | n/a | done, positive — proves bug is Linux-side |
| **H** RmOverrideInternalTimeoutsMs | — | — | — | yes | predicted negative; bug bypasses the timeout path |
| **I** Patch + dkms rebuild (retry in `osHandleGpuLost`) | — | **partial (multi-retry only)** | — | **yes (rebuild)** | proposed; ~10-line MVP |
| **K** Layer-1 cmdline experiments (`thunderbolt.clx=0`, `pcie_aspm.policy=performance`) | **direct** | — | — | no — pure cmdline | proposed |
| **J-1** L1 bus-hardening companion module | **direct** | — | — | **no — standalone kmod** | proposed; NVIDIA-agnostic |
| **J-2** L2+L3 NVIDIA-driver recovery (inline / hooks / kprobe) | — | direct | direct | **yes** | proposed; gated on Lever I + J-1 outcome |

**Lever I's honest scope: ~1/3 of the Windows feature set, the cheapest
slice.** It addresses the dominant failure mode (transient register
reads that would clear in ms if anyone waited) but does not implement
AER-style link retrain, does not implement TDR-style state reset, does
not address the L1 prevention angle. Worth doing because of cost/benefit
asymmetry — 10 lines, 1ms latency on the failure path — but not the
"complete fix."

### Lever J: sovereign module concept (split into J-1 + J-2 — 2026-05-03 refactor)

User-proposed (2026-05-03 evening) and refined later same evening once
we realised L1 is platform-agnostic and shouldn't be conflated with the
NVIDIA-driver work. The original "fork nvidia.ko, do everything" framing
has been split:

- **Lever J-1** — L1 bus-hardening companion module (standalone Linux
  kernel module, NVIDIA-agnostic, pure pluggable, zero changes to
  `nvidia.ko`). See `freeze-investigation-plan.md` Lever J-1 for the
  full design, scope, build mechanics, and decision tree.
- **Lever J-2** — L2/L3 NVIDIA-driver recovery (in-driver code, three
  implementation paths: inline patches, hooks-and-companion hybrid, or
  kprobe interception for research-grade work).

The remainder of this section enumerates the per-layer patch surface
and detail relevant to whichever implementation approach is chosen.
The high-level scope and decision tree live in
`freeze-investigation-plan.md`.

**Scope sketch:**

- L1: prevention patches in BIF / FSP / chipset code
  - Force GPU-side LTR enable regardless of upstream
    (`kbifInitLtr_GB202` patch — drop the upstream-supported check)
  - Pin link width/speed via PCI config writes at module load
  - More aggressive runtime PM disable when
    `PDB_PROP_GPU_IS_EXTERNAL_GPU` is set
- L2: recovery patches in `osHandleGpuLost`, `gpuVerifyExistence_IMPL`,
  `gpuSanityCheckRegRead_IMPL`
  - Multi-retry register reads (Lever I MVP)
  - On retry-budget exhaustion, attempt
    `pci_reset_function(pci_dev)` and re-verify
  - Hook AER subsystem callbacks (`pci_error_handlers`) for proactive
    link recovery on AER-reported errors
  - Re-init GSP RPC channel after recovery
- L3: graceful failure patches in `krcRcAndNotifyAllChannels`,
  `RmLogGpuCrash`, `rs_client.c`, `rs_server.c`
  - Replace asserts with logged warnings + clean error returns when
    `status == NV_ERR_GPU_IS_LOST`
  - Add timeouts to crash-dump register reads; bail early if the GPU
    is known-lost
  - TDR-equivalent: reset driver state (channels, contexts, command
    rings), mark in-flight CUDA contexts as failed, allow new
    contexts to be created without reboot
  - Audit `_gpuSetDisconnectedPropertiesWorker` for lock-cycle
    potential

**Build mechanics:**

- Maintain patch series in this repo or a sibling repo
  (e.g. `aorus-egpu-nvidia-open-patches/`)
- Build via DKMS using a `dkms.conf` that points at the cloned source
  with patches applied
- Install to `/lib/modules/$(uname -r)/extra/` (highest precedence)
- Optionally rename the module package to avoid conflicts with the
  dnf-managed `kmod-nvidia-open-dkms`
- Include a `modinfo`-visible version string identifying the patched
  build (e.g. "595.71.05-aorus-l1l2l3-v1") so we can confirm the right
  module is loaded
- A driver-version upgrade triggers a rebase; we cannot just sit at
  595.71.05 forever

**Maintenance and risk:**

- Every NVIDIA upstream release requires re-applying our patches.
  Patch conflicts are likely as the source evolves. Estimate:
  ~1-4 hours per release.
- A bug in our patches could cause its own freezes; bisecting against
  the stock module is harder than bisecting against upstream.
- Reduces our ability to file user-visible bugs against NVIDIA — they
  can (rightly) decline to triage anything that touches a forked
  module.
- Increases ability to *contribute* a fix, since we'd have a working
  reference implementation.

**Testing strategy:**

- Each layer's patches as separately-toggleable build options or
  module parameters, so we can A/B/C test which layer carried the
  win
- Long-soak test (multi-hour sustained inference) before declaring
  the module stable; one passing lite-test isn't sufficient (jciolek's
  unicorn boot ran for 3 hours then hit the freeze on next boot —
  same hardware, same code)
- Cross-validate against the WSL2 leg of the bench (Lever G) — same
  workload should produce comparable numbers if recovery is clean
- Stress the L2 path explicitly via fault injection: write a userspace
  helper that triggers a TB power-state transition mid-CUDA-call, see
  if recovery survives

**Decision criteria for pursuing Lever J:**

- If Lever I is sufficient (transients are the dominant failure mode
  and 10-line retry catches them all): no need for J. Stop.
- If Lever I helps but doesn't fully resolve (some failures remain
  even with retry): J becomes the path forward; specifically L2
  link-retrain and L3 graceful-failure patches.
- If Lever I doesn't help at all: the trigger isn't transient; J is
  still the path forward but starting with L1 prevention.

In all cases, Lever I is the cheapest first move: it tests the
"transients are dominant" hypothesis with a 10-line patch.

### Lever K: Layer-1 cmdline + module-option experiments

Cheap, pure-userspace L1 attempts. No driver rebuild required.

- **Boot args additions** (one cmdline change, one reboot to test):
  - `pcie_aspm.policy=performance` (per bilikaz)
  - `thunderbolt.clx=0` (per bilikaz)
- **NVreg additions via `NVreg_RegistryDwords`:**
  - There may be RM-internal registry keys for forcing LTR on; not
    yet enumerated. Requires another grep over `nvrm_registry.h`.
- **udev power-state pins:** mostly already done
  (`d3cold_allowed=0`, `power/control=on`).

These are partly already applied (Lever A took the pci/RmForceExternalGpu
slice), partly unexplored. Worth running before Lever I just to remove
known-cheap variables.

## Pass 5: Lever H + K test result + new deadlock locus (2026-05-03 late)

Lite test executed with all three levers stacked (A + H + K). Host froze
again. fsync-fixed harness preserved telemetry. Captured kernel log
sequence is **different from the previous freeze** and pins down the
deadlock locus to a new code path.

### Captured kernel error sequence (this freeze)

```
NVRM: nvCheckOkFailedNoLog: Check failed: GPU lost from the bus
       [NV_ERR_GPU_IS_LOST] (0x0000000F) returned from
       nvdEngineDumpCallbackHelper(pGpu, pPrbEnc, pNvDumpState, pEngineCallback)
       @ nv_debug_dump.c:273
NVRM: _issueRpcAndWait: rpcSendMessage failed with status 0x0000000f
       for fn 78 sequence 1106-1119  (14 iterations, fn 78 = engine state dump)
NVRM: nvAssertFailedNoLog: Assertion failed: status == NV_OK @ journal.c:2239
```

No Xid 79 emitted. The freeze hung the kernel **inside the
crash-logging path** before the journal flush completed.

### What's new vs. previous freeze

Previous freeze (lite-2026-05-03-192806, Lever-A-only) cascade:
- Xid 79 emitted
- fn 78 sequence 1091 (one)
- Then fn 10 sequences 1133-1140 (channel cleanup, `rs_client.c:844`)
- UVM fatal 0x60
- Host hang likely in cleanup deadlock

This freeze (lite-2026-05-03-211751, Lever A+H+K stacked):
- No Xid 79 (or not flushed before hang)
- 14 successive fn 78 RPCs (one per engine, `nvdEngineDumpCallbackHelper`)
- Final assertion at `journal.c:2239`
- Host hang in the assertion handler

The same `osHandleGpuLost` declaration triggers **both** cleanup and
crash-dump paths via `krcRcAndNotifyAllChannels` and `RmLogGpuCrash`
respectively. Which path deadlocks first appears non-deterministic —
likely depends on workitem scheduling and lock acquisition order.

### Refined deadlock-locus inventory

Both paths confirmed to deadlock the kernel under different races:

| Path | Source location | Trigger function |
|---|---|---|
| Channel cleanup | `rs_client.c:844`, `rs_server.c:259` | `krcRcAndNotifyAllChannels` → fn 10 (`rpcRmApiFree_GSP`) |
| **Engine state dump** | **`nv_debug_dump.c:273`, `journal.c:2239`** | **`RmLogGpuCrash` → `nvdEngineDumpCallbackHelper` → fn 78** |

The L3 (graceful-failure) work in any future Lever J-2 needs to harden
**both** paths. Patches needed:

- `rs_client.c:844`, `rs_server.c:259`: relax assert to accept
  `NV_ERR_GPU_IS_LOST` (already noted in Pass 3)
- **`nv_debug_dump.c:273`**: short-circuit `nvdEngineDumpCallbackHelper`
  if `PDB_PROP_GPU_IS_LOST` is set — don't try to dump engine state
  via GSP RPC for a known-lost GPU (NEW)
- **`journal.c:2239`**: relax the assert in the journal write path —
  if the GPU is lost, log to a host-side journal sink rather than
  asserting (NEW)
- `RmLogGpuCrash`: skip outright when GPU is lost, OR use only
  host-cached state, not register reads (NEW)

### Lever-by-lever empirical results so far

| Lever | Prediction | Observed | Conclusion |
|---|---|---|---|
| A | partial mitigation | identical fingerprint freeze | confirmed negative |
| H | **predicted negative** (sync sanity-check, not timeout-bounded) | freeze identical, with Lever H active | **confirmed negative — prediction validated** |
| K | partial mitigation if transients dominate | freeze still occurs; single-sample, can't claim rate change | **not statistically distinguishable from baseline** |
| G | n/a (control) | 45-iteration ladder up to 27B clean | confirmed positive — bug is Linux-side |

### Implications for forward plan

1. **Lever I remains the most promising not-yet-tested lever.** It
   addresses the *trigger* (the read-failure detection), so neither
   the cleanup deadlock nor the engine-dump deadlock fires. ~10 lines
   in `osHandleGpuLost`.

2. **Lever J-2 patch surface expanded.** Originally needed L3 graceful-
   failure patches at `rs_client.c:844` and `rs_server.c:259`. Now also
   needs `nv_debug_dump.c:273` and `journal.c:2239`. Still small (4-6
   patch sites total, each a few lines), but more sites means more
   testing.

3. **Lever H is closed out.** Confirmed to not affect this code path.
   Don't propose again. The 30s timeout override remains in place but
   can be removed without losing function (it's not catching anything).

4. **Lever K is closed out for "fix" purposes** but stays as defense-
   in-depth (can't be ruled harmful or actively beneficial from a
   single sample; pcie_aspm.policy=performance et al. are reasonable
   defaults regardless).

5. **The fsync changes paid off twice.** Both freezes since the
   methodology fix have produced kernel log + telemetry data we'd
   never had. Cost: small. Diagnostic value: high.

## Pass 6: Source review of new deadlock loci (2026-05-03 late, Task 3)

Read the two new sites called out by the Pass-5 captured kernel sequence.
Both files at `src/nvidia/src/kernel/diagnostics/`.

### `nv_debug_dump.c:269-281` (the loop containing line 273)

```c
NV_STATUS
nvdDumpAllEngines_IMPL(...)
{
    NVD_ENGINE_CALLBACK *pEngineCallback;
    NV_STATUS nvStatus = NV_OK;

    NV_CHECK_OK_OR_RETURN(LEVEL_ERROR,
        prbEncNestedStart(pPrbEnc, NVDEBUG_NVDUMP_GPU_INFO));

    for (pEngineCallback = pNvd->pCallbacks;
        (prbEncBufLeft(pPrbEnc) > 0) && (pEngineCallback != NULL);
        pEngineCallback = pEngineCallback->pNext)
    {
        NV_CHECK_OK_OR_CAPTURE_FIRST_ERROR(nvStatus, LEVEL_ERROR,
            nvdEngineDumpCallbackHelper(pGpu, pPrbEnc, pNvDumpState, pEngineCallback));   // <- line 273

        // Check to see if GPU is inaccessible
        if (pGpu->getProperty(pGpu, PDB_PROP_GPU_INACCESSIBLE))
        {
            pNvDumpState->bGpuAccessible = NV_FALSE;
        }
    }
    ...
}
```

**Bug analysis:**

1. The loop iterates through ALL engine callbacks (~14 on our GPU).
2. Each callback invokes a GSP RPC to read engine state.
3. With GPU lost, every RPC fails synchronously with `NV_ERR_GPU_IS_LOST`.
4. `NV_CHECK_OK_OR_CAPTURE_FIRST_ERROR` records the error but **does not break the loop** — it just captures the FIRST error and lets iteration continue.
5. The post-callback check sets a local flag `pNvDumpState->bGpuAccessible = NV_FALSE` if `PDB_PROP_GPU_INACCESSIBLE` is set — but **does not break out of the loop**. So even the existing inaccessibility check is advisory.
6. Note: `PDB_PROP_GPU_INACCESSIBLE` and `PDB_PROP_GPU_IS_LOST` are *different properties*; the code doesn't even check the latter here.

**Patch surface (Lever J-2):**

Insert a guard at the top of each iteration:

```c
for (pEngineCallback = pNvd->pCallbacks;
    (prbEncBufLeft(pPrbEnc) > 0) && (pEngineCallback != NULL);
    pEngineCallback = pEngineCallback->pNext)
{
    if (pGpu->getProperty(pGpu, PDB_PROP_GPU_IS_LOST) ||
        pGpu->getProperty(pGpu, PDB_PROP_GPU_INACCESSIBLE))
    {
        pNvDumpState->bGpuAccessible = NV_FALSE;
        break;  // PATCH: stop attempting dumps on a known-lost GPU
    }
    NV_CHECK_OK_OR_CAPTURE_FIRST_ERROR(nvStatus, LEVEL_ERROR,
        nvdEngineDumpCallbackHelper(pGpu, pPrbEnc, pNvDumpState, pEngineCallback));
    ...
}
```

~3 lines. Eliminates the 14-iteration cascade. Doesn't fix the underlying
deadlock-on-assertion (that's `journal.c:2239`), but cuts ~13 redundant
RPC failures from the path.

### `journal.c:2204-2263` (function containing line 2239)

This is the **deferred GPU-dump workitem** — queued from
`gpuSetDisconnectedProperties` via `osQueueWorkItem` after the GPU is
declared lost.

```c
static void
_rcdbAddRmGpuDumpDeferred(  // function name inferred; signature shows void+NvU32+pData
    NvU32 gpuInstance,
    void *pData
)
{
    OBJSYS *pSys = SYS_GET_INSTANCE();
    NV_STATUS status;

    status = osAcquireRmSema(pSys->pSema);                              // LOCK 1
    if (status == NV_OK) {
        status = rmapiLockAcquire(API_LOCK_FLAGS_NONE, RM_LOCK_MODULES_DIAG); // LOCK 2
        if (status == NV_OK) {
            status = rmGpuLocksAcquire(GPUS_LOCK_FLAGS_NONE,
                                       RM_LOCK_MODULES_DIAG);            // LOCK 3
            if (status == NV_OK) {
                Journal *pRcDB = SYS_GET_RCDB(pSys);
                OBJGPU  *pGpu = gpumgrGetGpu(gpuInstance);

                pRcDB->setProperty(pRcDB, PDB_PROP_RCDB_IN_DEFERRED_DUMP_CODEPATH, NV_TRUE);

                status = rcdbAddRmGpuDump(pGpu);   // <- calls nvdDumpAllEngines, fails
                NV_ASSERT(status == NV_OK);        // <- LINE 2239 — assertion fires

                pRcDB->setProperty(pRcDB, PDB_PROP_RCDB_IN_DEFERRED_DUMP_CODEPATH, NV_FALSE);
                rmGpuLocksRelease(...);
            }
            rmapiLockRelease();
        }
        osReleaseRmSema(pSys->pSema, NULL);
    }
}
```

**Bug analysis:**

1. **Three nested locks** are acquired before the dump: RM Semaphore, API lock, GPU lock. Held until `rmGpuLocksRelease` after the assertion.
2. `rcdbAddRmGpuDump(pGpu)` is the function that ultimately calls
   `nvdDumpAllEngines_IMPL` (the loop above). It returns the captured
   error from that loop.
3. With GPU lost, `rcdbAddRmGpuDump` returns `NV_ERR_GPU_IS_LOST`.
4. `NV_ASSERT(status == NV_OK)` fires. In a debug build this is a
   breakpoint; in a release build it logs but doesn't abort.
5. **The kernel hangs here, but the assert itself doesn't crash.** The
   hang is somewhere downstream — likely in the assertion handler's
   own state-collection code (which may attempt MORE register reads
   for stack/context trace), or in a downstream lock release that
   contends with another deadlocked thread.

**Patch surface (Lever J-2):**

Two complementary fixes possible:

1. **At line 2239** — replace the assertion with a graceful-error path:

   ```c
   if (status != NV_OK) {
       NV_PRINTF(LEVEL_ERROR, "rcdbAddRmGpuDump failed: 0x%x (GPU may be lost)\n", status);
       // Don't assert; the dump failed gracefully, continue cleanup.
   }
   ```

2. **Inside `rcdbAddRmGpuDump`** — short-circuit at entry:

   ```c
   if (pGpu->getProperty(pGpu, PDB_PROP_GPU_IS_LOST)) {
       NV_PRINTF(LEVEL_INFO, "Skipping GPU dump for lost GPU\n");
       return NV_OK;  // pretend dump succeeded; nothing to dump
   }
   ```

The second is preferred — it short-circuits BOTH the engine-dump loop
AND the assertion. ~3 lines. Both patches together (1 + 2) provide
defense in depth.

### Combined L3 patch surface (Lever J-2)

Updated full L3 patch surface from Pass 3 + Pass 5 + Pass 6:

| Site | File:line | Patch | Lines |
|---|---|---|---|
| Cleanup assert | `rs_client.c:844` | Add `NV_ERR_GPU_IS_LOST` to acceptable status set | 1 |
| Cleanup assert | `rs_server.c:259` | Add `NV_ERR_GPU_IS_LOST` to acceptable status set | 1 |
| Engine dump loop | `nv_debug_dump.c:269` | Insert per-iteration guard on `PDB_PROP_GPU_IS_LOST` | ~5 |
| Dump entry | `rcdbAddRmGpuDump` (caller of nvdDumpAllEngines) | Short-circuit on `PDB_PROP_GPU_IS_LOST` | ~3 |
| Dump assertion | `journal.c:2239` | Replace `NV_ASSERT(status == NV_OK)` with logged warning | ~3 |

Total: **5 patch sites, ~13 lines of code.** All defensive (replace
asserts with logged-and-continue, or short-circuit on known-lost-GPU).
None of these patches change behaviour on a healthy GPU — they only
change behaviour after `PDB_PROP_GPU_IS_LOST` has been set.

### What this does NOT fix

Lever I (the retry in `osHandleGpuLost`) still does the heavy lifting:
it prevents `PDB_PROP_GPU_IS_LOST` from being set in the first place
on transient PCIe failures. The L3 patches above only matter when the
GPU is GENUINELY lost (e.g. someone unplugged the eGPU). Without
Lever I, transients still cause loss-declaration even though the GPU
is actually fine; with Lever I, only real losses trigger the L3
paths, and L3 patches keep those losses from deadlocking the kernel.

**Both Lever I and the L3 patches are needed for full Windows-grade
robustness.** Lever I alone leaves the kernel hanging on real GPU
disconnect. L3 alone leaves the kernel committing to lost-GPU on
transients.

## Pass 7: Lever I patch surface (full implementation, 2026-05-03 late)

Implementation-grade documentation of the Lever I retry patch, parallel
to Pass 6's documentation of the L3 patch surface. Same style: read the
target site in full, show the patched form, justify the parameters,
cross-reference the artifacts.

This Pass produces three artifacts in this repo:

| Artifact | Path |
|---|---|
| The actual patch | `patches/0001-osHandleGpuLost-retry-on-transient-pcie-failure.patch` |
| Build/install script | `tools/build-patched-driver.sh` |
| Operator runbook | `docs/patched-driver-runbook.md` |

The runbook covers operator-level workflow (prereqs, build, verify,
test, rollback, maintenance). This section is the source-level analysis.

### Target: `osHandleGpuLost` at `osinit.c:340-409`

Original (current 595.71.05 source, lines 340-358):

```c
NV_STATUS
osHandleGpuLost(OBJGPU *pGpu, NvBool bEmitXid)
{
    nv_state_t *nv = NV_GET_NV_STATE(pGpu);
    nv_priv_t *nvp = NV_GET_NV_PRIV(nv);
    NvU32 pmc_boot_0;

    // Determine if we've already run the handler
    if (!pGpu->getProperty(pGpu, PDB_PROP_GPU_IS_CONNECTED))
    {
        return NV_OK;
    }

    pmc_boot_0 = NV_PRIV_REG_RD32(nv->regs->map_u, NV_PMC_BOOT_0);   // <- single read
    if (pmc_boot_0 != nvp->pmc_boot_0)
    {
        // ... declares GPU lost (Xid 79, gpuSetDisconnectedProperties,
        //     krcRcAndNotifyAllChannels, RmLogGpuCrash, etc.) ...
    }
    return NV_OK;
}
```

The single-read commit is the bug. Our patch wraps it in a retry loop.

### Patched form (semantic, full diff in `patches/0001-...`)

```c
NV_STATUS
osHandleGpuLost(OBJGPU *pGpu, NvBool bEmitXid)
{
    nv_state_t *nv = NV_GET_NV_STATE(pGpu);
    nv_priv_t *nvp = NV_GET_NV_PRIV(nv);
    NvU32 pmc_boot_0;
    NvU32 retry;            // PATCH

    if (!pGpu->getProperty(pGpu, PDB_PROP_GPU_IS_CONNECTED))
        return NV_OK;

    // PATCH: retry the read up to 10 times with 100us between attempts
    // before falling through to the lost-declaration path. 1ms total
    // retry budget. Zero added latency on healthy reads (loop exits
    // first iteration).
    for (retry = 0; retry < 10; retry++)
    {
        pmc_boot_0 = NV_PRIV_REG_RD32(nv->regs->map_u, NV_PMC_BOOT_0);
        if (pmc_boot_0 == nvp->pmc_boot_0)
        {
            if (retry > 0)
            {
                NV_DEV_PRINTF(NV_DBG_ERRORS, nv,
                              "AORUS Lever I: PCIe transient cleared after %u retries (%u us) - GPU not lost\n",
                              retry, retry * 100);
            }
            return NV_OK;
        }
        if (retry < 9)
            osDelayUs(100);
    }

    // FALL THROUGH: pmc_boot_0 is the last (still-mismatched) value.
    // Existing lost-declaration path runs unchanged.
    if (pmc_boot_0 != nvp->pmc_boot_0)
    {
        // ... existing code: Xid 79, gpuSetDisconnectedProperties, ...
    }
    return NV_OK;
}
```

### Parameter choices justified

#### `N_RETRIES = 10` and `osDelayUs(100)`

Total retry budget: **10 × 100 µs = 1 ms**.

- **Why 100 µs per attempt:** matches the cadence used by other polling
  loops in this driver. Existing precedent: `kbifPollBarFirewallDisengage_GB202`
  in `kernel_bif_gb202.c:327` uses `osDelayUs(100)` between attempts of
  a similar BAR-firewall poll. `thread_state.c:444` and
  `gpu_timeout.c:382` also use 100 µs as a polling tick.
- **Why 10 iterations:** gives a 1 ms window without going so long
  that we add meaningful latency to a real disconnect. Empirically, TB
  retimer drops, link power-state transitions, and LTR re-negotiation
  events are sub-ms phenomena. Issue #979 reporters' "unicorn boot"
  patterns (jciolek comment 14) imply the trigger is near-instantaneous
  — within ms of the first PCIe transaction the GPU may recover or fail
  permanently. 1 ms straddles the recoverable window.
- **What if 1 ms isn't enough?** Bump `N_RETRIES` to e.g. 50 (5 ms).
  Cost on real disconnect grows linearly with N. If 5 ms doesn't catch
  it, the trigger likely isn't a TB transient at all — the bug is
  elsewhere and Lever J-1 / J-2 take over.

#### `NV_DBG_ERRORS` log level for the catch message

NVIDIA's printf levels:
- `NV_DBG_INFO` — debug-only, suppressed in release builds
- `NV_DBG_ERRORS` — printed in release builds via `dmesg`
- `NV_DBG_WARNINGS` — printed in release builds, ranks above ERRORS

Using `NV_DBG_ERRORS` ensures the catch message lands in `dmesg` of
production driver builds. We *want* to see this — every catch is
proof the patch is doing useful work, and the absence over time would
suggest transients aren't the dominant failure mode.

A future tuning: bump to `NV_DBG_WARNINGS` if we want to differentiate
the catch message from "real" errors. Cosmetic.

#### Why patch only `osHandleGpuLost`, not `gpuVerifyExistence_IMPL`

`gpuVerifyExistence_IMPL` (`gpu_access.c:1215-1233`) already has a
1-retry pattern wrapped around its call to `osHandleGpuLost`. With
our patch inside `osHandleGpuLost`, the effective behaviour from
`gpuVerifyExistence` becomes:

1. Read `NV_PMC_BOOT_0` once, mismatch detected
2. Call `osHandleGpuLost(NV_TRUE)` — which now retries 10 times
3. If `osHandleGpuLost` returned without declaring lost: GPU is fine
4. Re-read once more (existing code), confirm
5. Return `NV_OK` or `NV_ERR_GPU_IS_LOST`

So we get up to 11+1 = 12 attempts total before giving up.
`gpuSanityCheckRegRead_IMPL` (`gpu_access.c:1245-1320`) is similar:
all-1s detected → re-read NV_PMC_BOOT_0 → call `osHandleGpuLost` if
INVALID. Same effective coverage from a single patch site.

**Patching only `osHandleGpuLost` keeps the surface minimal** while
covering all the read-failure entry points.

#### Why retain the original lost-declaration path on fall-through

If all 10 retries fail, `pmc_boot_0` holds a still-mismatched value
and the existing `if (pmc_boot_0 != nvp->pmc_boot_0)` block runs
unchanged. This is intentional:

- On a real GPU disconnect (eGPU unplugged), retries will all fail
  and the original code path runs — preserving the existing Xid 79
  emit, channel notification, crash-dump attempt, etc.
- This means **Lever I does not break the disconnect signal path**.
  Userspace still gets notified that the GPU is gone via the existing
  mechanisms.
- Lever J-2 is what makes the disconnect path itself robust (no
  kernel hang). Lever I just keeps the path from triggering on
  transients. Complementary, not redundant.

### Why the patch is small enough to be conservative

The patch:
- Touches **one function** in **one file**
- Adds **one local variable** (`NvU32 retry`)
- Replaces **one statement** (the single read) with a **for-loop**
  containing the same statement plus delay
- Adds **one log line** under a conditional that only fires on the
  catch path
- Does **not** modify the lost-declaration code below
- Does **not** add new headers (`osDelayUs` is already reachable via
  `<os/os.h>` per existing `osinit.c` includes; precedent in
  `kernel_bif_gb202.c`, `thread_state.c`, etc.)

A reviewer can read the patch in 30 seconds and verify it doesn't
change behaviour on healthy reads or real disconnects.

### Build mechanics summary

Full details in `tools/build-patched-driver.sh`. High-level:

1. Source at `/root/nvidia-open-src/`, tag `595.71.05`.
2. `git checkout -- src kernel-open` to ensure clean baseline.
3. `git apply patches/*.patch` (idempotent via `--check`).
4. `make -j$(nproc) modules SYSSRC=/lib/modules/$(uname -r)/build`.
5. `xz`-compress and install built `.ko` files to
   `/lib/modules/$(uname -r)/extra/`, replacing the dnf-managed copies
   after backing them up to sibling `.dnf-stock-<timestamp>` files.
6. `depmod -a $(uname -r)`.
7. Reboot manually (script does NOT reboot).

### Verification post-reboot

| Check | Command | Expected if patched |
|---|---|---|
| Module version | `modinfo nvidia \| grep version` | `version: 595.71.05` (same) |
| Source hash | `modinfo nvidia \| grep srcversion` | **NOT** `58D233B8E3F4A2973D73151` (will differ from stock) |
| Module load | `dmesg \| grep 'NVRM: loading'` | `NVRM: loading NVIDIA UNIX Open Kernel Module for x86_64 595.71.05` (text unchanged but build-date will reflect rebuild) |
| Patch active | `dmesg \| grep 'AORUS Lever'` | empty unless a transient has been caught |

### What this patch does NOT do

- **Does not implement AER recovery.** AER would let the kernel
  attempt a link retrain when the PCI subsystem reports a recoverable
  error. Our patch only re-reads a register; if the link is genuinely
  in a wedged state for >1 ms, our retries all fail.
- **Does not implement TDR-style state reset.** If the GPU is
  genuinely lost, the existing fall-through path runs and we hit the
  cleanup-deadlock or dump-deadlock that Pass 5 documented. Lever J-2
  patches address that separately.
- **Does not protect against non-`NV_PMC_BOOT_0` failure modes.**
  There may be other places in the driver where a register read
  failure leads to permanent declared-lost. Pass 3 identified
  `osHandleGpuLost` as the central declaration site and `gpuVerifyExistence`
  / `gpuSanityCheckRegRead` as the entry points; if there's another
  entry path we haven't found, this patch doesn't cover it.

### Why this is the right first move regardless

Even with all the caveats:

- It tests the dominant-trigger hypothesis directly (transients are
  the cause of most freezes vs. real failures).
- It's reversible in 30 seconds via the saved backup.
- It doesn't change behaviour on healthy reads or real disconnects.
- It produces a logged signal whenever it catches a transient — so
  every successful inference run gives us empirical data.

If this patch alone fixes our setup, we're done with the freeze
investigation. If it doesn't, we know the trigger isn't a transient
in the recoverable-by-retry sense, and Lever J-1 / J-2 become prime.

### Cross-reference: pass-by-pass summary

| Pass | Output |
|---|---|
| 1 | Repository cloned, surface mapped, eGPU detection found shallow |
| 2 | 4-second timeout default identified; H1 hypothesis sharpened (later disproven) |
| 3 | Failure model fully characterised: trigger → declaration → cascade |
| 4 | Three-layer reliability model (L1/L2/L3) introduced |
| 5 | Lever H + K test result; new deadlock locus at journal.c:2239 |
| 6 | L3 patch surface fully documented (Lever J-2): 5 sites, ~13 lines |
| **7** | **Lever I patch surface fully documented: 1 site, ~30 lines including comments + diagnostic printf** |

## Pass 8: Lever J-2 patch realisation (2026-05-03 late)

Pass 6 documented the L3 patch surface conceptually. Pass 8 stages the
actual patch files alongside Lever I (Pass 7) so a single build of
`tools/build-patched-driver.sh` deploys both levers together.

### Three patch files staged

| File | Targets | Purpose |
|---|---|---|
| `patches/0002-rcdbAddRmGpuDump-shortcircuit-on-gpu-lost.patch` | `journal.c:2917` (entry of `rcdbAddRmGpuDump`) | **Primary deadlock-prevention.** Early-return on `PDB_PROP_GPU_IS_LOST` so the engine-dump cascade never runs on a known-lost GPU |
| `patches/0003-nvDumpAllEngines-break-on-gpu-lost.patch` | `nv_debug_dump.c:269-281` (the engine callback loop) | **Defence-in-depth.** Per-iteration guard checking `PDB_PROP_GPU_IS_LOST` and `PDB_PROP_GPU_INACCESSIBLE`; breaks loop on either |
| `patches/0004-cleanup-asserts-accept-gpu-lost.patch` | `rs_client.c:844`, `rs_server.c:259`, `journal.c:2239` (three asserts) | **Defence-in-depth.** Relax asserts to accept `NV_ERR_GPU_IS_LOST` as valid status; log diagnostic markers |

All three patches add `NV_DBG_ERRORS`-level log markers (`AORUS Lever J-2`)
so operators can observe the patches firing in dmesg.

### Why this split

- **0002** is the *primary* fix. Prevents the entire engine-dump
  cascade from running on a lost GPU — eliminates the 14 fn-78 RPC
  failures captured in the kernel log at `lite-2026-05-03-211751`.
- **0003** is *secondary* defence. If some other entry path calls
  `nvdDumpAllEngines_IMPL` directly, the loop still exits cleanly.
- **0004** is *cosmetic* on the asserts (`NV_ASSERT` in release builds
  typically just logs, doesn't halt). Included for the diagnostic
  markers it adds.

The split makes selective application possible — moving a patch out of
`patches/` causes the build to skip it.

### Combined Lever I + J-2 outcome interpretation

With all four patches deployed:

| Scenario | Behaviour |
|---|---|
| Healthy reads | identical to stock |
| Transient ≤ 1 ms | **Lever I catches it.** dmesg: `AORUS Lever I: PCIe transient cleared after N retries`. Workload continues transparently. |
| Transient > 1 ms | Lever I's retries exhaust; falls through to lost-declaration. **Lever J-2 prevents the deadlock.** dmesg: `AORUS Lever J-2 (rcdbAddRmGpuDump): GPU lost, skipping crash dump`. Workload errors out cleanly. Host stays alive. |
| Real disconnect (eGPU unplugged mid-workload) | Same as transient > 1 ms. Host stays alive; workload errors out; eGPU unusable until reboot or manual PCI rebind. |

Matches the Windows-grade robustness model (multi-retry + TDR-equivalent
graceful failure), minus the AER link retrain layer.

### Total patch series footprint

- **6 sites across 4 files**
- **~52 lines of code change** (not counting comments)
- All defensive
- All conditional on `GPU_IS_LOST` / `INACCESSIBLE` / `NV_ERR_GPU_IS_LOST`
- Zero behaviour change on a healthy GPU

### Pass-by-pass summary updated

| Pass | Output |
|---|---|
| 1 | Repository cloned, surface mapped |
| 2 | 4-second timeout default; H1 hypothesis (later disproven) |
| 3 | Failure model fully characterised |
| 4 | Three-layer reliability model (L1/L2/L3) |
| 5 | Lever H + K test result; new deadlock locus at journal.c:2239 |
| 6 | L3 patch surface fully documented (Lever J-2 conceptually): 5 sites, ~13 lines |
| 7 | Lever I patch staged: 1 site, ~30 lines |
| **8** | **Lever J-2 patches staged: 3 patch files, 5 sites, ~22 lines** |

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
