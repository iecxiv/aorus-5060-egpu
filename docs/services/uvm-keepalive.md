# Service: aorus-egpu-uvm-keepalive.service

**Status:** RETIRED 2026-05-08
**Layer:** L4 (helper at `usr/local/sbin/aorus-egpu-uvm-keepalive`) + L5 (systemd unit)
**Lifecycle:** introduced 2026-05-02; retired 2026-05-08 (~6 days active)

## Purpose (historical)

Held `/dev/nvidia-uvm` and `/dev/nvidia-uvm-tools` open continuously to prevent the UVM close-path bug (Problem 4 in `architecture.md`). Same shape of mitigation as `nvidia-persistenced` for `/dev/nvidia0`, but for UVM.

## Mechanism (historical)

Tiny shell helper invoked by systemd:

```bash
exec 3</dev/nvidia-uvm 4</dev/nvidia-uvm-tools
echo 'uvm-keepalive: holding /dev/nvidia-uvm + tools'
exec sleep infinity
```

The sleep process inherits fds 3 and 4 and holds them for the lifetime of the unit. Kernel's UVM-side close-path teardown never runs because UVM open-count never drops to zero.

## Why it was retired

**Empirical evidence 2026-05-08:**

- **Patch 0030** added UVM close-path DIAG instrumentation (`uvm-open-entry`, `uvm-release-entry`, `uvm-pre-destroy`, `uvm-post-destroy`, `uvm-release-exit` sites in `nvidia-uvm.ko`)
- **n=3 single-shot probes** (`tools/uvm-close-path-probe.sh`) — drained UVM consumers, ran cuda-smoke-test, observed close path
- **n=3 churn probes** (`tools/uvm-churn-probe.sh`) — explicit reproduction of the 2026-05-02 freeze pattern (4× rapid cuda-smoke + 60s idle + 1× delayed cuda-smoke)
- **Total 6 reproductions, all benign:**
  - `WPR2 = 0x07f4a000` (UP) **unchanged across UVM teardown**
  - `GPU_LnkSta = 0x1043` (Gen3) **unchanged**
  - PMC_BOOT_0 healthy throughout
  - Zero AER signals
  - Lever M-recover counters: fires=0, successes=0, surrenders=0
  - UVM teardown duration: ~74ms (vs /dev/nvidia0 close-path's 629ms)

**Conclusion:** `uvm_va_space_destroy` does UVM-internal cleanup only (page tables, channels, mappings). It does **NOT** touch GSP firmware, WPR2 register, or PCIe link state. The original Problem 4 framing ("UVM close runs the same destabilising teardown as /dev/nvidia0 close") was a pattern-matched inference from Problem 2 that does not match what UVM's close-path actually does on this driver build.

The keepalive's stability value is empirically zero. Performance value is also small (~74ms teardown, similar re-init cost). Both arguments for keeping it are weak.

## Configuration and tuning (historical)

| Knob | Value | Purpose |
|---|---|---|
| `ConditionPathExists=/dev/nvidia-uvm-tools` | unit directive | Skip if UVM module hasn't materialised both device files (relies on `compute-load-nvidia` running `nvidia-modprobe -u -c 0` first) |
| `Restart=no` | unit directive | Restart would be a 1→0→1 transition — exactly what the helper prevents |
| Helper script | trivial | No knobs |

## Retirement actions taken (2026-05-08)

1. `systemctl disable --now aorus-egpu-uvm-keepalive.service` ✓
2. **Found and fixed:** the project's own `ollama.service.d/aorus-egpu.conf` had `Requires=aorus-egpu-uvm-keepalive.service` — was pulling in the service whenever ollama started, regardless of `disabled` state. Removed the dependency.
3. `apply.sh` updated: enable block flipped to disable block (so future `bash apply.sh` preserves retirement)
4. Captured ollama drop-in to repo at `etc/systemd/system/ollama.service.d/aorus-egpu.conf` (was previously only on live system) and added to `apply.sh`'s deploy list
5. Binary at `usr/local/sbin/aorus-egpu-uvm-keepalive` PRESERVED
6. Unit at `etc/systemd/system/aorus-egpu-uvm-keepalive.service` PRESERVED

The retirement is documented in:
- `service-retirement-roadmap.md` (RETIRED row + detail section)
- `architecture.md` (Problem 4 RESOLVED header + retirement note)
- Memory `project_uvm_keepalive_retired_2026_05_08.md`
- Memory `project_close_path_mitigated_2026_05_08.md` (the underlying H22 finding)

## Resurrection procedure

If a future regression observably reproduces the original 2026-05-02 freeze pattern (UVM-side host wedge after CUDA process churn + delayed reopen):

1. **Reproduce + characterise first.** Run `tools/uvm-churn-probe.sh` n=3 on the regressing build. Look in `archive/uvm-churn-probes/<run>/05-dmesg-delta-relevant.log` for actual destabilisation evidence (WPR2 cleared, link demoted, M-recover fires, AER signals).
2. **Document the regression in the hypothesis ledger.** Identify what changed (kernel version, NVIDIA driver version, hardware swap).
3. `systemctl enable --now aorus-egpu-uvm-keepalive.service` — restores the mitigation
4. Re-add `Requires=aorus-egpu-uvm-keepalive.service` to `etc/systemd/system/ollama.service.d/aorus-egpu.conf` — without this, ollama starting will not pull in the keepalive
5. Update apply.sh: flip the disable block back to enable
6. Reboot
7. Verify keepalive is holding fds: `lsof /dev/nvidia-uvm /dev/nvidia-uvm-tools` should show the `sleep` process
8. Update `service-retirement-roadmap.md` + this doc with resurrection date + the regression's cause

## Files installed / consumed

**Currently installed by `apply.sh`** (for resurrection readiness):
- `/etc/systemd/system/aorus-egpu-uvm-keepalive.service` (preserved)
- `/usr/local/sbin/aorus-egpu-uvm-keepalive` (preserved)

`apply.sh` will install both files but disables the service.

## Cross-references

- Empirical evidence: `archive/uvm-close-path-probes/2026-05-08T19-39-07+10-00/` (and 2 more single-shot probes), `archive/uvm-churn-probes/2026-05-08T20-*+10-00/` (3 churn probes)
- Patch 0030 instrumentation: [`docs/lever-catalog.md`](../lever-catalog.md) Lever M-recover entry
- H22 ledger: [`docs/reliability-hypothesis-ledger.md#h22`](../reliability-hypothesis-ledger.md#h22)
- Memory: `project_uvm_keepalive_retired_2026_05_08`, `project_close_path_mitigated_2026_05_08`
- Service retirement roadmap: [`docs/service-retirement-roadmap.md`](../service-retirement-roadmap.md)
- Probe tools: `tools/uvm-close-path-probe.sh`, `tools/uvm-churn-probe.sh`
