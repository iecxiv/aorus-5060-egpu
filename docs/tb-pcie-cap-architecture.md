# TB-Tunneled PCIe Downstream Cap — Architectural Design

The architectural rationale for capping downstream PCIe link speed below
TB-tunneled devices, why it generalizes beyond NVIDIA + RTX 5090, and the
correct kernel layer for the fix.

This document is the authoritative architectural reference. Implementation
specs live in `lever-catalog.md` (Lever V-prime + Lever U).

## The general problem

Any TB-tunneled PCIe device with a downstream hub has the same structural
issue we hit with the AORUS RTX 5090. The pattern is:

```
┌──────┐  ┌──────────┐  TB tunnel  ┌────────────┐  PCIe (real)  ┌────────┐
│ Host │──│ TB ctrl  │═════════════│ TB hub UP  │═══════════════│ Device │
└──────┘  └──────────┘             └────────────┘               └────────┘
                                          ↓
                                   TB hub downstream port
                                   (PCIe bridge to device)
                                          ↓
                                   This bridge's LnkCap reflects
                                   its silicon capability (often
                                   Gen4+) — NOT the TB tunnel
                                   capacity it sits behind
```

Mismatch source: the hub's downstream PCIe port advertises its OWN silicon
capability (typically Gen4 for Barlow Ridge/JHL9480, etc.). It doesn't
know — or doesn't expose — that the upstream TB tunnel can only carry
TB-spec-defined PCIe payload. When device negotiates with hub at the
hub's max LnkCap (e.g., Gen4 ×4 = 51 Gbps useful), the device tries to
push more than the tunnel can carry (~22-25 Gbps for TB4) → flow control
churn, retraining cycles, GSP_LOCKDOWN cascades for GPUs.

## Cap target by TB version

The downstream PCIe link must be capped to match the TB tunnel's PCIe
payload allocation:

| TB version | Useful PCIe payload per direction | Downstream cap target |
|---|---|---|
| TB3 (40 Gbps total) | ~22 Gbps | Gen3 ×4 (~25 Gbps useful) |
| TB4 (40 Gbps total) | ~22-25 Gbps | **Gen3 ×4** ← our case |
| TB5 symmetric (80 Gbps, 40+40) | ~32 Gbps each direction | Gen3 ×4 |
| TB5 asymmetric (80+40 Gbps) | ~50-64 Gbps unidirectional | Gen4 ×4 (~51 Gbps useful) |
| USB4 v2.0 80G | ~50-64 Gbps | Gen4 ×4 |

Hardware Autonomous Speed Disable (LnkCtl2 bit 5) must also be set to
prevent the link from autonomously renegotiating above the cap during
runtime (which we observed empirically — kernel/firmware will sometimes
reset the target speed if it sees errors, defeating the cap).

## Layer analysis — where to implement?

### Layer comparison

| Layer | Knows tunnel state? | Vendor-agnostic? | Upstream-friendly? | Verdict |
|---|---|---|---|---|
| Hub firmware | Yes | Per-vendor only | No (each silicon vendor) | Ideal but unreachable |
| **Linux thunderbolt driver** | **Yes** | **Yes** | **Yes** | **Correct lowest OS layer** |
| Linux PCI core quirks | No (per-device-ID match only) | Per-device-ID | Yes | Wrong abstraction (not topology-aware) |
| Vendor GPU driver (NVIDIA) | Via `pci_is_thunderbolt_attached()` | Per-vendor only | Per-vendor mainline | Per-vendor reinvention |
| Userspace systemd unit | No (manual config) | Per-system only | No | Band-aid (current) |

### Why thunderbolt driver is the right lowest layer

1. **Topology-authoritative**: the thunderbolt driver KNOWS this is a
   TB tunnel and what gen the tunnel negotiated. No other layer has this
   information natively. The PCI core doesn't know "this bridge is
   downstream of a TB tunnel"; the GPU driver only knows "I'm
   TB-attached" via heuristic.

2. **Vendor-agnostic across the entire device population**: the cap
   benefits any device behind a TB tunnel — GPUs (NVIDIA/AMD/Intel),
   NVMe drives in TB enclosures, capture cards, FPGAs. Implementing
   per-vendor in each device driver is duplicated effort.

3. **Vendor-agnostic across host TB silicon**: works for Intel TB
   controllers, future ARM/AMD TB controllers, regardless of chipset.

4. **OS-agnostic precedent**: Windows TB stack does something
   functionally equivalent (per our HWinfo64 + Windows ECRC observations
   showing stable operation at Gen4 internal). Linux should match.

5. **Generalizes to future TB versions**: TB6, USB4 v3, etc. — only the
   gen-mapping table needs updating in one place.

6. **Single source of truth**: future bug fixes, edge cases for
   asymmetric mode, etc. land in one file rather than every device
   driver.

7. **Empirically validated structure**: NVIDIA already exposes
   `pci_is_thunderbolt_attached()` in PCI core, but no kernel layer
   currently USES that to drive PCIe link cap policy. The thunderbolt
   driver should own this policy, not consumers of the helper.

### Why per-driver implementation is suboptimal

Our planned Lever U (NVIDIA-driver-side cap in `nv_pci_probe`) works
but:
- Doesn't help AMD/Intel GPU users in TB enclosures
- Doesn't help non-GPU TB-tunneled devices (NVMe, FPGA, capture cards)
- Each vendor would have to reimplement the same gen-mapping logic
- Each vendor would have to maintain it across TB version updates
- Diverges between vendors (one might cap at Gen3, another at Gen2,
  another not at all → fragmented user experience)

## The "perfect" implementation

**Location**: `drivers/thunderbolt/tunnel.c` (or new file
`drivers/thunderbolt/tunnel-pcie-cap.c`)

**Trigger**: at PCIe tunnel establishment (after device authorization,
before downstream PCIe enumeration completes — ideally before drivers
bind to downstream devices).

**Pseudocode**:

```c
// drivers/thunderbolt/tunnel.c (illustrative — not real code yet)

static enum pci_bus_speed tb_pcie_tunnel_max_speed(struct tb_tunnel *t)
{
    /* Map TB tunnel parameters to max PCIe gen the tunnel can carry. */
    switch (t->gen) {
    case 3:  return PCIE_SPEED_8_0GT;   /* TB3 → Gen3 */
    case 4:  return PCIE_SPEED_8_0GT;   /* TB4 → Gen3 */
    case 5:  return t->asymmetric ? PCIE_SPEED_16_0GT  /* TB5 asym → Gen4 */
                                  : PCIE_SPEED_8_0GT;  /* TB5 sym  → Gen3 */
    default: return PCIE_SPEED_8_0GT;   /* conservative default */
    }
}

static int tb_clamp_pcie_link(struct pci_dev *dev, void *data)
{
    enum pci_bus_speed *target = data;
    u16 lnkctl2;

    if (!pci_is_pcie(dev))
        return 0;
    if (pcie_get_speed_cap(dev) <= *target)
        return 0;  /* already at or below target — nothing to do */

    pcie_capability_read_word(dev, PCI_EXP_LNKCTL2, &lnkctl2);
    lnkctl2 &= ~PCI_EXP_LNKCTL2_TLS;       /* clear Target Link Speed */
    lnkctl2 |= pcie_speed_to_lnkctl2(*target);
    lnkctl2 |= PCI_EXP_LNKCTL2_HASD;       /* Hardware Autonomous Speed Disable */
    pcie_capability_write_word(dev, PCI_EXP_LNKCTL2, lnkctl2);

    pcie_retrain_link(dev);
    return 0;
}

static int tb_pcie_tunnel_clamp_downstream(struct tb_tunnel *tunnel)
{
    enum pci_bus_speed target = tb_pcie_tunnel_max_speed(tunnel);
    struct pci_dev *down_port = tunnel->dst_port->pci_dev;

    /* Walk all PCIe bridges and devices below the tunnel's downstream
     * port and clamp each to the tunnel's max PCIe gen. */
    pci_walk_bus(down_port->subordinate, tb_clamp_pcie_link, &target);
    return 0;
}
```

**Module parameter for opt-out**:

```c
static bool pcie_clamp_downstream = true;
module_param(pcie_clamp_downstream, bool, 0644);
MODULE_PARM_DESC(pcie_clamp_downstream,
    "Clamp downstream PCIe link speed to TB tunnel capacity (default true). "
    "Disable only for diagnostic purposes — disabling can cause flow control "
    "churn and device-specific instabilities (e.g., NVIDIA GSP lockdown).");
```

## Lever hierarchy (revised)

| Lever | Layer | Status | Replaces |
|---|---|---|---|
| **Lever V-prime** (NEW) | L1 — Linux thunderbolt driver | **Architectural destination** | All others |
| Lever U | L1 — NVIDIA driver `nv_pci_probe` | Defensive fallback for older kernels without V-prime | Userspace systemd |
| Bridge-link-cap systemd unit | L4 — userspace | Current production band-aid | — |

## Upstream path

Tasks for upstreaming:
1. **Survey prior art** (task #51 already pending): search linux-thunderbolt
   mailing list archives + LKML for "PCIe link speed cap", "tunnel
   bandwidth", "TB downstream clamp". Confirm no existing patch exists.
2. **Empirical justification**: cite our LOCKDOWN cascade investigation
   + nvbandwidth measurements. Document in
   `docs/tb4-tunnel-gen1-investigation.md` already.
3. **RFC patch** to `linux-thunderbolt@lists.linux.dev` and
   `linux-pci@vger.kernel.org`:
   - Subject: `[RFC PATCH] thunderbolt: clamp downstream PCIe link speed to tunnel capacity`
   - Reference our investigation as motivation
   - Propose the gen-mapping + clamp logic above
4. **Maintainer engagement**: Mika Westerberg (`mika.westerberg@linux.intel.com`)
   maintains drivers/thunderbolt. He has deep familiarity with TB
   internals and PCIe interactions.

Likely review feedback to expect:
- "Should this be unconditional or behind a module param?" → propose
  param with default-on
- "What about TB5 asymmetric mode edge cases?" → handle in mapping table
- "Does this break setups where users want max gen anyway?" → only
  affects setups with rate mismatch; opt-out via module param available
- "Why not in PCI core via quirks?" → topology-not-device-ID; respond
  with the layer analysis above

## Memory + cross-references

- **Memory entry**: `feedback_lspci_lnkcap_tb_virtual.md` — TB virtualizes
  PCIe registers, measure with nvbandwidth before investigating
- **Memory entry**: `feedback_no_bios_options_nuc15.md` — fixes must be
  in software (kernel/driver/userspace), no BIOS toggles available
- **Lever catalog**: Lever V-prime spec entry (kernel TB driver patch)
- **Lever catalog**: Lever U demoted to "defensive fallback for older kernels"
- **Hypothesis ledger**: H17 partially-resolved (port B Gen3+bit5 stable)
- **Hypothesis ledger**: H18 falsified (no Gen1 ceiling to raise)
- **Methodology**: `docs/cuda-bandwidth-methodology.md` (how to verify)
- **Topology**: `docs/tb4-pcie-topology.md` (diagram + measured ground truth)

---

## Port asymmetry on this hardware (2026-05-07) — Linux-specific

On this NUC 15 Pro+, our Linux stack succeeds at Gen3+bit5 on TB4 port B
(root port `00:07.2`) but fails on TB4 port A (root port `00:07.0`) with
36 GSP_LOCKDOWN_NOTICE, even with full software stack (UncMaskClear +
passive watchdog + M-recover scaffold + BDF-agnostic services). n=2
each.

**The asymmetry is Linux-specific, NOT hardware-specific.** User has
empirically confirmed Windows/WSL successfully runs llama3.1:8b on
port A on this same hardware. Same hardware, different OS, different
outcome → the failure mechanism is in our Linux stack or NVIDIA's
open driver, not in the NUC silicon/firmware/PCIe routing.

Candidate Linux-specific causes (none yet investigated as of 2026-05-07):
1. **TB tunnel setup timing** — Linux probes nvidia before port-A
   tunnel fully quiescent (Windows may delay until ready)
2. **bridge-link-cap.service ordering** — runs before TB tunnel
   settled on port A specifically
3. **Open driver fragility vs closed-driver tolerance** — Windows
   closed driver may retry rmInit gracefully where ours hits LOCKDOWN
   cascade
4. **NUC firmware ACPI/DSM differences per port** — Windows may
   invoke port-specific init Linux skips
5. **Cmdline parameter interaction** — `thunderbolt.host_reset=false`,
   `thunderbolt.clx=0`, etc. may affect port A specifically
6. **PCIe enumeration order edge case** — different bus topology per
   port causes Linux to hit a corner

Implication for Lever V-prime upstream RFC: the rate-mismatch class
of bug is still real and broadly relevant. But the per-port asymmetry
on this NUC is a separate Linux-specific issue (likely affecting other
users too) that V-prime alone may not fix. Frame V-prime as "fixes
the rate-mismatch class"; mention port-specific timing/ordering issues
as a related-but-separate workstream.

Production guidance for this NUC: use port B until Linux-specific port-A
cause is identified.
