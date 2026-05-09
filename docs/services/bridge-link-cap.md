# Service: aorus-egpu-bridge-link-cap.service

**Status:** ACTIVE — load-bearing for boot reliability
**Layer:** L4 (helper at `usr/local/sbin/aorus-egpu-bridge-link-cap`) + L5 (systemd unit)
**Lifecycle since:** 2026-05-07 (Lever H17 / G3-E)

## Purpose

Caps the upstream Thunderbolt-switch downstream port (the eGPU's parent PCIe bridge) at PCIe Gen3 with the Hardware Autonomous Speed Disable bit set, **before nvidia.ko binds**. This eliminates link-speed renegotiation during the GSP DMA setup window — the empirically-confirmed trigger for `GSP_LOCKDOWN_NOTICE` cascades on this hardware.

Without this cap, the bridge defaults to Gen4-capable, the link tries to autonomously shift between Gen3↔Gen4 during early GSP boot, GSP firmware sees host-link-loss-during-boot, trips its lockdown, and `rm_init_adapter` fails.

## Mechanism

The service runs once at boot, executing `aorus-egpu-bridge-link-cap apply`:

1. **Auto-detect** the AORUS GPU's parent bridge by walking sysfs from any device with vendor 0x10de + device 0x2b85 (RTX 5090) up to its immediate PCI parent. Works on either NUC TB4 port (BDF differs: `0000:03:00.0` on Port A, `0000:2d:00.0` on Port B). Override via `BRIDGE=` env var.
2. **Read** the bridge's PCIe Express Capability `LnkCtl2` register (offset 0x30 from PCIe cap base).
3. **Modify** in-place:
   - Bits [3:0] (Target Link Speed) → `0x3` (Gen3, 8 GT/s)
   - Bit 5 (Hardware Autonomous Speed Disable) → `1` (pin link at target; no autonomous shifts)
   - Bit 6 (Selectable De-emphasis) → preserve original
   - All other bits → preserve
4. **Write back** via `setpci`.
5. **Trigger Retrain Link** via `LnkCtl` bit 5 — without this, the kernel/bridge re-syncs `LnkCtl2` back to the active speed and the new target doesn't take effect.
6. Save the original `LnkCtl2` value to `/var/lib/aorus-egpu/bridge-link-cap.original` for clean restore on `ExecStop=`.

`ExecStop=aorus-egpu-bridge-link-cap restore` reverts the register on service stop (used in A/B testing; does not run on normal boot/shutdown because `RemainAfterExit=yes`).

### What actually protects the system (corrected understanding 2026-05-08 evening)

The original framing said "cap link at Gen3". Empirical investigation 2026-05-08 evening clarified the actual mechanism on this hardware:

- **`LnkCtl2 Target Link Speed` is not strictly enforced on this hardware.** PCIe spec calls it an "upper bound" but on this Intel TB controller + AORUS hub topology, the NVIDIA driver/firmware does software-driven retrains that exceed the Target. Empirically: with `Target=Gen1` (LnkCtl2=`0x0061`) + workload, the link retrains to Gen3 (LnkSta=`0x7043`) and back to Gen1 when idle. The Target is more "preferred initial retrain speed" than "maximum allowed".
- **Bit 5 (Hardware Autonomous Speed Disable) is the load-bearing setting.** It disables *hardware-initiated* autonomous speed changes — the dangerous Gen3↔Gen4 retraining storm that caused GSP_LOCKDOWN cascades pre-cap. Software-driven retrains (e.g. by the NVIDIA driver during workload) can still occur within whatever the link can sustain (~Gen3 effective on TB4 per `feedback_lspci_lnkcap_tb_virtual`).
- The historical Gen3-without-bit-5 test result (`36 LOCKDOWN events ✗ wedged` from the table below) confirms this: Target alone isn't enough; bit 5 is the actual mitigation. The Gen1+bit5 case stayed clean because bit 5 prevented autonomous Gen3↔Gen4 attempts even though Target was Gen1.
- Why we still set Target to Gen3: it influences the *initial* retrain at boot. With Target=Gen3, the boot-time link comes up at Gen3 cleanly (saving the workload-driven retrain cost on first activity). At runtime, kernel/hardware may re-sync Target bits to current LnkSta when retrain settles at a different speed — this is observable as the script's `LnkCtl2 readback differs from write` info-log line on a runtime restart while the link is already idle at Gen1.
- Bit 5 stays set across these transitions — that's why the cap is durably effective. The script's readback check (loosened 2026-05-08 evening) now accepts any readback where bit 5 is set, regardless of Target value.

**Empirical observation 2026-05-08 evening:** workload triggers Gen1→Gen3 retrain, idle returns to Gen1; cycle is observable via `setpci -s <bridge> CAP_EXP+0x12.W` (LnkSta) — flips between `0x7041` (Gen1) and `0x7043` (Gen3). This is the production-correct behaviour: the link uses what bandwidth the workload needs, never reaches dangerous Gen4.

## Why we need it today

Empirical test history on this hardware (from the script's own header comments):

| Cap setting | Result |
|---|---|
| Gen1 cap | 0 LOCKDOWN ✓ — but bandwidth-limited (1 GB/s ceiling) |
| Gen2 cap | 0 LOCKDOWN ✓ — ~2 GB/s bandwidth — PROD-OK alternative |
| Gen3 cap **without** bit 5 | 36 LOCKDOWN events ✗ — wedged (autonomous Gen3↔Gen4 retraining) |
| Gen4 (uncapped, default) | LOCKDOWN storms ✗ |
| **Gen3 cap WITH bit 5** | **0 LOCKDOWN ✓ — ~2.8 GB/s — current config** |

Forensic dossier: `archive/gen3-fail-2026-05-07-165158/` (the failed Gen3-no-bit-5 run).

The platform-side gap this addresses is **TB4-tunneled PCIe link instability at Gen4 negotiations** — a hardware-level signal-integrity issue specific to the Intel Barlow Ridge TB controller in the JHL9480 + AORUS hub topology. Without the cap, GSP boot races against the link state machine and loses.

## Configuration and tuning

### Hardcoded constants (in helper script)

| Variable | Default | Meaning |
|---|---|---|
| `TARGET_SPEED_BITS` | `0x3` | Target Link Speed: 0x1=Gen1, 0x2=Gen2, 0x3=Gen3, 0x4=Gen4 |
| `HW_AUTO_SPEED_DISABLE` | `1` | Bit 5 of LnkCtl2; `1` pins link at target |
| `LNKCTL2_OFFSET` | `0x30` | PCIe Express Capability offset for LnkCtl2 |
| `LNKCTL_OFFSET` | `0x10` | PCIe Express Capability offset for LnkCtl (used for retrain) |

### Environment variables (override at service-start time)

| Var | Default | Effect |
|---|---|---|
| `BRIDGE` | auto-detect | Force a specific bridge BDF instead of vendor/device-ID lookup |

### State files

| Path | Purpose |
|---|---|
| `/var/lib/aorus-egpu/bridge-link-cap.original` | Original LnkCtl2 value for clean restore via `ExecStop` |

### Tuning experiment matrix

To re-evaluate the cap setting (e.g., after kernel/firmware updates):

1. `systemctl stop aorus-egpu-bridge-link-cap` (restores original LnkCtl2)
2. Edit `TARGET_SPEED_BITS` in `/usr/local/sbin/aorus-egpu-bridge-link-cap` to test value
3. `systemctl start aorus-egpu-bridge-link-cap`
4. Reboot (cold-cold to fully reset link state)
5. Run `tools/uvm-close-path-probe.sh` and `tools/close-path-probe.sh` for n≥3 each
6. Watch `dmesg | grep GSP_LOCKDOWN` — should be 0
7. Measure `nvbandwidth -t 0` for actual bandwidth

The Gen2 cap is a tested-PROD-OK fallback if Gen3+bit5 ever regresses on a future kernel.

## Dependencies

**Requires (at boot):**
- `systemd-udev-settle.service` — needs udev to populate sysfs
- `bolt.service` — needs Thunderbolt to authorize the eGPU and establish the tunnel

**Required by:**
- `aorus-egpu-compute-load-nvidia.service` (`Before=` ordering — must run before nvidia binds)

**Implicit:**
- `setpci` binary (`pciutils` package)

## Lifecycle (boot / runtime / shutdown)

| Phase | Action |
|---|---|
| Boot | Runs after `systemd-udev-settle` + `bolt` complete; before `aorus-egpu-compute-load-nvidia` |
| Runtime | `Type=oneshot RemainAfterExit=yes` — stays "active (exited)" for the lifetime of the boot |
| Shutdown | No automatic action — the bridge state matters at next boot |

`Restart=` is not set; if the apply step fails the service fails and downstream services with `RequiredBy=` should fail too.

## Verification

After boot, confirm the cap is active:

```bash
# Auto-detect bridge and show LnkCtl2
sudo /usr/local/sbin/aorus-egpu-bridge-link-cap status
```

Expected: `LnkCtl2 = 0xNNNN` where `NNNN` has bits [3:0]=0x3 (Gen3 target) and bit 5 set.

Cross-check via `lspci`:
```bash
sudo lspci -vv -s $(ls -d /sys/bus/pci/devices/*/0000:04:00.0 2>/dev/null | head -1 | xargs -I{} dirname {} | xargs basename) \
  | grep -E "LnkCtl2|LnkSta:"
```

Expected: `LnkCtl2 ... Speed 8GT/s`, `Hardware Autonomous Speed Disabled+`. `LnkSta` should show actual link at `Speed 8GT/s, Width x4` after retrain.

In the per-boot Phase 5 snapshot (`archive/phase5-evidence/<boot-iso>.log`), look for `GPU_LnkSta=0x1043(Speed=3 ...)` at probe-end — confirms link is Gen3 from probe time onward. `Speed=4` would indicate the cap didn't take effect.

## Architectural destination

**Lever V-prime** — the correct lowest-OS-layer for downstream-PCIe link-speed cap on TB-tunneled devices is the kernel's `drivers/thunderbolt`, NOT a userspace helper, NOT a NVIDIA-side patch, NOT a PCI quirk. The TB driver knows when a tunnel is established and which downstream port hosts the device; it should set the speed cap as part of tunnel establishment.

Memory entry `feedback_tb_pcie_cap_architecture` documents the architectural rationale; `lever-catalog.md` Lever V-prime entry has the proposed kernel patch shape.

## Retirement criteria

This service can retire **only** when an upstream-kernel fix lands that achieves the same end state (downstream-port link-speed cap on TB-tunneled paths) without userspace intervention. Specifically:

1. A patch to `drivers/thunderbolt` (or equivalent layer) that sets `LnkCtl2` Target Link Speed + bit 5 on the downstream port at tunnel-establishment time
2. The patch must run **before** PCI scan / device enumeration completes
3. The patch must be in the running kernel (not just upstream)

Phase-5-style "n=10 boots without this service" empirical test is **not sufficient**; the failure mode (GSP_LOCKDOWN cascades) was reliably reproduced before this service existed and would re-emerge on its removal.

### Re-validation 2026-05-08 — empirically confirmed load-bearing

`Q2 cycle 1` (cap disabled, cold-cold-boot) reproduced the historical failure mode at n=1:
- `nvidia-smi -L` returned `No devices found` after one close-path-probe run
- 9 `GSP_LOCKDOWN` events in dmesg
- M-recover fired (post-rmInit-FAIL → bus reset → slot_reset DISCONNECT because PMC_BOOT_0=0xffffffff → surrender + PERMANENT_FAIL)
- Required cold-cold-boot (full eGPU enclosure power cycle) to recover

Forensic dossier: `archive/close-path-probes/2026-05-08T21-49-58+10-00/`. Test halted at n=1 — single failure was sufficient evidence.

**Bonus finding:** this was the **first real-world fire of Lever M-recover in production.** Phase 1-4 testing was synthetic via `force_trigger`; Q2 cycle 1 produced a natural failure that validated the in-driver recovery state machine end-to-end. M-recover fired correctly, H2 rate-limit deferred a follow-up attempt 22 s later, slot_reset surrendered cleanly when the bus was beyond software recovery. No storm, no kernel hang. The patches 0024 + 0026 + 0027 + 0028 are now production-validated.

## Retirement procedure

When the upstream kernel fix is in place:

1. Verify kernel-side cap is active by reading `LnkCtl2` on the bridge BEFORE any module touches it (early-userspace observability — could add a sysfs marker or kernel log line).
2. `systemctl disable --now aorus-egpu-bridge-link-cap.service`.
3. Cold-cold-boot reboot.
4. Run n=3 of: `tools/close-path-probe.sh` AND a real `loop-with-flr.sh ITERATIONS=1 MODEL=llama3.1:8b`. All must complete with `fires=0`, no `GSP_LOCKDOWN_NOTICE` in dmesg, `LnkSta` Gen3 at all DIAG sites.
5. If any reproduce the original failure: re-enable + roll back kernel; this service still earns its slot.
6. If all clean: update `service-retirement-roadmap.md` (move row from Active to Retired with date + kernel version), update this doc's Status header, leave binary + unit in place per project pattern.

## Resurrection procedure

If a future kernel update breaks the upstream fix or a regression occurs:

1. `systemctl enable --now aorus-egpu-bridge-link-cap.service`
2. Reboot — apply takes effect.
3. Verify per "Verification" section above.
4. Update `service-retirement-roadmap.md` with resurrection date + cause.

## Files installed / consumed

**Installed by `apply.sh`:**
- `/etc/systemd/system/aorus-egpu-bridge-link-cap.service`
- `/usr/local/sbin/aorus-egpu-bridge-link-cap`

**State written:**
- `/var/lib/aorus-egpu/bridge-link-cap.original`

**Reads:**
- `/sys/bus/pci/devices/*/{vendor,device}` (auto-detect AORUS GPU + parent bridge)
- PCI config space at the bridge BDF via `setpci` (LnkCtl2 + LnkCtl)

## Cross-references

- Empirical investigation: [`docs/h17-g3-gen3-investigation-2026-05-07.md`](../h17-g3-gen3-investigation-2026-05-07.md)
- Multi-cause GSP_LOCKDOWN analysis: [`docs/iommu-gsp-lockdown-analysis.md`](../iommu-gsp-lockdown-analysis.md)
- Architectural destination: [`docs/tb-pcie-cap-architecture.md`](../tb-pcie-cap-architecture.md), [`docs/lever-catalog.md`](../lever-catalog.md) Lever V-prime
- Hypothesis: [`docs/reliability-hypothesis-ledger.md`](../reliability-hypothesis-ledger.md) H17
- Forensic dossier (failed Gen3-no-bit-5 run): `archive/gen3-fail-2026-05-07-165158/`
- Memory: `feedback_tb_pcie_cap_architecture`, `feedback_lspci_lnkcap_tb_virtual` (the lspci LnkCap is virtual on TB-tunneled bridges; nvbandwidth is authoritative)
