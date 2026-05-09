# Retired: aorus-egpu-trust kernel module

**Retired 2026-05-09.** 7th retirement (and the only kernel-module retirement).

## Why it existed (2026-05-06)

PCI quirk that cleared `pci_dev->untrusted` on the AORUS RTX 5090
(NVIDIA GB202, vendor `0x10de` device `0x2b85`)
plus its paired HDMI audio function (`0x22e8`).
Bypasses the kernel's TB-untrusted DMA enforcement that was causing
GSP_LOCKDOWN cascades when the GPU was running under `iommu=pt`.

Documented mechanism + threat-model context in the original module
header comment in `aorus-egpu-trust.c`.

## Why it retired

Lever T (`iommu=off intel_iommu=off`) was adopted 2026-05-07,
the day after this module was written.
With IOMMU completely disabled,
the `pci_dev->untrusted` attribute is consulted by nothing
(IOMMU subsystem is bypassed entirely;
ATS is irrelevant without IOMMU;
TB-driver references are logging-only).

Empirical evidence on the running stack 2026-05-09:
- `/sys/class/iommu/dmar0` ABSENT (IOMMU disabled, confirmed)
- HEADER/EARLY fixups did NOT fire on this boot's TB-late-enumeration
  path (the module's own init log warns about exactly this)
- Module loaded but refcount 0 — nothing in kernel held it
- `rmmod aorus_egpu_trust` succeeded cleanly;
  GPU stayed bound; nvidia-smi continued working

Conclusion:
the module is dead code under the current cmdline.
It was effective in the `iommu=pt` era (~24 hours of project history)
and superseded by the cmdline change.

## Resurrection

If we ever revert `iommu=off` → `iommu=pt`
(e.g., security-sensitive deployment, multi-tenant host):

```bash
cd archive/retired-kernel-modules-aorus-egpu-trust
make
sudo make install
sudo dracut -f                              # rebuild initramfs
echo 'force_drivers+=" aorus-egpu-trust "' | \
    sudo tee /etc/dracut.conf.d/aorus-egpu-trust.conf
sudo dracut -f                              # rebuild initramfs again with the conf
sudo reboot
```

After reboot,
verify the fixups fire:
`dmesg | grep "AORUS eGPU trust"` should show
HEADER/EARLY fixup FIRED lines.
If only the init message appears
(no FIRED lines for the GPU's BDF),
the same dead-code state is in effect
and a different mechanism is needed.

## Cross-references

- `docs/iommu-gsp-lockdown-analysis.md` — multi-cause GSP_LOCKDOWN
  analysis;
  describes the `untrusted` mechanism this module worked around
- `docs/reliability-hypothesis-ledger.md` H10 (IOMMU/TB-untrusted)
- Lever T entry in `docs/lever-catalog.md`
  (the cmdline change that made this module redundant)
- Memory:
  `project_iommu_dmar_finding_2026_05_06.md`
- Memory:
  `project_aorus_egpu_trust_retired_2026_05_09.md`
