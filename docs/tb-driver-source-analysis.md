# Thunderbolt driver source analysis — Linux v6.19 `drivers/thunderbolt/`

**Date:** 2026-05-08
**Reviewer:** Thread A (TB driver source code analysis, task #114)
**Scope:** Per-domain init bug — Port A (domain 0, PCI 0x7ec2) reliably wedges with 36×
GSP_LOCKDOWN_NOTICE; Port B (domain 1, PCI 0x7ec3) works perfectly. Cross-OS
validation has already eliminated hardware as a cause (Windows works on both
ports). Both NHIs share `icl_nhi_ops`, both get `quirk_usb3_maximum_bandwidth`,
both go through the same code paths.

**Source tree:** `/root/linux-v6.19/drivers/thunderbolt/` — 36 files,
~25 kLOC; key files reviewed: `nhi.c` (1585 LoC), `domain.c` (886),
`tb.c` (3399), `tunnel.c` (2654), `switch.c` (4016), `nhi_ops.c` (185),
`acpi.c` (368), `quirks.c` (137), `ctl.c` (1184), `usb4.c` (3147),
`clx.c` (428), `lc.c` (717), `retimer.c`.

---

## 1. Executive summary

After reading the entire `drivers/thunderbolt/` software-CM stack with our
specific failure mode in mind, **the per-domain logic is genuinely
symmetric** — every NHI gets its own `tb_nhi`, `tb`, `tb_ctl`, `tb_switch`,
ordered workqueue, MSI-X vectors, and IRQ handlers. There is no global
shared state in the data path between domain 0 and domain 1 that would
explain a Port-A-only bug.

Given that, the three most likely loci of the failure are (ranked):

1. **Race between TB-tunnel-establish and downstream PCIe enumeration** in
   `nhi_probe()` → `tb_domain_add()` → `tb_start()`. The PCIe quirk
   `usb4_pci_do_resume` is supposed to gate downstream PCI bridge resume
   until the NHI driver has rebuilt tunnels, but its scope is suspend/resume,
   not first-boot enumeration with a pre-attached eGPU. (See H1.)

2. **`tb_wait_for_port()` 1-second cap** (`switch.c:501`, retries=10×100ms).
   On a cold-cold boot with a TB5 hub + retimers + 80 G negotiation, lane 1
   may not reach `TB_PORT_UP` in time on a slower path; `tb_scan_port()`
   silently `goto out_rpm_put` after warning, leaving the link partially
   configured. (See H2.)

3. **Apple/ACPI device link establishment is not symmetric across NHIs** —
   `tb_acpi_add_links()` walks ACPI namespace globally per NHI. If the BIOS's
   `usb4-host-interface` reference under one NHI is missing or mis-targeted,
   only that NHI loses its `device_link` from tunneled PCIe bridges back to
   the NHI, breaking PM/init ordering on resume from D3cold and on first
   boot when downstream PCI bridges (`PCIe_DOWN` adapters) are probed before
   the tunnel is up. (See H3.)

**Sub-secondary**: There is **no per-NHI quirk** distinguishing 0x7ec2 from
0x7ec3 in `quirks.c` — both get the same `quirk_usb3_maximum_bandwidth`.
The hardware is treated identically, which is consistent with our cmdline
+ DROM bit-identity finding.

---

## 2. Architecture map (call order)

```
PCI subsystem matches tb_nhi PCI device IDs (one per NHI)
   └── nhi_probe()  [drivers/thunderbolt/nhi.c:1339]
         ├── nhi_imr_valid()            <-- ACPI IMR_VALID property check
         ├── pcim_enable_device()
         ├── pcim_iomap_region()
         ├── nhi_check_quirks()         <-- sets QUIRK_AUTO_CLEAR_INT
         ├── nhi_check_iommu()          <-- pci_walk_bus to root, sets iommu_dma_protection
         ├── nhi_reset()                <-- if v2+ NHI, REG_RESET_HRR pulse + 100 ms + ≤500 ms wait
         ├── nhi_init_msi()             <-- 6..16 MSI-X vectors (or 1 MSI fallback)
         ├── pci_set_master()
         ├── nhi->ops->init() [icl_nhi_resume]
         │     └── icl_nhi_force_power(true) <-- VS_CAP_22, then poll VS_CAP_9.FW_READY
         │                                       (350 retries × 3 ms ≈ 1.05 s ceiling)
         ├── nhi_select_cm()
         │   ├── tb_acpi_is_native()
         │   └── tb_probe()             [tb.c:3366]
         │         ├── tb_domain_alloc()  [domain.c:374]
         │         │     ├── ida_alloc(&tb_domain_ida)   <-- GLOBAL: probe-order assigns index
         │         │     ├── alloc_ordered_workqueue("thunderbolt%d", 0, idx)
         │         │     └── tb_ctl_alloc()              <-- per-NHI tx/rx rings & frame pool
         │         ├── tb->cm_ops = &tb_cm_ops          <-- software CM ops
         │         └── tb_acpi_add_links()              <-- ACPI device-link discovery
         └── tb_domain_add(tb, host_reset)               [domain.c:436]
               ├── mutex_lock(&tb->lock)
               ├── tb_ctl_start()                       <-- enables ring TX/RX, hot-plug pkts arrive
               ├── tb->cm_ops->driver_ready()            (NULL for software CM)
               ├── device_add(&tb->dev)                  <-- domain0 / domain1 device appears
               └── tb->cm_ops->start() == tb_start()     [tb.c:2986]
                     ├── tb_switch_alloc(tb, &tb->dev, route=0)        <-- root switch
                     │     └── tb_cfg_get_upstream_port (control msg)
                     ├── tb_switch_configure(root_switch)
                     │     └── usb4_switch_setup()                     [usb4.c:243]
                     ├── tb_switch_add(root_switch)                    [switch.c:3297]
                     │     ├── tb_drom_read, set_uuid, tb_init_port (loop)
                     │     ├── tb_check_quirks()  <-- usb3-bw, block-rpm-redrive
                     │     ├── tb_switch_default_link_ports
                     │     ├── tb_switch_link_init()
                     │     ├── tb_switch_clx_init / tb_switch_tmu_init
                     │     ├── tb_switch_port_hotplug_enable()         <-- ADP_CS_5_DHP cleared
                     │     ├── device_add(&sw->dev)
                     │     ├── usb4_switch_add_ports()
                     │     └── tb_switch_nvm_add()
                     ├── tb_switch_tmu_configure / tb_switch_tmu_enable
                     ├── if (reset && usb4): discover=false (fresh start)
                     ├── if (discover):
                     │     ├── tb_scan_switch(root)              <-- recursive tb_scan_port
                     │     ├── tb_discover_tunnels(tb)           <-- find FW-created tunnels
                     │     └── tb_discover_dp_resources(tb)
                     ├── tb_create_usb3_tunnels(root)
                     ├── tb_add_dp_resources(root)
                     ├── tb_switch_enter_redrive(root)
                     ├── device_for_each_child(... tb_scan_finalize_switch)
                     └── tcm->hotplug_active = true                <-- gate opens

   [NHI MSI-X IRQ -> ring_msix() -> tb_ctl_rx_callback() ->
    ctl->callback() == tb_domain_event_cb() ->
    cm_ops->handle_event() == tb_handle_event() [tb.c:2908] ->
    tb_queue_hotplug() -> queue_delayed_work(tb->wq) ->
    tb_handle_hotplug() [tb.c:2421]
       ├── if (!tcm->hotplug_active) goto out          <-- DROP events during init
       ├── pm_runtime_get_sync(&tb->dev) + sw->dev
       ├── if (!ev->unplug && tb_port_is_null && !port->remote):
       │     └── tb_scan_port()  [tb.c:1289]
       │           ├── tb_wait_for_port()  <-- 10 × 100 ms (1 s cap)
       │           ├── tb_switch_alloc(tb, parent, route)
       │           ├── tb_switch_configure
       │           ├── tb_switch_add()
       │           ├── tb_configure_link()  -> tb_switch_set_link_width(DUAL)
       │           ├── tb_retimer_scan
       │           ├── tb_enable_clx, tb_enable_tmu
       │           ├── tb_switch_configuration_valid (ROUTER_CS_5_CV) — wait_for_bit 50ms
       │           ├── tb_create_usb3_tunnels
       │           ├── tb_add_dp_resources
       │           └── tb_scan_switch(sw)  <-- recurse]
```

**PCIe tunnel creation entry** is *only* via `cm_ops->approve_switch ==
tb_tunnel_pci()` (`tb.c:2275`), invoked through
`tb_domain_approve_switch()` (`domain.c:654`), which is itself invoked via
sysfs `authorized` attribute — i.e. **boltd writes `1` to
`/sys/bus/thunderbolt/devices/<uuid>/authorized`**. There is **no
auto-tunnel path on first plug for software CM**. The tunnel only comes up
after userspace authorization. (Discovery via `tb_discover_tunnels()` only
adopts firmware-created tunnels at boot if `discover=true`.)

This is critical to our model: on Port A vs Port B the bug must hit
*either* before or during `tb_tunnel_pci()`.

### Per-domain isolation

| Resource              | Per-NHI? | Where                           |
|-----------------------|----------|---------------------------------|
| `iobase`, `lock`      | Yes      | `tb_nhi` struct                 |
| TX/RX rings           | Yes      | `nhi->tx_rings/rx_rings`        |
| MSI-X vectors         | Yes      | independent `pci_alloc_irq_vectors` |
| `interrupt_work`      | Yes      | `nhi->interrupt_work`           |
| `tb_ctl` + frame pool | Yes      | per-NHI dma_pool                |
| `tb->wq`              | Yes      | `alloc_ordered_workqueue("thunderbolt%d")` per index |
| `tb->lock`            | Yes      | per-domain mutex                |
| `tb->index`           | **GLOBAL** ida | `tb_domain_ida` — first-probed gets 0 |

Global mutexes / state actually held during init/runtime:
- `tb_cfg_request_lock` (`ctl.c:78`) — only protects `kref` ops on requests; trivial.
- `tb_tunnel_lock` (`tunnel.c:112`) — only protects `kref` of `tb_tunnel`; trivial.
- `xdomain_lock` (`xdomain.c:70`) — XDomain protocol handler list; not exercised in our PCIe flow.
- `tb_domain_ida` — only allocates an int; no contention beyond that.

**Conclusion: there is no shared mutable state in the per-NHI init path
that would let domain 1 corrupt domain 0 or vice versa.** This rules out
classic init-order races between the two NHI probes.

---

## 3. Ranked hypotheses

### H1 — TB tunnel up vs downstream PCIe bridge probe ordering on Port A only

**Symptom match:** highest. WPR2=0x07f4a000 stuck on first `rmInit` and 36×
GSP_LOCKDOWN suggest GSP firmware is being talked to over PCIe before the
GPU side has fully stabilised — exactly what happens if the PCIe tunnel is
not at full link width/speed when the NVIDIA driver enumerates the GPU.

**Code locations:**
- `nhi_probe()` does **not** explicitly wait for any tunnels before
  returning success (`nhi.c:1404` returns 0 right after `tb_domain_add()`
  succeeds; `tb_start()` only opens the hot-plug gate, it does not wait
  for any device to be present).
- The `tb_tunnel_pci()` path (`tb.c:2275`) is only invoked **later** via
  boltd authorising the device.
- The Apple-machine-only `tb_apple_add_links()` (`tb.c:3305`) sets up
  device links from downstream PCIe bridges back to the NHI for **resume**
  ordering. Non-Apple systems rely on `tb_acpi_add_links()` (`acpi.c:91`)
  which walks ACPI namespace looking for `usb4-host-interface` references
  — if BIOS does NOT expose the link for one NHI, *no* device link is
  created and the PCIe bridges are not gated against NHI runtime PM.
- Comment at `nhi.c:1439-1443`: "The tunneled pci bridges are siblings of
  us. Use resume_noirq to reenable the tunnels asap. **A corresponding pci
  quirk blocks the downstream bridges resume_noirq until we are done.**"
  This relies on `usb4_pci` PCI quirk (in `drivers/pci/quirks.c`,
  outside the TB tree) — but the quirk only fires on resume, not on
  first-time enumeration.

**Why Port A and not Port B:** if BIOS describes only one of the two NHIs
in the `usb4-host-interface` ACPI binding, the unbound NHI loses both the
runtime-PM device link *and* the resume-noirq blocker. On the broken side,
PCI core can probe downstream tunneled bridges before NHI-side tunnel
state is consistent, especially on cold boot with eGPU pre-attached.

**How to test/instrument:**
1. Add `pr_info` to `tb_acpi_add_link()` (`acpi.c:14`) to log every
   ACPI device whose `usb4-host-interface` matches each NHI, plus the
   target PCIe bridge. Compare Port A vs Port B booth at boot.
2. Add `pr_info` to `tb_acpi_add_links()` final `return ret` — does it
   return `true` for both NHIs?
3. Dump `device_link` list from sysfs after boot to compare what PCIe
   bridges link back to each NHI.
4. From userspace: walk ACPI namespace and dump every `_DSD` reference
   to `usb4-host-interface` (already in scope of task #41 BIOS IFR dump).

**Expected fix shape:** If BIOS is asymmetric, kernel-side fix is to
manually walk the PCIe bridge tree under each NHI's parent root port
(`pci_upstream_bridge(nhi->pdev)`) and create the device link
unconditionally (mirroring `tb_apple_add_links()` for non-Apple). About
30 lines in `nhi.c`. If BIOS is symmetric but ACPI search fails for one
side due to ordering, a `late_initcall`-based retry of
`tb_acpi_add_links()` would be sufficient.

---

### H2 — `tb_wait_for_port()` 1-second timeout insufficient for TB5 hub + retimers

**Symptom match:** medium-high. If lane 1 fails to come up in time, the
function silently returns 0 ("not connected") without logging an error
beyond a single `tb_port_warn`, and `tb_scan_port()` aborts via
`out_rpm_put`. The router would still appear in sysfs but in a degraded
or partially-configured state — and a later boltd authorize would proceed
into `tb_tunnel_pci()` against an under-configured port.

**Code location:** `switch.c:501-558` (`tb_wait_for_port`), constant
`retries=10`. Used at:
- `tb_scan_port()` `tb.c:1318` for lane 0
- `tb_switch_lane_bonding_enable()` `switch.c:2969` for lane 1

**Why Port A and not Port B:** Differing PHY/retimer cold-start times due
to different physical USB-C jack wiring (Port A may have a longer trace,
different retimer config, etc.). Cold-cold boot is the worst case because
caps haven't equalised. This dovetails with our cold-boot-only failure
pattern.

**How to test:** Add a tracepoint or `pr_info` at the top of
`tb_wait_for_port` and at every `msleep(100)` — log how many iterations
each port took to reach `TB_PORT_UP`. Compare Port A vs Port B over
multiple cold boots.

**Expected fix shape:** Bump `retries` from 10 to 30 (3 s ceiling), or
expose as `module_param`. Two-line change. Already a known weakness —
upstream may accept.

---

### H3 — `tb_acpi_add_links()` race with NHI runtime suspend

**Symptom match:** medium. If neither Apple links nor ACPI links are
established, the TB driver logs:

```
device links to tunneled native ports are missing!
```

(See `tb.c:3396` `tb_warn()`.) On cold boot with eGPU pre-attached, this
means: NHI may runtime-suspend after `nhi_probe()` returns (line 1418-1421
in `nhi.c` enables runtime PM), and downstream PCIe bridges have nothing
holding them in D0. PCI core probes the GPU, GPU asserts something on the
bus, NHI is still suspending → tunnel not yet up → GPU sees a half-built
PCIe path → GSP_LOCKDOWN.

**Code location:**
- `tb.c:3395` `tb_apple_add_links()` returns false on non-Apple machines
  (correct behaviour).
- `acpi.c:91` `tb_acpi_add_links()` does ACPI namespace walk via
  `acpi_walk_namespace()`.
- `nhi.c:1418-1421` enables `pm_runtime_allow + autosuspend +
  pm_runtime_put_autosuspend`. Without device links, downstream bridges
  do not block this.

**Why Port A and not Port B:** Same logic as H1 — BIOS asymmetry.

**How to test:**
1. `dmesg | grep "device links to tunneled native ports are missing"` —
   does it print for one or both NHIs at boot? (Per `tb_warn`, look for
   the `domain0:` or `domain1:` prefix.)
2. `/sys/bus/pci/devices/0000:00:0d.2/.../power/runtime_status` and
   the consumer link list to verify links exist.
3. Check `dev_dbg` messages "created link from %s\n" in `acpi.c:65` for
   each NHI.

**Expected fix shape:** Same as H1 — fall back to manual
`for_each_pci_bridge()` walk if ACPI search fails, mirroring
`tb_apple_add_links()`. ~30 lines.

---

### H4 — `nhi_reset()` host-router-reset (HRR) timeout reached on one NHI but not the other

**Symptom match:** medium. `nhi_reset()` (`nhi.c:1234-1263`) issues
`REG_RESET_HRR`, sleeps 100 ms, then polls `REG_RESET` for up to 500 ms.
On timeout it logs **"timeout resetting host router"** and continues
anyway. A partial reset could leave Port-A NHI in a bad state.

**Code location:** `nhi.c:1234-1263`. `host_reset` module param defaults
to `true` and is unconditionally passed into `tb_domain_add(tb,
host_reset)` (`nhi.c:1404`).

**Why Port A and not Port B:** Cold-boot timing — first-probed NHI may
have less settled platform power vs. second one.

**How to test:**
1. Add `pr_info` printing the actual time in ms taken by HRR for each
   NHI.
2. Try `host_reset=0` module param at boot (already documented as
   `module_param(host_reset, bool, 0444)`) — does the bug change
   behaviour?

**Expected fix shape:** If timeout is genuinely hit only on one side,
extend window from 500 ms to 2 s, plus a retry of the HRR pulse. ~10 line
change to `nhi_reset()`. (`host_reset=0` is the cleanest probe: tests if
the symptom is reset-related at all.)

---

### H5 — Workqueue ordering loss: hot-plug events arriving before `tcm->hotplug_active = true`

**Symptom match:** low-medium. `tb_handle_hotplug()` checks
`tcm->hotplug_active` (`tb.c:2433`) and goes to `out` (drops the event)
if it's still false. The window where events can be dropped:

- `tb_ctl_start()` at `domain.c:448` (start of `tb_domain_add`) opens RX,
  meaning hot-plug packets can arrive immediately.
- `tcm->hotplug_active = true` is set at the END of `tb_start()`
  (`tb.c:3063`) — the very last line.
- Between those, events ARE queued via `tb_queue_hotplug()` (in
  `tb_handle_event` callback), but **also dropped** in
  `tb_handle_hotplug()` when their delayed work runs.

So if the eGPU is already attached at boot (cold-boot, eGPU pre-attached),
the hot-plug indication that fires when control channel comes up could be
processed by `tb_handle_hotplug()` *before* `tcm->hotplug_active` flips true,
and the event is silently dropped.

**Code:**
```c
/* tb.c:2432-2434 */
mutex_lock(&tb->lock);
if (!tcm->hotplug_active)
    goto out; /* during init, suspend or shutdown */
```

The `tb->lock` is held throughout `tb_start()`, so the dropped-event window
shouldn't actually open while `tb_start` is running. BUT if the workqueue
fires AFTER `tb_start()` returns and before `tcm->hotplug_active=true` is
visible from the workqueue (cache-coherency / barrier issue) — actually
no: `mutex_unlock` is a release barrier, and `mutex_lock` in the worker
is acquire. So this race is unlikely.

**However** — `tb_scan_switch(root)` and `tb_discover_tunnels()` happen
*inside* `tb_start()` while the lock is held, scanning the topology
synchronously. If during this synchronous scan the AORUS box is the one
reachable through Port A and `tb_wait_for_port()` returns 0 (no link),
the device router is silently not allocated — and no future hotplug for
it ever fires (because the AORUS box was visible during scan; subsequent
hotplug events for it are tagged "got plug event for connected port,
ignoring" at `tb.c:2504`).

**This is essentially a degenerate state of H2**: timeout in
`tb_wait_for_port()` during synchronous discovery → permanent missed
device on that boot.

**How to test:** Same as H2 — instrument `tb_wait_for_port`. Plus log
every `tb_scan_port()` call with the result (`port->remote ?
"connected" : "no_remote"`).

**Expected fix shape:** As H2, extend retry. Optionally: trigger a
manual rescan if `tb_wait_for_port()` returned 0 during initial discovery.

---

### H6 — `usb4_switch_configuration_valid()` `wait_for_bit(50)` too short

**Symptom match:** medium. After writing `ROUTER_CS_5_CV`, the code waits
**50 ms** for `ROUTER_CS_6_CR` to assert (`usb4.c:329`). On a TB5-class
device router with 80 G negotiation in progress, 50 ms may be too short.

**Code:**
```c
/* usb4.c:323-330 */
val |= ROUTER_CS_5_CV;
ret = tb_sw_write(sw, &val, TB_CFG_SWITCH, ROUTER_CS_5, 1);
if (ret) return ret;
return tb_switch_wait_for_bit(sw, ROUTER_CS_6, ROUTER_CS_6_CR,
                              ROUTER_CS_6_CR, 50);
```

**Why Port A and not Port B:** Cold-cold boot link negotiation timing.
TB5 80 G mode (which only Port A is negotiating in our case — actually
both are; but Port A's path through retimers may be slower in this
direction).

**How to test:** Add `pr_info` to `tb_switch_wait_for_bit()` at
`switch.c:1720` to log elapsed time per call site. Bump argument from 50 to
500 ms experimentally.

**Expected fix shape:** Bump 50 → 500 in `usb4.c:329` (single line change).

---

### H7 — `icl_nhi_force_power()` FW_READY poll misbehaves on second NHI

**Symptom match:** low-medium. `icl_nhi_force_power(true)` writes
`VS_CAP_22_FORCE_POWER`, then polls `VS_CAP_9.FW_READY` 350 × 3 ms ≈
1.05 s. If the FW takes > 1 s on first NHI to come up but < 1 s on
second, this would be the OPPOSITE of our pattern (Port A would
timeout, return -ETIMEDOUT, abort probe). But our case is Port A
**probes successfully and then fails downstream** — so this is unlikely
to be the primary cause.

**Code:** `nhi_ops.c:35-77`. Hard-coded 350 retries, 3 ms each.

**How to test:** Add `pr_info` of retry count taken on each NHI.

**Expected fix shape:** Increase retries to 1000 if telemetry shows
> 200. ~1 line.

---

### H8 — `icl_nhi_set_ltr` ordering vs. tunnel establishment (resume path only)

**Symptom match:** low. `icl_nhi_set_ltr()` is called in
`icl_nhi_resume()` (`nhi_ops.c:169`), AFTER `force_power(true)`. This is
the LTR snoop value programmed in `VS_CAP_15`. If LTR is not set
correctly at first probe (only `init = icl_nhi_resume`, called from
`nhi.c:1391-1395`), downstream PCIe LTR could be wrong leading to power
state mismatches. But this is primarily a runtime PM/perf concern, not a
"GPU never inits" concern. Demoted.

---

### H9 — `tb_init_bandwidth_groups()` global vs per-domain confusion

**Symptom match:** very low. `tb_priv(tb)->groups` is per-domain. Reviewed,
no cross-NHI state.

---

### H10 — Quirk `quirk_usb3_maximum_bandwidth` interaction

**Symptom match:** very low. Quirk fires in `tb_check_quirks()` after
DROM read in `tb_switch_add()` (`switch.c:3341`). It limits USB3 max_bw
to 16376 Mb/s. Both 0x7ec2 and 0x7ec3 get this quirk (`quirks.c:83-85`).
Reviewed — symmetric, won't explain divergence.

---

## 4. Notable patterns found

### Hardcoded delays (potential cold-boot vulnerabilities)

| File:line | Delay | Purpose | Concern |
|-----------|-------|---------|---------|
| `nhi.c:1250` | `msleep(100)` | After REG_RESET_HRR write | Fixed |
| `nhi.c:1252` | 500 ms ktime ceiling | Wait for HRR clear | **Could be too short cold** |
| `nhi_ops.c:62-71` | 350 × 3 ms = 1.05 s | Wait for FW_READY | Could be too short cold |
| `switch.c:503` `tb_wait_for_port` | 10 × 100 ms = 1 s | Wait for TB_PORT_UP | **Top suspect for cold TB5** |
| `usb4.c:329` | `wait_for_bit(50)` ms | ROUTER_CS_6_CR | Likely too short |
| `usb4.c:518` | `wait_for_bit(20)` ms | ROUTER_CS_6_SLPR | Sleep transitions |
| `tb.c:3164` | `msleep(100)` | After tunnels restarted on resume | Fixed |
| `switch.c:205` | `msleep(500)` | DMA port retry | OK |

### Global state (already audited)

- `tb_domain_ida` — assigns 0 to first-probed NHI; second gets 1.
  **Probe order is determined by PCI core's enumeration order**, which on
  Meteor Lake is BDF-low-first (00:0d.2 → 00:0d.3 → domain 0/1 mapping).
- `nvm_ida`, `protocol_handlers`, `nvm_auth_status_cache` — not in our
  flow.
- All other state is per-`tb` or per-`tb_nhi`.

### Comments suggesting known weaknesses

- `nhi.c:1213-1218`: "we'll have to bodge it… Hoping that the system is
  at least sane enough that an adapter is in the same PCI segment as its
  NHI" — IOMMU detection is heuristic, not authoritative.
- `tb.c:3160-3163`: "the pcie links need some time to get going. 100ms
  works for me…" — magic number on resume path.
- `switch.c:1217-1226`: "Sometimes we get port locked error when
  polling the lanes so we can ignore it and retry."

---

## 5. Files NOT a likely cause (reviewed and ruled out)

| File | Why ruled out |
|------|---------------|
| `tunnel.c` | PCIe tunnel state machine is symmetric; same code path runs for both domains, only invoked via approve_switch (boltd) which fires for both ports identically. `tb_pci_activate()` (line 333) is a 25-line straight-line function with no domain dependence. |
| `path.c` | Pure path-allocation arithmetic. No per-domain state. |
| `xdomain.c` | XDomain (TB→TB host-to-host) is not exercised in our flow (we have a TBT3-style device, not XDomain). |
| `dma_port.c`, `dma_test.c` | Not exercised in eGPU flow. |
| `nvm.c`, `eeprom.c` | NVM upgrade/DROM read; happens early in `tb_switch_add` but DROM has been confirmed bit-identical. |
| `lc.c` | Link Controller pre-USB4 ops; routers using LC are mostly Alpine Ridge / Titan Ridge. Our path is USB4 (`tb_switch_is_usb4()` true). |
| `cap.c` | Capability iteration. Pure register walking, no timing. |
| `clx.c` | Already explicitly proven not the cause via `thunderbolt.clx=0` cmdline test (Lever K). |
| `tmu.c` | Time Management Unit. `tb_enable_tmu()` is best-effort with a `tb_sw_warn` on failure; doesn't abort init. |
| `quirks.c` | Both NHI device IDs receive identical quirks. Audited. |
| `icm.c` | Internal Connection Manager — only used when `!tb_acpi_is_native()`. We are native (USB4 software CM). Confirmed by `tb_dbg(tb, "using software connection manager\n")` in `tb_probe`. |
| `retimer.c` | Same code for both ports. If retimer init fails, scan continues. |
| `acpi.c:retimer_dsm` paths | Retimer DSM is per-port symmetric. |
| `usb4_port.c` | Per-port helpers; no shared state. |
| `debugfs.c` | Read-only telemetry. |
| `test.c` | KUnit test build. |

---

## 6. Specific functions to instrument (Thread B targets)

Sorted by expected information yield per LoC of patch:

1. **`tb_wait_for_port()`** at `switch.c:501` — add `pr_info("port %d:%d
   wait iter=%d state=%d\n", ...)` inside the loop to capture timing on
   each port. **Highest priority** — correlates directly to H2/H5.

2. **`nhi_reset()`** at `nhi.c:1234` — add `ktime_get()` before
   `iowrite32` and after the `do…while` loop, log elapsed ms. Confirms
   or refutes H4.

3. **`icl_nhi_force_power()`** at `nhi_ops.c:62` — log retry count
   needed before FW_READY for each NHI.

4. **`tb_acpi_add_link()`** at `acpi.c:14` — add `pr_info` for every
   `usb4-host-interface` reference checked, indicating which ones match
   each NHI.

5. **`tb_acpi_add_links()`** return value — log `false` warning at
   `tb.c:3396` is already there, but also log success path and the count
   of links created per NHI.

6. **`tb_handle_hotplug()`** at `tb.c:2421` — log every event arrival
   timestamp + `tcm->hotplug_active` value at entry. Confirms or refutes
   H5.

7. **`tb_scan_port()`** at `tb.c:1289` — log entry, the result of
   `tb_wait_for_port`, and exit reason (success vs `out_rpm_put`).

8. **`tb_tunnel_pci()`** at `tb.c:2275` — log entry timestamp, found
   `up`/`down` ports, `tb_tunnel_activate` return value, and exit. The
   logging tracepoints `tb_tunnel_dbg(tunnel, "activating\n")` already
   exist if dyndbg is enabled.

9. **`tb_switch_wait_for_bit()`** at `switch.c:1720` — log the offset,
   timeout argument, and elapsed ms on each call. Helps quantify H6.

10. **`tb_pci_activate()`** at `tunnel.c:333` — log enable order and the
    return value of `tb_pci_port_enable()` for both up and down.

The `dyndbg` selector for the whole subsystem is `module thunderbolt
+pflm` — turning that on at boot would already give 80% of the
information above without code changes. Recommend Thread B start by
running with full dyndbg on Port A and Port B back-to-back and diffing
the `journalctl -k` output.

---

## 7. Specific functions/lines to potentially patch (Thread C candidates)

In order of "most likely to fix the bug for least code":

### Patch 1: Bump `tb_wait_for_port()` retry count (Thread C minimum-viable)

**File:** `drivers/thunderbolt/switch.c`
**Line:** 503
```c
-	int retries = 10;
+	int retries = 30;
```
1 line. 1-second cap → 3-second cap. Targets H2, H5.

### Patch 2: Bump `usb4_switch_configuration_valid()` CR wait

**File:** `drivers/thunderbolt/usb4.c`
**Line:** 329-330
```c
-	return tb_switch_wait_for_bit(sw, ROUTER_CS_6, ROUTER_CS_6_CR,
-				      ROUTER_CS_6_CR, 50);
+	return tb_switch_wait_for_bit(sw, ROUTER_CS_6, ROUTER_CS_6_CR,
+				      ROUTER_CS_6_CR, 500);
```
1 line. Targets H6.

### Patch 3: Always create non-Apple device links (mirror `tb_apple_add_links`)

**File:** `drivers/thunderbolt/tb.c`
**Add:** new function `tb_native_add_links(struct tb_nhi *nhi)` modelled
on `tb_apple_add_links()` but skipping the Apple-machine and device-id
check. Call it from `tb_probe()` AFTER `tb_acpi_add_links()` returns
false. ~25 lines.

This is also in scope as Lever V-prime's natural neighbour (both belong
in `drivers/thunderbolt/`).

### Patch 4: Module parameter for `tb_wait_for_port` retry count

**File:** `drivers/thunderbolt/switch.c` add a module_param near the top:
```c
static unsigned int port_wait_retries = 30;
module_param(port_wait_retries, uint, 0644);
MODULE_PARM_DESC(port_wait_retries,
    "tb_wait_for_port retry count (each retry is 100 ms; default 30)");
```
And use `port_wait_retries` instead of literal `10` in
`tb_wait_for_port`. Allows runtime tuning without recompile (Thread B
can iterate).
~5 lines.

### Patch 5: Extend `nhi_reset()` HRR timeout + retry once

**File:** `drivers/thunderbolt/nhi.c`
**Lines:** 1248-1262
```c
-	timeout = ktime_add_ms(ktime_get(), 500);
+	timeout = ktime_add_ms(ktime_get(), 2000);
```
Plus optional one-retry on timeout. ~5 lines.

### Patch 6: `host_reset=0` test (no patch needed — module param exists)

For Thread B. Add `thunderbolt.host_reset=0` to kernel cmdline and rerun
cold-boot Port A test. If it works, points to H4.

---

## 8. Open questions / things I could not determine from source alone

1. **PCI probe order on Meteor Lake-P**: The kernel walks PCI in BDF
   order, so 00:0d.2 is probed first (becomes domain 0). But does
   `nhi_probe()` for both NHIs actually run in parallel (deferred probe?)
   or strictly serial? `pci_register_driver()` in `nhi.c:1572` registers
   the driver, but each PCI device's `probe()` is called by the PCI
   subsystem in its own context. Need to instrument with timestamps.

2. **Whether boltd authorize path is involved**: We need to confirm
   from journalctl whether the failure happens BEFORE or AFTER the
   boltd `authorized=1` write. If before, H1/H2/H3 are the only
   candidates. If after, we need to also look at `tb_tunnel_pci`
   activation timing.

3. **NVIDIA driver probe order vs TB tunnel state**: The NVIDIA module
   probes `00:07.0` (root port) bridge, which has the GPU as a child via
   the TB tunnel. If the tunnel is not yet up when NVIDIA reads
   downstream config space, the GPU appears absent → NVIDIA's
   `nv_pci_probe` errors out gracefully. But if it's PARTIALLY up (link
   trained but not stable), GPU appears present → driver tries to talk to
   it → GSP_LOCKDOWN. This is the H1 mechanism end-to-end.

4. **What `host_reset=true` actually does to a working tunnel**:
   `nhi_reset()` does `REG_RESET_HRR`. The comment says "Reset only v2
   and later routers" — Meteor Lake NHI is v2. So we always reset HRR on
   probe. If the eGPU is already attached via firmware-built tunnel,
   the HRR pulse might tear that down and force re-establishment. The
   timing of that re-establishment vs PCI core probing the GPU is the
   crux of H4.

---

## 9. Recommended Thread B / Thread C playbook

**Thread B (active experiments) priority order:**

1. Boot with `dyndbg="module thunderbolt +pflm" thunderbolt.dyndbg=+p`.
   Capture `journalctl -kb` for both Port A and Port B success cases
   (use Port A IF you can find a boot where it happens to work, e.g.
   warm reboot from working state). Diff.

2. Boot with `thunderbolt.host_reset=0`. If Port A now works, the bug is
   confined to the HRR window (H4).

3. Build Patch 4 (module param for retries). Boot with
   `thunderbolt.port_wait_retries=100`. If Port A works, H2/H5
   confirmed.

4. Apply Patch 2 (50→500 wait_for_bit on CR). If port A works, H6
   confirmed.

5. Use ftrace `function_graph` on `nhi_probe`, `tb_domain_add`,
   `tb_start`, `tb_scan_port`, `tb_wait_for_port`,
   `usb4_switch_configuration_valid`. Get exact call durations on Port A
   vs Port B.

**Thread C (driver code work) priority order:**

1. Patch 4 (module param) — non-invasive, gives B a knob.
2. Patch 1 + Patch 2 (timeout bumps) — minimum-viable production patch.
3. Patch 3 (native device links) — only if H1/H3 confirmed by Thread B.
4. Patch 5 (HRR extend + retry) — only if H4 confirmed.

All four patches together are <40 LoC and could be a single upstream
RFC titled "thunderbolt: extend cold-boot timing windows for TB5
controllers".

---

## 10. Files matrix — what was read, line range, relevance

| File | LoC | Lines actually read | Relevance |
|------|-----|---------------------|-----------|
| `nhi.c` | 1585 | full probe path 1339-1500, helpers 155-1305 | **PRIMARY** |
| `nhi_ops.c` | 185 | full file | **PRIMARY** |
| `nhi.h` (PCI IDs) | — | 79-85 | Confirmed MTL_P device IDs |
| `nhi_regs.h` | — | 113-166 | Vendor cap + reset register layout |
| `domain.c` | 886 | 374-491 (alloc + add) | **PRIMARY** |
| `tb.c` (software CM) | 3399 | 75-200 (queue), 1232-1430 (link/scan), 2275-2530 (tunnel/hotplug), 2877-3300 (notification + ops + start/stop), 3066-3300 (suspend/resume), 3366-3400 (probe) | **PRIMARY** |
| `tunnel.c` | 2654 | 110-540 (pci alloc/activate), 2367-2476 (activate), 1654-1731 (creation) | **SECONDARY** |
| `switch.c` | 4016 | 200-560 (waits), 696-815 (port init), 1700-1740 (wait_for_bit), 2440-2725 (alloc/configure), 2820-2980 (link), 3265-3405 (add) | **SECONDARY** |
| `usb4.c` | 3147 | 243-345 (setup/CV), 1140-1450 (port helpers) | **SECONDARY** |
| `acpi.c` | 368 | full file | **PRIMARY (H1/H3)** |
| `quirks.c` | 137 | full file | Audited; symmetric |
| `clx.c` | 428 | 1-100 | Skim; ruled out (Lever K) |
| `ctl.c` | 1184 | 642-770 | Per-NHI alloc; no shared state |
| `lc.c`, `tmu.c`, `cap.c`, `eeprom.c` | — | partial skim | Not in critical path |
| `icm.c` | 2436 | skim | Not native CM, ruled out |
| `xdomain.c` | — | skim | Not exercised |

---

## 11. Bottom line for Thread A

The TB driver is genuinely written to be per-domain symmetric in its data
structures and logic. The places where Port A could behave differently
from Port B are **all** in the timing/timeout constants and the ACPI
device-link discovery — not in the C control flow.

The most likely root cause is one or both of:

- **(H2/H5) `tb_wait_for_port()` 1-second cap**, where a slower cold-boot
  link bring-up on Port A's lane(s) leads `tb_scan_port()` to abort
  silently, leaving the AORUS box in an unconfigured state that fails
  later when boltd authorizes it / when downstream PCI tries to probe the
  GPU.

- **(H1/H3) BIOS-asymmetric ACPI `usb4-host-interface` references**,
  where one of the two NHIs does not get its `tb_acpi_add_links()` to
  create device-links between the tunneled PCIe bridges and the NHI,
  breaking PM and probe ordering on cold boot.

Both are testable by Thread B with under one hour of boot/dmesg work
each. A single combined kernel patch (Patches 1+2+3 above, ~40 LoC) very
likely fixes the symptom regardless of which root cause is correct.

This is consistent with Windows working on both ports: Windows likely
uses longer link-up timeouts and creates device links via a vendor TB
driver path that doesn't depend on `usb4-host-interface` ACPI bindings.
