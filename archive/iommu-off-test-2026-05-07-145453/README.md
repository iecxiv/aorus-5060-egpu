# Forensic dossier — `iommu=off intel_iommu=off` test boot 2026-05-07 14:54:53

**Boot ID**: per `00-meta.log`
**Cmdline tested**: `iommu=off intel_iommu=off` (replacing prior `intel_iommu=on,sm_off`)
**Module**: aorus.8 (Commits 1+2+diag, no Commit 3 action)
**Recovery kill switch**: `nvidia.NVreg_AorusLeverMRecoverEnable=0`

## Headline finding — IOMMU is a contributing cause but NOT the sole cause

```
DMAR: IOMMU disabled                          ← cmdline honored
DMAR fault count                              0  (was 48-524 prior boots)
iommu_dma_protection                          0  (was 1)
GSP_LOCKDOWN_NOTICE events                    18 (still firing!)
rm_init_adapter failures                      4
post-rmInit-OK eventually fired               at ~30s wall time
```

**IOMMU truly disabled** — confirmed by kernel message + zero DMAR
faults + iommu_dma_protection=0. **Yet GSP_LOCKDOWN_NOTICE still fired
18 times before recovery.**

This proves there's a second cause of GSP lockdown beyond IOMMU
rejection. New hypothesis: **H16 — PCIe link transient during GSP boot**.

## Smoking gun for H16

`03-diag-timeline.log` line 3:
```
post-rmInit-FAIL  bar0=0x80000000  PMC_BOOT_0=0xffffffff
                                   WPR2_ADDR_HI=0xffffffff
                                   WPR2_VAL=0xfffffff0
                                   WPR2_up=YES
```

`PMC_BOOT_0=0xffffffff` indicates the eGPU's PCIe bus reads as **dead**
(electrical disconnect) at the moment of failure. IOMMU is disabled at
this point — so this can't be IOMMU-related. The brief bus-dead state
implies a PCIe link transient during initial GSP boot.

This matches the H16 mechanism described in
`docs/iommu-gsp-lockdown-analysis.md`.

## Cross-boot comparison

| Boot | DMAR faults | retries | total time |
|---|---|---|---|
| 16:14 (Commit 3 active, default IOMMU) | 524 | 21 | never |
| 16:50 (sm-on default) | 48 | 7 | ~48s |
| 17:04 (sm-off) | 174 | 27 | never (this boot) |
| **THIS (14:54, iommu=off)** | **0** | **4** | **~30s** ★ |

`iommu=off` produces fastest, cleanest recovery. Even with IOMMU-class
failures eliminated, residual H16-class failures still cause initial
rm_init_adapter failures.

## Files

| File | Lines | Purpose |
|---|---|---|
| `00-meta.log` | 5 | Boot ID, cmdline, uptime, iommu state |
| `01-full-dmesg.log` | 1825 | Complete kernel ring buffer this boot |
| `02-aorus-iommu-events.log` | 108 | NVRM + AORUS + DMAR + IOMMU lines |
| `03-diag-timeline.log` | 18 | Lever M-recover [DIAG] readings (incl. H16 smoking gun) |
| `04-iommu-state.log` | 3 | Kernel IOMMU state messages |
| `05-gsp-lockdown-rpc.log` | 26 | GSP_LOCKDOWN_NOTICE + RPC sanity check failures |

## Implications

- **Production cmdline workaround (Lever T)** validated as suitable
  for personal-workstation threat model
- **IOMMU work (#104, kernel patch)** still relevant for production
  systems that can't use `iommu=off`
- **H16 investigation** added as new branch — PCIe transient
  characterisation needed
- **Commit 3 hardening (#103)** more justified than ever — recovery
  layer is needed for residual failures even with prevention partially
  in place

## Cross-references

- `docs/iommu-gsp-lockdown-analysis.md` — canonical analysis
- `docs/reliability-hypothesis-ledger.md` — H10 (PROVEN partial), H14
  (multi-cause), H16 (NEW)
- `docs/lever-catalog.md` — Lever T (cmdline workaround entry)
- Prior dossiers:
  - `archive/diag-telemetry-2026-05-06-154732/`
  - `archive/commit3-recovery-loop-2026-05-06-161429/`
