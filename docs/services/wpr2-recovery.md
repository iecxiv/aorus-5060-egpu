# Service: aorus-egpu-wpr2-recovery.service

**Status:** PENDING RETIREMENT — Phase 5 evidence gate (5/10 as of 2026-05-08)
**Layer:** L4 (helper at `usr/local/sbin/aorus-egpu-wpr2-recovery`) + L5 (systemd unit)
**Lifecycle since:** 2026-05-06 (Lever R Tier 1 v3 era)

## Purpose

Detects boot-time WPR2-stuck condition and executes the validated PCI `remove + rescan + reset` sequence from userspace to recover a GPU that's bound but failed GSP init. Was the **primary mitigation** for cold-cold-boot WPR2-stuck failures before Lever M-recover landed in-driver (patches 0024 + 0026 + 0027 + 0028, 2026-05-08).

Currently active as **belt-and-braces backup** during Phase 5 evidence collection. Once retirement gate met, M-recover is the sole mitigation; this L4 helper retires.

## Mechanism

`Type=oneshot RemainAfterExit=yes`, runs once per boot. Script:

1. Run `nvidia-smi -L` to test if GPU is healthy. If output matches `^GPU [0-9]+:`, exit 0 (no-op — common path).
2. Otherwise, check `dmesg` for the WPR2-stuck signature (`_kgspBootGspRm: unexpected WPR2 already up` or similar).
3. If WPR2-stuck signature absent, exit 2 (different failure class — not our problem).
4. If signature present, execute recovery sequence (with retry budget):
   - Stop persistenced + uvm-keepalive (release any held fds — required for `modprobe -r` to succeed)
   - `modprobe -r nvidia_uvm`, `modprobe -r nvidia` (unbind + remove modules)
   - `echo 1 > /sys/bus/pci/devices/0000:04:00.0/remove`
   - `echo 1 > /sys/bus/pci/rescan`
   - `echo 1 > /sys/bus/pci/devices/0000:04:00.0/reset`
   - `systemctl restart aorus-egpu-compute-load-nvidia.service` (rebinds nvidia)
   - Restart persistenced + uvm-keepalive
   - Verify `nvidia-smi -L` works → return success
   - If still failing, retry up to `MAX_ATTEMPTS=3` times
5. Log all events (start, attempt, attempt-failed, attempt-succeeded, recovery-success, recovery-failed) to `/var/lib/aorus-egpu/wpr2-recoveries.log` as ISO-timestamp CSV rows.

## Why we need it today

Belt-and-braces during the Phase 5 evidence-collection window. After H9a retirement (2026-05-08 ~11:55 AEST), GSP_LOCKDOWN events have ceased to occur in normal boots, so the L4 helper's `no-op,GPU healthy` path is what runs every time. The helper has been **de facto inactive** for 11+ consecutive boots since H9a retirement.

The L4 helper is structurally race-prone with userspace bind-retriers (per memory `project_lever_m_recover_landed_2026_05_08`); Lever M-recover is the architectural destination. Once Phase 5 evidence confirms M-recover handles the failure mode (or that the failure mode no longer reproduces), the L4 helper retires.

## Configuration and tuning

### Knobs (env vars in helper script)

| Variable | Default | Meaning |
|---|---|---|
| `MAX_ATTEMPTS` | 3 | Retry budget per recovery invocation |
| `GPU_BDF` | `0000:04:00.0` | GPU BDF for sysfs writes |
| `STATE_DIR` | `/var/lib/aorus-egpu` | Where the history log is written |
| `HISTORY_LOG` | `$STATE_DIR/wpr2-recoveries.log` | History log file path |
| `INTER_ATTEMPT_DELAY_S` | 5 | Sleep between retry attempts |

### Detection signature (in helper)

WPR2-stuck pattern matched in dmesg: `_kgspBootGspRm: unexpected WPR2 already up`. Hardcoded — change in script if NVIDIA changes the kernel log message.

### History log format

CSV: `<iso-timestamp>,<run-uuid>,<event>,<details>`. Events: `started`, `attempt-started`, `attempt-failed`, `attempt-succeeded`, `recovery-success`, `recovery-failed`, `no-op`.

## Dependencies

**After (ordering):**
- `aorus-egpu-compute-load-nvidia.service`
- `nvidia-persistenced.service`
- `aorus-egpu-uvm-keepalive.service` (RETIRED, but `After=` is harmless)

**Wants (soft):**
- `aorus-egpu-compute-load-nvidia.service` — runs even if loader failed (precisely the scenario this helper targets)

**ConditionPathExists:**
- `/sys/bus/pci/devices/0000:04:00.0`

## Lifecycle (boot / runtime / shutdown)

| Phase | Action |
|---|---|
| Boot | Runs LAST in the boot chain; either no-op or recovery sequence |
| Runtime | `Type=oneshot RemainAfterExit=yes` — stays "active (exited)" |
| Shutdown | No action |

## Verification

```bash
systemctl is-active aorus-egpu-wpr2-recovery
# active (exited)

# This boot's record (should be no-op,GPU healthy on a healthy boot)
boot_iso=$(date -Iseconds -d "@$(awk '/^btime / {print $2}' /proc/stat)")
awk -F, -v cutoff="$boot_iso" '$1 >= cutoff' /var/lib/aorus-egpu/wpr2-recoveries.log

# Tally of all events to-date
awk -F, '/^[0-9]{4}/ {print $3}' /var/lib/aorus-egpu/wpr2-recoveries.log | sort | uniq -c
```

## Architectural destination

**Lever M-recover** (in-driver state machine, patches 0024 + 0026 + 0027 + 0028 LANDED 2026-05-08). M-recover handles the same failure mode at the kernel layer with single-arbiter recovery, no userspace race condition.

## Retirement criteria

**Phase 5 retirement gate (REVISED 2026-05-08 evening):**

n≥10 consecutive cold-cold-boots where BOTH:
1. `archive/phase5-evidence/<boot-iso>.log` records verdict `M-RECOVER-NOT-FIRED` (clean boot, no recovery needed at all)
2. `/var/lib/aorus-egpu/wpr2-recoveries.log` for the same boot's ISO-timestamp records `no-op,GPU healthy`

Original criterion ("n≥10 `M-RECOVER-FIRED-OK`") is **unreachable** because WPR2-stuck no longer naturally occurs after H9a retirement.

**Status as of 2026-05-08 evening:** 5/10. Boots `2026-05-08T181259`, `184934`, `193621`, `200027`, `202314` all met both criteria.

## Retirement procedure

When 10/10 met:

1. `systemctl disable --now aorus-egpu-wpr2-recovery.service`
2. Update `service-retirement-roadmap.md` row from "Pending n≥10" to "RETIRED" with date + Phase 5 evidence pointer
3. Update `architecture.md` "How configuration enforces" section
4. Update this doc's status header to RETIRED
5. Update memory: new entry `project_wpr2_recovery_retired_<date>.md` (4th userspace service retirement)
6. Binary at `usr/local/sbin/aorus-egpu-wpr2-recovery` and unit at `etc/systemd/system/aorus-egpu-wpr2-recovery.service` PRESERVED as documented archive (per project pattern)
7. State file `/var/lib/aorus-egpu/wpr2-recoveries.log` retained as historical record

Then: also evaluate retiring `aorus-egpu-lever-m-phase5-snapshot.service` since its primary purpose (collecting evidence for this gate) is now complete.

## Resurrection procedure

If a future kernel update or hardware regression brings back WPR2-stuck failures that M-recover doesn't catch:

1. `systemctl enable --now aorus-egpu-wpr2-recovery.service`
2. Reboot — script auto-runs at boot; will be no-op if GPU is healthy
3. Watch `wpr2-recoveries.log` for new events
4. Update memory + service-retirement-roadmap with resurrection date + cause

## Files installed / consumed

**Installed by `apply.sh`:**
- `/etc/systemd/system/aorus-egpu-wpr2-recovery.service`
- `/usr/local/sbin/aorus-egpu-wpr2-recovery`

**Writes:**
- `/var/lib/aorus-egpu/wpr2-recoveries.log` (CSV history)
- `/sys/bus/pci/devices/0000:04:00.0/remove` (recovery path)
- `/sys/bus/pci/rescan` (recovery path)
- `/sys/bus/pci/devices/0000:04:00.0/reset` (recovery path)

**Reads:**
- `nvidia-smi -L` output
- `dmesg` (for WPR2-stuck signature detection)

## Cross-references

- Architectural successor: [`docs/lever-catalog.md`](../lever-catalog.md) Lever M-recover entry
- Lever R three-tier strategy: [`docs/lever-R-design.md`](../lever-R-design.md)
- Phase 5 gate definition: [`docs/service-retirement-roadmap.md`](../service-retirement-roadmap.md)
- Evidence collector: [`lever-m-phase5-snapshot.md`](./lever-m-phase5-snapshot.md)
- H15 (resolved): [`docs/reliability-hypothesis-ledger.md#h15`](../reliability-hypothesis-ledger.md#h15)
- Memory: `project_lever_m_recover_landed_2026_05_08`
