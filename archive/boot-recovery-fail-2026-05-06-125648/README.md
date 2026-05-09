# Forensic dossier — cold-boot recovery failure 2026-05-06 12:56:48

**Boot ID:** `435f2183-81aa-406e-86e1-985987c367b2`
**Captured:** 2026-05-06 13:00–13:04 (within ~7 min of failure)
**Helper version:** Tier 1 v3 + Tier 2 PARTIAL retry-budget (landed 12:48)
**Outcome:** Helper fired, ran 3 attempts, all 3 returned "WPR2-stuck" verify-fail. Exit 1.
**GPU state at capture:** nvidia bound, `rm_init_adapter` looping in conf-compute mode every ~10s

## Headline finding

**Retry-budget plumbing works correctly.** Helper detected the failure, ran 3 attempts with 5s spacing, recorded each one in the history log, exited 1.

**Recovery sequence itself failed unexpectedly.** This is the FIRST time the
8-step sequence failed when run as automated boot recovery. The previous
n=1 success at 11:08 used the same sequence. Something is different here.

## Cumulative H13 evidence

| # | Time | Boot | Mode | Outcome |
|---|---|---|---|---|
| 1 | 12:04:59 | `f6bd94db` | no-op | Healthy GPU baseline |
| 2 | 12:32:59 | `85bf9c35` | first-pass auto (single-attempt era) | FAILED |
| 3 | 12:36:42 | `85bf9c35` | manual second pass (4 min later) | **SUCCESS** |
| 4 | 12:48:04 | `85bf9c35` | no-op | Healthy GPU after Tier 2 install |
| 5 | 12:56:48 | `435f2183` (this) | retry-budget 3× | **FAILED all 3** |

Auto-recovery success rate: **1/4** (25%). Manual rerun success rate: 1/1.

## Two-stage failure mode confirmed

This boot's dmesg shows a clean phase transition:

| Phase | Window | Failure mode | Bind blocked at |
|---|---|---|---|
| A — boot init | 12:56:48 → ~12:57:35 | `_kgspBootGspRm: WPR2 already up` | GSP secure-region check |
| B — post-helper | 12:57:35 → ongoing | `confComputeConstructEngine` + `gpuSanityCheck flags=0x1` | conf-compute init / GPU sanity |

**Phase A is what the helper is designed to recover from.** Phase B is a *different*
failure mode the helper does not address. The 12:33 evidence (where manual second
pass succeeded) was actually clearing Phase B, not WPR2.

## Hypothesis: helper's verify is racing the kernel's bind retry

Step 6 (`systemctl restart aorus-5090-compute-load-nvidia.service`) returns
quickly because compute-load runs `modprobe nvidia` async. Step 8 verify
runs ~2s after step 6. The kernel's `RmInitAdapter` cycle takes ~10s.

If verify fires while bind is still in flight, `nvidia-smi` sees no GPU and
records "attempt failed" — but this is a race, not a true failure. Worse,
the failed-bind path on this hardware re-asserts WPR2 (open-driver bug:
failed bind doesn't tear down GSP secure region cleanly), which then makes
attempt N+1 see WPR2 again.

**5s sleep between attempts does not help if the verify itself is racing.**
The 12:33 manual rerun success was 4 minutes (~230s) after the failure —
plenty of settle time.

If this hypothesis is right, the fix is not more retries — it is **wait
longer in the verify phase**, or poll `nvidia-smi` for up to N seconds before
deciding fail/success.

## Active retry source at capture

`nvidia-persistenced` (PID 4997) is firing every ~10s — 48 NVRM error blocks
in the 60s window before capture. Q-watchdog kthread alive (cycles=4,
detections=0 — it cannot detect because the GPU never binds far enough for
MMIO probes to fire).

## Comparison to last successful boot

`17-boot-minus-3-nvrm-success-comparison.log` shows the 11:00 boot where
Lever R Tier 1 v3 worked end-to-end. Single-pass cleared WPR2; **no
conf-compute messages in dmesg at all**. Phase B is conditionally triggered
by something in the boot environment — not deterministic.

## File index

| File | Lines | Purpose |
|---|---|---|
| `01-dmesg-this-boot.log` | 2841 | Full kernel ring buffer this boot |
| `02-nvrm-only.log` | 459 | NVRM/nvidia-only kernel messages |
| `03-helper-journal.log` | 36 | Helper's own journalctl trace |
| `04-svc-*.log` | varies | Per-service journal extracts |
| `05-systemctl-status.log` | 126 | All aorus services state at capture |
| `06-history-log-snapshot.log` | 14 | wpr2-recoveries.log at capture time |
| `07-lspci-vvv.log` | 178 | Full lspci dump for `0000:04:00.0/.1` |
| `08-pci-config-04-00-{0,1}.{bin,hex}` | — | PCI config space dumps |
| `09-gpu-sysfs-attrs.log` | 82 | sysfs attrs (driver, reset_method, link state, …) |
| `10-qwatchdog-counters.log` | 4 | cycles=4, detections=0 |
| `11-active-retriers.log` | 41 | Process tree + systemd loop sources |
| `12-boot-history.log` | 10 | journalctl --list-boots tail |
| `13-kernel-state.log` | 12 | cmdline + uname + modinfo |
| `14-nvidia-module-params.log` | 5 | NVreg_AorusWatchdogEnable=1, IntervalMs=200 |
| `15-post-helper-dmesg.log` | 2212 | Kernel ring 12:57:35 onward |
| `16-errors-only.log` | 544 | All journalctl -p err this boot |
| `17-boot-minus-3-nvrm-success-comparison.log` | 100 | Comparison: 11:00 boot helper SUCCEEDED |
| `18-history-log-analysis.log` | 18 | Aggregated event/boot summaries |
| `19-timeline-correlated.log` | 201 | Interleaved kernel + helper events |
| `20-kernel-reset-evidence.log` | 202 | What kernel did during PCI reset/remove |
| `21-ps-snapshot.log` | 486 | Full process tree at capture |

## Decision space (for user)

1. **Run helper manually now** — test whether 12:33-pattern still holds (one more pass clears Phase B). Cheap, reproduces evidence at n=2.
2. **Stop nvidia-persistenced first** to halt the every-10s retry loop, then run helper — cleaner experimental conditions.
3. **Power-cycle eGPU** if manual rerun also fails — known-good clean state.

The dossier is comprehensive enough that any of the above can proceed without losing forensic evidence.

## Drives revision of

- Tier 1 v3 helper — needs verify-with-backoff, not just retry-budget
- Tier 2 design — kobject_uevent + per-step watchdog now more important (per-step watchdog should be **per-verify**, not per-attempt)
- H13 ledger — auto-recovery reliability is 25%, not the supported-at-n=1 picture
