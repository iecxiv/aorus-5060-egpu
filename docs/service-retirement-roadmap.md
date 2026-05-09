# Service retirement roadmap — path to native in-driver hardening

> **Architectural philosophy** (user, 2026-05-06): "native in-driver
> hardening is indeed our goal." Every userspace workaround service
> in our stack exists because the open NVIDIA driver lacks a feature
> the closed Windows driver has. **The "perfect end state" of this
> project is zero workaround services — every recovery happens
> inside the driver.**
>
> This document catalogues each workaround service with the driver
> work that would let it retire. As driver capabilities land, the
> corresponding userspace service is removed.
>
> **Per-service deep dives:** for purpose, mechanism, configuration
> knobs, retirement criteria, retirement procedure, and resurrection
> procedure of any individual service, see [`docs/services/<name>.md`](./services/).
> This document is the cross-cutting status table; the per-service docs
> are the canonical detail.
>
> **Last updated:** 2026-05-08

## Retirement progress

| Service | Status | When |
|---|---|---|
| `aorus-egpu-link-monitor.service` | **RETIRED** ✓ | 2026-05-07 |
| `aorus-egpu-pcie-tune.service` (Lever H9a) | **RETIRED** ✓ | 2026-05-08 — caused 100% Port A boot failure; Mode B detection covered by Q-watchdog (see `project_port_a_h9a_root_cause_2026_05_08.md`) |
| `aorus-egpu-observability-watchdog.service` | Active (redesigned passive) | — |
| `aorus-egpu-bridge-link-cap.service` | Active (Gen3+bit5 cap) | — |
| `aorus-egpu-uvm-keepalive.service` | **RETIRED** ✓ | 2026-05-08 — Patch 0030 UVM-side instrumentation + n=3 single-shot probes + n=3 churn probes (6 total UVM close-path reproductions) all benign; UVM `uvm_va_space_destroy` doesn't touch GSP/WPR2/link, qualitatively different from /dev/nvidia0's close-path teardown. Binary + unit preserved as documented archive. |
| `nvidia-persistenced.service` (load-bearing role) | **RECLASSIFIED 2026-05-08** — close-path bug class empirically mitigated on current driver stack (n=3 close-path-probe runs 2026-05-08, host stable, fires=0). No longer load-bearing for stability. Remains load-bearing for **warmup latency** (~1.3s GSP-boot tax per first-open after LAST-CLOSE). Keep as performance optimization, not retire. | Architecturally optional |
| `aorus-egpu-wpr2-recovery.service` | **RETIRED** ✓ | 2026-05-09 — Phase 5 evidence gate met (10/10 clean cold-cold-boots with verdict `M-RECOVER-NOT-FIRED` AND `wpr2-recoveries.log` `no-op,GPU healthy`). Lever M-recover (in-driver, patches 0024 + 0026 + 0027 + 0028) is the sole recovery mechanism going forward. L4 helper preserved as documented archive. |
| `aorus-egpu-compute-load-nvidia.service` | Active (driver bind helper; architectural, not reliability) | — |

---

## Why this matters

The closed Windows driver works on this hardware (Lever G evidence).
It does so without a single userspace workaround service. Every
service in our Linux stack is a debt item — we should track it,
plan its retirement, and remove it when the driver is sufficient.

The retirement roadmap is the inverse of the lever catalog: the
catalog tracks driver capabilities we're ADDING; this roadmap tracks
userspace workarounds we'll be REMOVING.

---

## Active workaround services

### `nvidia-persistenced.service` (with project drop-in)

**Why it exists (original framing 2026-05-01):** Holds `/dev/nvidia0`
fds open continuously to prevent the close-path freeze (Problem 2 in
`architecture.md`). Without persistenced holding open, the second
close-of-`/dev/nvidia0` after process exit triggered a kernel-side
teardown that hard-froze the host on Blackwell over Thunderbolt.

**Why it exists (RECLASSIFIED 2026-05-08):** the close-path freeze
bug class is **empirically mitigated** on the current cumulative
driver stack — `tools/close-path-probe.sh` ran the exact "stop
persistenced, open via nvidia-smi -L, close, observe next open"
sequence with full Patch 0029 close-path DIAG instrumentation. n=3
back-to-back probes, identical outcome: the second open succeeds in
~1.3s with no host wedge, `fires=0` (Lever M-recover never had to
fire), no AER signals. Forensic dossiers in
`archive/close-path-probes/2026-05-08T1*+10-00/`. Mitigation owed to
H9a retirement + Lever T cmdline + recovery levers I/J-2/N/O +
G3-H UncMaskClear + Lever M-recover safety net (cumulative, not
single-cause).

**Persistenced is therefore NO LONGER load-bearing for stability.**
It IS load-bearing for **warmup latency**: by holding `/dev/nvidia0`
open continuously, every subsequent open is a no-op refcount bump
rather than a fresh GSP-boot. Retiring it would impose a ~1.3s
"first-open after LAST-CLOSE" tax on every consumer that opens
into a 0-baseline (e.g. `nvidia-smi` from monitoring scripts, ollama
daemon startup, ollama runners with idle gaps between, fresh
`vLLM`/`PyTorch` cuInit calls).

**Layer:** L7 (NVIDIA-shipped) consumed via L5 drop-in
(`etc/systemd/system/nvidia-persistenced.service.d/aorus-egpu.conf`)

**Retirement status:** OPTIONAL (architecturally) — KEEP (operationally).
The decision to retire is now a **performance/complexity tradeoff**, not a
stability requirement. For an idle workstation: ~1.3s tax per nvidia-smi.
For continuous CUDA workload (one long-running consumer): tax is paid
once, retirement viable. For ollama with frequent runner churn between
idle gaps: tax compounds; retirement costs measurable wall-time.

**Note:** Persistenced itself is NVIDIA's tool — vendor-recommended for
exactly this purpose. We don't retire IT; we may eventually unwire its
project-specific drop-in (`etc/systemd/system/nvidia-persistenced.service.d/aorus-egpu.conf`)
if the After= ordering with our loader becomes unnecessary, but the
service itself stays as performance optimization.

---

### `aorus-egpu-uvm-keepalive.service` — RETIRED 2026-05-08

**Why it existed:** Held `/dev/nvidia-uvm` and `/dev/nvidia-uvm-tools`
fds to prevent the UVM close-path freeze (Problem 4 in
`architecture.md`). Built 2026-05-02 after a host freeze attributed
to ollama runner churn closing `/dev/nvidia-uvm` and a delayed
unrelated reopen wedging the host.

**Layer:** L4 (helper at `usr/local/sbin/aorus-egpu-uvm-keepalive`) +
L5 (systemd unit)

**Why it retired:** Empirical evidence 2026-05-08:

1. **Patch 0030 UVM close-path instrumentation landed** — exposes
   open/close lifecycle DIAG sites (`uvm-open-entry`,
   `uvm-release-entry`, `uvm-pre-destroy`, `uvm-post-destroy`,
   `uvm-release-exit`) plus `[UVM-DIAG]` state captures via
   `aorus_lever_m_diag_dump_pdev`.
2. **n=3 single-shot probes** via `tools/uvm-close-path-probe.sh`
   (drain UVM consumers + cuda-smoke + 20s settle): identical
   outcomes — `WPR2=0x07f4a000` (UP) preserved across UVM teardown,
   link stays Gen3, no AER, M-recover fires=0. UVM teardown took
   ~74ms vs the /dev/nvidia0-side 629ms.
3. **n=3 churn probes** via `tools/uvm-churn-probe.sh` (4× rapid
   cuda-smoke + 60s idle + 1× delayed cuda-smoke — explicit
   reproduction of the 2026-05-02 freeze pattern): all 5 cuda-smoke
   invocations passed cleanly, 25 LAST-CLOSE events per probe, 10
   `pre-destroy`+`post-destroy` pairs each, identical state at every
   site, fires=0 throughout.

**Total: 6 reproductions of UVM close-path scenarios, all benign.**
The original Problem 4 hypothesis ("UVM close runs the same
destabilising teardown as /dev/nvidia0 close") was a pattern-matched
inference from Problem 2 that **does not match what UVM's close-path
actually does** on this driver build. `uvm_va_space_destroy` only
does UVM-internal cleanup (page tables, channels, mappings); it
doesn't touch GSP, WPR2, or PCIe link state.

**Retirement actions taken 2026-05-08:**
- `systemctl disable --now aorus-egpu-uvm-keepalive.service`
- `apply.sh` updated to disable on apply (was: enable) so future
  `bash apply.sh` invocations preserve the retirement
- Binary at `usr/local/sbin/aorus-egpu-uvm-keepalive` and unit at
  `etc/systemd/system/aorus-egpu-uvm-keepalive.service` PRESERVED
  as documented archive of the workaround era. Same pattern as
  `aorus-egpu-link-monitor.service` retirement 2026-05-07.

**Resurrection criterion:** if a future regression observably
reproduces the original 2026-05-02 freeze pattern (UVM-side host
wedge after CUDA process churn + delayed reopen) on the current
stack, `systemctl enable --now aorus-egpu-uvm-keepalive.service`
restores the mitigation. Patch 0030 DIAG telemetry would surface
the destabilisation that justifies resurrection.

**Cross-references:** `archive/uvm-close-path-probes/2026-05-08T19-39-07+10-00/`,
`archive/uvm-churn-probes/<3 dossiers from 2026-05-08T20:*+10-00>`,
patch `0030-Lever-M-recover-UVM-close-path-DIAG.patch`,
[H22 ledger entry](./reliability-hypothesis-ledger.md#h22),
memory `project_close_path_mitigated_2026_05_08.md`.

---

### `aorus-egpu-compute-load-nvidia.service`

**Why it exists:** Orchestrates the boot-time driver bind dance:
applies upstream PM policy, verifies BAR0/BAR1, clears `driver_override`,
calls `modprobe --ignore-install nvidia` (bypassing the
`install /bin/false` blocks in `etc/modprobe.d/`), pokes
`drivers_probe`, restores `driver_override`, pre-stages `nvidia_uvm`,
runs `nvidia-modprobe -u -c 0` to materialise UVM device files.

**Layer:** L4 (helper) + L5 (systemd unit)

**What driver work would retire it:**
- Cleaner default modprobe path that doesn't conflict with udev
  autoload (this is partly why we use `install /bin/false`)
- Driver should bind cleanly via standard udev path on this hardware
- Some of this is fundamental to the eGPU + compute-only model
  (preventing GNOME/etc from binding the GPU as a display)

**Retirement status:** ACTIVE — partially structural
**Tracked work:** Phase 6 polish (#63) — Windows feature parity
**Note:** Some functions of this service may always be needed
(compute-only enforcement). Retirement may be partial — keeping
the load-orchestration but removing the workaround pieces.

---

### `aorus-egpu-pcie-tune.service` (H9a CTV tightening)

**Why it exists:** Applies `CTV=2` (1-10ms range A2) on the TB host
port and GPU at boot to defensively reduce PCIe completion timeout.
H9a is OPEN (insufficient evidence to declare CAUSAL); kept defensive.

**Layer:** L4 (helper) + L5 (systemd unit)

**What driver work would retire it:**
- If H9a is eventually PROVEN: a small lever to set CTV=2 from
  inside `nv_pci_probe` (kernel can write DevCtl2 directly)
- If H9a is REJECTED: the service simply removes (no driver work needed)

**Retirement status:** ACTIVE — defensive
**Tracked work:** Resolution of [H9a](./reliability-hypothesis-ledger.md#h9a)
**Caveat:** Retiring this service means losing a defensive measure
that hasn't been proven harmful. Keep until H9a is RESOLVED in either
direction.

---

### `aorus-egpu-observability-watchdog.service` (NEW — Gap 1 closer)

**Why it exists:** Mode B silent freezes wedge the wrapper itself, leaving us blind to per-task / per-CPU kernel state at the moment of wedge. This independent observer detects wedge candidates (nvidia-smi unresponsive >3s + active iter's progress.csv stale >60s) and triggers SysRq dumps (`l`/`t`/`w`/`m`) that capture per-CPU backtraces, all task stacks, blocked tasks, and memory state into dmesg. The dumps survive into `journalctl -k -b -1` after reboot, giving us forensic data we previously lacked.

**Layer:** L4 (helper at `usr/local/sbin/aorus-egpu-observability-watchdog`) + L5 (systemd unit)

**What driver work would retire it:**
- Phase 4 M-recover (#62) + Phase 5 M-preserve (#56). Once in-driver recovery is complete:
  - AER wiring catches PCIe-level errors via kernel framework — visible through `journalctl -k`
  - slot_reset/resume callbacks make Mode B silent recoverable — no wedge state to observe
  - kdump catches the residual hardlockup cases — vmcore in /var/crash
  - **Lever R Tier 3 converged into M-recover** — single patch 0016 delivers both AER-runtime and probe-time-WPR2 trigger paths through the same state machine
- At that point an external observer adds little: the kernel already has full visibility, recovery happens automatically, and remaining failures produce vmcore.

**Retirement status:** ACTIVE (REDESIGNED 2026-05-07 task #108) — bridge measure pending in-driver recovery completeness
**Tracked work:** Phase 4 M-recover (#62), Phase 5 M-preserve (#56)
**Validation criterion for retirement:** in-driver recovery PROVEN at n≥3 across all known failure modes (Mode A graceful, Mode B silent, WPR2 boot-init); disable observability watchdog for n≥3 cold-cold-boots without losing forensic capture capability (kernel mechanisms suffice).

**2026-05-07 redesign (task #108):**

Original implementation polled `nvidia-smi -L` every 10s for liveness
detection. Each invocation opened/closed `/dev/nvidia0`, which on this
hardware triggers the close-path wedge bug (per Lever S #100): GPU
destabilises, link drops to Gen1, M-recover scaffold transparently
re-inits at Gen3. Net effect: a periodic ~17s recovery cycle entirely
caused by the watchdog's own polling.

Redesigned to use ONLY passive sysfs reads:
- `/sys/bus/pci/devices/<bdf>/vendor` + `device` (PCI enumeration)
- `/sys/bus/pci/devices/<bdf>/driver` (nvidia driver binding)
- `/sys/bus/pci/devices/<bdf>/aorus_lever_m_*` and `aorus_qwatchdog_*`
  (recovery-state counters)

None of these touch `/dev/nvidia*`, so they never trigger the close-path
wedge. Mode B silent freeze still detectable via "GPU unbound + active
iter progress.csv stale" combination. Validated 2026-05-07: post-redesign,
zero recovery cycles in extended idle observation; GPU stable at Gen3
internal indefinitely.

---

### `aorus-egpu-wpr2-recovery.service` — RETIRED 2026-05-09

**Why it existed:** Detected boot-time WPR2-stuck condition (failed
first `rm_init_adapter` leaving WPR2 register set, blocking driver
init) and executed the validated `remove + rescan + reset` sequence
to recover. The primary mitigation for cold-cold-boot WPR2-stuck
failures from 2026-05-06 (Lever R Tier 1 v3 era) until in-driver
recovery landed.

**Layer:** L4 (helper at `usr/local/sbin/aorus-egpu-wpr2-recovery`) +
L5 (systemd unit)

**Why it retired:** Phase 5 evidence gate met 2026-05-09:

1. **Lever M-recover Commit 3 LANDED 2026-05-08** — patches 0024 +
   0026 + 0027 + 0028 implement an in-driver recovery state machine
   via `pci_error_handlers` framework with H1 MaxAttempts gate / H2
   rate-limit / H3 kill-switch persistence / H4 smarter error_detected.
   Phase 1-4 testing PASS on landing day; production-validated via
   Q2's natural fire (cap-removed cold-boot, 2026-05-08 evening).
2. **H9a service retirement 2026-05-08** — `aorus-egpu-pcie-tune.service`
   was the dominant Port A boot-failure trigger. After retirement,
   GSP_LOCKDOWN events have ceased to occur in normal boots; WPR2-stuck
   no longer naturally happens.
3. **Phase 5 evidence gate met (10/10):** ten consecutive cold-cold-boots
   where `archive/phase5-evidence/<boot-iso>.log` records verdict
   `M-RECOVER-NOT-FIRED` AND `wpr2-recoveries.log` for the same boot is
   `no-op,GPU healthy`. The L4 helper has been dead code (always-no-op)
   for the last 10 boots.

**Retirement actions taken 2026-05-09:**
- `systemctl disable --now aorus-egpu-wpr2-recovery.service` on
  production
- `lib/install-manifest.sh` updated: moved from `EGPU_SERVICES_ACTIVE`
  to `EGPU_SERVICES_RETIRED`. apply.sh now installs the unit file but
  leaves it disabled (preserves the documented-archive pattern).
- Binary at `usr/local/sbin/aorus-egpu-wpr2-recovery` and unit at
  `etc/systemd/system/aorus-egpu-wpr2-recovery.service` PRESERVED as
  documented archive of the workaround era. Same pattern as
  `aorus-egpu-uvm-keepalive.service` and `aorus-egpu-link-monitor.service`
  retirements.

**Resurrection criterion:** if a future regression observably
reproduces WPR2-stuck on cold-cold-boot AND M-recover fails to handle
it (verifiable via Phase 5 snapshot showing `M-RECOVER-FIRED-FAIL` or
`SURRENDER` verdicts), `systemctl enable --now aorus-egpu-wpr2-recovery.service`
restores the L4 backup path. The kill-switch (`aorus-egpu-lever-m disable`)
can also force the older code path while M-recover is debugged.

**What this means architecturally:** Lever M-recover is now the sole
mitigation for the Mode A graceful failure class (post-rmInit-FAIL,
WPR2-stuck, AER NEED_RESET). The recovery surface is fully in-driver,
matching the project's "perfect end state is zero workaround services"
target. Four userspace service retirements in ~10 days (link-monitor,
pcie-tune, uvm-keepalive, wpr2-recovery); one reclassification
(persistenced as warmup-latency optimisation, not stability load-bearing).

**Cross-references:** `archive/phase5-evidence/` (10 datapoints from
2026-05-08 → 2026-05-09); `archive/cutover-2026-05-09/` (Stage C
cutover dossier including `08-reboot2-final-status.log` showing the
gate-met boot); patches `0024-Lever-M-recover-Commit3-hardening.patch`
through `0028-Lever-M-recover-attempt-count-reset-at-post-rmInit-OK.patch`;
[H15 ledger entry](./reliability-hypothesis-ledger.md#h15) (resolved);
[Lever M-recover](./lever-catalog.md#lever-m-recover) catalog entry;
memory `project_lever_m_recover_landed_2026_05_08.md`.

---

## Retirement workflow

For each service:

1. **Identify the driver gap** — what specific behavior is missing
2. **Track as a lever or hypothesis** — entry in lever-catalog.md or ledger
3. **Implement the driver capability** — patches, build, validate
4. **Side-by-side test** — run with both userspace service AND new
   driver feature; confirm driver feature works alone
5. **Disable the service** — `systemctl disable --now <svc>`,
   leave installed but stopped, n≥3 boots no regression
6. **Remove from project repo** — delete the systemd unit and helper
   files, document removal in `architecture.md` update log
7. **Update this roadmap** — move service from "active" to "retired"

---

## Retired services

(none yet — keep this section as we retire)

---

## Cross-references

- [`architecture.md`](./architecture.md) — describes the *current*
  installed config including all active services
- [`lever-catalog.md`](./lever-catalog.md) — the inverse: driver
  capabilities we're adding
- [`reliability-hypothesis-ledger.md`](./reliability-hypothesis-ledger.md) —
  open hypotheses, some of which gate service retirements
- [`stability-roadmap.md`](./stability-roadmap.md) — overall phased plan
- `feedback_native_in_driver_hardening` memory entry — the
  architectural philosophy

---

## Update log

- **2026-05-06 morning** — initial publication. Triggered by user's
  observation: "this kind of hardening logic in a perfect end state
  should all be handled within the driver itself, so it is not
  reliant on any system services." Catalogued 5 active workaround
  services and the driver work that would let each retire. Established
  the retirement workflow as the inverse of the lever catalog
  (capabilities-added vs services-removed).

---

## RETIRED: `aorus-egpu-link-monitor.service` (2026-05-07)

**Why it existed:** deployed during H17 / autonomous-downgrade investigation
to capture millisecond-resolution `LnkCtl2` / `LnkSta` deltas on the bridge
and GPU. Logged only state changes (not every poll) to
`/var/log/aorus-egpu/link-state.log`. Decoded BWMS/LABS bits to
distinguish explicit (kernel/driver-initiated) from autonomous
(hardware-initiated) bandwidth changes.

**Mission status: COMPLETE.**

| Question deployed to answer | Resolved? | How |
|---|---|---|
| What's causing the autonomous Gen3→Gen1 downgrade? | ✅ | observability-watchdog polling nvidia-smi (fixed task #108) |
| Is `Br_AER_Cor=0x1` an active error or stale state? | ✅ | stale RW1C bit (G3-H test, patch 0022) |
| Is bit 5 (HwAutoSpeedDisable) honored on this silicon? | ✅ | empirically tested negative, then positive at boot |
| Is host-side TB tunnel really Gen1? | ✅ | virtual-bridge spoofing (nvbandwidth, H18 falsified) |

**Why retired now:** all questions resolved; service was logging only
steady-state (no deltas firing post-watchdog-redesign). It has been
running for completeness without active mission.

**Retirement actions taken:**
- `systemctl stop aorus-egpu-link-monitor.service`
- `systemctl disable aorus-egpu-link-monitor.service`
- Final log archived to `archive/link-monitor-final-2026-05-07/link-state.log`
- Binary preserved at `/usr/local/sbin/aorus-egpu-link-monitor` (still
  present, just not auto-started)
- Unit file preserved at `/etc/systemd/system/aorus-egpu-link-monitor.service`
- Repo source preserved at `usr/local/sbin/` and `etc/systemd/system/`

**Resurrection criteria — when to re-enable:**

Bring the service back if a NEW investigation requires:
- Identifying which side (bridge or GPU) initiates a bandwidth change
- Capturing BWMS vs LABS bit semantics in real-time
- Sub-second-resolution PCIe link state change tracing
- Distinguishing software-initiated from hardware-autonomous transitions

**How to resurrect:**

```bash
sudo systemctl enable --now aorus-egpu-link-monitor.service
# Logs to /var/log/aorus-egpu/link-state.log
```

(No reinstall needed; binary + unit file remain in place. Disable
again with `systemctl disable --now` when investigation complete.)

**Forensic dossier preserved:**
- `archive/link-monitor-final-2026-05-07/link-state.log` — final state
  before retirement (36 lines covering investigation period)
- Cross-references in: `docs/h17-g3-gen3-investigation-2026-05-07.md`,
  `docs/tb4-tunnel-gen1-investigation.md`,
  `docs/reliability-hypothesis-ledger.md` H17 entries

**Lesson logged:** purpose-built observability services should have
explicit retirement criteria from day 1. link-monitor's mission was
forensic (find a specific failure pattern); when the pattern was
characterized + fixed elsewhere, the service became redundant. Other
"investigation tools" deployed in the future should follow the same
pattern: build, gather evidence, retire.
