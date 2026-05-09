# IOMMU / DMAR / GSP_LOCKDOWN — comprehensive analysis

> **Status:** Active investigation (2026-05-06 → 2026-05-07).
> **Authoritative source** for the IOMMU + GSP-lockdown failure mode that
> drives much of this project's reliability work.
>
> This document consolidates findings across:
> - H10 (IOMMU policy)
> - H13 (WPR2 register stuck — symptom level)
> - H14 (first-rm_init_adapter failure root cause)
> - H16 (PCIe transient as second lockdown trigger — NEW 2026-05-07)
>
> See also: forensic dossiers in `archive/diag-telemetry-2026-05-06-154732/`,
> `archive/commit3-recovery-loop-2026-05-06-161429/`,
> `archive/iommu-off-test-2026-05-07-145453/`.
>
> **Last updated:** 2026-05-07 14:58

---

## Executive summary (read this first)

On the AORUS RTX 5090 + Intel NUC 15 Pro+ + Thunderbolt 4 stack, the GPU fails
to bind on cold-cold-boot ~50–100% of the time depending on system state.
The user-visible symptom is `nvidia-smi` reporting "No devices found" and dmesg
containing `_kgspBootGspRm:
unexpected WPR2 already up`.

**The symptom we instrumented over weeks is "WPR2-stuck", but the actual
mechanism is GSP firmware entering LOCKDOWN mode and refusing to boot GSP
normally.** WPR2 register being set is a side effect of the failed GSP boot, not
the cause.

GSP enters lockdown for **at least two empirically distinct reasons**:

1. **IOMMU rejection of GSP DMA** (H10 / H14) — kernel marks the
   Thunderbolt-attached eGPU as untrusted; IOMMU enforces DMA translation; GSP
   firmware's runtime DMA setup hits unmapped addresses and is rejected;
   firmware interprets as security violation and locks down.
   **Eliminated empirically by `iommu=off` cmdline.**
2. **PCIe link transient during initial GSP boot** (H16, NEW 2026-05-07) — eGPU
   briefly drops off the PCIe bus during GSP's self-bootstrap; GSP firmware sees
   host link disappear, interprets as security violation, locks down.
   **Persists even with IOMMU fully disabled.**

**Working today's pragmatic stack** (validated 2026-05-07 14:54):
- `iommu=off intel_iommu=off` cmdline → eliminates the IOMMU-class failures
- L4 helper `aorus-egpu-wpr2-recovery.service` OR natural retries in ~30 seconds
  → handles residual H16-class failures
- Result:
  cold-cold-boot eventually reaches healthy GPU within ~30–60s without manual
  intervention; GPU-on-demand workloads are reliable

---

## Mechanism — full path from cold-boot to lockdown

### Phase 1: cold-cold-boot baseline

After full power cycle (host poweroff + eGPU AC disconnect / reconnect), the
hardware is in a clean state:
- WPR2 register reads 0 (clear)
- GSP firmware not running
- eGPU has fresh power-up state
- Thunderbolt link negotiated; eGPU enumerated by kernel as PCI device
  `0000:04:00.0` (vendor 0x10de, device 0x2b85, GeForce RTX 5090)

Kernel-side at this point:
- `pci_dev->untrusted = 1` (TB-attached → kernel security policy)
- IOMMU group 22 created for eGPU + audio function
- Default IOMMU treatment:
  full DMA translation (because `untrusted=1` overrides global `iommu=pt`)
- `dmesg`:
  `Intel-IOMMU force enabled due to platform opt in` — BIOS sets a flag that the
  kernel respects regardless of user `iommu=pt`

### Phase 2: nvidia.ko probe

`nv_pci_probe` runs:
- BAR0 mapped at physical 0x80000000 (64MB region)
- Per-pdev nvl + lever_m allocated (Commit 1 scaffolding)
- WPR2 register read (Commit 2):
  always reads 0 at this point → no detection trigger
- `aorus_qwatchdog_init` spawned:
  kthread runs at 200ms intervals reading PMC_BOOT_0
- Probe returns 0 successfully

GPU is now bound to nvidia driver.
No GSP boot has been attempted yet.

### Phase 3: First /dev/nvidia0 open → rm_init_adapter

When persistenced (or any consumer) opens `/dev/nvidia0`:
- `nv_open` → `nv_start_device` → `rm_init_adapter`
- Diagnostic [DIAG] readings at this point:
  **WPR2 = 0** (still clear)
- `rm_init_adapter` calls into RM-side code:
  `_kgspBootGspRm`
- GSP boot sequence begins:
  load firmware → set up secure region (WPR2) → start GSP RPC channel → wait for
  GSP_INIT_DONE

**This is where it breaks.** The GSP firmware attempts to:
1. Allocate runtime DMA buffers in host RAM
2. Set up secure region pointer (sets WPR2 register hardware-side)
3. Start its self-bootstrap

If anything goes wrong during step 1 or step 3, GSP firmware sends
`GSP_LOCKDOWN_NOTICE` (RPC function 4124) to the host instead of `GSP_INIT_DONE`
(function 4097).

### Phase 4: Lockdown trigger #1 — IOMMU rejection (H10/H14)

Pattern in dmesg:
```
DMAR: DRHD: handling fault status reg 3
DMAR: [DMA Write NO_PASID] Request device [04:00.0] fault addr 0x...
      [fault reason 0x71] SM: Present bit in first-level paging entry is clear
```

Mechanism:
GSP firmware's DMA engine attempts `dma_write` to an address.
Kernel IOMMU has no first-level paging entry for that address (the NVIDIA driver
hasn't pre-registered it via `iommu_dma_map_*`).
IOMMU rejects the transaction.
GSP firmware sees DMA failure, interprets as security violation, sends
`GSP_LOCKDOWN_NOTICE`.

Fault reasons observed:
- `0x71` (Scalable Mode) — when SM-mode IOMMU is active
- `0x05` (Write access not set), `0x06` (Read access not set) — when legacy mode
  is active (`intel_iommu=on,sm_off`)

Both reasons are different IOMMU error codes for the same fundamental problem:
address not authorized in IOMMU page tables.

**Volume**:
48–524 fault events per failed boot, depending on how many DMA addresses GSP
probes.

**Eliminated by**:
`iommu=off intel_iommu=off` cmdline (validated 2026-05-07:
0 DMAR faults observed).

### Phase 5: Lockdown trigger #2 — PCIe link transient (H16)

Pattern in dmesg (this boot, with IOMMU disabled):
```
[DIAG]: site=post-rmInit-FAIL  PMC_BOOT_0=0xffffffff  WPR2_ADDR_HI=0xffffffff
                                                       ↑↑↑
                          Bus dead — GPU briefly off PCIe link
```

Mechanism (proposed):
during GSP's self-bootstrap, the eGPU's PCIe link to the upstream Thunderbolt
switch goes through a brief state transition that looks like a "device removed"
signal from the GPU's perspective.
GSP firmware sees its host link disappear during boot, interprets as security
violation, sends `GSP_LOCKDOWN_NOTICE`.

This is **independent of IOMMU**.
With `iommu=off`, IOMMU doesn't reject any DMA, but the PCIe transient still
occurs and still triggers lockdown.

Possible underlying causes:
- Thunderbolt link layer renegotiation during high-bandwidth GSP boot
- TB switch's internal buffering / credit allocation hiccup
- GPU's own PCIe link training during firmware transition

This is the same family as our earlier "Mode B silent freeze" work (Levers Q,
H8, H9).
Lever H9 tightened PCIe Completion Timeout to catch and recover from these
transients faster, but apparently doesn't fully prevent them at GSP-boot time.

**Status**:
H16 is NEW as of 2026-05-07.
Not yet investigated in detail.
Needs forensic dossier on its own.

### Phase 6: Subsequent retries see "WPR2 already up"

After GSP locks down in Phase 4 or Phase 5:
- WPR2 register is left set in hardware (GSP allocated it before locking down —
  value 0x07f4a000, the normal-running value)
- Persistenced retries `open(/dev/nvidia0)` every ~10s
- Each retry:
  `_kgspBootGspRm` reads WPR2 register, sees it set, refuses to proceed with GSP
  boot
- dmesg:
  `_kgspBootGspRm:
  unexpected WPR2 already up, cannot proceed with booting GSP`

This is the symptom that originally tagged this as "WPR2-stuck".
But the WPR2 register being set is the consequence, not the cause.

### Phase 7: Eventual recovery (if it happens)

Empirically we've seen recovery happen via three paths:

1. **Natural firmware recovery**:
   GSP firmware times out its lockdown state internally and a subsequent retry
   succeeds.
   Stochastic.
   With `iommu=off`, observed at ~30 seconds (4 retries).
   Without `iommu=off`, observed at ~50 seconds (7 retries) on one boot, never
   recovering on another.

2. **L4 helper recovery** (`aorus-egpu-wpr2-recovery.service`):
   does `pci_remove + pci_rescan + pci_reset_function` sequence.
   Forces a hardware-level state reset that clears WPR2 and re-initializes the
   GSP startup sequence.
   Usually succeeds in 1-3 attempts.

3. **In-driver recovery** (Commit 3 of patch 0019, currently disabled):
   programmatically does the same as L4 helper from a kernel work queue.
   Works structurally but caused recovery storm at 16:14:29 boot when fired too
   aggressively.

---

## Empirical fingerprints — how to recognise each failure path

| dmesg signal | Cause | Mitigation |
|---|---|---|
| `_kgspBootGspRm: unexpected WPR2 already up` | Symptom of any prior failed GSP boot — not diagnostic by itself | Recovery (clear WPR2 via reset) |
| `DMAR: ... fault reason 0x71 SM: Present bit ... is clear` | IOMMU SM-mode rejection | `iommu=off` |
| `DMAR: ... fault reason 0x05/0x06 PTE Read/Write access not set` | IOMMU legacy-mode rejection | `iommu=off` |
| `Intel-IOMMU force enabled due to platform opt in` | BIOS forcing IOMMU on; cmdline `iommu=pt` ignored | Use `iommu=off intel_iommu=off` to override |
| `GSP_LOCKDOWN_NOTICE` in RPC event history | GSP firmware locked down — confirmation of failure mode | Either prevent (H10/H14/H16) or recover |
| `_kgspLogRpcSanityCheckFailure: GPU0 sanity check failed 0xf waiting for RPC response from GSP. Expected function 4097 (GSP_INIT_DONE)` | GSP didn't send INIT_DONE because it locked down | Same as above |
| `[DIAG]: site=post-rmInit-FAIL  PMC_BOOT_0=0xffffffff` | PCIe bus dead at moment of failure → H16 (transient, not IOMMU) | H16 investigation needed |
| `[DIAG]: site=post-rmInit-FAIL  PMC_BOOT_0=0x00000000` | GPU stalled but bus alive → IOMMU class | Eliminated by `iommu=off` |
| `[DIAG]: site=post-rmInit-FAIL  PMC_BOOT_0=0x1b2000a1 WPR2_ADDR_HI=0x07f4a000` | Normal post-failure state — WPR2 set, bus alive, GSP locked | Recovery |
| `aorus_qwatchdog_cycles` not incrementing post-failure | Q-watchdog stopped after RM saw GPU-lost — Q-active correctly engaged | Working as designed |

---

## What we tested and what each test concluded

### Test 1: `intel_iommu=on,sm_off` (2026-05-06 17:04)

**Hypothesis**:
SM-mode-specific bug in IOMMU handling causes GSP DMA rejection.

**Result**:
FALSIFIED.
DMAR faults still occur in legacy IOMMU mode, just with different fault reasons
(0x05/0x06 instead of 0x71).
174 faults observed; 27 rm_init_adapter failures; no recovery in 70+s.

**Side benefit retained**:
L4 helper recovery succeeded 1/1 on this boot (vs 0/3 on prior default-IOMMU
boot).
SM-off may make recovery more reliable due to simpler IOMMU paging structures
during reset.

### Test 2: Loadable PCI quirk module (2026-05-07 00:39)

**Hypothesis**:
Mark eGPU as `pci_dev->untrusted=0` via `DECLARE_PCI_FIXUP_HEADER` to bypass
TB-untrusted IOMMU enforcement.

**Implementation**:
`kernel-modules/aorus-egpu-trust/` — standalone kernel module with
EARLY/HEADER/FINAL fixups for vendor 0x10de devices 0x2b85 + 0x22e8.
Embedded in initramfs via `force_drivers+=" aorus-egpu-trust "` and
`rd.driver.pre=aorus_egpu_trust`.

**Retired 2026-05-09:** the module is dead code under the current `iommu=off
intel_iommu=off` cmdline (Lever T, adopted 2026-05-07).
With IOMMU disabled, `pci_dev->untrusted` is consulted by nothing.
Module source moved to `archive/retired-kernel-modules-aorus-egpu-trust/`;
resurrection notes in that directory's README.
The structural- infeasibility caveat below explains why the loadable-module
quirk approach was the wrong path even before Lever T superseded it.

**Result**:
FALSIFIED at infrastructure level.
Module loaded from initramfs at 00:39:50.824826.
eGPU enumerated at 00:39:50.771188.
Module loaded **53.6ms after** PCI scan.
Kernel only iterates `__pci_fixups_*` sections of BUILTIN code during
`pci_setup_device` — module-registered fixups don't apply to already-enumerated
devices.

**Conclusion**:
Loadable-module approach is structurally infeasible for this fixup type.
Production mechanism must be either:
- Built-in kernel patch (compiled into kernel, fires during PCI scan)
- Driver-side `dma_map_*` registration (the upstream-correct path)

### Test 3: Runtime sysfs `iommu_group/type=identity` (2026-05-07)

**Hypothesis**:
Change IOMMU group type from `DMA` (translation) to `identity` (passthrough) at
runtime.

**Result**:
FALSIFIED.
`echo identity > .../iommu_group/type` returns EPERM.
Kernel security policy blocks userspace IOMMU type changes for active devices.

### Test 4: `iommu=off intel_iommu=off` cmdline (2026-05-07 14:54) ★

**Hypothesis**:
Full IOMMU disable will eliminate IOMMU-related lockdown triggers; remaining
failures (if any) reveal other causes.

**Result**:
**PARTIAL SUCCESS.**
- IOMMU truly disabled:
  dmesg shows `DMAR:
  IOMMU disabled`
- DMAR faults:
  0 (confirmed prevention of IOMMU-class failures)
- `iommu_dma_protection`:
  0 (TB domain reflects no protection)
- GSP_LOCKDOWN_NOTICE:
  still 18 events observed
- rm_init_adapter:
  4 failures → 1 success after ~30s

**Conclusion**:
IOMMU is a contributing cause, not the sole cause.
With IOMMU off, recovery is faster and more reliable, but a second trigger (now
H16, PCIe transient) still produces lockdown events.

### Comparison across tests

| Boot | DMAR faults | retries to success | total time | iommu_dma_protection |
|---|---|---|---|---|
| 2026-05-06 16:50 (sm-on, default) | 48 | 7 | ~48s | 1 |
| 2026-05-06 17:04 (sm-off) | 174 | 27 | never (this boot) | 1 |
| 2026-05-06 16:14 (Commit 3 active) | 524 | 21 | never | 1 |
| **2026-05-07 14:54 (iommu=off)** | **0** | **4** | **~30s** | **0** |

`iommu=off` produces the cleanest, fastest recovery.
H10/H14 (IOMMU) contribution is eliminated.
Residual failures expose H16.

---

## Production workaround — current state

### Cmdline workaround (validated 2026-05-07)

```
GRUB_CMDLINE_LINUX="... iommu=off intel_iommu=off ..."
```

Or via grubby:

```bash
sudo grubby --update-kernel=ALL --args="iommu=off intel_iommu=off"
```

**What this does:**
- Disables Intel VT-d / DMAR entirely
- Forces kernel to honor user request despite "platform opt in"
- All PCI devices use raw, untranslated DMA
- Kernel-level `iommu_dma_protection` reads 0

**What this trades off:**
- DMA-attack protection from hot-pluggable PCI/TB devices
- VT-d-based VM PCI passthrough (if user runs VMs with passthrough)

**Acceptable for**:
personal AI/dev workstation with sealed eGPU, single user, physically secure
location, no untrusted TB devices.

**Not acceptable for**:
shared workstations, multi-tenant environments, security-sensitive deployments,
hosts running guests with PCIe passthrough.

### Combined workaround stack

After the cmdline workaround, residual failures (H16) still occur ~50% of
cold-cold-boots.
Mitigations:

1. **`iommu=off` cmdline** — eliminates H10/H14 (IOMMU)
2. **L4 helper service** (`aorus-egpu-wpr2-recovery.service`) — handles residual
   H16 + any other failure class
3. **Q-watchdog kthread** — detects dead-bus state for runtime diagnostics
4. **Lever I/J-2/N/O patches** — clean up driver state when GPU is declared lost

This combined stack is the current best practical mitigation.

### What this is NOT

This is a **mitigation**, not a fix.
The proper fix is one of:

1. **Driver-side DMA registration** in NVIDIA fork — the closed Windows driver
   works on this hardware (per Lever G WSL2 evidence) by correctly
   pre-registering DMA mappings via `iommu_map_*` calls so IOMMU translation
   works rather than fails.
   Multi-day reverse- engineering work; most upstream-correct.
2. **Kernel patch** marking the device as trusted via PCI quirk built into
   kernel.
   Faster than driver work; less elegant; non-upstreamable.
3. **Eliminate the H16 PCIe transient** at the link layer (e.g., by tighter PCIe
   tuning, TB credit configuration, or driver-side handling of brief link-down
   events).

---

## Open questions / next investigations

### Q1: Why does the platform opt-in honor `iommu=off`?

Earlier kernel docs reading suggested `dmar_force_on` (set by platform opt-in)
overrides `dmar_disabled` (set by `intel_iommu=off`).
But our test showed it actually IS overridden.
Either:
- Our reading was wrong (some specific sequence works)
- Newer kernel changed the override semantics
- Platform opt-in is not actually set on this BIOS (despite the dmesg message)

Worth investigating because it affects how we recommend cmdline workarounds in
documentation.

### Q2: What exactly is the H16 PCIe transient?

Need to instrument:
- PCIe link state transitions during GSP boot (lspci -vvv before/after)
- TB controller state (USB4 capabilities)
- Power management state of eGPU upstream port

Forensic capture:
trigger a cold-cold-boot with extra logging and capture the moment when
PMC_BOOT_0 transitions from 0x1b2000a1 to 0xffffffff and back.

### Q3: Why does Windows driver work?

Lever G WSL2 evidence shows closed Windows driver succeeds on same hardware.
Hypotheses:
- WSL2 uses VFIO passthrough (different IOMMU treatment)
- Closed driver pre-registers DMA correctly (most likely)
- Closed driver has internal retry/wait logic that masks H16 transients

Comparing the open vs closed driver's `dma_map_*` call patterns would be
illuminating.

### Q4: Can we make Q-watchdog catch H16 transients?

Q-watchdog runs every 200ms reading PMC_BOOT_0.
The H16 transient appears to last <1 second based on our [DIAG] readings.
Q-watchdog should catch it if running.
But Q-watchdog spawns at the END of probe, which may be too late for the FIRST
GSP boot attempt's transient.

### Q5: Is `iommu=off` workaround actually overriding "platform opt in"?

Our 2026-05-07 boot showed `DMAR:
IOMMU disabled` despite the prior boot showing `Intel-IOMMU force enabled due to
platform opt in`.
Need to verify:
did the `force enabled` message also appear on this boot and we missed it?
Or did the cmdline truly override it?

---

## Cross-references

- **Hypothesis ledger entries**:
  - [H10](./reliability-hypothesis-ledger.md#h10) — IOMMU policy variation
  - [H13](./reliability-hypothesis-ledger.md#h13) — WPR2 register stuck
    (symptom)
  - [H14](./reliability-hypothesis-ledger.md#h14) — first rm_init_adapter
    failure root cause
  - [H16](./reliability-hypothesis-ledger.md#h16) — PCIe transient as second
    lockdown trigger (NEW)
- **Forensic dossiers**:
  - `archive/diag-telemetry-2026-05-06-154732/` — first 4-point timeline;
    mechanism reveal
  - `archive/commit3-recovery-loop-2026-05-06-161429/` — 524 DMAR faults;
    in-driver recovery storm
  - `archive/iommu-off-test-2026-05-07-145453/` — proof IOMMU is contributing
    but not sole cause
- **Lever entries**:
  - [Lever R](./lever-catalog.md) — L4 helper (recovery)
  - [Lever M-recover](./lever-M-recover-design.md) — in-driver recovery (#62,
    #103)
  - [Lever T](./lever-catalog.md) — IOMMU disable cmdline workaround (NEW, to be
    added)
- **Tasks**:
  - #93 H10 IOMMU policy test
  - #102 H14 first-failure investigation
  - #103 patch 0020 Commit 3 hardening
  - #104 built-in kernel patch (replaces failed loadable module)
  - (NEW) H16 PCIe transient investigation
- **Memory**:
  - `project_iommu_dmar_finding_2026_05_06.md` — the major mechanism reveal
  - `project_wpr2_mechanism_2026_05_06.md` — symptom-vs-mechanism correction
