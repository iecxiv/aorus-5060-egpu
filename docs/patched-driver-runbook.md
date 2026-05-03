# Patched-driver runbook — Lever I + Lever J-2 build, install, test, rollback

Operator-level runbook for the bundled patch series. Currently four
patches in `patches/`:

| # | Patch | Lever | Purpose |
|---|---|---|---|
| 0001 | `osHandleGpuLost-retry-on-transient-pcie-failure.patch` | I | Multi-retry on `NV_PMC_BOOT_0` read in `osHandleGpuLost` to prevent permanent declared-lost on transient PCIe failures |
| 0002 | `rcdbAddRmGpuDump-shortcircuit-on-gpu-lost.patch` | J-2 | Primary deadlock-prevention fix — short-circuit `rcdbAddRmGpuDump` on `PDB_PROP_GPU_IS_LOST` so the dump cascade never runs on a known-lost GPU |
| 0003 | `nvDumpAllEngines-break-on-gpu-lost.patch` | J-2 | Defence-in-depth — per-iteration guard in `nvdDumpAllEngines_IMPL`, breaks the loop on `PDB_PROP_GPU_IS_LOST` or `PDB_PROP_GPU_INACCESSIBLE` |
| 0004 | `cleanup-asserts-accept-gpu-lost.patch` | J-2 | Relax cleanup-path asserts in `rs_client.c`, `rs_server.c`, `journal.c:2239` to accept `NV_ERR_GPU_IS_LOST` |

For the *why* and the source-review trail:

- `docs/freeze-investigation-plan.md` (Lever I and Lever J-2 sections)
- `docs/source-review-notes.md` Pass 3 (failure model), Pass 6 (J-2
  patch surface), Pass 7 (Lever I patch surface), Pass 8 (J-2 patch
  realisation)

Lever I and Lever J-2 are **complementary, not redundant**:

- Lever I prevents the trigger on transient PCIe failures (`PDB_PROP_GPU_IS_LOST`
  is never set if the transient clears within 1 ms)
- Lever J-2 keeps the kernel alive when `PDB_PROP_GPU_IS_LOST` IS set
  (real GPU disconnect, transient longer than Lever I's retry budget)

The build harness `tools/build-patched-driver.sh` iterates over all
`patches/*.patch` in lexical order, so deploying the full bundle is a
single build invocation. Patches can be selectively skipped by moving
them out of `patches/`.

## Pre-flight

1. **Source must be cloned** at `/root/nvidia-open-src/` and on tag
   `595.71.05`. To clone or refetch:

   ```bash
   git clone --depth 1 -b 595.71.05 https://github.com/NVIDIA/open-gpu-kernel-modules /root/nvidia-open-src
   # or, if already cloned:
   git -C /root/nvidia-open-src fetch --tags
   git -C /root/nvidia-open-src checkout 595.71.05
   ```

2. **Confirm current driver state.** The build assumes the running
   kernel module is the NVIDIA-CUDA-repo-managed
   `kmod-nvidia-open-dkms-595.71.05`:

   ```bash
   modinfo nvidia | grep -E '^(version|srcversion):'
   # version:        595.71.05
   # srcversion:     58D233B8E3F4A2973D73151
   ```

   If `srcversion` already differs from `58D233B8E3F4A2973D73151`,
   either a previous Lever I build is loaded (check `dmesg | grep
   'AORUS Lever'`) or you're on a different driver version (re-baseline
   the patch).

3. **eGPU state recommendation.** The build itself does not touch the
   GPU. **Recommended state: eGPU disconnected during build** so any
   build-time module reload doesn't perturb the running driver. Build
   completes regardless; reconnect before the test pass.

4. **Kernel headers must be installed** for the running kernel:

   ```bash
   ls -d /lib/modules/$(uname -r)/build
   ```

   On Fedora: `sudo dnf install kernel-devel-$(uname -r)`.

5. **Snapshot if you want a safety net.** Lever I changes module
   binaries under `/lib/modules/`; a btrfs snapshot of `/` lets you
   roll back to a known-good state even if rollback via the script
   misbehaves. See `tools/migration-snapshot.sh`.

## Build + install

```bash
sudo /root/aorus-5090-gpu/tools/build-patched-driver.sh
```

What the script does (concretely):

1. Verifies preconditions (source cloned, on right tag, kernel headers
   present, running as root).
2. Resets source to clean state via `git checkout -- src kernel-open`
   (discards any prior in-tree changes).
3. Applies every patch in `patches/*.patch` in lexical order. Idempotent:
   skips patches that are already applied.
4. Builds via `make -j$(nproc) modules SYSSRC=/lib/modules/$(uname -r)/build`.
   Build log: `/tmp/build-patched-driver.log`.
5. **Backs up the dnf-managed `.ko.xz` files** to sibling files named
   `nvidia*.ko.xz.dnf-stock-<timestamp>`.
6. Compresses our built `.ko` with `xz` (matching dnf packaging) and
   installs to `/lib/modules/$(uname -r)/extra/`.
7. Runs `depmod -a $(uname -r)`.
8. **Does NOT reboot.** Prints the next-step instructions.

The script is idempotent: re-running with the same patch series
applied does nothing destructive. If patches conflict (e.g., after a
driver upgrade changed the lines we patch), the script aborts before
touching anything in `/lib/modules/`.

## Reboot + verify

```bash
sudo reboot
```

After reboot:

```bash
# 1. Confirm the patched module loaded (srcversion will differ from stock):
modinfo nvidia | grep -E '^(version|srcversion):'
# Expected:
#   version:        595.71.05
#   srcversion:     <DIFFERENT FROM 58D233B8E3F4A2973D73151>

# 2. Confirm patch presence indirectly via the new init message lookups:
dmesg | grep -i 'NVRM: loading'
# (Should show 595.71.05 Release Build, same as stock.)

# 3. Confirm baseline platform health:
sudo /usr/local/sbin/aorus-5090-status
# Expected: all green; same 77 OK / 6 WARN / 0 FAIL as before.

# 4. eGPU operations should be functional at idle:
nvidia-smi
# Expected: GPU shown as idle, P8 power state.
```

## Test

```bash
cd /root/ollama
sudo ./tools/run-with-telemetry.sh
```

This is the same lite test we've run with each lever (qwen2.5:0.5b
+ "Write one sentence about Paris."). The fsync'd telemetry harness
captures CSVs + a context dump + a dmesg snapshot at start.

### What to watch for (in priority order)

#### Outcome A — test completes successfully

```bash
# After the test:
dmesg | grep -iE 'AORUS Lever (I|J-2)'
```

If you see lines like:

```
AORUS Lever I: PCIe transient cleared after 2 retries (200 us) - GPU not lost
```

**The patch caught a transient.** Lever I is doing its intended job.
Confirms the "transients are dominant" hypothesis. Significant.

If you see lines like:

```
AORUS Lever J-2 (rcdbAddRmGpuDump): GPU lost, skipping crash dump (was deadlock locus)
AORUS Lever J-2 (nvdDumpAllEngines): GPU lost/inaccessible, skipping remaining engine dumps
AORUS Lever J-2 (rs_client.c:844): cleanup RPC returned GPU_IS_LOST, gracefully ignoring
AORUS Lever J-2 (rs_server.c:259): clientFreeResource returned GPU_IS_LOST, gracefully ignoring
AORUS Lever J-2 (journal.c:2239): rcdbAddRmGpuDump returned 0x... in deferred dump path
```

**The Lever J-2 patches caught a real GPU loss** — i.e. either the GPU
was genuinely lost (eGPU unplugged, hardware fault) OR a transient
exceeded Lever I's 1 ms retry budget. Either way, the kernel survived
where it would have hung before. The workload will have errored out
(cuMemAlloc returns error etc.) but the host stays alive and the user
can investigate at leisure.

If you see *both* Lever I markers AND Lever J-2 markers in dmesg,
that means: I caught some transients (good), and at least one was too
long or a real loss occurred (covered by J-2). Both patches working in
their intended roles.

If `dmesg | grep 'AORUS Lever'` is empty AND the test succeeded,
either no transient occurred during this run (TB transients are
stochastic — a clean run is possible) or the test was somehow shorter
than the trigger window. Run a longer soak (5+ minutes sustained
inference) before declaring victory.

#### Outcome B — test freezes the host

The patch did not catch the trigger. Possibilities:

- The transient lasted longer than 1 ms (unlikely but possible — bump
  the retry budget in the patch and rebuild)
- The trigger isn't a transient at all — bug is elsewhere. Move to
  Lever J-1 (L1 prevention) or Lever J-2 (L3 graceful failure).
- The patched module didn't load (verify srcversion in step 1 above).

After cold-boot, examine the captured telemetry:

```bash
ls -lat /root/ollama/archive/lite-* | head -3
cat /root/ollama/archive/lite-<latest>/timeline.txt
journalctl --boot=-1 --no-pager -k | grep NVRM | head -50
```

Note: with our fsync harness, the kernel error sequence should be
preserved. Look specifically for whether `AORUS Lever I:` lines were
logged before the freeze (proving the patch ran) or whether the freeze
hit before any retry (proving something else triggered the loss-
declaration path that bypasses our patched site).

#### Outcome C — test fails differently

Anything else: clean error code, partial work, longer-than-expected
runtime followed by graceful failure. Save the full archive directory
for analysis.

## Longer soak (only after Outcome A confirmed)

If the lite test passes, validate stability before declaring Lever I a
fix:

```bash
# Sustained inference for ~5 minutes:
for i in $(seq 1 30); do
    curl -sS -X POST http://127.0.0.1:11434/api/generate \
        -H 'Content-Type: application/json' \
        -d '{"model":"qwen2.5:0.5b","prompt":"Write one paragraph about Paris.","stream":false}' \
        | jq -r '.response | .[0:80]'
    sleep 5
done
```

Watch for any freeze, throttle, or `dmesg` AER/NVRM error during the
loop. If clean for 30 iterations, escalate to a heavier model (e.g.
qwen2.5:14b) for the next pass.

## Rollback

If the patched module misbehaves, reverts via the backup files the
build script saved:

```bash
# Find the most recent backup:
ls -lat /lib/modules/$(uname -r)/extra/nvidia.ko.xz.dnf-stock-* | head -1

# Restore it:
TS="$(ls -1t /lib/modules/$(uname -r)/extra/nvidia.ko.xz.dnf-stock-* | head -1 | sed 's/.*\.dnf-stock-//')"
for ko in /lib/modules/$(uname -r)/extra/*.ko.xz.dnf-stock-$TS; do
    target="${ko%.dnf-stock-$TS}"
    sudo cp "$ko" "$target"
done
sudo depmod -a
sudo reboot
```

After reboot, `modinfo nvidia | grep srcversion` should show
`58D233B8E3F4A2973D73151` again.

## Maintenance

The Lever I patched build is **not integrated with DKMS** in this
revision. That means:

| Event | What happens | What to do |
|---|---|---|
| `dnf update kmod-nvidia-open-dkms` | dnf installs new stock module to same path; our patch is overwritten | re-run `tools/build-patched-driver.sh` after the dnf update |
| `dnf update kernel` | DKMS auto-rebuilds the dnf-managed source for the new kernel; our patch is gone | re-run `tools/build-patched-driver.sh` after the new kernel boots |
| `dnf update nvidia-driver-cuda` | usually no module rebuild; safe | nothing to do |

Future improvement: register our patched source as a separate DKMS
package (`kmod-nvidia-open-dkms-aorus-patched` or similar) so DKMS
auto-rebuilds it across kernel upgrades. Out of scope for the testing
phase.

## What this runbook does NOT cover

- L3 graceful-failure patches (5 sites, ~13 lines per
  `docs/source-review-notes.md` Pass 6). Those are Lever J-2; this
  runbook is Lever I only. If/when J-2 patches are added to
  `patches/`, this script will pick them up automatically (it loops
  over all `patches/*.patch`).
- DKMS integration (see Maintenance above).
- Filing a PR upstream (see Lever C, Task #40).
- Validation against non-NVIDIA workloads (e.g., 3DMark Nomad on Linux
  via Wine/Proton). Not part of the testing scope.

## File-and-line index for this lever

| Artifact | Path |
|---|---|
| Patch (unified diff) | `patches/0001-osHandleGpuLost-retry-on-transient-pcie-failure.patch` |
| Build/install script | `tools/build-patched-driver.sh` |
| Source target file | `/root/nvidia-open-src/src/nvidia/arch/nvalloc/unix/src/osinit.c` |
| Source target function | `osHandleGpuLost` (around line 340) |
| Source target hunk | line 357 (the single `NV_PRIV_REG_RD32` read) |
| Stock module location | `/lib/modules/$(uname -r)/extra/nvidia.ko.xz` |
| Backup naming pattern | `nvidia.ko.xz.dnf-stock-<YYYYMMDD-HHMMSS>` |
| Build log (per run) | `/tmp/build-patched-driver.log` |
