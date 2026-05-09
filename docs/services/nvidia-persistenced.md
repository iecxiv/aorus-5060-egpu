# Service: nvidia-persistenced.service (with project drop-in)

**Status:** RECLASSIFIED 2026-05-08 — was load-bearing for stability, now load-bearing for warmup latency
**Layer:** L7 (NVIDIA-shipped daemon) consumed via L5 drop-in (`etc/systemd/system/nvidia-persistenced.service.d/aorus-egpu.conf`)
**Lifecycle since:** project inception (vendor-shipped)

## Purpose

NVIDIA's official daemon for keeping the GPU's persistent software state alive across `/dev/nvidia*` consumer transitions. On this stack, by holding `/dev/nvidiactl` once and `/dev/nvidia0` four times for its lifetime, it ensures every subsequent open is "additional open alongside an existing one" — never "first open after last close" — saving the ~1.3s GSP-boot tax that would otherwise apply to every consumer warmup.

**Historical role (2026-05-01 → 2026-05-08):** prevented the close-path host-freeze bug (Problem 2 in `architecture.md`).
**Current role (2026-05-08 onward):** warmup-latency optimisation.

## Mechanism

Vendor binary `/usr/bin/nvidia-persistenced`. Holds open file descriptors on the device files for its process lifetime:

```
$ lsof -p $(pgrep nvidia-persistenced)
... /dev/nvidiactl (1 fd)
... /dev/nvidia0 (4 fds)
```

The reference count on each device file never drops to zero, so the kernel's close-side teardown sequence (`nvidia_close_callback` → `nv_close_device` → `nv_stop_device` → `nv_shutdown_adapter`) doesn't run on consumer-exit. Next consumer's open is a no-op refcount bump.

Project drop-in `aorus-egpu.conf` adds:
- `After=`, `Requires=aorus-egpu-compute-load-nvidia.service` — won't start until GPU is bound
- `ConditionPathExists=/sys/bus/pci/devices/0000:04:00.0` — skip cleanly if eGPU disconnected
- `Restart=no` — explicit override of vendor default; if persistenced dies while nvidia is loaded, restarting it would be a close+reopen which IS the 1→0→1 transition we're optimising against

## Why we need it today

Without persistenced:
- Every `nvidia-smi` invocation opens then closes /dev/nvidia0 → if no other consumer holds it, the close drops `usage_count` to 0 → next open pays ~1.3s GSP-boot tax
- For monitoring scripts running `nvidia-smi` frequently, this becomes hundreds of seconds of accumulated tax per day
- For ollama spawning short-lived runners between idle gaps, every gap is a potential LAST-CLOSE → next runner pays the tax

The 2026-05-08 close-path-probe evidence (n=3) confirmed the host stays stable across LAST-CLOSE transitions on the current driver stack — so persistenced is no longer required to prevent freezes. But the GSP boot is still real work; persistenced amortises it across all consumers.

## Configuration and tuning

### Vendor binary knobs (not project-specific)

| Flag | Effect |
|---|---|
| `--persistence-mode` | Enable persistence mode (default; what we want) |
| `--user nvidia-persistenced` | Drop privileges (default; honoured by our drop-in) |
| `--verbose` | More verbose logging (diagnostic) |

### Project drop-in

`/etc/systemd/system/nvidia-persistenced.service.d/aorus-egpu.conf` — see project repo for full content.

Key directives:
- `After=aorus-egpu-compute-load-nvidia.service` — order
- `Requires=aorus-egpu-compute-load-nvidia.service` — fail loud if GPU isn't bound
- `ConditionPathExists=/sys/bus/pci/devices/0000:04:00.0` — eGPU-disconnected handling
- `Restart=no` — explicit override of vendor default

### Permissions interaction

Persistenced runs as user `nvidia-persistenced` (vendor default). For it to open `/dev/nvidia*`, those devices must be group-readable by `ollama` (the project's chosen group). The udev rule `82-aorus-egpu-nvidia-permissions.rules` sets `MODE=0660 GROUP=ollama`; `apply.sh` adds `nvidia-persistenced` user to the `ollama` group.

## Dependencies

**Requires:**
- `aorus-egpu-compute-load-nvidia.service` — needs GPU bound first

**Required by (project services that depend on persistenced):**
- `ollama.service` (drop-in `Requires=`) — for the warmup-latency optimisation
- `aorus-egpu-lever-m-phase5-snapshot.service` (`After=`)

## Lifecycle (boot / runtime / shutdown)

| Phase | Action |
|---|---|
| Boot | Starts after compute-load-nvidia binds the GPU; opens fds; remains running |
| Runtime | Daemon loop; replies to NVML queries from clients |
| Shutdown | Closes fds (which will NOT trigger close-path issues at shutdown because module unload follows immediately) |

## Verification

```bash
systemctl is-active nvidia-persistenced
# active (running)

lsof -p $(pgrep nvidia-persistenced) | grep /dev/nvidia
# 5 fds: 1× nvidiactl, 4× nvidia0

# nvidia-smi should be fast
time nvidia-smi -L
# real    0m0.05s     (NOT ~1.3s — that would indicate persistenced is down)
```

## Architectural destination

The vendor-recommended pattern. Persistenced is **not retiring**. The "load-bearing role" reclassification is about *why* we depend on it (now perf, not stability), but the dependency itself is permanent on this stack.

If a future driver landed an in-kernel "soft close-path" (the M-preserve patch — see `lever-catalog.md`), persistenced would become genuinely optional even for the perf optimisation: `usage_count → 0` would no longer trigger GSP teardown, so the warmup tax would be paid only at module unload (i.e., never during normal operation).

## Retirement criteria

**Persistenced itself does NOT retire.** It's NVIDIA's official tool, and we use it correctly.

The **project drop-in** (the `aorus-egpu.conf` portion) could potentially simplify if:
1. The `Requires=aorus-egpu-compute-load-nvidia` becomes unnecessary (i.e., compute-load-nvidia retires) — currently inseparable from compute-only mode
2. The `Restart=no` override can be removed if the close+reopen race becomes safe (M-preserve patch)

## Retirement procedure

**Persistenced itself:** N/A.

**Drop-in simplification (e.g., remove `Restart=no` post-M-preserve):**
1. Edit `/etc/systemd/system/nvidia-persistenced.service.d/aorus-egpu.conf` to remove the relevant directive
2. Reboot
3. Verify behaviour change is benign (e.g., `kill -9 $(pgrep nvidia-persistenced)` doesn't crash the host)

## Resurrection procedure

If persistenced is somehow disabled / failing:

```bash
systemctl status nvidia-persistenced
# diagnose

systemctl restart nvidia-persistenced
# careful: if nvidia is loaded, this is a 1→0→1 transition; could trigger
# the historical close-path bug if for some reason it's regressed.
# Safer: cold-cold-boot to a known-good state.
```

## Files installed / consumed

**Installed by `apply.sh`:**
- `/etc/systemd/system/nvidia-persistenced.service.d/aorus-egpu.conf` (drop-in)

**NOT installed by us:**
- `/usr/lib/systemd/system/nvidia-persistenced.service` (vendor)
- `/usr/bin/nvidia-persistenced` (vendor)

**Holds open at runtime:**
- `/dev/nvidiactl` × 1
- `/dev/nvidia0` × 4

## Cross-references

- Reclassification rationale: [`docs/architecture.md`](../architecture.md) Problem 2 + memory `project_close_path_mitigated_2026_05_08`
- Empirical evidence (n=3 close-path probes): `archive/close-path-probes/2026-05-08T18-57-32+10-00/` (and 2 more)
- H22 ledger entry: [`docs/reliability-hypothesis-ledger.md#h22`](../reliability-hypothesis-ledger.md#h22)
- M-preserve future patch (would change retirement criteria): [`docs/lever-catalog.md`](../lever-catalog.md)
