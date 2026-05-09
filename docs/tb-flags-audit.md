# Thunderbolt / boltctl Flags Audit

Read-only audit of all available thunderbolt/USB4 configuration surfaces
to determine if any existing flag, parameter, or sysfs property can
change PCIe payload allocation, link speed cap, or tunnel parameters
on the AORUS RTX 5090 + NUC 15 Pro+ TB4 stack.

**Date:** 2026-05-07
**Kernel:** 6.19.14-200.fc43.x86_64
**bolt version:** 0.9.11
**Hardware:** Intel Meteor Lake-P "Gen14" TB4 (host) + Intel JHL9480 Barlow Ridge TB5 80G (AORUS box)

## TL;DR

**No existing flag, sysfs property, boltctl setting, or module parameter
can change PCIe payload allocation in the TB tunnel.** All
configuration surfaces are either read-only, security/authentication-
focused, or affect orthogonal concerns (low-power states, networking).
The TB tunnel PCIe cap logic is hardcoded in the kernel TB driver
(`drivers/thunderbolt/`) at tunnel establishment, with no parameterization.

This hardens the case for **Lever V-prime** (kernel TB driver patch) as
the architectural destination — there's currently no way to express the
needed cap via existing flags. See
`docs/tb-pcie-cap-architecture.md`.

Three module parameters are *worth experimental testing* for marginal
gains, listed in "Conditional follow-ups" below, but none can lift the
tunnel ceiling above its current TB4-saturated state.

## Phase A — boltctl (userspace TB daemon)

`boltctl` is a security/authentication policy daemon. It does NOT
control tunnel-level configuration.

### Subcommands available

| Subcommand | Purpose | Tunnel-config impact |
|---|---|---|
| `list` | Show connected/stored devices | Read-only |
| `info <uuid>` | Detailed device info | Read-only |
| `domains` | Active TB domains | Read-only |
| `monitor` | Watch for changes | Read-only |
| `authorize <uuid>` | Authorize a device | No PCIe impact |
| `enroll <uuid>` | Authorize + store | No PCIe impact |
| `forget <uuid>` | Remove from store | No PCIe impact |
| `power <state>` | Force power configuration | Power state only |
| `config` | Get/set properties | **See below** |

### `boltctl config` — writable properties

Of all bolt-exposed properties, only 4 are writable (`rw`):

| Property | Type | Default | Affects PCIe? |
|---|---|---|---|
| `global.auth-mode` | enabled / disabled | enabled | No (auth policy) |
| `domain.bootacl` | UUID list | `[]` | No (pre-boot device whitelist) |
| `device.policy` | auto / iommu / manual | iommu (for AORUS) | No (auth policy) |
| `device.label` | string | "" | No (cosmetic) |

**Verdict:** None affect bandwidth, link speed, or tunnel capacity.

### Read-only properties (informational only)

- `device.linkspeed` is "described" but the bolt daemon doesn't actually
  expose its value (returns opaque pointer string `((BoltLinkSpeed*) 0x...)` —
  bolt API formatting bug). Real values live in sysfs (rx/tx_speed, rx/tx_lanes).
- `domain.iommu = no` (we have `iommu=off` cmdline, confirmed)
- `domain.security = user` (no BIOS-level TB security restriction)
- `device.generation = 4` (TB4 / USB4 v1)
- `device.authflags = boot` (auto-authorized at boot via bootacl)

## Phase B — TB sysfs surfaces

### Per-device sysfs (`/sys/bus/thunderbolt/devices/<id>/`)

All attributes exposed:

| Attribute | Writable? | What it controls |
|---|---|---|
| `authorized` | yes (root) | Device authorization state (1=auth, 0=deauth). NOT a config knob. |
| `boot` | no | Was device authorized via boot ACL flag |
| `device` | no | TB device-ID (informational) |
| `device_name` | no | Vendor-supplied name |
| `generation` | no | TB version (4 here) |
| `nvm_authenticate` | yes (root) | TB controller firmware update path. NOT for tuning. |
| `nvm_version` | no | Current TB controller firmware version (62.2 for AORUS) |
| `rx_lanes` / `tx_lanes` | no | Negotiated lanes (2 each) |
| `rx_speed` / `tx_speed` | no | Negotiated lane speed (20.0 Gb/s each) |
| `unique_id` | no | TB device UUID |
| `vendor` / `vendor_name` | no | Vendor info |

**Verdict:** Zero configurable items related to bandwidth or PCIe.

### Per-domain sysfs (`/sys/bus/thunderbolt/devices/domain*/`)

| Attribute | Writable? | What it controls |
|---|---|---|
| `deauthorization` | yes | Whether deauthorization is allowed |
| `iommu_dma_protection` | no | DMA protection state (0 here, expected with `iommu=off`) |
| `security` | no | BIOS-set security level (`user` here) |

**Verdict:** Security-only, no tunnel config.

### usb4_port sysfs (`/sys/.../usb4_portN/`)

Only one attribute: `link = none`. No tunables.

### NHI sysfs (`/sys/bus/pci/drivers/thunderbolt/0000:00:0d.{2,3}/`)

Standard PCI device attributes only (aer, ari_enabled, dma_mask_bits,
local_cpus, msi_bus, etc.). No TB-specific tunables exposed at the
NHI level.

## Phase C — DebugFS

`/sys/kernel/debug/thunderbolt/` exists with rich content:

```
0-0/   1-0/   1-0:1.1/   1-1/
  ├─ drom (Device ROM)
  ├─ regs (router registers)
  └─ portN/
       ├─ counters (port statistics)
       ├─ path (TB tunnel routing tables)
       └─ regs (port registers)
```

The AORUS device shows 24 ports (port0..port23) each with
counters/path/regs.

### Write capability

```
$ ls -la /sys/kernel/debug/thunderbolt/1-1/regs
-r--------  ...
$ ls -la /sys/kernel/debug/thunderbolt/1-1/port18/path
-r--------  ...
```

**Read-only.** Write capability is gated by `CONFIG_USB4_DEBUGFS_WRITE`,
which is **NOT SET** in this kernel:

```
$ grep CONFIG_USB4_DEBUGFS /boot/config-$(uname -r)
# CONFIG_USB4_DEBUGFS_WRITE is not set
```

Enabling it requires recompiling the kernel — and even then, writing
arbitrary register values would require deep TB internals knowledge.
Not a reasonable lever.

**Verdict:** DebugFS is informational-only on stock Fedora 43 kernels.

## Phase D — Kernel CONFIG_THUNDERBOLT_* / CONFIG_USB4_*

```
$ grep -E "^CONFIG_(THUNDERBOLT|USB4)" /boot/config-$(uname -r)
CONFIG_USB4=m
CONFIG_USB4_NET=m
```

Only two options enabled:
- `CONFIG_USB4=m` — TB/USB4 driver (necessary)
- `CONFIG_USB4_NET=m` — XDomain networking (orthogonal to PCIe)

`CONFIG_USB4_DEBUGFS_WRITE` is OFF (would gate debugfs writes).

No CONFIG_USB4_* options are available for PCIe tunnel tuning.

**Verdict:** Kernel build offers no additional configuration surface
beyond what the runtime module exposes.

## Phase E — Module parameters (semantics deep-dive)

All 8 parameters of the `thunderbolt` module:

| Param | Default | Current | Description (modinfo) | Effect on PCIe payload? |
|---|---|---|---|---|
| `clx` | true | **N** (forced via cmdline) | Allow low-power states on high-speed lanes | No (PM only) |
| `xdomain` | true | Y | Allow XDomain protocol | No (networking only) |
| `start_icm` | false | N | Start ICM firmware | No (Apple/legacy mode) |
| `dprx_timeout` | 12000 | 12000 | DisplayPort RX timeout (ms) | No (DP only) |
| `dma_credits` | 14 | 14 | Custom credits for DMA tunnels | **Possible** (see follow-ups) |
| `bw_alloc_mode` | true | Y | Enable bandwidth allocation mode if supported | **Possible** (USB4 v2.0 feature) |
| `asym_threshold` | 45000 | 45000 | Threshold (Mb/s) to switch Gen 4 link symmetry | No (TB5 only; our link is TB4) |
| `host_reset` | true | **N** (forced via cmdline) | Reset USB4 host router | **Possible** (cleaner negotiation) |

All parameters are runtime read-only (`-r--r--r--`) — changing requires
either module reload (disconnects all TB devices) or cmdline change +
reboot.

### Conditional follow-ups (worth experimental testing)

These three are the only candidates that *could* affect PCIe bandwidth.
Even successful tuning would likely yield marginal (≤10%) improvements,
not break the TB4 ceiling.

1. **`thunderbolt.host_reset=true`** (revert from current `=false`).
   Default is true; we explicitly forced false early in the project to
   avoid disrupting the eGPU during initial setup. Reverting may allow
   cleaner tunnel renegotiation at boot. Risk: brief TB disconnect at
   boot. Test cost: one cmdline change + reboot.

2. **`thunderbolt.dma_credits=<larger>`** (e.g., 28 or 64). Default 14
   credits affect DMA tunnel buffer depth. Larger may improve bursty
   throughput at TB4 saturation. Speculative — no documentation on
   higher-value behavior. Test cost: one cmdline change + reboot.

3. **`thunderbolt.bw_alloc_mode=N`** (disable USB4 v2.0 BW allocation).
   Default true; only takes effect if both endpoints support USB4 v2.0.
   Our host is USB4 v1.0 (TB4) so this is likely a no-op already. But
   if the AORUS box (USB4 v2.0 capable) is requesting v2.0 BW allocation
   while host can't honor it, disabling might simplify negotiation.
   Speculative.

None will lift the tunnel above TB4 spec ceiling (~32 Gbps PCIe payload).

## Phase F — Cmdline state at audit time

```
thunderbolt.host_reset=false      ← deviates from default
pcie_aspm.policy=performance       ← orthogonal (PCIe ASPM, not TB)
thunderbolt.clx=0                 ← deviates from default
pcie_port_pm=off                   ← orthogonal (PCIe port PM)
iommu=off                          ← orthogonal (Lever T)
intel_iommu=off                    ← orthogonal (Lever T)
```

Two TB-related cmdline overrides: `host_reset=false` and `clx=0`.
Both were added during the project for stability reasons. The
follow-ups in Phase E include reverting `host_reset`.

## Audit conclusion

**Existing flag surface offers NO mechanism to:**
- Change PCIe gen/speed allocation within the TB tunnel
- Override the TB driver's hardcoded gen-mapping for tunnel setup
- Tune the downstream PCIe link speed cap (LnkCtl2 Target Link Speed)

The needed logic — "given a TB tunnel of this version + mode, clamp
downstream PCIe LnkCtl2 to a matching gen and set Hardware Autonomous
Speed Disable" — does not exist anywhere in the userspace, sysfs,
debugfs, or module-parameter surface. It must be added to the kernel
TB driver (Lever V-prime per `docs/tb-pcie-cap-architecture.md`).

Three module parameters MIGHT yield marginal gains if reverted to
their defaults, but cannot lift the TB4 saturation ceiling. Worth
testing if a definitive 5-10% bandwidth improvement is desired
(separate from the Lever V-prime upstream work).

## Recommended next steps

1. **Lever V-prime** (kernel patch) is the architectural answer —
   confirmed no existing surface bypasses it.
2. **Optional cheap experiments** (cmdline + reboot, ~5 min each):
   - revert `thunderbolt.host_reset=true` (back to default)
   - try `thunderbolt.dma_credits=64`
   - validate via nvbandwidth before/after
3. **Defer** module-reload-based experiments (they disconnect the
   eGPU mid-session) — only do at planned reboot points.

## See also

- `docs/tb-pcie-cap-architecture.md` — why kernel TB driver is the
  correct layer for the cap
- `docs/cuda-bandwidth-methodology.md` — how to validate any change
  with nvbandwidth
- `docs/tb4-pcie-topology.md` — full topology diagram + measured
  ground truth
- Memory `feedback_lspci_lnkcap_tb_virtual.md` — virtual-bridge
  spoofing rule
- Memory `feedback_tb_pcie_cap_architecture.md` — correct layer rule
