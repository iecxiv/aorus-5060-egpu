# Forensic dossier — Lever M-recover diagnostic telemetry 2026-05-06 15:47:32

**Boot ID:** `7a1c0441-7237-4d1a-9c13-1ce124a118a2`
**Captured:** 2026-05-06 15:57 (within ~10 min of boot)
**Patch version:** 595.71.05-aorus.8 (binary; modinfo shows aorus.5 due to version.h cache)
**Diagnostic:** Patch 0018 — 4-point lifecycle telemetry of NV_PMC_BOOT_0 and NV_HUBMMU_PRI_MMU_WPR2_ADDR_HI

## Headline finding — falsifies original Commit 2 hypothesis

**WPR2 is NOT stuck across boots.** It transitions from clear (0) to set (0x07f4a000) **during** the first failed `rm_init_adapter` call. Subsequent retries see WPR2 already up and fail with `_kgspBootGspRm: unexpected WPR2 already up`.

`0x07f4a000` is the **normal** WPR2 value when GSP boots successfully (validated by `post-rmInit-OK` reading). It's not a "stuck" indicator on its own — non-zero alone is normal. The stuck condition is "WPR2 set but GSP isn't running" — a state mismatch from a failed first init.

## Conclusive timeline (first failure cycle, abbreviated)

```
15:47:32 probe-end          PMC=0x1b2000a1 WPR2=0          up=no   ← cold-boot, register clean
15:47:33 startdev-entry     PMC=0x1b2000a1 WPR2=0          up=no   ← /dev/nvidia0 opened
15:47:33 pre-rmInit         PMC=0x1b2000a1 WPR2=0          up=no   ← still clean immediately before rm_init_adapter
15:47:34 post-rmInit-FAIL   PMC=0x00000000 WPR2=0x07f4a000 up=YES  ← FAILED, WPR2 NOW SET, PMC briefly zero
15:47:34 startdev-entry     PMC=0x1b2000a1 WPR2=0x07f4a000 up=YES  ← retry; WPR2 stays set
15:47:34 pre-rmInit         PMC=0x1b2000a1 WPR2=0x07f4a000 up=YES  ← about to fail-fast
15:47:34 post-rmInit-FAIL   PMC=0x1b2000a1 WPR2=0x07f4a000 up=YES  ← "WPR2 already up" message fires
... (multiple persistenced retries, all fail with WPR2=0x07f4a000) ...
15:48:21 startdev-entry     PMC=0x1b2000a1 WPR2=0          up=no   ← L4 helper ran, cleared WPR2 via PCI reset
15:48:22 post-rmInit-OK     PMC=0x1b2000a1 WPR2=0x07f4a000 up=YES  ← rm_init_adapter SUCCEEDS, WPR2=normal-running value
```

## Three falsified premises

| Premise (assumed in design before today) | Reality (per diagnostic) |
|---|---|
| WPR2 is stuck from previous boot cycle | False — WPR2=0 at cold-boot probe AND pre-rmInit |
| Probe-time MMIO check at BAR0+0x88a828 detects stuck condition | False — register is clean at probe; never fires |
| WPR2 ≠ 0 means stuck | False — `0x07f4a000` is the normal running value; "stuck" is a state-mismatch |

## Implication for Commit 3

**Trigger location moved**: post-rmInit-FAIL with WPR2 ≠ 0, NOT probe-end.
**Detection criterion sharpened**: not "is WPR2 non-zero?" but "is WPR2 non-zero AFTER rm_init_adapter just failed?"
**Recovery action unchanged**: PCI bus reset clears WPR2, next attempt succeeds.

## Open question (deferred)

**Why does the FIRST `rm_init_adapter` call fail?** The PMC_BOOT_0 reads as `0x00000000` immediately after the first failure (vs `0x1b2000a1` everywhere else) — suggests a transient bus state during initial GSP boot. This is the *root cause* of the WPR2-stuck mechanism. Solving it would prevent the cycle entirely (preventive lever) vs Commit 3 which is reactive (recovery lever).

Tracked as new sub-hypothesis in `docs/reliability-hypothesis-ledger.md` (next update).

## Files

| File | Lines | Content |
|---|---|---|
| `00-capture-meta.log` | 4 | Boot ID, timestamp, module file info |
| `01-diag-timeline.log` | 28 | All `[DIAG]` lines from this boot |
| `02-nvrm-full.log` | 147 | Full NVRM/AORUS dmesg this boot |
| `03-wpr2-context.log` | 55 | WPR2-specific kernel messages + rm_init_adapter context |
| `04-modinfo.log` | small | Module + Lever M params at capture time |
