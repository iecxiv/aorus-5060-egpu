# Architecture

This document explains why each piece of the configuration exists. Read this if you want to understand the system, change it safely, or escalate a bug upstream.

> For the **active stability roadmap** (layer model, phased plan, lever
> status, completion criteria) see [`stability-roadmap.md`](./stability-roadmap.md).
> For the **historical investigation log** (lever origins, source review)
> see [`freeze-investigation-plan.md`](./freeze-investigation-plan.md).

## The three core problems

### Problem 1: BAR1 collapses during Thunderbolt authorization

On boot, the firmware enumerates the eGPU PCI tunnel and assigns the RTX 5090 a 32 GiB resizable BAR1 on a 32 GiB downstream bridge window. The kernel's Thunderbolt authorization path then issues a host-router reset, tears the tunnel down, and re-enumerates. During the re-enumeration, the downstream bridge gets a smaller window (256-288 MiB) and BAR1 is forced down to 256 MiB. NVIDIA driver bind fails with `BAR0 is 0M @ 0x0` or similar.

**Fix:** kernel boot arg `thunderbolt.host_reset=false`. Skips the host-router reset; the firmware-assigned 32 GiB BAR1 survives authorization. `bolt.service` works normally.

Supporting boot args to keep the BAR allocation healthy:

- `pci=realloc,pcie_bus_perf` - allow the kernel to re-allocate PCI resources after Thunderbolt authorization, instead of giving up when initial assignment fails.
- `hpmmioprefsize=256M` - cap empty hotplug bridge prefetchable windows at 256 MiB so they do not starve the actual GPU's bridge.
- `resource_alignment=35@0000:03:00.0` - force the occupied bridge to be aligned for 32 GiB (= 2^35).

### Problem 2: Second open of `/dev/nvidia0` (historically hard-freezes the host; now mitigated by the cumulative driver stack)

**Historical (2026-05-01 era, open kernel module 580.142):** the first open+close of `/dev/nvidia0` works; the second open in the same module-load session hangs in the kernel's `open()` syscall and locks up the host. No flushed kernel logs; forced reboot is the only recovery.

The boundary was originally confirmed with an `LD_PRELOAD` ioctl tracer:

```
open64_enter dirfd=-100 path=/dev/nvidia0 flags=0x80802 mode=00
   (no matching open64_exit)
```

The bug originally persisted across `modprobe -r nvidia ; modprobe nvidia` — so the wedge state lived below the kernel module, in GPU/GSP firmware state or a per-PCI-device kernel structure. Setting `NVreg_EnableNonblockingOpen=0` only relocated the hang from `NV_ESC_WAIT_OPEN_COMPLETE` ioctl into `open()` itself; not a fix.

**Status update 2026-05-08 — empirically mitigated by the cumulative driver stack.** The `tools/close-path-probe.sh` instrumented experiment (Patch 0029 close-path DIAG sites + state-capture + 20s settle window) ran the exact "stop persistenced, open via `nvidia-smi -L`, close, observe next open" sequence three times back-to-back. **n=3 reproductions: identical outcome — the second open succeeds in ~1.3s with no host wedge.** The close path mutates real state (WPR2 cleared 0x07f4a000 → 0; PCIe link demoted Gen3 → Gen1; PMC_BOOT_0 stays healthy; zero AER), and the next `rm_init_adapter` cycles the link Gen1 → Gen3 and re-establishes WPR2 cleanly. Lever M-recover never had to fire (`fires=0` across all 3 probes). Forensic dossiers in `archive/close-path-probes/2026-05-08T1*-*+10-00/`.

**Why it doesn't reproduce now:** the bug class was multi-cause; we cumulatively eliminated each cause. Likely contributors in order: H9a retirement (was the dominant Port A trigger — `aorus-egpu-pcie-tune.service` tightening DevCtl2 Range B too tight on Port A, retired 2026-05-08); Lever T cmdline (`iommu=off intel_iommu=off`, eliminates IOMMU rejection of GSP DMA); recovery levers I/J-2/N/O (convert "GPU lost ⇒ deadlock" into "GPU lost ⇒ clean error"); G3-H UncMaskClear (Internal Error fires through AER instead of Cor=0x2000 demotion); Lever M-recover (last-line bus-reset insurance). Single-cause explanation never fit; all of these together are why.

**Reclassified workaround:** `nvidia-persistenced` is **no longer required for stability** on this stack. It is now a **performance optimization**: by holding `/dev/nvidiactl` once and `/dev/nvidia0` four times for its lifetime, every subsequent open is "additional open alongside existing", never "first open after last close" — so the ~1.3s GSP-boot tax for re-establishing rm_init from a torn-down state is paid once at boot, not on every consumer warmup.

**Operational cost of retiring it (measured 2026-05-08):** ~1.3s GSP-boot per first-open after any LAST-CLOSE. For workloads with frequent gaps between GPU consumers (e.g. ollama daemon spawning runners with idle gaps in between, periodic `nvidia-smi` from monitoring), this tax compounds; for workloads that hold continuous open (long-running CUDA apps), the cost is paid once.

This is a vendor-supported configuration. It is not a hack. It is no longer load-bearing for stability; it remains load-bearing for warmup latency on this hardware.

### Problem 3: Failed `cuInit` causes delayed kernel panics

A separate failure mode, identified on 2026-05-01:

- The compute-only modprobe config blocks all four NVIDIA modules from auto-loading via `install nvidia* /bin/false` lines. This is needed to prevent any process other than our loader from binding the eGPU before `nvidia-persistenced` is up.
- However, when CUDA's `cuInit()` runs, it ensures `nvidia_uvm` is loaded as part of initialisation. With the blocks in place, `cuInit`'s internal `modprobe nvidia_uvm` call returns 1 (because `/bin/false` ran), and `cuInit` returns `CUDA_ERROR_UNKNOWN` (999) to the caller.
- The catastrophic behaviour: a failed `cuInit` does not unwind cleanly on this stack. Some partial state has already been set up on the GPU (we observed 1 MiB allocated and never freed). Minutes later, the host kernel-panics — no flushed logs, forced reboot the only recovery.

**Fix:** the loader script pre-loads `nvidia_uvm` after `nvidia` binds, via `modprobe --ignore-install nvidia_uvm` (the `--ignore-install` flag bypasses our own block). With `nvidia_uvm` already loaded, no later `cuInit` call ever has to invoke modprobe; CUDA initialisation finds everything it needs and succeeds cleanly.

Validated 2026-05-01: with `nvidia_uvm` pre-staged, the CUDA Driver API smoke test (`cuInit -> cuMemAlloc -> cuMemcpyDtoH`) passes end-to-end, returns 0 MiB used after cleanup (no leak), and the host survives the 30 s post-test idle window without any delayed panic. See `archive/cuda-validation-2026-05-01/` for evidence.

The install lines in `etc/modprobe.d/aorus-egpu-compute-only.conf` remain because they still serve their original purpose — preventing arbitrary processes from triggering an `nvidia` or `nvidia_uvm` load before our service has bound them. We just route around them at boot via the loader's `--ignore-install`.

### Problem 4: The close-path bug also affects `/dev/nvidia-uvm` (RESOLVED 2026-05-08 — UVM-side bug class empirically does not reproduce; uvm-keepalive retired)

A delayed-discovery extension of Problem 2, identified on 2026-05-02 during the ollama bring-up that followed the validated `cuInit` work above. Full evidence at `/root/ollama/docs/freeze-2026-05-02-1032.md` and the forensic snapshot at `/root/ollama/archive/freeze-2026-05-02-1032/`.

Persistenced's mitigation in Problem 2 holds `/dev/nvidiactl` and `/dev/nvidia0` open. It does NOT cover `/dev/nvidia-uvm` (or `/dev/nvidia-uvm-tools`). Confirmed via `lsof -p $(pidof nvidia-persistenced)`: zero fds on either UVM device file.

CUDA processes (vLLM, ollama, anything that calls `cuInit`) open `/dev/nvidia-uvm` for unified memory. When such a process exits, it closes UVM. If it was the LAST opener of UVM at that moment, the kernel/GSP runs the same close-side teardown that Problem 2 documents — but on UVM rather than `/dev/nvidia0` — and a future open hangs the host. Identical silent-hang fingerprint: no Xid, no NVRM, no AER, no panic, no coredump.

The bug is probabilistic: not every CUDA-process exit triggers the wedge, and the wedge often manifests minutes later when an unrelated background process (e.g. PackageKit during `dnf-makecache`) makes the next UVM open. ollama amplifies the exposure because its daemon spawns short-lived `ollama runner` subprocesses for discovery (4 runners on startup) and one per inference; every runner exit is a potential UVM close-path event.

**Status update 2026-05-08 — UVM bug class empirically does not reproduce; original framing was inaccurate.** Patch 0030 added UVM close-path DIAG instrumentation analogous to Patch 0029. n=3 single-shot probes (`tools/uvm-close-path-probe.sh`) plus n=3 churn probes (`tools/uvm-churn-probe.sh` mimicking the 2026-05-02 ollama-runner-churn pattern: 4× rapid cuda-smoke + 60s idle + 1× delayed cuda-smoke) — **6 total reproductions, all benign.** UVM `uvm_va_space_destroy` only does UVM-internal cleanup (page tables, channels, mappings); it does **not** touch GSP, WPR2, or PCIe link state. WPR2 stays at `0x07f4a000` (UP), link stays Gen3, no AER signals, Lever M-recover never fires. The original Problem 4 framing — "the kernel/GSP runs the same close-side teardown that Problem 2 documents — but on UVM" — was a pattern-matched inference that does not match what UVM's close-path actually does on this driver build.

**Original fix (2026-05-02 → 2026-05-08, now retired):** `aorus-egpu-uvm-keepalive.service` — a small shell helper that opens `/dev/nvidia-uvm` and `/dev/nvidia-uvm-tools` read-write, `echo`'s a status line, and `exec sleep infinity`. With the helper held open, the open-count on each UVM device file never drops below 1, the close-side teardown never runs, and subsequent opens always succeed. Same shape of mitigation as persistenced for `/dev/nvidia0`.

**Retirement 2026-05-08:** `aorus-egpu-uvm-keepalive.service` retired (`systemctl disable --now`; `apply.sh` updated to disable on apply). Binary + unit preserved as documented archive of the workaround era. UVM teardown duration (~74ms) plus light next-open re-init give the keepalive negligible warmup-latency value — qualitatively different from persistenced's case where the /dev/nvidia0 close-path costs ~1.3s GSP-boot per cycle. See `docs/service-retirement-roadmap.md` for the retirement record + resurrection criteria.

**Boot-time prerequisite (discovered 2026-05-02 the hard way):** `modprobe nvidia_uvm` only creates `/dev/nvidia-uvm` via devtmpfs — it does **NOT** create `/dev/nvidia-uvm-tools`. The `-tools` device file gets materialised lazily, by the first userspace caller to invoke `nvidia-modprobe -u -c 0` (or by a CUDA process triggering the same path internally). Without an explicit creation step, the keep-alive's `ConditionPathExists=/dev/nvidia-uvm-tools` fails at boot, the unit skips, and the system runs unprotected. The aorus-egpu-compute-load-nvidia loader script invokes `nvidia-modprobe -u -c 0` immediately after `modprobe --ignore-install nvidia_uvm` to materialise both UVM device files before the keep-alive's condition check runs. The bare invocation `nvidia-modprobe -u` (without `-c 0`) is a no-op; `-u -c 0 -c 1` is destructive (creates additional UVM devices at minors 1 and 2 that overwrite the canonical files). `-u -c 0` is the only correct form.

## How the configuration enforces this

> **Status note 2026-05-08:** this section describes the live system as
> currently deployed. Three userspace workaround services have retired
> this week; their entries below are marked **RETIRED** with the date
> and the binary/unit preservation policy. Per project pattern, retired
> services keep their helper script in `usr/local/sbin/` and unit file
> in `etc/systemd/system/` as documented archive of the workaround era,
> with `enabled=disabled` in systemd. Resurrection (if a regression ever
> reproduces the original failure) is `systemctl enable --now`.

### Boot args

See `etc/kernel/cmdline.txt`. Kernel-level fixes for problem 1 plus defence-in-depth nouveau blacklist (in 3 forms, one for each path: cmdline, initramfs, modprobe).

### udev rules

`79-aorus-egpu-no-autoload.rules`:

- Sets `driver_override=aorus_5090_manual` on the GPU. PCI's `drivers_autoprobe` will not auto-bind any registered driver to a device with a `driver_override` that does not match. `aorus_5090_manual` is a fictitious driver name, so nothing binds.
- Clears `ENV{MODALIAS}` before systemd-udevd's `80-drivers.rules` matcher runs. This stops `kmod` from loading `nvidia` from a generic PCI modalias autoload event. (Just having `driver_override` is not enough, because the module would still load by alias even without binding.)
- Mirror behaviour for the HDMI audio function (`10de:22e8`), with a `RUN+=` calling `aorus-egpu-disable-audio` to actively unbind it from `snd_hda_intel` if it ever did bind.

`81-aorus-egpu-compute-power.rules`:

- For each device on the eGPU PCI path (TB controller, bridge, GPU, audio), forces `power/control=on` (no autosuspend) and `d3cold_allowed=0` (no D3cold). Without this, runtime PM can put the path into D3cold; coming back out over the TB tunnel is unreliable.

### modprobe configs

`aorus-egpu-compute-only.conf`:

- `blacklist nvidia / nvidia_modeset / nvidia_uvm / nvidia_drm` - blocks udev/modalias autoload.
- `install nvidia /bin/false` - and equivalents - turns explicit `modprobe nvidia` calls (e.g. by NVIDIA's RPM scriptlets, by `nvidia-modprobe`, by other tools) into no-ops.
- `options nvidia_drm modeset=0 fbdev=0` - belt and suspenders: even if `nvidia_drm` somehow loads, it will not register a DRM device.

The loader script bypasses these blocks with `modprobe --ignore-install nvidia`.

`blacklist-nouveau.conf` - additional defence in depth; redundant with cmdline.

### systemd

`aorus-egpu-compute-load-nvidia.service`:

- `After=systemd-udev-settle.service bolt.service`, `Before=graphical.target`. The eGPU must be enumerated and authorized before this runs; persistenced and GDM must come after.
- `ConditionPathExists=/sys/bus/pci/devices/0000:04:00.0` - skip cleanly if the eGPU is not connected.
- `Type=oneshot, RemainAfterExit=yes` - one-shot bind, then stays "active (exited)" so dependents (persistenced) can `Requires=` it.
- Calls `/usr/local/sbin/aorus-egpu-compute-load-nvidia`, which: applies upstream PM policy; verifies BAR0 and BAR1; clears `driver_override`; `modprobe --ignore-install nvidia`; pokes `drivers_probe`; restores `driver_override` to prevent any future auto-rebind to a wrong driver; `modprobe --ignore-install nvidia_uvm`; runs `nvidia-modprobe -u -c 0` to materialise both `/dev/nvidia-uvm` and `/dev/nvidia-uvm-tools` (see Problem 4).

`nvidia-persistenced.service.d/aorus-egpu.conf` (drop-in):

- `After=` and `Requires=aorus-egpu-compute-load-nvidia.service` - persistenced will only start if the GPU is bound, and it will start after the bind.
- `ConditionPathExists=/sys/bus/pci/devices/0000:04:00.0` - skip cleanly with eGPU disconnected (mirrors the bind service).
- `Restart=no` - explicitly disable systemd auto-restart. If persistenced dies while `nvidia` is loaded, restarting it would close+reopen device files and freeze the host. Better to fail loud.

`aorus-egpu-uvm-keepalive.service` — **RETIRED 2026-05-08 evening:**

- Originally complemented persistenced for `/dev/nvidia-uvm` + `/dev/nvidia-uvm-tools` (see Problem 4 above for original rationale).
- Retirement evidence: Patch 0030 instrumentation + n=3 single-shot probes + n=3 churn probes (6 total UVM close-path reproductions, all benign). UVM teardown duration ~74ms, doesn't touch GSP/WPR2/link state — qualitatively different from /dev/nvidia0's close-path. See [`service-retirement-roadmap.md`](./service-retirement-roadmap.md) for full retirement record + resurrection criteria, [H22 ledger](./reliability-hypothesis-ledger.md#h22) for the empirical work.
- Binary at `usr/local/sbin/aorus-egpu-uvm-keepalive` and unit at `etc/systemd/system/aorus-egpu-uvm-keepalive.service` preserved as documented archive.
- Note: prior to 2026-05-08 this service was kept alive by a `Requires=` in `ollama.service.d/aorus-egpu.conf` even after `systemctl disable`; that dependency was also removed.

`aorus-egpu-pcie-tune.service` (Lever H9a) — **RETIRED 2026-05-08 morning:**

- Originally applied CTV=2 (1-10ms range A2) on TB host port (0000:00:07.0) and GPU (0000:04:00.0) via setpci writes to DevCtl2 register. Intended as defensive measure pending H9a resolution.
- Retirement reason: H9a investigation 2026-05-08 identified this service as the *cause* of 100% Port A boot failures. Tight DevCtl2 timeout caused TB-tunneled config reads to time out → driver classified GPU as PCI-not-PCIe → rm_init failed. Disabling the service restored Port A boot reliability.
- See [`reliability-hypothesis-ledger.md`](./reliability-hypothesis-ledger.md) and project memory `project_port_a_h9a_root_cause_2026_05_08.md`.

`aorus-egpu-wpr2-recovery.service` (Lever R Tier 1 v3) — **PENDING RETIREMENT (5/10 Phase 5 evidence):**

- Detects boot-time WPR2-stuck condition and executes the validated PCI `remove + rescan + reset` sequence to recover a GPU that's bound but failed GSP init.
- Currently active as belt-and-braces backup during Phase 5 evidence collection. With Lever M-recover patches landed (0024 + 0026 + 0027 + 0028) the in-driver recovery path is the primary mitigation; the L4 helper is now redundant on every boot since H9a retirement (no GSP_LOCKDOWN events occurring).
- Retirement gate: n≥10 cold-cold-boots with verdict `M-RECOVER-NOT-FIRED` in `archive/phase5-evidence/` AND `no-op,GPU healthy` in `wpr2-recoveries.log` for the same boot. See [`service-retirement-roadmap.md`](./service-retirement-roadmap.md).
- Idempotent: if `nvidia-smi` shows a working GPU at start, exits 0 immediately (no-op).
- See [`lever-R-design.md`](./lever-R-design.md) for full three-tier strategy.

`aorus-egpu-lever-m-phase5-snapshot.service` (added 2026-05-08, Phase 5 evidence collector):

- One-shot oneshot post-boot snapshot of M-recover state, kill-switch state, post-rmInit-{OK,FAIL} count, close-path event counts, L4 helper records this boot, GPU functional check, and a `## Verdict` line.
- Writes `archive/phase5-evidence/<boot-iso>.log` (one file per boot, idempotent via /proc/stat btime).
- Used to track Phase 5 evidence progress toward the wpr2-recovery retirement gate (n≥10 above).

`aorus-egpu-observability-watchdog.service` (redesigned 2026-05-07, passive):

- Detects Mode B silent freeze candidates via passive sysfs reads (no `/dev/nvidia*` opens).
- Triggers SysRq dumps (`l`/`t`/`w`/`m`) on detection — captures per-CPU backtraces, blocked tasks, memory state into dmesg for forensic analysis post-reboot.
- Original 10s `nvidia-smi -L` poll (close-path triggering) was replaced with sysfs-only checks 2026-05-07 task #108.

### Other state

- `nvidia-fallback.service` masked. It would run `modprobe nouveau` on NVIDIA failure, fighting our nouveau blacklist.
- `nvidia-powerd.service` disabled. Opens/closes device files; would re-trigger the wedge.
- `nvidia-suspend / -resume / -hibernate` enabled (default). These run during sleep transitions; we accept the small risk of suspend issues for normal sleep behaviour.
- `nvidia-settings` user autostart neutralized via `Hidden=true` in `/etc/xdg/autostart/nvidia-settings-user.desktop`.

## Why GNOME stays stable

GNOME on Wayland uses `i915` as its DRM device for the internal Intel Arc. We never expose an NVIDIA DRM device:

- `nvidia_drm` is blacklisted with `install ... /bin/false`.
- The loader explicitly errors out if `nvidia_drm` ends up loaded.
- `driver_override=aorus_5090_manual` plus cleared `MODALIAS` means GNOME's `switcheroo-control` and friends see the eGPU on PCI but nothing has bound it as a display device.

Validated: across many test boots, `/sys/class/drm/card*` always shows only `card1: i915`.

## Why the eGPU stays cool

The AORUS AI Box's water cooling pump and fan are driven by the NVIDIA driver. With the driver unloaded, the device sits with no thermal control. The boot path here ensures the driver loads as early as possible (right after udev settle and bolt), so thermal management starts in seconds.

Persistence mode keeps the GPU in P8 idle (low power) when not in use, with the fan stable around 30% and idle temperature 45-50C.
