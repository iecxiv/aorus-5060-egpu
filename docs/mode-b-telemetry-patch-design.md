# Mode B telemetry scaffolding — patch design

**Patch:** `patches/0023-mode-b-telemetry-S1-S2-S3.patch` — **LANDED 2026-05-08**
**Scope:** S1 (trigger-event AER capture) + S2 (expanded DIAG sites) + S3 (Q-watchdog persistent detection state)
**Driver:** open NVIDIA driver (NVIDIA-Linux-x86_64-595.71.05-aorus.3 fork)
**Sovereign layer:** L1 (in-driver)
**Status:** Built + installed. ~165 LoC actual (487 patch lines including context). Next test: reboot to verify [DIAG-AER2] fires + sysfs files visible.

## Problem

Mode B (silent freeze) currently has these observable signals:
- Q-watchdog `cycles`/`detections` counters in sysfs (high-level — "we caught one")
- Lever M `[DIAG]` lines at 4 named sites with GPU + Bridge AER

Missing for investigating "why doesn't AER fire on TB-tunneled Mode B":
- Root port AER state at any moment
- DPC (Downstream Port Containment) state — DPC may be intercepting/swallowing errors silently
- AER masking state at moment of detection (UEMsk/CEMsk — error sources may be masked)
- AER state at the **exact moment** Q-watchdog or error_handler fires

## Three additions

### S1 — Trigger-event AER capture

**Goal:** When Mode B is detected (Q-watchdog OR error_handler), atomically dump full AER + DPC + link state across the PCI hierarchy in one printk block.

**Mechanism:**

New helper in `kernel-open/nvidia/nv-aorus-aer-dump.c`:

```c
void aorus_dump_full_aer_state(struct pci_dev *gpu_pdev, const char *trigger);
```

Walks: `gpu_pdev → pci_upstream_bridge(gpu_pdev) → pci_upstream_bridge(bridge)` (typically GPU → AORUS bridge → host root port). For each, reads:

| Register | Source | Purpose |
|---|---|---|
| `LnkSta` | PCIe Express cap | Current speed/width/active |
| `LnkSta2` | PCIe Express cap | EqualizationComplete / Phase bits |
| `DevSta` | PCIe Express cap | CorrErr+ / NonFatalErr+ / FatalErr+ stickies |
| `UESta`, `UEMsk`, `UESvrt` | AER ext cap | Uncorrectable error state + mask + severity |
| `CESta`, `CEMsk` | AER ext cap | Correctable error state + mask |
| `HdrLog` | AER ext cap | First TLP header captured (4 dwords) |
| `RootCmd`, `RootSta`, `ErrorSrc` | AER ext cap (root only) | Error reporting enables, received error msgs |
| `DPC Status`, `Trigger`, `ErrSrcID` | DPC ext cap | Whether DPC fired and why |

Plus: Q-watchdog cycles + last `PMC_BOOT_0` value + workload context (current task pid + comm).

Output format:
```
NVRM: AORUS Mode-B Trigger [event=qwatchdog-detect|error-handler]:
  GPU(04:00.0)
    LnkSta=0x1043(Gen3 x4 Active=N) LnkSta2=0x... DevSta=0x...
    AER UESta=0x... UEMsk=0x... UESvrt=0x... CESta=0x... CEMsk=0x...
    AER HdrLog=........_........_........_........
  Bridge(03:00.0) [pci_upstream_bridge of GPU]
    LnkSta=0x7043(Gen3 x4 Active=Y) DevSta=0x...
    AER UESta=0x... UEMsk=0x... CESta=0x... CEMsk=0x...
  RootPort(00:07.0) [pci_upstream_bridge of bridge]
    LnkSta=0x... DevSta=0x... RootCmd=0x... RootSta=0x... ErrorSrc=0x...
    AER UESta=0x... UEMsk=0x... CESta=0x... CEMsk=0x...
    DPC: not present | Status=0x... Trigger=0x... ErrSrcID=0x...
  Q-wd: cycles=XXXXX detections=Y last_pmc_boot_0=0x...
  Context: pid=XXX comm=... in_irq=N in_softirq=N
```

**Callsites:**
1. In `aorus_qwatchdog_thread()` (0014) immediately after `qw->detections++`:
   ```c
   aorus_dump_full_aer_state(nvl->pci_dev, "qwatchdog-detect");
   ```
2. In `nv_pci_error_detected()` callback (0007/0016) at top of function:
   ```c
   aorus_dump_full_aer_state(pci_dev, "error-handler");
   ```

**Cost / perturbation:** Each callsite reads ~20 registers via setpci-equivalent config-space reads (~50us each = ~1ms total). Fires only on detection events (not continuously). Per `feedback_observability_perturbs_bug`: reactive observability is preferred over active. This is reactive — qualifies.

**LoC estimate:** ~80 lines C (helper) + 5 lines for 2 callsites = ~85 LoC.

### S2 — Expanded Lever M [DIAG] sites

**Goal:** Extend existing DIAG emission at 4 named sites (probe-end, startdev-entry, pre-rmInit, post-rmInit) to include root port AER + DPC + AER masks.

**Mechanism:**

Modify the DIAG emit function in patch 0018 (and downstream patches that extended it). Currently emits:
```
[DIAG]: site=X bar0=... PMC_BOOT_0=... WPR2=... GPU_LnkSta=... Br_LnkSta=... GPU_AER_Unc=... Cor=... Br_AER_Unc=... Cor=...
[DIAG-AER]: site=X GPU_AER_UncMsk=... CapCtl=... HdrLog=... FirstErrPtr=...
```

Extend to:
```
[DIAG]: site=X (existing fields)
[DIAG-AER]: site=X (existing) + Br_AER_UncMsk=... Br_AER_CorMsk=... Root_LnkSta=... Root_DevSta=... Root_AER_UESta=... Root_AER_UEMsk=... Root_AER_CESta=... Root_AER_CEMsk=... Root_RootCmd=... Root_RootSta=... DPC: present|absent (if present: Status=... Trigger=...)
```

**Callsites:** Existing 4 sites already wired up. Just expand the format string + register reads.

**Cost / perturbation:** Adds ~6 register reads per DIAG site. DIAG fires once per site per rmInit attempt — a few times per boot. Negligible.

**LoC estimate:** ~30 LoC modification to existing function.

### S3 — Q-watchdog persistent detection state in sysfs

**Goal:** Capture last-detection metadata persistently in sysfs so post-boot analysis doesn't need kernel log scraping.

**Mechanism:**

Extend `struct aorus_qwatchdog` (defined in 0014) with new fields:
```c
struct aorus_qwatchdog {
    /* existing: thread, cycles, detections */
    /* NEW: */
    u64 last_detection_jiffies;
    u32 last_pmc_boot_0;
    /* AER snapshot at last detection (compact) */
    u32 last_gpu_aer_uesta;
    u32 last_gpu_aer_cesta;
    u32 last_br_aer_uesta;
    u32 last_br_aer_cesta;
    u32 last_root_aer_uesta;
    u32 last_root_aer_cesta;
    u32 last_root_rootsta;
    u32 last_dpc_status;
};
```

Populate in `aorus_qwatchdog_thread()` immediately after detection. Expose via new sysfs:
- `aorus_qwatchdog_last_detection_jiffies` (read-only u64)
- `aorus_qwatchdog_last_pmc_boot_0` (read-only u32 hex)
- `aorus_qwatchdog_last_aer_summary` (read-only multi-line text)

Pattern matches existing 0015 sysfs entries.

**Cost / perturbation:** Zero between detections (memory-only writes when one fires).

**LoC estimate:** ~50 LoC C.

## Total scope

| Component | LoC | Files touched |
|---|---|---|
| S1 helper + 2 callsites | ~85 | new `nv-aorus-aer-dump.c`, `nv-qwatchdog.c`, `nv-pci.c` |
| S2 DIAG expansion | ~30 | `nv-pci.c` (or wherever `aorus_diag_emit()` lives) |
| S3 sysfs + state | ~50 | `nv-qwatchdog.c`, `nv-qwatchdog-sysfs.c` |
| **Total** | **~165** | **3-4 files** |

## Patch numbering

`0023-mode-b-telemetry-S1-S2-S3.patch` (or split into 0023/0024/0025 if user prefers). Single patch is simpler for testing + revert.

## Test plan (post-build)

1. **Build:** DKMS rebuild of `nvidia.ko`, boot with new module
2. **Smoke test on Port B (success path):**
   - Trigger rm_init via `/dev/nvidia0` open
   - Verify expanded DIAG sites emit root-port + DPC + mask info
   - Verify Q-watchdog continues to run with new state fields populated to zero
3. **Stress test for S1 trigger:** Cannot deliberately reproduce Mode B without breaking the system. Wait for natural occurrence or simulate via `pcie_simulate_event()` if available.
4. **Regression test on Port A:** With H9a still retired, confirm Port A boot still succeeds (no regression from new telemetry code).
5. **Cross-reference with state-capture:** Compare new DIAG output against state-capture's existing AER captures — confirm consistency.

## What this patch does NOT do

- **Does not** address Q-watchdog idle awareness (deferred to Idle-A telemetry-only later)
- **Does not** address task #103 (Lever M-recover Commit 3 hardening — MaxAttempts + rate-limit + kill-switch + smarter error_handler) — separate concern, separate patch
- **Does not** modify Q-watchdog polling rate or behavior
- **Does not** add active probing (all observability is reactive/event-driven)

## Upstream readiness

Per `feedback_no_premature_upstream_filing.md`: NOT to be filed upstream until empirically validated. Validation criteria:
- ≥1 captured Mode B event with full S1 dump showing what AER state actually was at detection
- ≥3 boots without regression on Port A or Port B
- Known: helper functions are NVIDIA-internal style; if upstream-able, would ship as part of NVIDIA driver release, not as kernel patch

---

## Build notes (2026-05-08)

### Compile error encountered + fix

First build attempt failed with:
```
nv-lever-m-recover.c:293:6: error: conflicting types for 'aorus_dump_aer_trigger_event';
  have 'void(struct pci_dev *, const char *, struct aorus_qwatchdog_aer_snapshot *)'
note: previous declaration of 'aorus_dump_aer_trigger_event' with type
  'void(struct pci_dev *, const char *, struct aorus_qwatchdog_aer_snapshot *)'
```

GCC flagged identical-looking signatures as conflicting. Root cause: the
header file's forward declaration `struct aorus_qwatchdog_aer_snapshot;`
was ambiguous in some include orderings — gcc treated it as a type that
existed in the .h's local scope vs the full definition in nv-qwatchdog.h.

**Fix:** in `nv-lever-m-recover.h`, replace the inline forward decl with
explicit forward decls at file scope, BEFORE the prototype:

```c
struct nv_linux_state_s;
typedef struct nv_linux_state_s nv_linux_state_t;
struct pci_dev;
struct aorus_qwatchdog_aer_snapshot;  /* full def in nv-qwatchdog.h */
```

This forward-declares both `pci_dev` (which the prototype uses) and the
snapshot struct, at file scope where any later inclusion of the full
definition will be compatible.

### Verified outputs

`nm` on built nvidia.ko shows all expected symbols:
- `T aorus_dump_aer_trigger_event` (S1)
- `t aorus_qwatchdog_last_detection_jiffies_show` (S3)
- `t aorus_qwatchdog_last_pmc_boot_0_show` (S3)
- `t aorus_qwatchdog_last_aer_summary_show` (S3)
- `t aorus_read_aer_full.constprop.0` (helper)
- `t aorus_read_dpc_state.constprop.0` (helper)
- `d dev_attr_aorus_qwatchdog_last_*` (S3 device attrs × 3)

### Lifetime + permanence

| Component | Permanent? |
|---|---|
| S1 helper `aorus_dump_aer_trigger_event` | **Permanent** — reactive, zero idle cost; canonical "dump AER at fault time" function |
| S2 [DIAG-AER2] expanded sites | **Transitional** — gate behind `NVreg_AorusLeverMDiagEnable=0` default-off when Lever M-recover Commit 3 lands (#103) |
| S3 sysfs persistent state | **Tied to Q-watchdog lifetime** — retires when Q-watchdog retires (when AER-on-TB fix lands) |

### Tooling integration (T1.7, 2026-05-08)

`tools/state-capture/state-capture.sh` extended with section 124 to read
`aorus_qwatchdog_last_*` and `aorus_lever_m_*` sysfs counters. Future
state dossiers automatically include the new telemetry surfaces.

`tools/event-capture/hypotheses/mode-b-aer-silent.sh` added — fires when
the S1 trigger-event dump shows AER state all zero, confirming the
"AER silent" failure mode that motivated this patch.

### Cross-references

- Patch file: `patches/0023-mode-b-telemetry-S1-S2-S3.patch` (487 lines)
- Driver source modified: `kernel-open/nvidia/{nv-pci.c, nv-qwatchdog.{c,h}, nv-lever-m-recover.{c,h}}`
- Memory `feedback_observability_perturbs_bug.md`: validated — all telemetry is reactive, no continuous probing added
- Memory `feedback_targeted_comprehensive_patches.md`: shipped as ONE complete patch series, not incremental
