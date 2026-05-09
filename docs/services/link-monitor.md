# Service: aorus-egpu-link-monitor.service

**Status:** RETIRED 2026-05-07 — first userspace service retirement
**Layer:** L4 (helper at `usr/local/sbin/aorus-egpu-link-monitor`) + L5 (systemd unit)
**Lifecycle:** introduced earlier (Mode B forensic era); retired 2026-05-07

## Purpose (historical)

Independent observer that polled PCIe link state during workloads to detect Mode B silent freeze conditions where the link drops mid-workload. Forensic observability: captured link state into a CSV for post-mortem analysis of host wedges.

## Mechanism (historical)

`Type=simple` long-lived service. Polled `/sys/bus/pci/devices/0000:04:00.0/...` link-status registers periodically and wrote rows to a state CSV. On link state change (down/degraded), logged at error level into journal.

## Why it was retired

**Forensic mission complete.** The Mode B silent-freeze investigation that justified the link monitor converged: the failure mode was characterised, the mitigations (Lever Q-watchdog + Lever M-recover + H9a retirement + Lever T cmdline) landed, and Mode B silent freezes have not occurred in production since these mitigations were active.

The monitor's ongoing forensic value diminished because:
- Q-watchdog (in-driver) catches Mode B more reliably and from kernel context
- The DIAG telemetry in patches 0018/0020/0023 captures link state at all relevant lifecycle points
- The replacement role (general observability) was taken over by `aorus-egpu-observability-watchdog.service` (passive sysfs polling)

**Pattern lesson learned:** purpose-built observability services should have explicit retirement criteria from day one. Without those criteria, "it's still useful sometimes" can keep dead code in the stack indefinitely. The link-monitor retirement was the project's first explicit application of "did the mission converge? if yes, retire."

## Configuration and tuning (historical)

| Knob | Default | Purpose |
|---|---|---|
| `POLL_INTERVAL_S` | 1 | How often to read link state |
| `LOG_PATH` | `/var/log/aorus-link-state.csv` | Where to write the rolling CSV |

## Retirement actions taken (2026-05-07)

1. `systemctl disable --now aorus-egpu-link-monitor.service` ✓
2. Update memory: `project_link_monitor_retired_2026_05_07.md`
3. Update `service-retirement-roadmap.md` (first RETIRED row in the table)
4. Binary + unit PRESERVED

## Resurrection procedure

If a future investigation needs continuous link-state CSV capture (e.g., a new Mode B reproduction that requires fine-grained timing):

1. `systemctl enable --now aorus-egpu-link-monitor.service`
2. Verify CSV is being written: `tail -f /var/log/aorus-link-state.csv`
3. Document the resurrection cause in the hypothesis ledger
4. Consider whether the broader `observability-watchdog` service can be extended to cover the new need instead — that's the cleaner forward path

## Files installed / consumed (preserved)

**Installed by `apply.sh`:**
- `/etc/systemd/system/aorus-egpu-link-monitor.service`
- `/usr/local/sbin/aorus-egpu-link-monitor`

**State written (historical):**
- `/var/log/aorus-link-state.csv`

## Cross-references

- Memory: `project_link_monitor_retired_2026_05_07`
- Successor (general passive observability): [`observability-watchdog.md`](./observability-watchdog.md)
- Service retirement roadmap: [`docs/service-retirement-roadmap.md`](../service-retirement-roadmap.md)
- Pattern lesson (retirement criteria from day one): memory `feedback_native_in_driver_hardening`
