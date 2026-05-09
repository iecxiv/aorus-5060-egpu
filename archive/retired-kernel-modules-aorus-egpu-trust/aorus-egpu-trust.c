/*
 * aorus-egpu-trust.c — AORUS RTX 5090 eGPU IOMMU trust override (2026-05-06)
 *
 * Marks the AORUS RTX 5090 (NVIDIA GB202, vendor 0x10de device 0x2b85)
 * as IOMMU-trusted by clearing pci_dev->untrusted=0 via a PCI quirk.
 *
 * BACKGROUND
 *
 * Linux kernel marks Thunderbolt-attached PCI devices as `untrusted` by
 * default — a security policy intended to prevent malicious DMA attacks
 * from hot-plugged devices. When a device is untrusted, the IOMMU
 * subsystem enforces DMA translation regardless of the global
 * `iommu=pt` setting.
 *
 * For our specific use case (NUC 15 Pro+ with sealed eGPU enclosure
 * containing a known-good AORUS RTX 5090), the untrusted treatment
 * causes the GSP firmware's runtime DMA setup to fail with
 * `DMAR: ... [fault reason 0x71/0x05/0x06] ...` events. GSP firmware
 * interprets the DMA failure as a security violation and enters
 * lockdown mode, sending GSP_LOCKDOWN_NOTICE to the host driver
 * instead of GSP_INIT_DONE. rm_init_adapter fails. WPR2 register is
 * left set as a side effect, leading to the "WPR2 already up" symptom
 * on subsequent retries.
 *
 * Empirical evidence:
 *   - 2026-05-06 archive/diag-telemetry-2026-05-06-154732/
 *   - 2026-05-06 archive/commit3-recovery-loop-2026-05-06-161429/
 *     (524 DMAR fault entries; GSP_LOCKDOWN_NOTICE in RPC history)
 *   - 2026-05-06 17:04 boot: confirmed sm_off doesn't help — fault
 *     reasons change from 0x71 (SM) to 0x05/0x06 (legacy PTE) but
 *     mechanism identical
 *   - BIOS has NO Thunderbolt security setting; kernel-side override
 *     is the only available path
 *
 * THREAT MODEL CONTEXT
 *
 * This override is appropriate for personal AI/dev workstation use:
 * the eGPU is a sealed enclosure owned by the user, plugged into a
 * dedicated personal NUC. Removing IOMMU enforcement for THIS specific
 * device does NOT compromise the kernel's protection against:
 *   - other untrusted TB devices (they're matched by vendor:device, not
 *     this quirk)
 *   - random hot-plug attack scenarios (would need attacker to plug in
 *     a *spoofed* GB202 with vendor 0x10de device 0x2b85 — a very
 *     specific and unlikely attack)
 *
 * Inappropriate for: shared workstations, multi-tenant environments,
 * security-sensitive deployments, or any system where TB ports are
 * accessible to untrusted parties.
 *
 * MECHANISM
 *
 * The kernel's PCI fixup framework runs registered DECLARE_PCI_FIXUP_*
 * handlers at well-defined phases of device enumeration. We use
 * DECLARE_PCI_FIXUP_HEADER, which fires after the PCI header is read
 * but before resource allocation, IOMMU setup, or driver binding.
 *
 * At that point the kernel has already set pci_dev->untrusted=1 (TB
 * policy) but has not yet consulted it for IOMMU decisions. Clearing
 * the flag here means subsequent IOMMU initialization treats the
 * device as trusted, applying the global `iommu=pt` policy
 * (passthrough — no DMA translation).
 *
 * SOVEREIGN LAYER
 *
 * L7 — companion module, completely separate from the NVIDIA fork.
 * Pure kernel-API consumer (DECLARE_PCI_FIXUP_HEADER + pci_dev field).
 * No coupling to any NVIDIA code; no maintenance burden tracking
 * NVIDIA upstream; no impact on driver upstream-readiness.
 *
 * RUNTIME LOAD CONSIDERATIONS
 *
 * If this module is loaded AFTER initial PCI enumeration (the default
 * for runtime-loaded modules), the quirk does not fire on the existing
 * device. To apply the quirk to an already-enumerated device, the
 * device must be re-scanned:
 *
 *   modprobe aorus-egpu-trust
 *   echo 1 > /sys/bus/pci/devices/0000:04:00.0/remove
 *   echo 1 > /sys/bus/pci/rescan
 *
 * For boot-time application, the module needs to be loaded BEFORE the
 * eGPU is enumerated. Easiest path: include in initramfs via
 * /etc/dracut.conf.d/aorus-egpu-trust.conf adding `force_drivers+=
 * "aorus-egpu-trust"`.
 */

#include <linux/module.h>
#include <linux/pci.h>
#include <linux/printk.h>
#include <linux/atomic.h>

#define AORUS_VENDOR_NVIDIA 0x10de
#define AORUS_DEVICE_GB202  0x2b85

/* Counter for debugging — increments every time the fixup fires.
 * Visible via /sys/module/aorus_egpu_trust/parameters/fixup_fires (if
 * we expose it as a module param). */
static atomic_t aorus_fixup_fires_gpu = ATOMIC_INIT(0);
static atomic_t aorus_fixup_fires_audio = ATOMIC_INIT(0);

static void aorus_egpu_clear_untrusted(struct pci_dev *pdev)
{
    int fire = atomic_inc_return(&aorus_fixup_fires_gpu);

    /* pr_warn so it's visible at default verbosity even if dev_info is filtered. */
    pr_warn("AORUS eGPU trust override: PCI HEADER fixup FIRED for %s "
            "(fire #%d), pdev->untrusted was %u, clearing to 0\n",
            pci_name(pdev), fire, pdev->untrusted);

    pdev->untrusted = 0;
}

DECLARE_PCI_FIXUP_HEADER(AORUS_VENDOR_NVIDIA, AORUS_DEVICE_GB202,
                          aorus_egpu_clear_untrusted);

/* Also fixup the GB202 audio function (04:00.1) for completeness; same
 * vendor, different device ID.  Without this, the audio function would
 * still be marked untrusted and might behave inconsistently. */
#define AORUS_DEVICE_GB202_AUDIO 0x22e8

static void aorus_egpu_audio_clear_untrusted(struct pci_dev *pdev)
{
    int fire = atomic_inc_return(&aorus_fixup_fires_audio);
    pr_warn("AORUS eGPU trust override: PCI HEADER fixup FIRED for %s "
            "(audio, fire #%d), pdev->untrusted was %u, clearing to 0\n",
            pci_name(pdev), fire, pdev->untrusted);
    pdev->untrusted = 0;
}

DECLARE_PCI_FIXUP_HEADER(AORUS_VENDOR_NVIDIA, AORUS_DEVICE_GB202_AUDIO,
                          aorus_egpu_audio_clear_untrusted);

/* Belt-and-suspenders: also register EARLY fixups (run before HEADER).
 * If HEADER doesn't fire on rescan for some reason, EARLY will. */
static void aorus_egpu_clear_untrusted_early(struct pci_dev *pdev)
{
    pr_warn("AORUS eGPU trust override: PCI EARLY fixup FIRED for %s, "
            "pdev->untrusted was %u\n", pci_name(pdev), pdev->untrusted);
    pdev->untrusted = 0;
}

DECLARE_PCI_FIXUP_EARLY(AORUS_VENDOR_NVIDIA, AORUS_DEVICE_GB202,
                        aorus_egpu_clear_untrusted_early);
DECLARE_PCI_FIXUP_EARLY(AORUS_VENDOR_NVIDIA, AORUS_DEVICE_GB202_AUDIO,
                        aorus_egpu_clear_untrusted_early);

/* Also FINAL — runs after device is fully set up. By this time IOMMU is
 * already configured, so clearing untrusted here probably won't help with
 * THIS bind cycle, but useful as observability marker. */
static void aorus_egpu_clear_untrusted_final(struct pci_dev *pdev)
{
    pr_warn("AORUS eGPU trust override: PCI FINAL fixup FIRED for %s, "
            "pdev->untrusted was %u (note: too late for IOMMU setup)\n",
            pci_name(pdev), pdev->untrusted);
}

DECLARE_PCI_FIXUP_FINAL(AORUS_VENDOR_NVIDIA, AORUS_DEVICE_GB202,
                         aorus_egpu_clear_untrusted_final);
DECLARE_PCI_FIXUP_FINAL(AORUS_VENDOR_NVIDIA, AORUS_DEVICE_GB202_AUDIO,
                         aorus_egpu_clear_untrusted_final);

static int __init aorus_egpu_trust_init(void)
{
    pr_info("AORUS eGPU trust override: module loaded "
            "(vendor=0x%04x device=0x%04x[+0x%04x] PCI fixups registered)\n",
            AORUS_VENDOR_NVIDIA, AORUS_DEVICE_GB202, AORUS_DEVICE_GB202_AUDIO);
    pr_info("AORUS eGPU trust override: NOTE — for the quirk to take effect "
            "on an already-enumerated device, run remove + rescan via sysfs\n");
    return 0;
}

static void __exit aorus_egpu_trust_exit(void)
{
    pr_info("AORUS eGPU trust override: module unloaded "
            "(existing pci_dev untrusted state unchanged; effects persist "
            "until next remove+rescan)\n");
}

module_init(aorus_egpu_trust_init);
module_exit(aorus_egpu_trust_exit);

MODULE_AUTHOR("aorus-5090-egpu (apnex.com.au)");
MODULE_DESCRIPTION("Mark AORUS RTX 5090 (NVIDIA GB202) as IOMMU-trusted "
                   "to prevent GSP lockdown caused by Thunderbolt-untrusted "
                   "DMA rejection on personal eGPU stacks");
MODULE_LICENSE("GPL");
MODULE_VERSION("1.0");
