# Service: aorus-egpu-compute-load-nvidia.service

**Status:** ACTIVE — load-bearing for compute-only architecture
**Layer:** L4 (helper at `usr/local/sbin/aorus-egpu-compute-load-nvidia`) + L5 (systemd unit)
**Lifecycle since:** project inception (one of the original three services)

## Purpose

Realises the **compute-only architecture** by orchestrating the boot-time bind of the AORUS RTX 5090 to the NVIDIA driver. Without this orchestration, the compute-only architectural choice (no DRM device, no autoload, no GNOME-picks-up-display) has no actual binding mechanism — `nvidia.ko` would either not bind (because `driver_override="aorus_5090_manual"`) or bind too early (before persistenced is up, exposing the close-path race).

The service is the explicit handoff between "platform setup is done; nothing has bound the GPU yet" and "GPU is bound to nvidia, persistenced can start".

## Mechanism

`Type=oneshot` running `aorus-egpu-compute-load-nvidia` once at boot. The script:

1. **Detect AORUS GPU + audio function** by walking `/sys/bus/pci/devices/*` looking for vendor `0x10de` device `0x2b85` (RTX 5090) and `0x22e8` (HDMI audio function). Sets `gpu_dev` and `audio_dev` paths. Exits 1 fast if GPU not present (systemd skips cleanly).
2. **(simplified 2026-05-08, removed)** PM policy is now set entirely by the udev rule `81-aorus-egpu-compute-power.rules` which covers all 4 devices on the eGPU PCI path (Intel TB upstream, Intel root port, RTX 5090, audio function). `status.sh` verifies the rule's effect on all four. Previously this script walked the path and re-applied the same policy as defense-in-depth (~26 lines); now the udev rule is the single source of truth. See "Configuration and tuning" → "Workaround-flavoured bits" below for the change history.
3. **Clear `driver_override`** on the GPU (was `aorus_5090_manual` from udev — a fictitious driver name that prevents auto-binding).
4. **`modprobe --ignore-install nvidia`** — bypasses the `install /bin/false` block in `etc/modprobe.d/aorus-egpu-compute-only.conf`. The block exists to prevent autoload from anything else (RPM scriptlets, nvidia-modprobe called by random tools); `--ignore-install` is the explicitly-blessed override.
5. **Trigger `drivers_probe`** on the GPU device — kernel binds nvidia.
6. **Restore `driver_override`** to `aorus_5090_manual` so any future kernel-driven rebind attempt (e.g., after a `modprobe -r` from somewhere unexpected) fails closed instead of binding to whatever driver might match.
7. **`modprobe --ignore-install nvidia_uvm`** — pre-stages UVM module before any CUDA process can need it. Addresses Problem 3: a failed `cuInit` (caused by `cuInit`'s internal modprobe call hitting our `install /bin/false` block) leaves partial GPU state and causes delayed kernel panics.
8. **`nvidia-modprobe -u -c 0`** — materialises `/dev/nvidia-uvm-tools` device file. `modprobe nvidia_uvm` only creates `/dev/nvidia-uvm` via devtmpfs; the tools device gets materialised lazily, by the first userspace caller to invoke `nvidia-modprobe -u -c 0`. Without this step, downstream services that `ConditionPathExists=/dev/nvidia-uvm-tools` skip silently.

## Why we need it today

Compute-only mode is an **architectural choice** that:
- Prevents GNOME / mutter from binding the eGPU as a display device (a known cause of host wedge with NVIDIA + Wayland on TB-attached devices)
- Avoids the `nvidia_drm` module entirely (which would create `/dev/dri/cardN` and trigger that pickup)
- Keeps `/dev/nvidia*` access tightly scoped to known consumers (persistenced, ollama group)

The compute-only architecture requires:
- Modprobe blocks (`install nvidia* /bin/false`) to prevent autoload
- `driver_override="aorus_5090_manual"` to prevent autoprobe binding
- A controlled bind step that bypasses both — that's this service

## Configuration and tuning

### Environment variables (diagnostic; default off, leave alone for normal operation)

| Var | Effect |
|---|---|
| `AORUS_5090_DISABLE_GSP=1` | Sets `NVreg_EnableGpuFirmware=0` at modprobe time. **Will fail to bind on Blackwell** — diagnostic only, since GSP is mandatory on this GPU. |
| `AORUS_5090_DISABLE_NONBLOCKING_OPEN=1` | Sets `NVreg_EnableNonblockingOpen=0`. Does not fix the historical close-path wedge — diagnostic only. |

### Hardcoded values (in helper script)

| Value | Where | Meaning |
|---|---|---|
| `0x10de:0x2b85` | GPU detection | NVIDIA vendor ID + RTX 5090 device ID |
| `0x10de:0x22e8` | Audio function detection | HDMI audio function on the eGPU |
| `aorus_5090_manual` | driver_override restore string | Fictitious driver name; preserved in `79-aorus-egpu-no-autoload.rules` |

### Related modprobe.d files

This service intersects with three modprobe.d configs (NOT this service's, but it depends on them):

| File | Relevant content |
|---|---|
| `aorus-egpu-compute-only.conf` | `install nvidia /bin/false` (the block this service bypasses); `NVreg_DynamicPowerManagement=0x00`; module blacklists |
| `aorus-egpu-lever-m.conf` | `NVreg_AorusLeverMRecoverEnable=1` (production posture for Lever M-recover, applied at modprobe time) |
| `nvidia.conf` | Drops the `softdep nvidia post: nvidia-uvm nvidia-drm` (which would auto-load nvidia-drm and trigger the wedge); sets `NVreg_TemporaryFilePath=/var/tmp` |

### Workaround-flavoured bits inside (potential simplification targets)

| Step | Workaround for | If NVIDIA fixes upstream |
|---|---|---|
| ~~#2 (PM policy walk)~~ | ~~Defense-in-depth — udev rule already does it~~ | **REMOVED 2026-05-08** — udev rule is sole source of truth; status.sh enforces |
| #7 (`modprobe --ignore-install nvidia_uvm`) | Problem 3 (cuInit panic if its internal modprobe fails) | Drop step 7 |
| #8 (`nvidia-modprobe -u -c 0`) | devtmpfs gap on `/dev/nvidia-uvm-tools` materialisation | Drop step 8 |

Step #2 was the cleanest available simplification — removed 2026-05-08, ~26 lines deleted from the script (the `apply_upstream_power_policy` function + caller + a separate NVIDIA-vendor iteration loop). status.sh extended same day to verify PM policy on all 4 devices on the eGPU PCI path (Intel TB upstream, Intel root port, RTX 5090, audio function), so any silent udev-rule failure is now visible as a status WARN.

## Dependencies

**Requires (at boot):**
- `systemd-udev-settle.service` — needs udev to populate `/sys/bus/pci/devices/`
- `bolt.service` — needs Thunderbolt to authorize the eGPU and populate the PCI tree
- `aorus-egpu-bridge-link-cap.service` (`Before=` ordering — not strictly Requires=, but bridge cap should be applied first)

**Required by (downstream services that wait for nvidia to be bound):**
- `nvidia-persistenced.service` (via drop-in `Requires=`)
- `aorus-egpu-wpr2-recovery.service` (via `After=`)
- `aorus-egpu-lever-m-phase5-snapshot.service` (via `After=`)
- `ollama.service` (via drop-in `Requires=`)

**Implicit:**
- `modprobe`, `nvidia-modprobe` binaries (NVIDIA-shipped)
- The 30-patch driver build installed at `/lib/modules/$(uname -r)/extra/nvidia*.ko.xz`

## Lifecycle (boot / runtime / shutdown)

| Phase | Action |
|---|---|
| Boot | Runs after udev-settle + bolt; before `graphical.target` (so persistenced/GDM come after) |
| Runtime | `Type=oneshot RemainAfterExit=yes` — stays "active (exited)" for the boot |
| Shutdown | No action — kernel module unload happens via systemd-shutdown |
| Restart (manual) | Re-runs the bind script; idempotent — no-op if nvidia is already bound |

## Verification

After boot, expect:

```bash
systemctl is-active aorus-egpu-compute-load-nvidia.service
# active (exited)

journalctl -u aorus-egpu-compute-load-nvidia.service -b 0 | tail
# Should show "RTX 5090 is bound to the base nvidia driver." and
# "nvidia_uvm is loaded (pre-staged for CUDA)."

readlink /sys/bus/pci/devices/0000:04:00.0/driver
# .../bus/pci/drivers/nvidia

cat /sys/bus/pci/devices/0000:04:00.0/driver_override
# aorus_5090_manual    (restored after bind)

ls -la /dev/nvidia-uvm /dev/nvidia-uvm-tools
# both present; both 0660 root:ollama
```

In a `aorus-egpu-status` run (the project's verification tool), the relevant checks are: GPU bound to nvidia, both UVM device files present, persistenced active.

## Architectural destination

This service is **inherent to compute-only mode.** Full retirement requires either:
- Abandoning compute-only mode (accept GNOME-picks-up-display risk), OR
- A future NVIDIA driver that supports a "compute-only-no-DRM" flag at module load time, eliminating the need for the `install /bin/false` + `driver_override` + `--ignore-install` dance

Neither is a near-term path. The service is part of the project's permanent architectural surface.

**Partial retirement** of the workaround-flavoured bits inside it is more tractable — see "Configuration and tuning" → "Workaround-flavoured bits".

## Retirement criteria

**Full retirement:** not feasible without abandoning compute-only mode. No criteria defined.

**Partial retirement** of internal workarounds:

| Bit | Retirement criterion |
|---|---|
| Step #2 (PM policy walk) | n=3 boots with the script step removed AND udev rule alone, all show `power/control=on` and `d3cold_allowed=0` on every device on the eGPU PCI path at probe-end. Acceptance: simplification of script. |
| Step #7 (nvidia_uvm pre-stage) | NVIDIA libcuda fixes the cuInit→modprobe panic path (upstream — track via release notes), AND n=10 boots without the pre-stage show no kernel panics on cuInit failure, AND we deliberately exercise cuInit failure (e.g., transient module unload) without panic. |
| Step #8 (nvidia-modprobe -u -c 0) | `modprobe nvidia_uvm` reliably creates BOTH `/dev/nvidia-uvm` and `/dev/nvidia-uvm-tools` via devtmpfs (track upstream nvidia-modprobe / udev rules), AND n=3 boots without the step show both device files at the expected `aorus-egpu-uvm-keepalive`-historical condition-check time. |

## Retirement procedure

**Full retirement** — not currently planned.

**Partial-retirement (e.g., dropping step #2):**

1. Edit `/usr/local/sbin/aorus-egpu-compute-load-nvidia` to comment out / remove the targeted step.
2. Reboot cold-cold.
3. Verify the dropped step's effect is still present via the upstream mechanism (e.g., for step #2: check `power/control` on every PCI device on the path).
4. Run n=3 cold-cold-boots; each must produce a clean Phase 5 snapshot.
5. If clean: commit the simplification, document in this file's "Configuration and tuning" section.

## Resurrection procedure

If full retirement was attempted (e.g., abandon compute-only mode) and reverted:

1. `systemctl enable --now aorus-egpu-compute-load-nvidia.service`
2. Verify all three udev rules are in place (`79-aorus-egpu-no-autoload.rules`, `81-aorus-egpu-compute-power.rules`, `82-aorus-egpu-nvidia-permissions.rules`)
3. Verify modprobe blocks are in place (`/etc/modprobe.d/aorus-egpu-compute-only.conf` with `install nvidia /bin/false` + blacklists)
4. Reboot.

For partial-retirement reverts: re-add the removed step to the script.

## Files installed / consumed

**Installed by `apply.sh`:**
- `/etc/systemd/system/aorus-egpu-compute-load-nvidia.service`
- `/usr/local/sbin/aorus-egpu-compute-load-nvidia`

**Reads:**
- `/sys/bus/pci/devices/*/{vendor,device,driver_override}` (GPU detection + override management)
- `/sys/bus/pci/devices/*/power/{control,d3cold_allowed}` (PM policy)

**Writes:**
- `power/control` and `d3cold_allowed` on each device in the eGPU PCI path
- `driver_override` on GPU (cleared then restored)
- `drivers_probe` (kernel sysfs trigger)

**Indirect (via `modprobe`):**
- Loads `nvidia.ko`, `nvidia_uvm.ko` from `/lib/modules/$(uname -r)/extra/`

## Cross-references

- Architecture (compute-only mode): [`docs/architecture.md`](../architecture.md)
- Modprobe blocks rationale: [`docs/architecture.md`](../architecture.md) "How the configuration enforces this" section
- Problem 3 (cuInit panic — why step #7 exists): [`docs/architecture.md`](../architecture.md) Problem 3
- Problem 4 mechanics (why step #8 was needed historically): [`docs/architecture.md`](../architecture.md) Problem 4
- udev rule that sets the override that this service clears+restores: `etc/udev/rules.d/79-aorus-egpu-no-autoload.rules`
- udev rule that sets the PM policy that step #2 redundantly applies: `etc/udev/rules.d/81-aorus-egpu-compute-power.rules`
