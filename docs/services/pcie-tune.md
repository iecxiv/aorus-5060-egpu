# Service: aorus-egpu-pcie-tune.service (Lever H9a)

**Status:** RETIRED 2026-05-08 — was actively harmful
**Layer:** L4 (helper at `usr/local/sbin/aorus-egpu-pcie-tune`) + L5 (systemd unit)
**Lifecycle:** introduced 2026-05-05; retired 2026-05-08 (~3 days active)

## Purpose (historical)

Applied `CTV=2` (1-10ms range A2) on the TB host port (0000:00:07.0) and GPU (0000:04:00.0) via `setpci` writes to the DevCtl2 register, intended as a defensive measure pending H9a investigation outcomes. The hypothesis was that tighter PCIe Completion Timeout would help recover from runtime transients faster.

## Mechanism (historical)

`Type=oneshot RemainAfterExit=yes`. Helper script wrote `setpci -s <bdf> CAP_EXP+0x28.W=...` to update DevCtl2 bits [3:0] (Completion Timeout Value) to range A2 (1-10ms). `ExecStop=` reversed via the helper's `restore` subcommand for clean A/B testing.

## Why it was retired

**The service caused the failures it was supposed to mitigate.**

H9a investigation 2026-05-08 (matched-pair forensic comparison B4 vs B3 boots) identified this service as the **dominant cause of 100% Port A boot failures.** Mechanism:

- Tight DevCtl2 Range B (1-10ms) caused **TB-tunneled config reads to time out** during early GPU enumeration
- Driver classified the GPU as PCI-not-PCIe (because PCIe-capability config reads timed out)
- `rm_init_adapter` then failed because the driver's PCIe-aware init paths assumed PCIe, but the driver thought it was PCI
- Cascade: failed rm_init → GSP firmware sees host-side communication failure → tripped lockdown → host wedge
- This entire failure pattern was being misattributed to "H16 PCIe transient at GSP boot" until the matched-pair test isolated H9a

Disabling the service immediately restored Port A boot reliability. 11+ consecutive clean boots since.

## Configuration and tuning (historical)

| Knob | Value | Purpose |
|---|---|---|
| `BDFS` | `0000:00:07.0 0000:04:00.0` | Hardcoded BDF list (Port A only — was the bug) |
| `CTV_VALUE` | `0x2` | DevCtl2 bits [3:0] for Range B (1-10ms) |
| `CAP_EXP_OFFSET` | `0x28` | DevCtl2 register offset within PCIe Express Capability |

The hardcoded Port-A-only BDF list was itself a bug (the helper wouldn't have applied tuning on Port B even if needed); compounded the original problem by being silently broken on Port B and silently harmful on Port A.

## Retirement actions taken (2026-05-08)

1. `systemctl disable --now aorus-egpu-pcie-tune.service` ✓
2. Update memory: `project_port_a_h9a_root_cause_2026_05_08.md` documents matched-pair forensic test that isolated the service as causal
3. Update `service-retirement-roadmap.md` (RETIRED row + detail)
4. Update H16 ledger entry (PROBABLY-FALSIFIED — was H9a in disguise)
5. Binary + unit PRESERVED

## Resurrection procedure

**Resurrection is unlikely to be appropriate** — this service was actively harmful, not just unnecessary. If a future investigation identifies a real need for DevCtl2 tuning:

1. **Do NOT reuse this service as-is.** The hardcoded BDFs (Port A only) and the specific CTV value (0x2 / Range B) caused the failure mode this retirement addressed.
2. Design a new helper that:
   - Auto-detects BDFs (works on any port)
   - Uses a less aggressive CTV value (Range A1 50µs–10ms instead of Range A2 1ms–10ms; or higher ranges)
   - Empirically tested on n≥3 cold-cold-boots before deployment
3. Treat as a **new lever** with its own catalog entry, not a resurrection of H9a.

The original H9a hypothesis ledger entry should remain marked PROBABLY-FALSIFIED — its stated mechanism ("tight CTV helps recover from transients") was wrong.

## Files installed / consumed (preserved)

**Installed by `apply.sh`** (for archive purposes):
- `/etc/systemd/system/aorus-egpu-pcie-tune.service` (preserved)
- `/usr/local/sbin/aorus-egpu-pcie-tune` (preserved)

`apply.sh` should ensure this service stays disabled. Verify in apply.sh's enable block list.

**State written (historical):**
- `/var/lib/aorus-egpu/pcie-tune-original.txt` — original DevCtl2 values for restore

## Cross-references

- Matched-pair forensic dossier: `archive/<port-a-h9a-investigation-dossier>` (2026-05-08 morning)
- Memory: `project_port_a_h9a_root_cause_2026_05_08`
- H9a hypothesis (PROBABLY-FALSIFIED): [`docs/reliability-hypothesis-ledger.md`](../reliability-hypothesis-ledger.md)
- H16 link to this retirement: [`docs/reliability-hypothesis-ledger.md#h16`](../reliability-hypothesis-ledger.md#h16) (H16 was H9a in disguise)
- Service retirement roadmap: [`docs/service-retirement-roadmap.md`](../service-retirement-roadmap.md)
- Memory: `feedback_check_existing_guards_before_cmdline_experiments` — methodology lesson learned from H9a
