# Service: aorus-egpu-observability-watchdog.service

**Status:** **RETIRED 2026-05-09** — Mode B detection covered by in-driver Lever
Q-watchdog (patches 0010-0015); n=5 cold-cold-boots all `CLEAN-BOOT` verdict;
userspace observability redundant.
Service preserved on disk as documented archive; resurrect via `systemctl enable
--now` if a future regression bypasses Q-watchdog.
**Layer:** L4 (helper at `usr/local/sbin/aorus-egpu-observability-watchdog`) +
L5 (systemd unit) — both PRESERVED in repo + on disk.
**Lifecycle:** Phase B3 era → redesigned 2026-05-07 (passive sysfs-only) →
retired 2026-05-09.

## Purpose (historical)

Independent observer that detected Mode B silent-freeze conditions (where the
inference wrapper itself wedges) and triggered SysRq dumps to capture per-task
kernel state into `dmesg` **before the host reboots or hangs completely.**
Forensic capture only — recovery was the responsibility of the wrapper or Lever
M-recover.

## Resurrection (if Mode B detection regresses)

```bash
sudo systemctl enable --now aorus-egpu-observability-watchdog.service
```

Resurrection criteria:
a future regression observably reproduces a Mode B silent freeze that Lever
Q-watchdog did NOT catch.
Signal:
host hang during CUDA workload with no `Q-watchdog detected` event in dmesg.
The userspace watchdog gives a second-opinion observer for that case.

See
[`docs/service-retirement-roadmap.md`](../service-retirement-roadmap.md#aorus-egpu-observability-watchdogservice--retired-2026-05-09)
for the full retirement record + n=5 evidence table.

## Mechanism

Runs continuously as `Type=simple` long-lived service.
Polls every ~10s:

1. **Passive liveness:** GPU enumerated (vendor 10de:2b85 in
   `/sys/bus/pci/devices/*`)?
   Driver bound (driver symlink → `nvidia`)?
   M-recover counters readable?
2. **Wedge declaration:** if liveness fails for `>detect_threshold_s` AND any
   active inference iteration has stale `progress.csv` (>`progress_threshold_s`
   since last write).
3. **On wedge:** log to journal at err level, fire `echo l/t/w/m >
   /proc/sysrq-trigger` to dump backtraces / task stacks / blocked tasks /
   memory state into dmesg, then sleep extended period to avoid re-firing.

The dumps survive reboot via `journalctl -k -b -1`, providing forensic data for
Mode B incidents that would otherwise be invisible.

## Why we need it today

Mode B silent freezes wedge the wrapper, leaving the wrapper unable to capture
diagnostic state.
Without an independent observer, the only forensic data available post-reboot is
whatever made it to disk before the wedge — which is typically nothing.

The 2026-05-07 redesign was critical:
the **original design ran `nvidia-smi -L` every 10s**, which open()/close()s
`/dev/nvidia0`.
The close-path wedge (per memory `feedback_avoid_nvidia_smi_for_state_checks`)
destabilised the GPU/PCIe link, triggering ~17s recovery cycles that masked
themselves but defeated stable Gen3 operation.
The watchdog's own polling was creating the failures it was supposed to detect.

The current passive-only design observes via sysfs reads only — none of which
touch `/dev/nvidia*` — so the watchdog cannot trigger the failure mode it
watches for.

## Configuration and tuning

### Knobs (env vars / hardcoded thresholds in script)

| Variable | Default | Meaning |
|---|---|---|
| `detect_threshold_s` | 30 | How long passive liveness must be failing before declaring a wedge candidate |
| `progress_threshold_s` | 60 | How stale `progress.csv` must be (in active iter) to corroborate wedge |
| `poll_interval_s` | 10 | How often to check |
| `post_dump_sleep_s` | 600 | Sleep after firing SysRq to avoid re-fire |

### sysfs files read

- `/sys/bus/pci/devices/0000:04:00.0/{vendor,device}` (auto-detect)
- `/sys/bus/pci/devices/0000:04:00.0/driver` (binding check)
- `/sys/bus/pci/devices/0000:04:00.0/aorus_lever_m_*` (M-recover counters)
- `/sys/bus/pci/devices/0000:04:00.0/aorus_qwatchdog_*` (Q-watchdog counters)

### sysfs files written (at SysRq fire time)

- `/proc/sysrq-trigger` ← `l`, `t`, `w`, `m` (each as a separate write)

### Resource caps (in unit file)

- `Nice=10`, `CPUQuota=10%` — limits blast radius if helper misbehaves

## Dependencies

**Wants (soft dependency):**
- `aorus-egpu-compute-load-nvidia.service` — useful even if loader didn't run

**No `Requires=` or hard ordering** — designed to be independent.

## Lifecycle (boot / runtime / shutdown)

| Phase | Action |
|---|---|
| Boot | Starts at multi-user.target time; begins polling loop |
| Runtime | Continuous polling at `poll_interval_s`; fires SysRq on wedge detection |
| Shutdown | Killed by systemd; no cleanup needed |
| Crash | `Restart=on-failure RestartSec=5` |

## Verification

```bash
systemctl is-active aorus-egpu-observability-watchdog
# active (running)

journalctl -u aorus-egpu-observability-watchdog -b 0 | tail -10
# Should show periodic "passive liveness OK" markers, no wedge declarations
```

## Architectural destination

The watchdog provides **forensic capture** that the kernel itself doesn't.
The architectural destination is two-fold:

1. **kdump** for the residual hardlockup cases (panic → vmcore in `/var/crash`)
2. **In-driver recovery** (Lever M-recover + future M-preserve) such that wedge
   candidates become recoverable rather than fatal — at which point external
   SysRq capture adds little beyond what the kernel logs natively

When both are in place, this watchdog is dead code.

## Retirement criteria

This service can retire when:

1. Lever M-recover PROVEN at n≥10 across all known failure modes (Mode A
   graceful, Mode B silent, WPR2 boot-init) — partially met by current Phase 5
   evidence
2. M-preserve patch landed (close-path soft teardown) — eliminates the residual
   close-path-as-Mode-B class
3. kdump configured + tested for residual hardlockups
4. n≥3 cold-cold-boots with this service disabled, no missed forensic captures
   relative to current behaviour

## Retirement procedure

1. `systemctl disable --now aorus-egpu-observability-watchdog`
2. Cold-cold-boot
3. Run extended workload (`tools/uvm-churn-probe.sh` n=3, `loop-with-flr.sh
   ITERATIONS=10`)
4. Verify Phase 5 snapshots remain clean; no missed Mode B events relative to
   historical baseline
5. Retain binary + unit per project pattern (`enabled=disabled` in systemd)

## Resurrection procedure

If a wedge slips through M-recover + kdump:
1. `systemctl enable --now aorus-egpu-observability-watchdog`
2. Document the wedge case in the hypothesis ledger
3. Update retirement criteria to require coverage of the new case before
   re-retirement

## Files installed / consumed

**Installed by `apply.sh`:**
- `/etc/systemd/system/aorus-egpu-observability-watchdog.service`
- `/usr/local/sbin/aorus-egpu-observability-watchdog`

**Reads:** sysfs (passive only) **Writes:** `/proc/sysrq-trigger` (only on wedge
detection)

## Cross-references

- 2026-05-07 redesign rationale:
  task #108 / project memory
- Memory:
  `feedback_avoid_nvidia_smi_for_state_checks` (the original close-path-trigger
  discovery that drove the redesign)
- Service retirement roadmap:
  [`docs/service-retirement-roadmap.md`](../service-retirement-roadmap.md)
