# TB4 PCIe Topology — AORUS RTX 5090 + NUC 15 Pro+

Canonical reference for how PCIe is tunneled over Thunderbolt 4 on this
hardware, what the OS reports vs what's actually happening, and where
the real performance ceilings are.

## Why this doc exists

The OS-reported PCIe link state on TB-tunneled devices is heavily
virtualized. Reading `lspci` literally leads to wrong conclusions about
bandwidth. This document is the empirically-validated reference for the
actual topology, with measurements that prove the OS reports are not
the truth.

Empirical proof: 2026-05-07 nvbandwidth measurements (this hardware,
port B, Gen3+bit5 cap, M-recover scaffold + passive watchdog).

## Topology diagram

```
┌─────────────────────────────────────────────────────────────────────────────────────────┐
│                                                                                         │
│   HOST (NUC 15 Pro+, Intel Meteor Lake-P)              eGPU (AORUS RTX 5090 AI BOX)     │
│                                                                                         │
│   ┌──────────┐     ┌────────────┐         ┌──────────┐     ┌──────────┐    ┌───────┐    │
│   │   CPU    │═════│  Intel TB4 │═════════│ Barlow   │═════│ Barlow   │════│  RTX  │    │
│   │ Complex  │ IDI │ Controller │ TB Cable│ Ridge    │ PCIe│ Ridge    │PCIe│ 5090  │    │
│   │          │     │  ("Gen14") │ TB5-rated│ Hub UP  │     │ Hub Down │    │       │    │
│   └──────────┘     └────────────┘         └──────────┘     └──────────┘    └───────┘    │
│                          ↑                      ↑                ↑           ↑          │
│                          │                      │                │           │          │
│  CPU-internal       PCIe Tunnel           AORUS-internal   AORUS-internal  GPU PCIe IP  │
│  fabric (IOSF)      (TB protocol)         PCIe (real)      PCIe (real)                  │
│  not standard PCIe                                                                      │
│                                                                                         │
│   ┌───────────────────────── PHYSICAL LINK CAPABILITIES ─────────────────────────┐      │
│                                                                                         │
│      Bridge BDF:        00:07.2          1-1 (TB)        2c:00 → 2d:00     2e:00.0      │
│      OS-reported gen:   Gen1 ×4 ⚠       40 Gb/s ×2L     "Gen1" then Gen4   Gen3 ×4      │
│      Reality:           VIRTUAL          REAL            VIRTUAL→REAL       REAL        │
│      Actual capacity:   ~32 Gbps PCIe    40 Gbps wire    32→25 Gbps         32 Gbps     │
│                          payload (TB4)   (per direction) PCIe payload       (Gen3 ×4)   │
│                                                                                         │
│   └───────────────────────────────────────────────────────────────────────────────┘     │
│                                                                                         │
│   ┌────────────────────── MEASURED END-TO-END BANDWIDTH ───────────────────────┐        │
│                                                                                         │
│      nvbandwidth host_to_device_memcpy_ce:    2.80 GB/s = 22.4 Gbps  ←─┐               │
│      nvbandwidth device_to_host_memcpy_ce:    3.29 GB/s = 26.3 Gbps  ←─┤ ~70-80%       │
│      nvbandwidth bidirectional:               2.47 GB/s = 19.8 Gbps  ←─┘ TB4 spec      │
│                                                                                         │
│   └─────────────────────────────────────────────────────────────────────────────┘       │
│                                                                                         │
└─────────────────────────────────────────────────────────────────────────────────────────┘
```

## Key insights

### 1. lspci LnkCap on TB roots is VIRTUAL — not a measurement of throughput

The TB host controller exposes a virtualized PCIe bridge to the OS
(at root port 00:07.2 and at the Barlow Ridge upstream bridge 2c:00.0).
These bridges advertise `LnkCap = 2.5GT/s ×4` (Gen1) regardless of
actual TB tunnel capacity. Reading `lspci` and concluding "the host
link is Gen1, so we're at 8 Gbps" is **wrong** — the value is a
register state, not a measurement.

The kernel's "8.000 Gb/s available PCIe bandwidth, limited by 2.5 GT/s
PCIe x4 link at 0000:00:07.2" message is reading these virtualized
registers. It is NOT measuring real bandwidth.

### 2. The TB cable carries TB protocol, not raw PCIe

TB4 link operates at 40 Gbps per direction (2 lanes × 20 Gbps), full
duplex. PCIe TLPs are encapsulated into TB protocol packets, transmitted,
and unpacked on the other side. After TB protocol overhead, ~32 Gbps
of the 40 Gbps wire is allocated to PCIe payload (per TB4 spec).

### 3. nvidia-smi `pcie.link.gen.current = 3` reports the INTERNAL link

Inside the AORUS box, the PCIe link from the Barlow Ridge downstream
hub port (2d:00.0) to the GPU (2e:00.0) IS real PCIe. Our cap script
sets this to Gen3 ×4 (LnkCtl2 = 0x0063: Gen3 + Hardware Autonomous
Speed Disable). nvidia-smi reports this internal link.

This is a DIFFERENT link from the host-side TB tunnel. It is NOT the
end-to-end bandwidth.

### 4. End-to-end bandwidth is TB4-saturated at ~2.8 GB/s

Empirically measured 2026-05-07 with NVIDIA nvbandwidth (the official
replacement for the deprecated bandwidthTest):

| Direction | GB/s | Gbps useful | % of TB4 spec ceiling (32 Gbps) |
|---|---|---|---|
| H2D (host → GPU) | 2.80 | 22.4 | 70% |
| D2H (GPU → host) | 3.29 | 26.3 | 82% |
| Bidirectional H2D | 2.47 | 19.8 | 62% |

This is at or near TB4 saturation. Higher bandwidth would require:
- TB5 host (Lunar Lake / Arrow Lake successor) — out of scope
- Different cable/enclosure — out of scope
- Software pipelining (overlap with filesystem I/O) — task #74

### 5. Cap target of Gen3 ×4 internally MATCHES TB4 tunnel capacity

We cap the AORUS-internal link to Gen3 ×4 (~32 Gbps theoretical) via
LnkCtl2=0x0063 on bridge 2d:00.0. This matches TB4 tunnel max.

If we let the internal link train to Gen4 ×4 (the bridge's LnkCap), we'd
have a mismatch: GPU↔hub PCIe link could carry ~64 Gbps but TB tunnel
can only carry ~32 Gbps. The GPU's PCIe link layer would attempt to
push more than the tunnel can carry, leading to flow control churn,
retraining, and the GSP_LOCKDOWN cascades we observed at uncapped boot.
Capping at Gen3 internally aligns the rates and avoids this.

## Common misinterpretations corrected

| Statement | Correct? | Why |
|---|---|---|
| "lspci says Gen1 on root port, so we're stuck at 8 Gbps" | ❌ WRONG | Virtual register; doesn't reflect tunnel capacity |
| "nvidia-smi says Gen3, so end-to-end is 32 Gbps" | ❌ WRONG | Internal link only; tunnel is the bottleneck |
| "nvbandwidth says 2.80 GB/s, so we're at TB4-saturated end-to-end" | ✅ CORRECT | Measures actual data rate via copy engines |
| "Cold-load 8s for 9.4 GB = ~1 GB/s = Gen1 limited" | ❌ WRONG | Cold-load includes filesystem read + parse, NOT pure PCIe; pure PCIe portion ≈ 3.4s |
| "Raising tunnel from Gen1 to Gen3 will give 3× speedup" | ❌ WRONG | No Gen1 to raise; tunnel already TB4-saturated |

## How to verify (always trust measurement over OS reports)

For PCIe bandwidth questions on this hardware, run:

```bash
# Build (one-time, ~5 min)
sudo dnf install -y cuda-minimal-build-13-2 cuda-nvml-devel-13-2 cmake boost-devel
git clone --depth 1 https://github.com/NVIDIA/nvbandwidth.git
cd nvbandwidth && mkdir -p build && cd build
PATH=/usr/local/cuda/bin:$PATH cmake .. -DCMAKE_BUILD_TYPE=Release
make -j$(nproc)

# Measure (each run takes ~10 seconds)
./nvbandwidth -t 0   # host → device
./nvbandwidth -t 1   # device → host
./nvbandwidth -t 2   # bidirectional

# Caveats:
# - Each invocation opens /dev/nvidia0; will trigger ONE close-path wedge
#   recovery cycle handled by M-recover. Wait ~20s before re-running.
# - Results are stable on this hardware to ±0.05 GB/s across runs.
```

Expected results on this hardware (port B, Gen3+bit5 cap):
- H2D: 2.7-2.9 GB/s
- D2H: 3.2-3.4 GB/s
- Bidirectional H2D: 2.4-2.6 GB/s

If results materially differ, something has regressed (cap not applied,
TB tunnel degraded, cable issue, etc.) — investigate.

## See also

- `docs/h17-g3-gen3-investigation-2026-05-07.md` — Gen3 cap investigation
  that led to current Gen3-internal cap
- `docs/tb4-tunnel-gen1-investigation.md` — H18 investigation (RESOLVED:
  hypothesis falsified by nvbandwidth measurement)
- `docs/reliability-hypothesis-ledger.md` H18 — falsified entry
- `docs/lever-catalog.md` Lever U (Gen3 cap) — current production
- `docs/lever-catalog.md` Lever V (TB tunnel raise) — RETIRED 2026-05-07
- `feedback_avoid_nvidia_smi_for_state_checks.md` — passive observability
- Memory `feedback_lspci_lnkcap_tb_virtual` — quick-reference rule
