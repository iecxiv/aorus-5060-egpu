# H18 — TB4 Tunnel Host-Side Stuck at PCIe Gen1: Investigation Plan

**Status:** **RESOLVED 2026-05-07 (FALSIFIED)**. Lever V retired.
See "Resolution" section at the end.

**Original status:** Active 2026-05-07. Hypothesis [H18](./reliability-hypothesis-ledger.md#h18).
Lever V (proposed). User priority: HIGH.

**Canonical topology reference**: see `docs/tb4-pcie-topology.md`
(diagram + measured bandwidths, replaces the (incorrect) topology
description below).

> ⚠️ The investigation plan below was authored under a since-falsified
> hypothesis. Reading order: skip to "Resolution" at the bottom for the
> outcome. Sections above are preserved for context but should not be
> acted upon.

## Problem

Host-side PCIe link to the TB controller advertises and operates at
**Gen1 ×4** despite TB4 spec allowing tunneled PCIe up to **Gen3 ×4**.

```
Host root port 00:07.0 (port A): LnkCap Speed 2.5GT/s ×4
Host root port 00:07.2 (port B): LnkCap Speed 2.5GT/s ×4
HWinfo64 (Windows):              PCIe Link Speed 2.5 GT/s
```

Both NUC TB4 ports, both Linux and Windows, all show host-side Gen1.

**Empirical impact:** Windows cold-load TTFT for 9.4 GiB llama3.1:8b
model = 8.0s, matching Gen1 ×4 saturation (~8 Gbps payload). Raising
to Gen3 ×4 (~25 Gbps) would yield ~3× cold-load speedup. Steady-state
inference is mostly VRAM-bound so impact there is small.

## Constraints (from project memory)

- **No user-configurable BIOS options** on this NUC 15 Pro+. BIOS UI has
  no TB security mode toggle, no PCIe gen cap, no IOMMU policy switch.
  See `feedback_no_bios_options_nuc15.md`.
- Fixes must come from: **system layer / TB module / boltctl / kernel /
  NVIDIA driver**. Not BIOS.
- Memory `feedback_observability_perturbs_bug` and
  `feedback_avoid_nvidia_smi_for_state_checks`: prefer passive
  observability. Don't trigger close-path wedge during investigation.

## Hardware facts confirmed

| Component | Spec | Evidence |
|---|---|---|
| NUC 15 Pro+ TB controller | Intel Meteor Lake-P "Gen14" TB4 | `lspci` + `thunderbolt` sysfs |
| AORUS box TB controller | Intel JHL9480 Barlow Ridge TB5 80G/120G | `lspci -v` on bridge `2c:00.0` |
| TB cable | NVIDIA-approved short TB5-rated | user-confirmed |
| TB physical link | 20 Gb/s × 2 lanes = 40 Gbps total | `cat /sys/bus/thunderbolt/devices/1-1/{rx,tx}_speed`, `*_lanes` |
| AORUS internal PCIe (hub→GPU) | Gen3 ×4 effective at our cap, Gen4 ×4 capable | `lspci -vv -s 2d:00.0`, nvidia-smi |
| Host PCIe (root port→TB ctrl) | **Gen1 ×4** ← THE PROBLEM | `lspci -vv -s 00:07.{0,2}` LnkCap |

The TB4 cable + AORUS box could carry Gen3, but host advertises Gen1.

## Possible mechanisms (to discriminate)

1. **Linux thunderbolt driver doesn't request higher gen at tunnel setup**
   - Fixable in `drivers/thunderbolt/tunnel.c` or via module param
   - Most plausible if Windows also shows Gen1 (both OSes underutilising)

2. **Intel Meteor Lake-P TB4 controller silicon caps tunneled PCIe at Gen1**
   - Not fixable in software; firmware-level
   - Some older Intel TB controllers (Alpine Ridge) WERE Gen1-only
   - Need to verify: is Meteor Lake-P TB4 in this category?

3. **NUC firmware (CSE/PCH) sets host-side LnkCap before OS boots**
   - Not fixable from OS layer; requires firmware update
   - User has no BIOS settings; unlikely to find an exposed lever

4. **TB security mode forces Gen1 for pre-boot DMA protection**
   - Modern TB has `iommu_dma_protection` mode that may restrict speed
   - Currently `iommu_dma_protection=0` per sysfs (security=user)

5. **PCIe ASPM / power-management forcing Gen1 for low-power state**
   - Currently ASPM=0 on all bridges per [DIAG] data
   - Unlikely cause given ASPM is disabled

## Investigation plan

### Phase 1 — Read-only telemetry (cheap, no risk)

Goal: gather all available signals about TB tunnel negotiation state.

```bash
# 1. boltctl — TB userspace tool
boltctl list                                              # connected TB devices
boltctl info $TB_UUID                                     # detailed device info

# 2. TB sysfs surface
ls /sys/bus/thunderbolt/devices/
for d in /sys/bus/thunderbolt/devices/*/; do
    echo "=== $d ==="
    for f in "$d"/{generation,nvm_version,security,authorized,
                    rx_speed,tx_speed,rx_lanes,tx_lanes,
                    iommu_dma_protection,connection_id,connection_key}; do
        [ -e "$f" ] && printf '  %s = %s\n' "$(basename "$f")" "$(cat "$f" 2>/dev/null)"
    done
done

# 3. Kernel TB negotiation events
journalctl -k -b 0 | grep -iE "thunderbolt|TBT|tunnel|router|new device|retimer" | head -50

# 4. Module parameters currently set
modinfo thunderbolt | grep -E "^parm:" 
cat /sys/module/thunderbolt/parameters/* 2>/dev/null

# 5. Active cmdline TB-related options
cat /proc/cmdline | tr ' ' '\n' | grep -i thunderbolt

# 6. PCI link info on the TB root ports
for bdf in 00:07.0 00:07.2; do
    lspci -vv -s "$bdf" | grep -E "LnkCap|LnkSta|LnkCtl|LnkCap2"
done

# 7. Any kernel debug output about PCIe-over-TB
dmesg | grep -iE "pci.*link|Gen[1-5]"
```

### Phase 2 — Source review (read-only, focused)

Goal: identify the exact code path that establishes the PCIe tunnel
gen, find any hardcoded Gen1 assumptions or missing gen request logic.

Files to review:
- `drivers/thunderbolt/tunnel.c` (tunnel establishment)
- `drivers/thunderbolt/switch.c` (TB switch capabilities)
- `drivers/thunderbolt/usb4.c` (USB4-protocol negotiation)
- `drivers/thunderbolt/tb_msgs.h` (TB protocol messages)
- Search for: `LinkSpeed`, `link_speed`, `Gen1`, `Gen3`, `2.5G`, `8G`,
  `pcie_speed`, `set_pcie_speed`

Goal of this review: identify if (1) tunnel setup explicitly requests
a gen and (2) what gen it requests. If neither tunnel setup nor any
quirk requests gen, that's our software lever.

### Phase 3 — Active experiments (after Phase 1+2)

Conditional on what Phase 1+2 reveal. Candidates:

- `thunderbolt.dyndbg=+p` cmdline → enable verbose TB driver logs
- `thunderbolt.host_reset=true` (currently `false` in cmdline) → force
  TB controller reset at boot, may renegotiate gen
- `thunderbolt.clx=1` (currently `0` in cmdline) → enable Compliance
  Link Extension (TB CLx feature) — affects tunnel parameters
- TB tunnel teardown + renegotiation via `boltctl forget` / authorize
  cycle (carefully — may disconnect eGPU)
- Custom thunderbolt module patch to request Gen3 at tunnel setup
- `pcie_ports=native` cmdline → force Linux PCIe port driver (vs
  ACPI handover) — may affect TB tunnel parameters

### Phase 4 — Validation if a knob works

If any knob raises host-side Gen3:
- `lspci -vv -s 00:07.{0,2}` should show LnkCap Speed 8GT/s
- `lspci -vv` GPU should show NO downgrade marker
- Cold-load TTFT for llama3.1:8b should drop to ~3s (3× improvement)
- Steady-state perf delta vs current baseline (likely small, VRAM-bound)
- n≥3 cold-cold-boots to confirm stable

If no knob found, document as silicon limitation and raise upstream
with kernel/firmware folks.

## Risk register

- **TB tunnel teardown could disconnect GPU** mid-investigation. Mitigate:
  do experimentation BEFORE running heavy workloads; keep eGPU
  connection state pre-checked.
- **Module reload of thunderbolt** could disconnect peripherals (keyboard,
  display via USB-C). Mitigate: do via console/ssh, save state first.
- **Cmdline experiments require reboots**, which incur ~5min round-trip.
  Mitigate: stack hypotheses in priority order so each reboot tests the
  highest-value hypothesis.
- **Close-path wedge** during investigation (don't run nvidia-smi). Use
  passive sysfs reads only.

## Tracking

- Hypothesis: H18 in `docs/reliability-hypothesis-ledger.md`
- Lever: Lever V in `docs/lever-catalog.md`
- Tasks: TBD (created during investigation)
- Forensic dossier per cold-cold-boot: `archive/h18-tb-tunnel-<date>/`

## What's NOT in scope

- BIOS toggles (none available — see feedback_no_bios_options_nuc15.md)
- Replacing hardware (NUC, AORUS box, cable) — we work with what we have
- Modifying TB protocol on AORUS box side — out of our control

---

## Resolution (2026-05-07)

**HYPOTHESIS FALSIFIED via empirical measurement.**

A second LLM consulted by the user pushed back on the H18 hypothesis,
arguing that:
1. TB controllers virtualize PCIe bridge registers
2. lspci `LnkCap = Gen1` is virtual, not a measurement of throughput
3. The correct test methodology is to MEASURE actual bandwidth, not
   read OS reports
4. Expected TB4-saturated H2D: 2.2–3.1 GB/s
5. Expected Gen1-bottleneck H2D: ~1.0 GB/s

We installed CUDA build deps (`cuda-minimal-build-13-2`, `cuda-nvml-devel-13-2`,
`cmake`, `boost-devel`), cloned NVIDIA's nvbandwidth tool (the official
replacement for the deprecated bandwidthTest), built it, and measured.

### Measurement results (port B, Gen3+bit5 cap)

```
$ ./nvbandwidth -t 0    # host_to_device_memcpy_ce
Device 0: NVIDIA GeForce RTX 5090 (00000000:2e:00)
memcpy CE CPU(row) -> GPU(column) bandwidth (GB/s)
           0
 0      2.80

$ ./nvbandwidth -t 1    # device_to_host_memcpy_ce
memcpy CE CPU(row) <- GPU(column) bandwidth (GB/s)
           0
 0      3.29

$ ./nvbandwidth -t 2    # bidirectional H2D
memcpy CE CPU(row) <-> GPU(column) bandwidth (GB/s)
           0
 0      2.47
```

### Conclusion

**Measured H2D = 2.80 GB/s = 22.4 Gbps useful payload.** This is at or
near TB4-saturation (TB4 spec ceiling ~32 Gbps PCIe payload after
protocol overhead). We are getting 70-80% of TB4 spec, which is what
real hardware delivers.

**There is no Gen1 ceiling to raise.** The lspci `LnkCap = Gen1` reading
is virtual-bridge spoofing — the actual TB tunnel carries TB4-spec
bandwidth.

**Lever V retired.** No software lever exists to raise this on TB4 host.
Remaining performance levers operate elsewhere:
- Async pipelining of cuMemcpyHtoD with filesystem read (task #74)
- System tuning: hugepages, IRQ affinity (task #76)

To exceed TB4 envelope: hardware change (TB5 host = Lunar Lake / Arrow
Lake successor). Out of project scope.

### Lessons (for future investigations)

1. **The hardware doesn't lie, even when the software does.** When OS
   reports suggest a bandwidth ceiling, MEASURE before investigating
   software fixes. Use `nvbandwidth` (build instructions in
   `docs/tb4-pcie-topology.md`).

2. **TB controllers virtualize PCIe**. `lspci` on TB-tunneled bridges
   reads register state, not throughput. This is documented behavior
   per USB4 spec to prevent OS power-management interference with the
   tunnel. Saved to memory `feedback_lspci_lnkcap_tb_virtual` for
   future sessions.

3. **Cold-load timing decomposition**: the 8s for 9.4 GB Windows TTFT
   includes filesystem read + ollama deserialization + PCIe transfer.
   At measured 2.8 GB/s, pure PCIe portion is ~3.4s; the other ~4.6s
   is filesystem + parsing. This points task #74 (async pipelining)
   as a real perf lever for cold-load.

4. **Cost of this falsification**: ~30 min of investigation
   (telemetry + nvbandwidth build + measurement). Cost of NOT
   running the test first: would have spent hours on kernel TB
   driver source review chasing a non-existent bug.

### Updated references

- Canonical topology: `docs/tb4-pcie-topology.md`
- Hypothesis ledger H18: marked FALSIFIED
- Lever catalog Lever V: marked RETIRED
- Memory `feedback_lspci_lnkcap_tb_virtual`: rule for future sessions
