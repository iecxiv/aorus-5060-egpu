# aorus-egpu — Thunderbolt eGPU compute stack

Fork of [apnex/aorus-5090-egpu](https://github.com/apnex/aorus-5090-egpu), adapted for:

- **GPU:** NVIDIA GeForce RTX 5060 Ti 16 GB (PCI `0x10de:0x2d04`, audio `0x10de:0x22eb`)
- **Host:** Intel NUC 15 Pro+ (Thunderbolt 4)
- **OS:** Fedora 44
- **Driver:** akmod-nvidia 595.71.05

## Changes vs upstream

| File | Change |
|---|---|
| `usr/local/sbin/aorus-egpu-compute-load-nvidia` | BAR1 minimum `32 GiB → 16 GiB`; all labels `RTX 5090 → RTX 5060 Ti` |
| `usr/local/sbin/aorus-egpu-status` | Sources `common.sh` for device IDs; fallback IDs updated to 5060 Ti |
| `usr/local/lib/aorus-egpu/common.sh` | Fallback device IDs `0x2b85/0x22e8 → 0x2d04/0x22eb` |
| `reset.sh` | Fixed double `[[` syntax error on line 183; BAR1 expected size `32→16 GiB` |

## Requirements

- `thunderbolt.host_reset=false` in kernel boot args
- eGPU connected **before** power-on (cold boot)
- `passim` group: add your user (`sudo usermod -aG passim $USER`) — Fedora assigns `/dev/nvidia*` to group `passim` via udev
- `ollama` group: required for Ollama GPU access
- **Suspend disabled** — see troubleshooting below

## Quick start

```bash
git clone https://github.com/iecxiv/aorus-5090-egpu.git
cd aorus-5090-egpu
sudo ./apply.sh
sudo aorus-egpu-status
nvidia-smi
```

## Verify GPU in Ollama

```bash
# Terminal 1
ollama run llama3.2 "hola"

# Terminal 2 — while model generates
watch -n 1 nvidia-smi
# Expect: Memory-Usage > 0MiB, library=cuda in journalctl
```

## Troubleshooting

**`nvidia-smi: Insufficient Permissions`** — add user to `passim` group:
```bash
sudo usermod -aG passim $USER
newgrp passim
```

**`GPU: not present` after reboot** — run recovery:
```bash
sudo ./reset.sh --auto
```

**Ollama uses CPU instead of CUDA** — `ollama` user needs `passim` group:
```bash
sudo usermod -aG passim ollama
sudo systemctl restart ollama
sudo journalctl -u ollama -n 10 --no-pager | grep library
```

**`nvidia-smi: No devices were found` after suspend/resume** — the Thunderbolt
tunnel breaks on suspend and the NVIDIA driver cannot re-probe the device.
Recovery without reboot is not reliable on this hardware. Full recovery procedure:

1. Disconnect the eGPU from the Thunderbolt port
2. Reboot the host
3. Reconnect the eGPU **before** or immediately after power-on
4. Run `sudo ./apply.sh` if the stack services did not start automatically
5. Verify with `nvidia-smi`

Root cause: `aorus-egpu-compute-only.conf` (placed by the stack to sequence
driver load at boot) is not cleaned up when the system suspends mid-session.
After resume, `modprobe nvidia` fails with `No such device` because the PCIe
bridge secondary bus reset is unavailable on this hardware
(`/sys/bus/pci/devices/0000:03:00.0/reset` is not writable post-resume).

**Recommended: disable suspend permanently** while the eGPU is in use:
```bash
sudo systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target
```

To re-enable (e.g. when using the machine without the eGPU):
```bash
sudo systemctl unmask sleep.target suspend.target hibernate.target hybrid-sleep.target
```
