# PCIe / PCI kernel cmdline options — investigation notes

Reference catalogue of kernel command-line flags that may be relevant to
the AORUS RTX 5090 eGPU host-freeze investigation. Compiled from a sweep
of the running Fedora 43 kernel (`6.19.14-200.fc43.x86_64`) on
2026-05-04 after several misfired Lever L attempts.

This is a *research* document — most flags listed here are NOT currently
applied. The purpose is to have an informed escalation path documented
when subsequent tests need to layer in additional flags.

## How this list was derived

The Linux kernel does not ship every parameter name in
`Documentation/admin-guide/kernel-parameters.rst` in a way that
maps cleanly to the `pci=` sub-option parser. Found via:

```bash
# Decompress vmlinuz (zstd-compressed in F43)
/usr/src/kernels/$(uname -r)/scripts/extract-vmlinux \
    /boot/vmlinuz-$(uname -r) > /tmp/vmlinux

# Sub-options of pci= (lowercase tokens parsed by drivers/pci/pci.c:pci_setup)
strings /tmp/vmlinux | grep -E '^(no[a-z_]+|earlydump|realloc|...)$'

# Top-level pcie_* kernel parameters
strings /tmp/vmlinux | grep -E '^pcie_(aspm|ports|bus|aer|hp|pme)[a-z_=]*$'
```

Repeat per-kernel: parameter set can change between kernel versions
(e.g. earlier sessions tried `pcie_aer=off` which works in some
versions but not 6.19.14).

## `pci=` sub-options (comma-list inside a single `pci=` argument)

These are parsed by `drivers/pci/pci.c:pci_setup`. They MUST be
appended (or comma-joined) inside the existing `pci=` argument — they
are NOT standalone parameters. (Earlier mistake: trying `nodpc` and
`noaer` as standalone args; kernel rejected with `PCI: Unknown
option`.)

| Sub-option | What it does | Currently applied? | When to consider |
|---|---|:-:|---|
| `realloc=off` | Don't reallocate BARs after kernel-side bus enumeration | ✅ | Already part of Lever A. Per HPE advisory a00151736en_us, default `realloc` can lose BIOS-allocated BARs. |
| `pcie_bus_perf` | MaxPayloadSize policy = performance | ✅ | Set as part of original config. |
| `hpmmioprefsize=256M` | Reserve 256 MB prefetchable MMIO per hotplug bridge | ✅ | Sized for our BAR1 + BAR3 |
| `resource_alignment=...` | Force BAR alignment for our specific GPU device | ✅ | Already applied |
| `noaer` | Disable AER (Advanced Error Reporting) | ❌ Lever L (REVERTED 2026-05-04) | See "Why Lever L was reverted" section below |
| `noats` | Disable Address Translation Services | ❌ | Unlikely to help — our hardware doesn't use ATS for the GPU |
| `noari` | Disable Alternative Routing-ID Interpretation | ❌ | Not relevant; ARI is for VFs which we don't use |
| `nomsi` | **Disable MSI interrupts globally, fall back to INTx** | ❌ | **Heavy** — affects all PCI devices. Could help IF MSI delivery itself stalls on the dying TB tunnel. Try only after other levers fail. |
| `earlydump` | Dump PCI config space early in boot | ❌ | Diagnostic only — adds verbose dmesg output. Useful if we need to debug enumeration. |
| `nobfsort`/`bfsort` | BIOS-driven device sort order | ❌ | Not relevant |
| `nodomains` | Disable PCI domain awareness | ❌ | Not relevant; we have only one domain |
| `noearly` | Skip early PCI init | ❌ | Could break TB enumeration |
| `firmware` | Force firmware to control resources (rare) | ❌ | Same effect as `pcie_ports=compat` but partial |
| `use_crs`/`nocrs` | ACPI CRS resource list usage | ❌ | Last-resort if BIOS BAR layout is wrong |

## Top-level PCIe kernel parameters (separate args)

Parsed by their own `__setup()` or `early_param()` handlers.

| Parameter | What it does | Currently applied? | When to consider |
|---|---|:-:|---|
| `pcie_aspm.policy=performance` | Set ASPM policy via the module-param dot-notation. Keeps ASPM negotiating but uses most-power-aggressive policy. | ✅ Lever K | Soft form; doesn't disable ASPM, just steers policy |
| `pcie_aspm=off` | **Disable ASPM signaling globally**, harder than `policy=performance` | ❌ | If ASPM L-state transitions on the TB-tunnel are contributing to the trigger. Cost: small power increase at idle. |
| `pcie_aspm=performance` | Top-level form, equivalent to `policy=performance` | ❌ | Redundant if we already have `pcie_aspm.policy=performance` |
| `pcie_pme=off` | Disable PME (Power Management Event) interrupt handling | ❌ | If we observe PME-related stalls in dmesg post-failure (we haven't) |
| `pcie_pme=force` | Force PME enable even if BIOS says no | ❌ | Opposite direction; not for us |
| `pcie_pme=nomsi` | Use INTx for PME instead of MSI | ❌ | Lighter version of `pcie_pme=off` if MSI specifically is the issue |
| `pcie_ports=compat` | **Firmware-first PCIe service control. OS does NOT claim AER, DPC, PME, hotplug via _OSC negotiation.** | ❌ | **Heaviest hammer.** Most likely to definitively prevent the AER/DPC/MCE chain that triggered the kernel panic. Risk: may affect TB hotplug, but our eGPU is boot-attached, not dynamically hotplugged. |
| `pcie_ports=native` | OS owns ports natively (default-ish) | (default) | No — opposite of what we want |
| `pcie_ports=auto` | Negotiate with firmware via _OSC (default) | (default) | No |
| `pcie_ports=dpc-native` | Force OS to own DPC specifically | ❌ | No — opposite |
| `pcie_hp=off` | Disable PCIe hotplug | ❌ | Would break TB device-attached state recovery; do NOT use |

## Thunderbolt parameters (separate args)

| Parameter | What it does | Currently applied? | When to consider |
|---|---|:-:|---|
| `thunderbolt.host_reset=false` | Don't reset TB host controller on driver init | ✅ | Existing baseline |
| `thunderbolt.clx=0` | Disable TB Common Lane CLx low-power states | ✅ Lever K | TB low-power state transitions were a candidate trigger source |

## Recommended escalation order

If the current configuration (`pci=...,noaer`) doesn't fully resolve
the freeze, consider in this order:

### Tier 1 (cheap, low side-effect) — try one at a time

1. **`pcie_aspm=off`** — fully disable ASPM globally. Replaces or
   supplements our existing `pcie_aspm.policy=performance`. Try if
   ASPM transitions are suspected.
2. **`pcie_pme=off`** — disable PME interrupts. Try if dmesg shows
   PME-related errors during freeze.

### Tier 2 (heavier hammer)

3. **`pcie_ports=compat`** — definitively cuts OS-native PCIe service
   control. Most likely to prevent the kernel-side AER/DPC/MCE
   cascade. Risk: TB hotplug may stop working — manageable for our
   boot-attached setup but means **the eGPU must always be
   connected at cold boot**.

### Tier 3 (drastic, last resort)

4. **`pci=...,nomsi`** — disable MSI globally. Falls back to
   legacy INTx. May cause performance regressions everywhere on the
   PCI bus. Try only if MSI delivery during dying-GPU is implicated.

Each escalation should be justified by a specific failure-mode signal
in dmesg, not added preemptively.

## What about disabling DPC specifically?

There is **no kernel cmdline to directly disable DPC** on Linux 6.19.x.
Confirmed via:

```bash
strings /tmp/vmlinux | grep -E '^(nodpc|disable_dpc|no_dpc)$'
# (no matches)
```

DPC is enabled via PCIe AER capability. Disabling AER (`pci=noaer`)
breaks the AER → DPC trigger chain — DPC won't fire spontaneously
because it has no error reports to act on. So `pci=noaer` is the
indirect DPC mitigation.

If a more direct DPC disable becomes necessary, the only mechanisms
are:

1. **`pcie_ports=compat`** (Tier 2) — disables OS-owned DPC entirely
2. **Per-port sysfs** — runtime toggle via
   `/sys/bus/pci/devices/<port>/dpc_ctl` (if exposed; not all ports do)
3. **PCI config-space write** — directly clear the DPC enable bit; not
   recommended without thorough understanding of the device's ER/DPC
   capability layout

## What about enabling PEX Reset and Recovery (the actual fix)?

NVIDIA's own comment at `osinit.c:361-364` admits:

> *This doesn't support PEX Reset and Recovery yet.*

The "real fix" would be the open module registering `pci_error_handlers`
in nv-pci.c (Lever M in our investigation plan). That's a code-side
patch, not a cmdline flag. Catalogued here for completeness — when
Lever M becomes the active workstream, this doc gets updated to note
that the cmdline flags become defensive layers around a now-functional
recovery path.

## Cross-references in this repo

- `freeze-investigation-plan.md` — Lever L section. References this
  doc for available cmdline options.
- `source-review-notes.md` Pass 11 — captured the MCE-broadcast panic
  signature that motivated the AER/DPC investigation.
- `apply.sh` preflight — recommends the canonical cmdline including
  `pci=noaer`.
- `status.sh` — checks for the canonical cmdline form.

## Why Lever L was reverted (2026-05-04)

`pci=...,noaer` was correctly applied (verified via /proc/cmdline + the
ACPI _OSC line dropping AER from the OS-controlled service list) but
the next test still froze — and the failure mode was qualitatively
worse than the AER-on baseline:

| Aspect | AER on (default) | AER off (Lever L active) |
|---|---|---|
| Bus error → driver | propagated via PCIe error path | swallowed by kernel |
| `PDB_PROP_GPU_IS_LOST` set | yes | **never** |
| AORUS-marker patches activate | yes | **no — driver doesn't enter the GPU-lost path** |
| Failure trace | Xid + cleanup chain in dmesg | **silent kernel hang** |
| Recovery patches (I, J-2, N) | exercised | **dormant** |

The novel-mode freeze on test `lite-2026-05-04-113350` showed:
- Zero NVRM activity beyond module-load message
- Zero AORUS markers across all boots (-3, -2, -1, 0)
- No panic, no MCE, no RCU stall, no hung_task — completely silent
- Last journal entry was ollama at the model-mmap step (CUDA
  initialisation, before any GPU register work)

Conclusion: with AER suppressed, a transient PCIe link failure during
`cuInit` register probing does not generate any kernel-side error
event. The driver thread blocks forever on the dead register read. No
watchdog fires loud enough to leave a trace. The host wedges
silently, and our recovery patches never get a chance to engage —
they are gated on the GPU-lost path the kernel never enters.

The "real fix" remains Lever M (register `pci_error_handlers` in
`nv-pci.c`) so the AER signal has a structured place to land. Until
that's implemented, AER must remain enabled so the existing recovery
chain stays diagnosable.

`pci=...,noaer` will only be re-considered AFTER Lever M lands.

## Update log

- **2026-05-04**: created. Initial sweep of pci= and pcie_* options on
  Linux 6.19.14-200.fc43. Identified `pcie_ports=compat` as the most
  likely Tier-2 escalation if `pci=noaer` proves insufficient.
- **2026-05-04 (later)**: Lever L (`pci=noaer`) reverted after one
  test cycle. The flag worked as documented at the kernel level
  (AER infrastructure disabled, _OSC negotiation lost AER) but
  produced a worse, fully-silent failure mode where our patches
  could not engage. Catalogue entry updated to mark REVERTED with
  rationale. Tier-2 escalation (`pcie_ports=compat`) is now also
  off the table for the same reason — both flags suppress the very
  signal our patches require.
