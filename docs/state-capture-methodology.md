# TB Domain Forensics — Methodology

How to deterministically capture and compare Thunderbolt domain
configuration across runs. Tool: `tools/state-capture/state-capture.sh`.

This is the canonical methodology for answering questions like:
- "Are TB domain 0 and TB domain 1 actually identical silicon/config?"
- "Did a kernel upgrade change TB domain config?"
- "Does NUC #1 differ from NUC #2 in TB controller behavior?"
- "Did the AORUS box itself change between port A and port B sessions?"

## When to run

Always **read-only**, can be run at any time without disturbing the GPU.
Does NOT touch `/dev/nvidia*` (per memory rule
`feedback_avoid_nvidia_smi_for_state_checks`).

Run scenarios:
1. **Per-port comparison**: boot on port A, run; boot on port B, run.
   Compare dossiers.
2. **Cross-NUC comparison**: identical NUC model #2 — boot, run, compare
   to dossier from NUC #1.
3. **Kernel upgrade regression**: before kernel upgrade, run; after, run.
4. **OS comparison**: run on Linux, run on Windows-with-WSL (would need
   a parallel Windows-side capture tool — separate workstream).

## Run

```bash
sudo /root/aorus-5090-egpu/tools/state-capture/state-capture.sh
```

Output: `archive/state-captures/<timestamp>-<hostname>-active<domain-id>/`

Each run creates a fresh timestamped directory; nothing is overwritten.

## Output layout

```
archive/state-captures/2026-05-07T12345Z-obpc-active0/
├── 00-meta.txt              # context: kernel, distro, dmidecode summary
├── 01-summary.txt           # top-line per-domain table (DIFF THIS FIRST)
├── 10-nhi-pci-vv/           # per-NHI lspci -vv (one file per NHI)
├── 11-nhi-pci-bytes/        # per-NHI raw config space bytes (lspci -xxxxx)
├── 12-nhi-sysfs/            # per-NHI sysfs attribute dump
├── 20-domain-sysfs/         # per-TB-domain sysfs (security, iommu_dma_protection)
├── 30-tb-device-sysfs/      # per-TB-device sysfs (router/peripheral/retimer)
├── 40-debugfs/              # /sys/kernel/debug/thunderbolt (regs/counters/path)
├── 41-debugfs-drom-*.bin    # raw DROM bytes per router (binary diff)
├── 50-acpi-paths.txt        # firmware_node paths for TB-related devices
├── 60-module-params.txt     # thunderbolt module param values + CONFIG_USB4_*
├── 61-cmdline.txt           # /proc/cmdline filtered to TB/PCIe/IOMMU
├── 70-kernel-tb-events.txt  # journalctl -k filtered to TB events
└── 80-boltctl/              # boltctl list + per-device info
```

## Compare two dossiers

```bash
# Human-readable diff (recommended starting point):
diff -ruN dossier_port_A dossier_port_B | less

# Just the top-line summary:
diff dossier_port_A/01-summary.txt dossier_port_B/01-summary.txt

# Byte-level DROM diff (binary):
cmp -l dossier_port_A/41-debugfs-drom-0-0.bin dossier_port_B/41-debugfs-drom-1-0.bin

# Specific domain comparison:
diff dossier_port_A/20-domain-sysfs/domain0.txt \
     dossier_port_B/20-domain-sysfs/domain1.txt
```

Note: per-port BDFs differ between dossiers (the GPU is at `04:00.0` on
port A and `2e:00.0` on port B). Filenames use BDFs, so the diff will
show "files only in A" / "files only in B" — that's expected. Look at
the actual content of corresponding files.

## What to look for in a diff

When comparing two dossiers (port A vs port B, or NUC#1 vs NUC#2):

| Diff in... | What it suggests |
|---|---|
| `00-meta.txt` | Different host (expected if cross-NUC) or kernel (regression) |
| `01-summary.txt` device gen/auth | Different TB protocol negotiation |
| `10-nhi-pci-vv/` LnkCap/AER caps | Different TB controller silicon/revision |
| `11-nhi-pci-bytes/` | Byte-level silicon/firmware revision differences |
| `12-nhi-sysfs/` | Different IRQ count / capability advertising |
| `20-domain-sysfs/` security/iommu | Different security posture per domain |
| `30-tb-device-sysfs/` rx/tx_speed/lanes | Different tunnel negotiation |
| `40-debugfs/regs.txt` | Router register state differences (most invasive but most informative) |
| `41-debugfs-drom-*.bin` byte cmp | Different DROM contents = different firmware/silicon |
| `50-acpi-paths.txt` | Different ACPI methods invoked |
| `60-module-params.txt` | Module params differ (cmdline change) |
| `61-cmdline.txt` | Cmdline differs |
| `70-kernel-tb-events.txt` | Different probe sequence / different events |
| `80-boltctl/` | Different bolt daemon state |

## Project usage (what we plan to do)

1. **Run on port A** (current session, while we're here)
   → dossier_port_A
2. **User reboots to port B**
3. **Run on port B**
   → dossier_port_B
4. **Compare**: `diff -r dossier_port_A dossier_port_B`
5. Identify divergence points; if domain 0 and domain 1 silicon are
   identical, asymmetry is in Linux kernel / driver behavior. If they
   differ, hardware factors are in play.

## Reproducing across NUCs

For any user reporting a similar TB-eGPU issue:
1. Send them this script + methodology doc
2. They run on their NUC, send back the dossier
3. We diff their dossier vs our known-good dossier
4. Identify what differs in their config

This is the foundation for upstream RFC empirical evidence: instead of
"works on my machine", we have a reproducible cross-host comparison
methodology.

## Future extensions

- Windows-side equivalent (PowerShell + reg dump + HWinfo64 export)
- Automated diff highlighting (script that flags interesting diffs)
- Periodic capture for time-series analysis (was this ever different?)
- JSON export for programmatic comparison

These are nice-to-haves. The current bash script is the minimum
viable methodology.
