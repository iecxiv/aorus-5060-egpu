# H17.G3 — Gen3 Cap Investigation (2026-05-07)

Forensic dossier and active test plan for achieving Gen3 + zero errors on
the AORUS RTX 5090 eGPU + NUC 15 Pro+ (TB4) platform. Task #106.

Companion docs: `iommu-gsp-lockdown-analysis.md` (parent analysis),
`reliability-hypothesis-ledger.md#h17` (hypothesis tracking),
`lever-catalog.md#lever-u` (architectural destination).

## Executive summary (revised 2026-05-07 21:00)

- **Port B Gen3+bit5 cap (`LnkCtl2 = 0x0063`) WORKS** (n=2): 0 LOCKDOWN,
  GPU bound at Gen3, rmInit succeeds first try, stable indefinitely with
  passive watchdog + M-recover scaffold.
- **Port A Gen3+bit5 cap FAILS** (n=2): 36 GSP_LOCKDOWN_NOTICE, GPU wedged.
  Re-validation needed with full new stack (UncMaskClear + passive
  watchdog + M-recover enabled).
- **AER errors reframe (G3-H finding)**: `Br_AER_Cor=0x1` and
  `GPU_Cor=0x2000` we'd been chasing as "active Gen3 errors" were
  STALE RW1C bits from PCI enumeration. With UncMask=0 (matching
  Windows), Internal Error never fires — the masked bit was a
  pre-existing flag, not a live error class. AER is not the proximate
  cause of port A's failure.
- **Periodic ~17s recovery cycles root-caused** to
  `aorus-egpu-observability-watchdog` polling `nvidia-smi` every 10s
  (close-path wedge bug). Watchdog redesigned to passive sysfs reads
  only (task #108). Cycles eliminated.
- **Production cap is Gen3+bit5 on port B**. Lever U updated to
  target Gen3 (not Gen2) when on port B. Auto-negotiation does NOT
  fall back to Gen2 on its own — see "Why Gen2 doesn't auto-negotiate"
  below.
- **NEW H18 hypothesis**: host-side TB tunnel runs at PCIe Gen1 ×4
  on both ports / both OSes, despite TB4 spec allowing Gen3 ×4. Likely
  software-fixable. Investigation pending — see
  docs/tb4-tunnel-gen1-investigation.md.

## Findings

### 1. Bridge Receiver Error fires from first DIAG site

```
Br_AER_Cor=0x00000001  (bit 0 = Receiver Error / 8b/10b decode failure)
```

Set on bridge `0000:03:00.0` at `[DIAG]` site `probe-end` — BEFORE any
DMA traffic, BEFORE rmInit, while link is active and stable at Gen3.
Persists through all subsequent retries. Bridge AER Uncor remains zero.

This is a **physical-layer indicator**: bit corruption arriving at the
bridge's PCIe receiver from the eGPU upstream direction. The link is
unclean from boot.

### 2. GPU Cor=0x2000 is demoted Internal Error

`GPU_AER_UncMsk = 0x00400000` (bit 22 = Uncorrectable Internal Error).
With this bit masked, when the GPU PCIe IP fires Internal Error, it gets
demoted to Advisory Non-Fatal (Cor bit 13 = 0x2000) instead of firing as
Uncorrectable.

`GPU_AER_HeaderLog = 00000000_00000000_00000000_00000000` because PCIe
spec §7.8.4.7 only updates Header Log on UncStatus capture — masked
errors bypass it. So the offending TLP is not recorded.

**Hypothesis**: GPU Internal Error is downstream consequence of bad
input from corrupted upstream traffic. Not directly observable in
software because masking suppresses Header Log capture.

### 3. ASPM is already disabled — falsifies ASPM hypothesis

```
GPU_LnkCtl=0x0040 (ASPM=0 ClkPM=0)
Br_LnkCtl=0x0c40  (ASPM=0 ClkPM=0)
```

Linux already disabled ASPM at boot (likely via TB topology quirk).
`pcie_aspm=off` cmdline test would be redundant.

### 4. Hardware Autonomous Speed Disable doesn't honor speed-down — falsifies G3-E

LnkCtl2 bit 5 set (HwAutoSpeedDisable=1) at Gen3. Link still drops to
Gen1 after rmInit fails. Bit 5 honored on speed-up but not speed-down
on this TB switch silicon (or kernel/driver explicitly writes LnkCtl2
post-failure — both happen).

### 5. LBMS=1, LABS=0 — link bandwidth changes are explicit, not autonomous

Bridge `LBMS=1` set after our retrain. `LABS=0` throughout. No autonomous
hardware-initiated bandwidth changes occurred. All speed transitions
are software/kernel-initiated (we wrote LnkCtl2, kernel rewrote it
post-failure).

## Test history

| # | Cap | LnkCtl2 | LOCKDOWN | rmInit | Outcome |
|---|---|---|---|---|---|
| 1 | None (Gen4 default) | 0x0044 | many | fails | LOCKDOWN storms, baseline |
| 2 | Gen1 | 0x0041 | 0 ✓ | succeeds | Works, bandwidth-limited |
| 3 | Gen2 (PROD) | 0x0042 | 0 ✓ | succeeds | Works, slight perf hit vs Gen3 |
| 4 | Gen3 plain | 0x0043 | 36 ✗ | fails | Wedged. Br_AER_Cor=0x1 |
| 5 | Gen3 + bit 5 (G3-E) | 0x0063 | 36 ✗ | fails | Wedged. Same Br_AER_Cor=0x1. G3-E falsified. |

n=2 confirmation Gen3 fails. n=2 confirmation Gen2 works.

## Why Gen2 doesn't auto-negotiate cleanly

Without our cap script, the boot uncapped at Gen4 → LOCKDOWN storms
even though Gen2 would work if reached. The auto-fall-back path would be:

1. Link tries Gen4 negotiation
2. Receiver errors at Gen4 (signal integrity)
3. AER fires, kernel `pcie_bandwidth_notification` reduces speed
4. Link retrains at Gen3 → still fails (Gen3 also unclean)
5. Retrain at Gen2 → would succeed

**Problem**: by the time steps 4-5 would complete (tens of ms), GSP
boot has already crashed with WPR2-stuck. nvidia.ko `rm_init_adapter`
starts DMA setup at probe time without waiting for link stability. The
LTSSM negotiation timing loses to the GSP boot timing.

**Architectural fix (Lever U)**: in `nv_pci_probe`, walk upstream — if
TB-tunnelled topology detected, write LnkCtl2 cap BEFORE calling rmInit.
This is what our userspace systemd unit does, just relocated to where
it belongs. Eliminates the cap-script need.

**Alternative (kernel quirk)**: PCI subsystem caps known-problematic TB
topologies before any driver binds. Upstreamable.

## PCIe lever inventory (untested)

What software CAN influence on the physical layer at Gen3:

| Lever | Register | Status |
|---|---|---|
| **De-emphasis (Selectable)** | LnkCtl2 bit 6 | **Gen2-only per spec §7.5.3.20**. Does NOT apply at Gen3. |
| **Equalisation Presets P0-P10** | PCIe Link Equalisation Cap (extended) | Untested. Substantial work — find cap, read per-lane control, write presets. |
| **Compliance Preset / De-emphasis** | LnkCtl2 bits[15:12] | Compliance mode only. Not normal operation. |
| **Transmit Margin** | LnkCtl2 bits[9:7] | Untested. Compliance/test feature, default normal. |
| **MaxPayloadSize** | DevCtl bits[7:5] | Smaller TLPs = less DMA burst. Untested at Gen3. |
| **MaxReadRequest** | DevCtl bits[14:12] | Smaller read bursts. Untested at Gen3. |
| **ECRC Generation/Check** | AER CapCtl bits 6,8 | Currently capable (CapCtl=0xa0) but disabled. Would distinguish transport corruption from internal errors. |
| **Replay/Ack timers** | impl-specific extended caps | Untested. |

**Most promising for Gen3 root-cause attribution**: Link Equalisation
Capability presets. Substantial driver-side work — only worth doing if
the port-swap test and Windows comparison leave us with positive
evidence Gen3 should work but doesn't.

## Active test plan

### Test 1 (next): Port swap

NUC 15 Pro+ has 2 TB4 ports. Cheapest most-discriminating test.

Procedure: power-off, move TB cable to other port, boot with current
Gen3+bit5 cap unchanged.

| Outcome | Diagnosis | Action |
|---|---|---|
| 0 LOCKDOWN, Br_AER_Cor=0x0, GPU at Gen3 | Port A's PCB trace/connector is the problem | Use port B as production. Investigate further. |
| 0 LOCKDOWN, Br_AER_Cor=0x1, GPU at Gen3 | Receiver Error tolerable on port B (different signal envelope) | Investigate why both ports show but only B succeeds |
| 36 LOCKDOWN, Br_AER_Cor=0x1 | Both ports identical, problem downstream of TB controller | Skip eq tuning. Go to Windows comparison. |

### Test 2: Windows host comparison

Boot Windows on same hardware. Capture authoritative Gen3-or-not
behaviour from closed driver.

Tools: HWinfo64 (free, hwinfo.com), nvidia-smi.exe.

Capture:
- `nvidia-smi.exe --query-gpu=name,pcie.link.gen.current,pcie.link.gen.max,pcie.link.width.current --format=csv`
- HWinfo64 → Bus → PCI Express → AORUS GPU device → screenshot:
  - Current Link Speed
  - Current Link Width
  - AER counters (correctable / uncorrectable)
  - LnkCtl2 register dump if available
- Run for ~5 min idle + a brief CUDA workload, observe whether AER
  counters increment (→ Windows tolerates errors) or stay zero
  (→ Windows runs at Gen2 too, or Gen3 cleanly).

**Decisive question**: does Windows achieve clean Gen3 with closed
driver? If no, our Gen2 ceiling matches Windows. If yes, the closed
driver does something we don't.

### Test 3 (deferred): Link Equalisation Capability tuning

Only if tests 1+2 indicate Gen3 should be achievable on this hardware.
Substantial driver-side investigation:

1. `pci_find_ext_capability(pdev, PCI_EXT_CAP_ID_SECPCI)` on bridge + GPU
2. Read per-lane Equalisation Control registers
3. Try transmitter presets P0-P10 (different equalisation profiles)
4. Trigger re-equalisation via Eq Control bits
5. Capture which preset (if any) eliminates Br_AER_Cor=0x1

## Production decision

**Cap = Gen2 + Hardware Autonomous Speed Disable** (`LnkCtl2 = 0x0062`).

Rationale:
- Empirically proven (n=2 already, candidate for n≥3 validation)
- Hardware Autonomous Speed Disable prevents post-success downgrade to
  Gen1 (observed at 17:38:29 — bridge LnkCtl2 rewritten to 0x0041)
- Lever U is the architectural destination — same logic, in driver

Performance: WSL2 perf at 98-105% of native at Gen2 confirms this is
NOT throughput-limited. Gen3 would offer ~60% more theoretical bandwidth
but practical gains are likely small for inference workloads.

## Open questions

1. Is port B clean at Gen3? (Test 1)
2. Does Windows achieve clean Gen3? (Test 2)
3. If neither port is clean and Windows agrees: is the Gen3 issue
   fixable via Equalisation Preset tuning, or fundamentally cable/silicon?
   (Test 3, conditional)
4. What about the "auto-negotiation post-success downgrade" we observed
   on Gen2 boots (LnkCtl2 0x0042 → 0x0041 ~14s after success)? Bit 5
   in Gen2 cap should fix this. Untested at Gen2.
