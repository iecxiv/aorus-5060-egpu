# Lever Catalog — permanent reliability improvements to the open NVIDIA driver

> **Authoritative reference** for every reliability/recovery mechanism
> we have built or proposed for the NVIDIA open kernel module on this
> hardware. Each entry is a discrete, named, permanent improvement —
> not a workaround, not a debug aid, not a transient patch.
>
> **Last updated:** 2026-05-06

---

## Why this catalog exists

The project (`feedback_project_scope_path_a`) is not "patch around a buggy
driver." It is "build the reliability surface that the open driver lacks
vs the closed Windows driver." Every lever in this catalog is:

1. **Explainable** — motivation grounded in observed evidence and a stated
   hypothesis (cross-referenced in `reliability-hypothesis-ledger.md`)
2. **Testable** — explicit test plan with pass/fail criteria
3. **Reproducible** — re-applicable to fresh upstream NVIDIA source via
   the patch series; each lever specifies the upstream tag it applies
   against
4. **Upstream-ready** — designed so the eventual PR to
   `NVIDIA/open-gpu-kernel-modules` is straightforward when the project
   reaches that maturity

When asked "why is Lever X here?", the answer is found in this catalog:
**Lever X is here, for this reason, as a permanent improvement to the driver.**

---

## Lever class taxonomy

| Class | Purpose | Examples |
|---|---|---|
| **Prevention** | Reduce failure rate (L1 in the three-layer reliability model) | (none yet implemented; H8 DPC was REJECTED at hardware) |
| **Signaling** | Detect failures fast and route them | I, J-2, M-base, Q-passive, Q-active, Q-watchdog |
| **Recovery** | Survive failures cleanly, optionally resume the workload | N, O, M-recover, M-preserve, P-comprehensive, R |
| **Infrastructure** | Plumbing that other levers depend on | M-base (`pci_error_handlers` registration) |

A lever can span multiple classes (e.g. M-base is Infrastructure + Signaling).

---

## Lever index

| ID | Name | Class | Status | Patch | Hypothesis | One-line |
|---|---|---|---|---|---|---|
| I | osHandleGpuLost retry | Recovery | LANDED 2026-05-03 | 0001 | (pre-ledger) | Survive transient bus glitches via 10×100µs retry on PMC_BOOT_0 |
| J-2 | rcdbAddRmGpuDump shortcircuit + 3 sites | Signaling | LANDED 2026-05-04 | 0002-0004 | (pre-ledger) | Prevent crash-dump deadlock on GPU-lost cleanup paths |
| N | rpcRmApiFree_GSP shortcircuit | Recovery | LANDED 2026-05-04 | 0006 | (pre-ledger) | Free RPCs return NV_OK silently when GSP is gone, allowing cleanup to drain |
| O | _issueRpcAndWait shortcircuit | Recovery | LANDED 2026-05-04 | 0008 | (pre-ledger) | RPC dispatch returns NV_ERR_GPU_IS_LOST when state is set, no further GSP poll |
| M-base | pci_error_handlers struct registration | Infrastructure | LANDED 2026-05-04 | 0007 | (pre-ledger) | Register `err_handler` so AER events reach our handler |
| M-recover | slot_reset + resume callbacks | Recovery | TODO #62 | (pending) | H11 | In-driver recovery via kernel's PCIe error machinery |
| M-preserve | State preservation across reset | Recovery | TODO #56 | (pending) | (future H) | Preserve channel/context state across slot_reset |
| P-probe | UVM destroy diagnostic markers (18 sites) | Diagnostic-transient | LANDED 2026-05-04 | 0009 | (pre-ledger) | Locate the deadlock locus inside `uvm_va_space_destroy` |
| P-comprehensive | UVM destroy fail-fast | Recovery | TODO #60 | (pending) | (future H) | Single comprehensive shortcircuit covering all sites P-probe identified |
| Q-passive | osDevReadReg{8,16,32} early-out | Signaling | LANDED 2026-05-04 | 0011-0012 | (pre-ledger) | Skip MMIO read when device known disconnected; return 0xFFFFFFFF |
| Q-active | post-read PMC_BOOT_0 sanity check | Signaling | LANDED 2026-05-04 | 0013 | (pre-ledger) | Verify dead bus and propagate disconnect on suspect 0xFFFFFFFF reads |
| Q-watchdog | Per-device kthread heartbeat | Signaling | LANDED 2026-05-05 | 0014 | (pre-ledger) | Active MMIO probe every 200ms catches DMA-path Mode B silent freezes |
| **R** | **WPR2-stuck detection + auto-FLR at probe** | **Recovery** | **PROPOSED #96** | **(pending)** | **H13** | **Boot-time recovery from WPR2 left over from prior session** |

Total LANDED: 9 levers (across 14 patches). PROPOSED: 1. TODO: 4.

---

## Per-lever specifications

### Lever R — WPR2-stuck recovery (PIVOTED to L4 userspace 2026-05-06)

> **Full design:** [`lever-R-design.md`](./lever-R-design.md) — three-tier strategy with v1/v2/v3 evolution.
> **Tier 1 v1 status:** RETIRED (pcie_reset_flr empirically insufficient).
> **Tier 1 v2 status:** RETIRED (pci_reset_function returns ENOTTY pre-rescan).
> **Tier 1 v3 status:** **LANDED + SUPPORTED at n=1 (2026-05-06 11:08)** — helper validated end-to-end under real cold-cold-boot WPR2-stuck conditions; full 8-step recovery sequence executed automatically; GPU restored. Detection bug found+fixed during validation (`nvidia-smi -L` returns exit 0 even on "No devices found" — must parse stdout for `^GPU N:` pattern). 2026-05-06 12:33 cold-cold-boot reproduction: first pass FAILED (post-recovery bind blocked in conf-compute / gpuSanityCheck flags=0x1, distinct from WPR2-stuck mode); manual retry SUCCEEDED with identical sequence. Drove Tier 2 PARTIAL (retry budget) landing. Need n≥3 cold-cold-boot reproductions WITH retry-budget for PROVEN status.
> **Tier 2 status:** **PARTIAL LANDED 2026-05-06 12:48** — retry budget shipped (MAX_ATTEMPTS=3, RETRY_DELAY_S=5s; per-attempt history-log entries; recovery sequence extracted to `do_recovery_pass()` function). Remaining features (kobject_uevent, kill-switch, per-step watchdog, sysfs counters) DESIGNED, FUTURE — see [`lever-R-design.md` Tier 2 section](./lever-R-design.md#tier-2--telemetry-safety-configurability-follow-up).
> **Tier 3 status:** APPROVED design, FUTURE work (research). Retires the L4 helper service entirely.
> **Forensic dossier:** [`archive/boot-init-mode-b-2026-05-06-074608/`](../archive/boot-init-mode-b-2026-05-06-074608/)
>
> **Architectural framing (corrected 2026-05-06):** L4 is the
> PRAGMATIC landing today. Native in-driver async recovery is the
> architectural DESTINATION (Tier 3). Per
> [`service-retirement-roadmap.md`](./service-retirement-roadmap.md),
> every userspace workaround service in our stack is debt — Tier 3
> retires the L4 service when in-driver recovery proves out.

**Class:** Recovery (L3 in three-layer reliability model)
**Sovereign layer (modularity):** L1 (NVIDIA fork — must be inside `nv_pci_probe` / RM-side `_kgspBootGspRm`)

**Why it exists**

> **2026-05-06 mechanism CORRECTION:** This entry's original framing
> ("WPR2 persists across host poweroff/poweron cycles") was falsified
> by diagnostic telemetry on 2026-05-06 15:47 (see [H13](./reliability-hypothesis-ledger.md#h13)
> + [H14](./reliability-hypothesis-ledger.md#h14)). Actual mechanism:
> WPR2 register transitions from clear (0) to set (0x07f4a000) **during**
> the first failed `rm_init_adapter` call within a boot. Subsequent
> retries see the leftover WPR2 setting. The L4 helper's recovery
> sequence still works (PCI reset clears WPR2) — Lever R remains a
> valid recovery lever — but the *trigger condition* and *prevention
> framing* needed correction.

When `rm_init_adapter` fails on cold-cold-boot for any reason (root
cause tracked as H14 — PMC_BOOT_0 transient observed), the GSP boot
attempt leaves WPR2 register set to 0x07f4a000 in hardware, even though
GSP isn't actually running. `nvidia.ko`'s subsequent `_kgspBootGspRm`
retries detect "WPR2 already up" and refuse to proceed, leaving the
driver in `RmInitAdapter failed` state. The GPU is unbindable until a
PCI reset clears WPR2.

The closed Windows driver does not exhibit this failure (Windows boots
on this hardware reliably) — implying it either prevents the first-call
failure (H14 root cause) or recovers from it gracefully. The open
driver does neither. **Lever R fills the recovery gap. H14
investigation tracks the prevention gap.**

**Symptom without Lever R**

```
NVRM: _kgspBootGspRm: unexpected WPR2 already up, cannot proceed with booting GSP
NVRM: _kgspBootGspRm: (the GPU is likely in a bad state and may need to be reset)
NVRM: RmInitAdapter failed!
```

GPU unbindable; `nvidia-smi` reports "No devices were found"; manual
recovery via FLR (`echo 1 > /sys/.../reset`) or full eGPU AC power cycle
required.

**Mechanism**

1. At `nv_pci_probe` early init (before `_kgspBootGspRm` would normally fire):
   read GSP WPR2 status register
2. If WPR2 is up:
   - Log marker: `AORUS Lever R: WPR2-stuck detected at probe — triggering FLR`
   - Call `pci_reset_function(pci_dev)` (kernel-managed FLR, validated to clear WPR2 per `recovery-mechanism-findings.md`)
   - Brief settle delay (50-100ms)
   - Verify WPR2 cleared
3. Continue probe path normally; GSP init now proceeds against clean state

**Code surface**

| File | Change |
|---|---|
| `kernel-open/nvidia/nv-pci.c` | Insert WPR2 check + FLR + retry at probe entry |
| OR | RM-side `_kgspBootGspRm` modified to attempt FLR on WPR2-stuck before failing |

**Estimated**: ~30 lines, single new patch (`0015-Lever-R-wpr2-stuck-recovery.patch`).

**Test plan**

1. **Unit-level**: induce WPR2-stuck state by killing host process during GSP init, then poweroff. Boot with patched driver. Expect: marker fires, FLR triggers, init succeeds.
2. **Integration**: cold-cold-boot test (overnight power-off) repeated n≥3 times. Pass: each boot successfully binds nvidia.ko within normal probe time.
3. **Regression**: confirm previously-working boots (clean WPR2) still proceed without spurious FLR. Marker should not fire when WPR2 is clean.
4. **Acceptance**: `dmesg | grep 'AORUS Lever R'` shows the marker on cold-cold-boot AFTER a degraded session, AND `nvidia-smi` succeeds within 30s of boot.

**Reproducibility**

- Applies against `NVIDIA/open-gpu-kernel-modules` tag `595.71.05`
- Requires Levers I, J-2, M-base, N, O, Q-passive, Q-active, Q-watchdog already applied (no logical dependency, but expected order)
- DKMS-buildable via project's `tools/build-patched-driver.sh`

**Upstream-readiness**

- **High** — the underlying problem is general (any system that can leave WPR2 stuck would benefit). The fix uses standard kernel PCI APIs.
- Suitable for upstream PR after validation in our environment with n≥10 cold-cold-boots showing reliable recovery.
- Discussion to have with NVIDIA: their position on auto-FLR at probe (some hardware vendors prefer to fail-loud and require operator intervention; others prefer auto-recovery). Our case (TB-attached eGPU on consumer hardware) clearly favours auto-recovery.

**Cross-references**

- Hypothesis: [H13](./reliability-hypothesis-ledger.md#h13) STRONGLY SUPPORTED at n=1
- Forensic evidence: [`archive/boot-init-mode-b-2026-05-06-074608/`](../archive/boot-init-mode-b-2026-05-06-074608/)
- Recovery mechanism: [`recovery-mechanism-findings.md`](./recovery-mechanism-findings.md) (FLR clears WPR2, validated)
- Task: #96
- Related lever: [M-recover](#lever-m-recover) — same `pci_reset_function` machinery, applied at runtime instead of probe-time

---

### Lever I — osHandleGpuLost retry on transient PCIe failure

**Class:** Recovery
**Status:** LANDED 2026-05-03 (patch [0001](../patches/0001-osHandleGpuLost-retry-on-transient-pcie-failure.patch))
**Sovereign layer:** L1

**Why it exists**

The open driver's `osHandleGpuLost` immediately commits to permanent GPU
loss on the first failed register read. On TB-attached hardware,
single-read failures can be transient (cable jitter, link renegotiation).
Without retry, the driver permanently loses the GPU on noise.

**Symptom without it:** transient PCIe glitches that the closed driver
shrugs off cause permanent GPU-lost on the open driver, requiring full
reboot to recover.

**Mechanism:** retry up to 10× with 100µs delay reading `NV_PMC_BOOT_0`.
If any retry succeeds, the GPU is alive — log success and continue.
Only after all 10 retries fail does the driver commit to GPU-lost
state and continue with cleanup.

**Code surface:** ~20 lines in RM-side `osHandleGpuLost`.

**Test plan:** validated by observing the marker fire on transient bus
glitches without committing to permanent loss. Empirical n≥1 in
`lite-153940`.

**Cross-references:** patch 0001; original hypothesis pre-dates ledger.

---

### Lever J-2 — rcdbAddRmGpuDump shortcircuit + 3 companion sites

**Class:** Signaling
**Status:** LANDED 2026-05-04 (patches [0002-0004](../patches/))
**Sovereign layer:** L1

**Why it exists**

When the GPU is lost, the driver's crash-dump path tries to read GPU
registers to populate the dump. Those reads hang against a dead bus,
preventing the cleanup path from completing. Result: kernel deadlock
during cleanup.

**Mechanism:** at the entry of `rcdbAddRmGpuDump` and three companion
crash-dump sites, check `PDB_PROP_GPU_IS_LOST`; if set, return early
without attempting the dump. Cleanup path drains cleanly.

**Test plan:** validated in `lite-145232` and `lite-153940` —
markers fired, deadlock at known previous locus did not recur.

**Cross-references:** patches 0002, 0003, 0004; pre-dates ledger.

---

### Lever N — rpcRmApiFree_GSP shortcircuit

**Class:** Recovery
**Status:** LANDED 2026-05-04 (patch [0006](../patches/0006-rpcRmApiFree-GSP-shortcircuit-on-gpu-lost.patch))
**Sovereign layer:** L1

**Why it exists**

The cleanup path issues many GSP RPCs to free per-context resources.
When GSP is gone, every one of these RPCs blocks on completion poll.
Cleanup wedges with 100+ outstanding free RPCs.

**Mechanism:** at entry of `rpcRmApiFree_GSP`, check `PDB_PROP_GPU_IS_LOST`;
if set, return `NV_OK` silently (the resource is going to be freed by
hardware reset anyway).

**Test plan:** marker fired in `lite-145232` and `lite-153940`;
collapsed 107 cleanup-path assertions to zero.

**Cross-references:** patch 0006; pre-dates ledger.

---

### Lever O — _issueRpcAndWait shortcircuit

**Class:** Recovery
**Status:** LANDED 2026-05-04 (patch [0008](../patches/0008-issueRpcAndWait-shortcircuit-on-gpu-lost-Lever-O.patch))
**Sovereign layer:** L1

**Why it exists**

`_issueRpcAndWait` is the lowest-level GSP RPC dispatcher. Any code path
issuing an RPC on a lost GPU hangs in the wait loop. Lever N covers the
free path; Lever O covers all other RPC dispatch sites at the source.

**Mechanism:** at entry of `_issueRpcAndWait`, check `PDB_PROP_GPU_IS_LOST`;
if set, return `NV_ERR_GPU_IS_LOST` immediately without dispatching.

**Test plan:** marker has not yet been observed firing in real test —
cleanup completes via Levers N and J-2 before Lever O's path is reached.
Defensive coverage; activates if a future code path reaches dispatch
on a lost GPU.

**Cross-references:** patch 0008; pre-dates ledger.

---

### Lever M-base — pci_error_handlers struct registration

**Class:** Infrastructure
**Status:** LANDED 2026-05-04 (patch [0007](../patches/0007-nv-pci-register-error-handlers-Lever-M-base.patch))
**Sovereign layer:** L1

**Why it exists**

The kernel's PCIe AER subsystem routes uncorrectable error events to
the affected driver via `pci_driver.err_handler`. NVIDIA's open driver
does not register this struct; AER events have nowhere to go and are
effectively black-holed. Closed driver registers full handlers.

**Mechanism:** populate `nv_pci_driver.err_handler` with our four
callbacks: `error_detected`, `mmio_enabled`, `slot_reset`, `resume`.
M-base only implements `error_detected` (returns DISCONNECT for now);
the other three are stubs filled in by Lever M-recover.

**Test plan:** struct registered; on AER fire, `error_detected` invoked.
Verified on Mode A failures (e.g. `loop-2026-05-05-182625`).

**Cross-references:** patch 0007; pre-dates ledger. Tied to Phase 4
M-recover (#62).

---

### Lever M-recover — in-driver recovery state machine (LANDED 2026-05-08, Phase 1-4 PASS, Phase 5 in-progress)

**Class:** Recovery
**Status:** **LANDED 2026-05-08** (patches 0024 + 0026 + 0027 + 0028; Phase 1-4 PASS, Phase 5 evidence collection ACTIVE) — see [`lever-m-recover-commit3-hardening-design.md`](./lever-m-recover-commit3-hardening-design.md) for the hardened-reimplementation design that actually shipped, and [`lever-M-recover-design.md`](./lever-M-recover-design.md) for the original canonical design.
**Sovereign layer:** L1
**Hypothesis:** [H11](./reliability-hypothesis-ledger.md#h11) + [H13](./reliability-hypothesis-ledger.md#h13) at full scope; resolves [H15](./reliability-hypothesis-ledger.md#h15) (the storm-prevention hardening)
**Task:** #62

**Why it exists**

The L4 helper (Lever R Tier 1 v3) is empirically race-prone with any
userspace component holding bind-state authority. 2026-05-06 12:56:48
forensic dossier ([`archive/boot-recovery-fail-2026-05-06-125648/`](../archive/boot-recovery-fail-2026-05-06-125648/))
proved that recovery succeeds when persistenced is stopped first, fails
when it's running. Single-arbiter is the only correct architecture, and
the only authority that has unconditional priority is the driver itself.

This is **the architectural destination** that retires:
- L4 helper `aorus-egpu-wpr2-recovery.service` (per `service-retirement-roadmap.md`)
- Lever R Tier 3 (which is the same engineering, viewed from the boot-WPR2 angle)

Lever M-recover delivers the in-driver recovery state machine that
handles BOTH:
- **Boot-time WPR2-stuck** (probe detects, schedules bus reset, kernel re-probes)
- **Runtime AER errors** (error_detected returns NEED_RESET, kernel does bus reset, slot_reset re-inits)

**Mechanism (full design in [`lever-M-recover-design.md`](./lever-M-recover-design.md)):**

**2026-05-06 15:47 mechanism CORRECTED by diagnostic telemetry** (`archive/diag-telemetry-2026-05-06-154732/`). Original "WPR2 stuck across boots" hypothesis FALSIFIED. Actual mechanism: WPR2 register transitions from clear (0) to set (0x07f4a000) *during* the first failed `rm_init_adapter` call within a boot. Subsequent retries see "WPR2 already up" and fail. `0x07f4a000` is the **normal** running WPR2 value; the stuck condition is a *state-mismatch*: WPR2 set but GSP not actually running. See new hypothesis [H14](./reliability-hypothesis-ledger.md#h14) for the root-cause investigation of why the first `rm_init_adapter` fails.

- Recovery primitive: pci-level `remove + rescan + reset` from work-queue context (matching the validated L4 helper sequence) — clears WPR2, kernel re-probes, next `rm_init_adapter` call succeeds
- **Trigger location (sharpened by diagnostic):** post-`rm_init_adapter`-FAIL with WPR2 ≠ 0, in `nv_start_device` (kernel-open/nvidia/nv.c). Probe-time detection (Commit 2 in patch 0017) was based on the falsified hypothesis and is replaced.
- Detection criterion: not "WPR2 non-zero" alone (false positives — that's normal running), but "WPR2 non-zero AFTER rm_init_adapter just returned failure" (unambiguous state-mismatch signal)
- Runtime AER path (separate code path): `error_detected` flipped to NEED_RESET; `slot_reset` and `resume` callbacks. AER may not fire on this hardware (per dmesg history), so this is defensive.
- State eventing: `kobject_uevent_env(KOBJ_CHANGE, AORUS_GPU_STATE=RECOVERING/READY/PERMANENT_FAIL)`
- Module params (production posture set 2026-05-08):
  - `NVreg_AorusLeverMRecoverEnable` (default 0; production posture sets 1 via `/etc/modprobe.d/aorus-egpu-lever-m.conf`; kill-switch file at `/var/lib/aorus-egpu/lever-m-killswitch=0` overrides to 0)
  - `NVreg_AorusLeverMMaxAttempts` (default 3, H1 gate)
  - `NVreg_AorusLeverMResetSettleMs` (default 500ms)
  - `NVreg_AorusLeverMMinAttemptIntervalMs` (default 30000, H2 rate-limit)
  - `NVreg_AorusLeverMSurrenderResetSec` (default 300, H1 burst-boundary idle reset)
  - `NVreg_AorusLeverMTestForceTrigger` (default 0; test-only; forces WPR2-clear branch override inside trigger function)
- Sysfs counters (per-pdev under `/sys/bus/pci/devices/0000:04:00.0/`): `aorus_lever_m_fires`, `aorus_lever_m_successes`, `aorus_lever_m_surrenders`, `aorus_lever_m_last_fire_jiffies`, `aorus_lever_m_force_trigger` (write-only, mode 0200, Phase 3 test path)
- Userspace CLI: `aorus-egpu-lever-m enable|disable|status`
- udev rule: `82-aorus-egpu-lever-m-killswitch.rules` triggers `aorus-egpu-lever-m-killswitch-restore` on nvidia module add (defense-in-depth alongside in-driver `kernel_read_file_from_path`)

**Code surface (LANDED):** ~240 LoC C across `nv-lever-m-recover.{h,c}`, `nv-pci.c`, `nv.c`; ~105 LoC bash + udev; plus Patch 0029 close-path instrumentation. Six patches:
  - **0024** — Commit 3 + H1/H2/H3/H4 hardening (the main patch)
  - **0025** — Kbuild reads `NVIDIA_VERSION` from `version.mk` (eliminated drift bug discovered during Patch 0024 verification; standalone candidate for upstreaming)
  - **0026** — sysfs `aorus_lever_m_force_trigger` for Phase 3 testing
  - **0027** — work handler explicitly dispatches `aorus_lever_m_slot_reset` + `_slot_reset_resume` after `pci_reset_bus` (because `pci_reset_bus` does NOT go through `pci_error_handlers`; only AER does — production WPR2-stuck recoveries come through the manual path, so without 0027 they never get success accounting or READY uevent)
  - **0028** — attempt_count resets at post-rmInit-OK (verified end-to-end recovery), not at slot_reset_resume — makes H1 MaxAttempts gate reachable in real recovery storms (without this, attempt_count cycles 0→1→0 every iteration and the gate is unreachable; this is the bug pattern from the original 2026-05-06 storm)
  - **0029** — close-path DIAG instrumentation + AER err_handlers surface completion. Adds 4 close-path DIAG sites (close-entry, pre-stop, post-shutdown, close-exit) gated on LAST-CLOSE; mmio_enabled + cor_error_detected callbacks. Companion script: `tools/close-path-probe.sh` for controlled close-path observability experiments. Empirically demonstrated 2026-05-08 (n=3 probes, dossiers in `archive/close-path-probes/`) that the close-path bug class (architecture.md Problem 2) is mitigated on the current cumulative driver stack — second open succeeds in ~1.3s, no host wedge, fires=0. Reclassified persistenced as performance optimization (no longer load-bearing for stability).

**Test plan results:**
- **Phase 1 PASS (build verification)** — modinfo nvidia shows all 6 module params; build clean; modprobe loads
- **Phase 2 PASS (cold-boot baseline)** — Enable=0 default behaves as M-base; DIAG telemetry intact; no regressions
- **Phase 3 PASS (manual trigger via sysfs force_trigger)** — `force_trigger` fired clean recovery sequence: `scheduling recovery` → `bus-reset starting` → `pci_reset_bus OK` → `slot_reset RECOVERED` → `resume → emitting READY`. ~681ms total; GPU re-bound; PCIe link re-trained Gen1 → Gen3 automatically; `success_count=1`
- **Phase 4 H1 PASS (MaxAttempts)** — 4 fires spaced 31s apart (persistenced stopped so post-rmInit-OK doesn't reset counter): fires 1-3 do real bus resets accumulating attempt_count; fire 4 logged `surrender after 4 attempts (max=3); emitting PERMANENT_FAIL` and skipped the bus reset. Final counters: fires=3, successes=3, surrenders=1
- **Phase 4 H2 PASS (rate-limit)** — fire #2 at 2s after fire #1 logged `(H2): rate-limited (last fire 2015ms ago, min 30000ms); deferring`; fires not incremented
- **Phase 4 H3 PASS (kill-switch persistence)** — `aorus-egpu-lever-m disable` + `modprobe -r nvidia + modprobe nvidia` → `kill-switch file engaged (/var/lib/aorus-egpu/lever-m-killswitch=0); overriding NVreg_AorusLeverMRecoverEnable to 0` fired during init even though modprobe.d explicitly set Enable=1; round-trip enable + reload returned to runtime=1
- **Phase 4 H4 deferred** — needs natural AER fire which we can't synthesise on demand
- **Phase 5 ACTIVE (criterion REVISED 2026-05-08 evening)** — `aorus-egpu-lever-m-phase5-snapshot.service` writes `archive/phase5-evidence/<boot-iso>.log` per cold-boot with verdict line. Original criterion "n≥10 `M-RECOVER-FIRED-OK`" became unreachable after H9a retirement eliminated the WPR2-stuck failure mode (see [H16 falsification](./reliability-hypothesis-ledger.md#h16) and recovery log evidence). **Revised criterion:** n≥10 consecutive cold-cold-boots with (a) `M-RECOVER-NOT-FIRED` snapshot verdict AND (b) `no-op,GPU healthy` in `wpr2-recoveries.log` for the same boot. Currently at 9/10. M-recover stays in-driver as regression insurance; once criterion met, retire L4 helper.

**Service retirement:** L4 helper (`aorus-egpu-wpr2-recovery.service`) retires upon n≥10 PROVEN (cold-cold-boot recoveries via the in-driver path with `post-rmInit-FAIL ≥ 1` and `M-RECOVER-FIRED-OK` verdict). Remains in `usr/local/sbin/` as documented archive of the workaround era. See `service-retirement-roadmap.md`.

**Upstream-readiness:** High — `pci_error_handlers` is the standard kernel pattern; many vendor drivers implement it. Patches separable into upstream-friendly slices: Patch 0025 (Kbuild version source-of-truth) is the cleanest standalone candidate; 0024 main hardening would need NVIDIA-internal review for the hardware-specific WPR2 register read and the AORUS-namespaced sysfs/uevent surface. Realistic timeline: 6-12 months after Phase 5 PROVEN here, with NVIDIA co-development.

**Cross-references:**
- [`lever-M-recover-design.md`](./lever-M-recover-design.md) — full design
- [`lever-R-design.md`](./lever-R-design.md) Tier 3 — converges into M-recover
- [`recovery-mechanism-findings.md`](./recovery-mechanism-findings.md) — bus reset primitive evidence
- [`archive/boot-recovery-fail-2026-05-06-125648/`](../archive/boot-recovery-fail-2026-05-06-125648/) — empirical justification
- [H11](./reliability-hypothesis-ledger.md#h11), [H13](./reliability-hypothesis-ledger.md#h13)
- Tasks: #62 (Phase 4 M-recover), #98 (Lever R Tier 3 — converges)

**Mode B telemetry extensions (patch 0023, LANDED 2026-05-08):**
- **S1 — `aorus_dump_aer_trigger_event()`** new public helper in
  `nv-lever-m-recover.c`. Reactive AER + DPC + link-state snapshot
  emitted as one printk block; called from Q-watchdog detection AND
  `nv_pci_error_detected`. Walks GPU → bridge → root_port. Permanent —
  becomes the canonical "dump AER state at fault time" function for
  any future error_handler / slot_reset path.
- **S2 — `[DIAG-AER2]` follow-up line** at the existing 4 DIAG sites
  (probe-end / startdev-entry / pre-rmInit / post-rmInit-OK|FAIL).
  Adds bridge AER masks, root port AER state + RootSta, DPC capability
  state. Always emitted (not gated). Transitional — gate behind
  `NVreg_AorusLeverMDiagEnable=0` default-off when Commit 3 lands.
- See [`mode-b-telemetry-patch-design.md`](./mode-b-telemetry-patch-design.md)
  for full design, build notes, and lifetime/permanence assessment.

---

### Lever Q (passive + active + watchdog) — three-stage MMIO health

**Status:** Q-passive and Q-active LANDED 2026-05-04, Q-watchdog LANDED 2026-05-05
**Sovereign layer:** L1
**Patches:** [0010-0014](../patches/)
**Cross-references:** [`lever-Q-design.md`](./lever-Q-design.md) for full design rationale

**Why it exists (combined)**

The open driver does not have any active mechanism to detect that a
TB-attached GPU has dropped off the bus mid-operation. Mode B silent
freezes (host wedge with no signal) result. Q-stack adds three layers
of detection:

| Sub-lever | Mechanism | Purpose |
|---|---|---|
| Q-passive | Wraps `osDevReadReg{8,16,32}` with early-out when `os_pci_disconnected==1` | Avoid hung reads on subsequent calls after first detection |
| Q-active | Post-read sanity check on `NV_PMC_BOOT_0` for any 0xFFFFFFFF read | First-fire detection of dead bus from MMIO read path |
| Q-watchdog | Per-device kthread reading PMC_BOOT_0 every 200ms | Catch failures that don't fire MMIO reads (DMA-path Mode B) |

**Test plan:**
- Q-active: validated on `loop-2026-05-05-182625` and the boot-init failure 2026-05-06 07:46 — fires correctly when bus drops
- Q-passive: validated by observing it short-circuits subsequent reads in same dmesg slices
- Q-watchdog: kthread alive on all aorus.3 boots; has not yet caught a Mode B that the userspace path missed (small sample)

**Open issue with Q-watchdog spawn timing:** kthread spawns at the END of
`nv_pci_probe`, so cannot catch boot-init failures (per H13 forensic dossier).
Future enhancement: move spawn earlier OR add a separate boot-time probe.

**Mode B telemetry S3 extension (patch 0023, 2026-05-08):** Q-watchdog
`struct aorus_qwatchdog` extended with persistent detection state,
populated atomically by the kthread inside the `detected_logged` latch
(once per disconnect episode, not per cycle). Three new sysfs files
expose the state:

```
/sys/bus/pci/drivers/nvidia/<gpu_bdf>/aorus_qwatchdog_last_detection_jiffies
/sys/bus/pci/drivers/nvidia/<gpu_bdf>/aorus_qwatchdog_last_pmc_boot_0
/sys/bus/pci/drivers/nvidia/<gpu_bdf>/aorus_qwatchdog_last_aer_summary
```

Lets cross-boot post-mortems read what AER looked like at the moment of
the most recent Mode B detection without parsing kernel log. Designed
to be picked up automatically by `tools/state-capture/state-capture.sh`
section 124. Lifetime: tied to Q-watchdog's lifetime (retires when
Q-watchdog retires).

**Open hypothesis (project memory `feedback_observability_perturbs_bug`):**
H1 — Q-watchdog kthread MMIO probe might convert Mode A → Mode B.
n=1 each side, unresolved. The S3 telemetry doesn't change this concern
(reactive only) but gives us better data to investigate it.

---

### Lever P-probe / P-comprehensive

**Status:** P-probe LANDED 2026-05-04 (transient diagnostic, patch [0009](../patches/0009-uvm-destroy-diagnostic-markers-Lever-P-probe.patch));
P-comprehensive TODO #60

**Note:** P-probe is the one lever in this catalog that is INTENTIONALLY
transient. It exists to identify the precise locus inside
`uvm_va_space_destroy` that deadlocks; once located, P-comprehensive
will be a single fail-fast patch covering all identified sites, and
P-probe will be retired.

This is a deliberate exception to the "permanent" framing. Documented
here so the catalog is honest about the lifecycle of each entry.

---

## Adding a new lever — template

When proposing or implementing a new lever, fill in this structure as
either an entry in this catalog OR a separate `lever-X-design.md`
referenced from the index above.

```markdown
### Lever T — IOMMU disable cmdline workaround for TB-eGPU GSP lockdown

**Class:** Prevention (partial — eliminates IOMMU-class trigger; doesn't address H16 transient)
**Status:** **VALIDATED 2026-05-07 14:54** as best practical mitigation today; production-suitable for personal-workstation threat model
**Sovereign layer:** L5 (kernel cmdline)
**Hypothesis:** [H10](./reliability-hypothesis-ledger.md#h10), [H14](./reliability-hypothesis-ledger.md#h14)
**Patch:** none (pure cmdline)

**Why it exists**

Linux kernel marks Thunderbolt-attached PCI devices as `untrusted` by
default. The IOMMU subsystem honors this by enforcing DMA translation
even when `iommu=pt` is on the cmdline. On the AORUS RTX 5090 eGPU,
this causes IOMMU to reject the GSP firmware's runtime DMA setup,
which in turn causes GSP firmware to enter LOCKDOWN mode and refuse
to boot. See [`docs/iommu-gsp-lockdown-analysis.md`](./iommu-gsp-lockdown-analysis.md).

The closed Windows driver works on the same hardware (per Lever G WSL2
evidence) by correctly pre-registering DMA mappings via `iommu_map_*`
calls. The open driver lacks this. Lever T is a kernel-side workaround
that bypasses the issue entirely by disabling IOMMU.

**Symptom without it**

```
DMAR: [DMA Read NO_PASID] Request device [04:00.0] fault addr 0xXXXXXXXX
      [fault reason 0x71] SM: Present bit in first-level paging entry is clear
NVRM: GPU0 _kgspBootGspRm: unexpected WPR2 already up, cannot proceed with booting GSP
NVRM: GPU0 RmInitAdapter: Cannot initialize GSP firmware RM
```

48 to 524 DMAR fault entries per failed boot, depending on how many DMA
addresses GSP probes before locking down.

**Mechanism**

```
sudo grubby --update-kernel=ALL --args="iommu=off intel_iommu=off"
```

- `iommu=off`: generic kernel IOMMU disable
- `intel_iommu=off`: specifically disables Intel VT-d / DMAR
- Both together: ensure IOMMU is fully disabled regardless of "platform
  opt-in" override mechanism in the kernel

After reboot:
- dmesg: `DMAR: IOMMU disabled`
- `/sys/bus/thunderbolt/devices/domain0/iommu_dma_protection` reads 0
- All PCI devices use raw DMA (no translation)

**Test plan**

Validated 2026-05-07 14:54: cold-cold-boot with this cmdline showed:
- 0 DMAR faults (was 48-524)
- 0 GSP-lockdowns from IOMMU rejection (still 18 from H16)
- rm_init_adapter succeeded after 4 retries (~30s) vs 7+ retries
  (~50s+) without

**Reproducibility**

Single-line cmdline change. Persistent across reboots. Trivially reverted:
```
sudo grubby --update-kernel=ALL --remove-args="iommu=off intel_iommu=off"
```

**Threat model — when this is appropriate**

Acceptable for: personal AI/dev workstation, single user, sealed eGPU
enclosure, physically secure location, no untrusted TB device hot-plug.

NOT acceptable for: shared workstations, multi-tenant servers,
security-sensitive deployments, hosts running VMs with PCI passthrough.

**Tradeoffs**

- ✗ Removes DMA-attack protection from all PCI/TB devices (security
  reduction)
- ✗ Breaks Intel VT-d-based VM PCI passthrough (functional impact for
  VM use cases)
- ✓ Marginal performance improvement (no IOMMU translation overhead)
- ✓ Zero install/build cost — just a cmdline change
- ✓ Trivially reversible

**Upstream-readiness**

**Not for upstream** — this is a per-system mitigation, not a generic
fix. Upstream-correct paths:
- Driver-side `dma_map_*` registration in NVIDIA fork (most correct,
  expensive)
- PCI quirk built into kernel marking specific TB-attached eGPU vendor
  IDs as trusted (limited scope, niche, debatable upstream value)

Lever T documents the practical workaround for our threat model;
upstream paths are tracked separately as #104 (kernel patch) and
follow-up driver-side investigation.

**Cross-references**

- [`docs/iommu-gsp-lockdown-analysis.md`](./iommu-gsp-lockdown-analysis.md) — comprehensive analysis
- [H10](./reliability-hypothesis-ledger.md#h10), [H14](./reliability-hypothesis-ledger.md#h14), [H16](./reliability-hypothesis-ledger.md#h16)
- `archive/iommu-off-test-2026-05-07-145453/` — validation forensic dossier
- Tasks: #93 (H10), #102 (H14), #104 (kernel patch alternative)
- Related: Lever R (helper recovery for residual H16 failures), Lever
  M-recover (in-driver recovery)

---

### Lever X — short name

**Class:** [Prevention | Signaling | Recovery | Infrastructure | Diagnostic-transient]
**Status:** [PROPOSED | LANDED YYYY-MM-DD | TODO #task]
**Sovereign layer:** [L1-L7 per architecture-and-modularity.md]
**Hypothesis:** [link to ledger entry HXX]
**Patch:** [link to patches/XXXX-*.patch]

**Why it exists**

[Plain-language explanation of the gap in NVIDIA's open driver this fills.
Reference closed-Windows-driver behaviour where applicable. Cite the
forensic evidence that motivates this lever.]

**Symptom without it**

[What fails when this lever is absent. Concrete kernel log examples,
user-visible failure mode.]

**Mechanism**

[How the lever detects the bad state and what it does. Function names,
register reads, code flow.]

**Code surface**

| File | Change |
|---|---|
| ... | ... |

[Estimated lines, patch number.]

**Test plan**

[Numbered steps. Each step has a pass/fail criterion. Validation must
include: the lever firing on the expected condition, the lever NOT firing
on healthy operations (no false positives), and the system observably
better with the lever than without.]

**Reproducibility**

- Applies against `NVIDIA/open-gpu-kernel-modules` tag X.X.X
- Lever dependencies: [list other levers required for this one to make sense]
- Build mechanism: [how to apply / DKMS / etc]

**Upstream-readiness**

- **High | Medium | Low** — [reasoning]
- [Conditions for upstream PR; contentious design decisions to discuss with NVIDIA]

**Cross-references**

- Hypothesis: ...
- Forensic evidence: ...
- Patch: ...
- Task: ...
- Related levers: ...
```

---

## How this catalog is used

| Question | Answer found in |
|---|---|
| "What does Lever X do?" | This catalog, per-lever entry |
| "Why is Lever X needed?" | Per-lever entry "Why it exists" + cross-referenced hypothesis |
| "How was Lever X validated?" | Per-lever "Test plan" + cross-referenced forensic dossier |
| "How do I re-apply Lever X to fresh upstream?" | "Reproducibility" section + patch file + design doc |
| "Is Lever X ready for upstream PR?" | "Upstream-readiness" section |
| "Where does Lever X live structurally?" | "Sovereign layer" + `architecture-and-modularity.md` |
| "What's still being investigated?" | `reliability-hypothesis-ledger.md` (open hypotheses become future levers) |

---

## Lifecycle of a lever

```
hypothesis (ledger H##)
        │
        │ evidence accumulates, n≥3 SUPPORTED
        ▼
proposed (catalog entry, status=PROPOSED, task created)
        │
        │ design + patch + DKMS build
        ▼
landed (catalog entry, status=LANDED, patch in patches/)
        │
        │ test plan executed, validated
        ▼
validated (catalog entry, status=VALIDATED, n≥3 cold-boot)
        │
        │ project reaches sufficient maturity
        ▼
upstream-PR'd (catalog entry, status=UPSTREAM, link to NVIDIA PR)
        │
        │ NVIDIA accepts
        ▼
merged (catalog entry, status=MERGED — lever no longer needs to live in our fork)
```

The catalog tracks every lever through this lifecycle. Even after a
lever merges upstream, its entry stays in the catalog as historical
documentation of how the project achieved 100% reliability.

---

## Cross-references

- [`reliability-hypothesis-ledger.md`](./reliability-hypothesis-ledger.md) — open and resolved hypotheses; new levers grow out of supported hypotheses
- [`stability-roadmap.md`](./stability-roadmap.md) — phased plan; lever-level summary in inventory tables
- [`architecture-and-modularity.md`](./architecture-and-modularity.md) — sovereign-module assignments per lever
- [`lever-Q-design.md`](./lever-Q-design.md) — full design rationale for the Q stack (template for future per-lever design docs)
- [`recovery-mechanism-findings.md`](./recovery-mechanism-findings.md) — FLR machinery validation, foundational for M-recover and Lever R
- [`/root/aorus-5090-egpu/patches/`](../patches/) — actual patch files, in numbered order

## Update log

- **2026-05-06 morning** — initial publication. Established the catalog
  format triggered by the user's framing: "We need to ensure that we
  capture the gap or new feature in a way that is both explainable,
  testable, and can be re-implemented again on the same upstream
  NVIDIA driver code if required. We intend to frame these
  improvements as upstream code requests when the full suite is
  determined." Backfilled all existing levers (I, J-2, N, O, M-base,
  P-probe, Q-passive, Q-active, Q-watchdog) and added Lever R as the
  motivating new entry from today's forensic capture.

### Lever U — NVIDIA-driver-side TB-aware PCIe link speed cap (DEMOTED 2026-05-07: defensive fallback to Lever V-prime)

**Status update 2026-05-07**: Lever U demoted from "architectural destination"
to "defensive fallback for older kernels without Lever V-prime". Per
`docs/tb-pcie-cap-architecture.md`, the correct architectural destination
for TB-tunneled PCIe downstream caps is `drivers/thunderbolt/` (Lever V-prime),
not the NVIDIA driver. NVIDIA-driver-side caps duplicate logic that should
exist once in the kernel TB stack, and don't help non-NVIDIA TB-tunneled
devices.

**When Lever U is still useful:**
- On older kernels that don't yet have Lever V-prime upstreamed
- As belt-and-suspenders if Lever V-prime has a regression
- For NVIDIA-specific tuning beyond the link cap (e.g., GSP timeout overrides)

**Original design preserved below as historical reference.**

---

### Lever U (FORMER architectural label) — driver-side TB-aware PCIe link speed cap

**Class:** Prevention
**Status:** **DESIGN — retirement target for `aorus-egpu-bridge-link-cap.service`**
**Sovereign layer:** L1 (NVIDIA fork)
**Hypothesis:** [H17](./reliability-hypothesis-ledger.md#h17)
**Pairs with:** Lever R, Lever M-recover (unrelated; this is prevention, those are recovery)

**Why it exists**

The current Lever T workaround (cmdline `iommu=off`) handles H10/H14 (IOMMU
class). The current Lever-T-companion `aorus-egpu-bridge-link-cap.service`
handles H17 (PCIe link speed renegotiation triggering GSP_LOCKDOWN) by
writing the *upstream bridge's* LnkCtl2 to cap Target at Gen1 before
nvidia binds. **Architectural problem:** the systemd service touches a host
PCI bridge that the NVIDIA driver doesn't own. Layering violation; per-system
specificity; not upstream-able.

The architecturally-correct fix: **NVIDIA driver clamps the GPU's OWN
LnkCtl2 Target Link Speed to the TB-version-spec max (Gen3 for TB4) when
running over Thunderbolt**. This is almost certainly what the closed
Windows driver does — TB-aware probe-time speed clamping.

**Mechanism (planned)**

In `nv_pci_probe`, after BAR mapping + early init, before any GSP work:

```c
if (pci_is_thunderbolt_attached(pci_dev)) {
    u16 lnkctl2;
    pcie_capability_read_word(pci_dev, PCI_EXP_LNKCTL2, &lnkctl2);
    /* TB4 max is Gen3 (8 GT/s); TB5 max is Gen4 (16 GT/s).
     * Detect TB version from controller (or default to Gen3 conservative). */
    if ((lnkctl2 & PCI_EXP_LNKCTL2_TLS) > AORUS_TB_MAX_SPEED) {
        lnkctl2 = (lnkctl2 & ~PCI_EXP_LNKCTL2_TLS) | AORUS_TB_MAX_SPEED;
        pcie_capability_write_word(pci_dev, PCI_EXP_LNKCTL2, lnkctl2);
        /* Trigger retrain so cap takes effect. */
        pcie_capability_set_word(pci_dev, PCI_EXP_LNKCTL, PCI_EXP_LNKCTL_RL);
    }
}
```

PCIe spec: link speed = min(both endpoints' Target Link Speed). Setting GPU's
side to Gen3 → bridge respects it → link never trains above Gen3 (or Gen1 in
practice on hardware with retimers, which is fine — we cap the *attempt*, not
the negotiated speed).

**Code surface**

| File | Change | Lines |
|---|---|---|
| `kernel-open/nvidia/nv-pci.c` | Add TB detection + LnkCtl2 cap in `nv_pci_probe` | ~15 |
| `kernel-open/nvidia/nv-pci.c` | Module param `NVreg_AorusTbMaxLinkSpeed` (default 3 = Gen3) | ~10 |

Total: ~25 lines, single new patch (e.g., `0021-Lever-U-tb-link-speed-cap.patch`).

**Test plan**

1. Validate on cold-cold-boot with Lever U enabled, `aorus-egpu-bridge-link-cap.service`
   DISABLED (verify NVIDIA-side cap is sufficient on its own)
2. n≥3 cold-cold-boots: 0 GSP_LOCKDOWN events expected
3. Disable test: `NVreg_AorusTbMaxLinkSpeed=4` reverts to default behavior
4. Performance test: should match current (Gen1 link is practical max anyway)

**Reproducibility**

- Applies on top of patch 0001-0018 baseline + Lever T cmdline
- Replaces Lever-T-companion `aorus-egpu-bridge-link-cap.service` workaround
- DKMS-buildable

**Upstream-readiness**

**HIGH** — `pci_is_thunderbolt_attached()` is upstream kernel API. Cap to
TB-version max is a reasonable default for a TB-aware GPU driver. Could be
proposed to NVIDIA as a small TB-awareness patch. Closed Windows driver
likely does equivalent.

**Cross-references**

- [H17](./reliability-hypothesis-ledger.md#h17) — empirical justification
- `archive/phase-A-telemetry-2026-05-07-151807/` — telemetry showing link
  renegotiation as the trigger
- Lever-T-companion `aorus-egpu-bridge-link-cap.service` — the L4 systemd
  workaround that Lever U retires
- [`docs/iommu-gsp-lockdown-analysis.md`](./iommu-gsp-lockdown-analysis.md)
LEVER_U
echo "Lever U appended; size now $(wc -l < /root/aorus-5090-egpu/docs/lever-catalog.md) lines"

# Add bridge-link-cap to retirement roadmap
cat >> /root/aorus-5090-egpu/docs/service-retirement-roadmap.md <<'EOF'

---

### `aorus-egpu-bridge-link-cap.service` (NEW — H17 PCIe link cap)

**Why it exists:** Caps upstream bridge LnkCtl2 Target Link Speed at Gen1
before nvidia.ko binds. Prevents PCIe link speed renegotiation events
during GSP boot that trigger GSP_LOCKDOWN_NOTICE (per H17 mechanism).

**Layer:** L4 (helper at `/usr/local/sbin/aorus-egpu-bridge-link-cap`) +
L5 (systemd unit ordered Before=aorus-egpu-compute-load-nvidia.service).

**Architectural problem:** writes a *host PCI bridge* register that
NVIDIA driver doesn't own. Layering violation; per-system; not upstreamable.

**What driver work would retire it:**
- **Lever U — driver-side TB-aware PCIe link speed cap.** ~25-line patch
  in `nv_pci_probe` to clamp the GPU's own LnkCtl2 Target Link Speed to
  TB-version max when `pci_is_thunderbolt_attached()`. Same effect via
  the GPU-side register; clean architectural layering; upstream-friendly.

**Retirement status:** ACTIVE — bridge measure pending Lever U.
**Validation criterion for retirement:** Lever U PROVEN at n≥3 cold-cold-boots
with bridge-link-cap.service DISABLED, confirming GPU-side cap alone
suffices. Disable bridge-link-cap.service for n≥3 additional cycles;
zero functional regression; zero GSP_LOCKDOWN events.
**Path:** Highest-leverage workaround for cold-boot reliability today.
Should retire via Lever U in 2026.

**2026-05-07 — Cap target REVISED (Gen3 viable on port B):**

Initial Gen3 fail on port A drove conclusion "Gen3 not viable on this
hardware". Subsequent port-B + Windows-comparison + UncMaskClear
investigation falsified that conclusion:

| Test | Cap | Result |
|---|---|---|
| Gen3 plain on port A | `0x0043` | 36 LOCKDOWN ✗ |
| Gen3 + bit 5 (G3-E) on port A | `0x0063` | 36 LOCKDOWN ✗ |
| Gen2 cap on port A | `0x0042` | 0 LOCKDOWN ✓ |
| Gen3 + bit 5 + G3-G/G2/H telemetry on port B (n=2) | `0x0063` | 0 LOCKDOWN ✓ rmInit ✓ |

Mechanism reframe (G3-H 2026-05-07 patch 0022):
The `Br_AER_Cor=0x1` (Receiver Error) and `GPU_AER_Cor=0x2000` (Advisory
Non-Fatal) we'd interpreted as "active Gen3 signal integrity errors" were
STALE RW1C bits from PCI enumeration, not live error firings. Confirmed
via Header Log (always empty) + UncMaskClear test (no Unc Internal Error
fired post-clear). The Gen3 fail on port A was NOT due to ongoing PCIe
errors at Gen3; mechanism still TBD (port-A-specific silicon/firmware).

**Production cap (revised) = Gen3 + bit 5 (`LnkCtl2 = 0x0063`) ON PORT B.**
Lever U now targets Gen3 with autonomous-shift-disabled, paired with:
- Patch 0022 (UncMaskClear matching Windows)
- Patch 0021 (full AER + ASPM + LBMS/LABS telemetry)
- aorus-egpu-observability-watchdog redesigned (no nvidia-smi polling)
- aorus-egpu-bridge-link-cap.service auto-detects parent bridge BDF

**Pending:**
- n≥3 cold-cold-boots on port B with full stack (validate stability)
- Re-test port A with full new stack (UncMaskClear may have unblocked it)
- Lever V (host-side TB tunnel raise from Gen1 to Gen3) — see below

**Untested but reserved as fallback** if port B Gen3+bit5 doesn't sustain:
- PCIe Link Equalisation Capability presets (extended cap)
- ECRC enable / MaxPayload reduction
- Gen2 fallback cap (`LnkCtl2 = 0x0062`)

LnkCtl2 bit 6 (Selectable De-emphasis) is **Gen2-only** per PCIe spec
§7.5.3.20 and does NOT apply at Gen3.

---

### Lever W — kernel thunderbolt driver per-domain init timing fixes (NEW 2026-05-08, Thread A output) — **EMPIRICAL JUSTIFICATION FALSIFIED 2026-05-08 09:37**

**Class:** Reliability / Prevention
**Status:** **DEPRIORITIZED 2026-05-08** — All three underlying hypotheses (H19/H20/H21) FALSIFIED on Port A boot with `thunderbolt.dyndbg=+pflm`. TB driver came up cleanly on Port A (no timeouts, no missing-links warning, AORUS enumerated, USB4 link up). Failure was downstream of TB layer (GSP_LOCKDOWN cascade, bridge Gen3→Gen1 demote, 18 rmInit FAIL, 0 OK). Patch series retained as **defensive robustness candidates** (each patch is independently defensible — no patch is harmful) but no longer hypothesized as the Port A fix. See `docs/reliability-hypothesis-ledger.md` H17/H19/H20/H21 entries dated 2026-05-08 09:37 for falsification evidence.
**Sovereign layer:** L1 (Linux kernel mainline — drivers/thunderbolt)
**Hypotheses:** [H19](./reliability-hypothesis-ledger.md#h19) (FALSIFIED), [H20](./reliability-hypothesis-ledger.md#h20) (FALSIFIED), [H21](./reliability-hypothesis-ledger.md#h21) (FALSIFIED)
**Pairs with:** Lever V-prime (separate concern: PCIe gen cap; Lever W is about per-domain init timing/ordering)

**Why it exists (HISTORICAL — kept for record)**

Thread A source analysis of `drivers/thunderbolt/` (Linux v6.19) identified
multiple plausible per-domain init timing/ordering issues that *could*
explain asymmetric Port A failure. The patches are well-targeted and would
be reasonable upstream contributions for any system that DOES exhibit
these timeouts. **However on this NUC 15 Pro+ + AORUS 5090 stack, the
TB driver does NOT exhibit these timeouts** — verified empirically with
verbose dyndbg on Port A 2026-05-08 09:37. The Port A asymmetric failure
is NOT in the TB driver init code.

Per-domain isolation in the driver is structurally clean (no shared
mutable state between domains). Per-domain *behavior* is also clean
(both domains' TB drivers come up cleanly on this hardware). The
asymmetry — whatever its source — is downstream of TB.

Full source review: `docs/tb-driver-source-analysis.md`. Falsification
evidence: `archive/event-captures/B1-dyndbg-portA-2026-05-07T233951Z`.

**Mechanism (consolidated patch series, ~40 LoC total)**

Five candidate patches identified:

| # | Location | Change | Hypothesis |
|---|---|---|---|
| 1 | `drivers/thunderbolt/switch.c:503` | Bump `port_wait_retries` from 10 → 30 (1s → 3s cap) | H19 |
| 2 | `drivers/thunderbolt/usb4.c:329-330` | Bump CR-bit wait from 50ms → 500ms | H20 |
| 3 | `drivers/thunderbolt/acpi.c` (new function) | Add `tb_native_add_links()` mirroring `tb_apple_add_links()` for non-Apple machines | H21 |
| 4 | `drivers/thunderbolt/switch.c` | New `port_wait_retries` module param (gives Thread B a runtime knob to validate H19) | Test infrastructure |
| 5 | `drivers/thunderbolt/nhi.c` | Extend `nhi_reset()` HRR window from 500ms → 2s with retry once | Defensive |

Order of testing: patch 4 first (gives module-param validation knob),
then 1+2 if 4 reveals the timeout fires, then 3 if patches 1+2 don't
fix it.

**Validation criteria (HISTORICAL)**

- Port A: 0 GSP_LOCKDOWN cold-cold-boot, n≥3 — *not achievable via this lever; failure is downstream of TB driver*
- Port B: zero regression, nvbandwidth same, [DIAG] same
- Other Linux users with similar Meteor Lake hardware can confirm fix
  (cross-NUC validation via `tools/state-capture/state-capture.sh` dossier diff)

**Sovereign layer rationale**

L1 (Linux mainline) would be the only correct destination if the bug
were here. It isn't. Per `feedback_no_premature_upstream_filing.md`,
filing this upstream now is barred (no working tested fix; the patches
don't fix the actual Port A failure mode we observe).

**Upstream path — DEFERRED INDEFINITELY**

These patches are reasonable as small kernel hardening contributions
in a future cleanup cycle, BUT not as a "fix Port A asymmetric failure"
RFC. Any future upstream filing should be framed as opportunistic
robustness improvement on TB driver, not as a fix for any specific
hardware bug, since we have no failing system to demonstrate them
against. **Recommended action: park Lever W until/unless we have a
system that empirically exhibits the timeouts these patches address.**

**Tasks:** #114 (Thread A — done), #115 (Thread B — DROPPED, hypotheses falsified), #116 (Thread C — DROPPED, no fix to write), #117 (Thread D — newer kernel test still useful but redirected: investigate whether newer kernel improves NVIDIA/GSP layer behavior, not TB driver).

**Why this entry is preserved (not deleted)**

Per `feedback_lever_catalog_discipline.md`, every reliability lever gets a
permanent spec entry. This includes falsified levers — the falsification
record is itself valuable to future investigators. If a future investigator
considers similar hypotheses (TB driver per-domain timing on this hardware),
they can read this entry and avoid re-doing the work.

---

### Lever V-prime — kernel thunderbolt driver downstream PCIe cap (NEW 2026-05-07, supersedes Lever U as architectural destination)

**Class:** Prevention (reliability + bandwidth-matching)
**Status:** **DESIGN — upstream RFC pending**
**Sovereign layer:** L1 (Linux kernel mainline — drivers/thunderbolt)
**Hypothesis:** [H17](./reliability-hypothesis-ledger.md#h17) (the original GSP_LOCKDOWN cascade)
**Pairs with:** All current TB-eGPU reliability work — supersedes them as the
architectural single-source-of-truth.

**Why it exists**

Any TB-tunneled PCIe device with a downstream hub has the same structural
problem: the hub's downstream PCIe port advertises its OWN silicon LnkCap
(typically Gen4+), but the upstream TB tunnel can only carry TB-spec PCIe
payload (~22-25 Gbps for TB4, ~50-64 Gbps for TB5 asymmetric). When device
negotiates with hub at the hub's max LnkCap, it tries to push more than the
tunnel can carry → flow control churn → retraining → for GPUs, GSP_LOCKDOWN
cascade.

This problem is NOT NVIDIA-specific. Applies to any TB-tunneled PCIe device
class: GPUs (NVIDIA/AMD/Intel), NVMe drives in TB enclosures, capture cards,
FPGAs, anything. Linux kernel has no TB-aware PCIe link cap logic as of
mid-2026.

Architecture rationale + layer analysis: `docs/tb-pcie-cap-architecture.md`.

**Mechanism**

In `drivers/thunderbolt/tunnel.c`, at PCIe tunnel establishment:
1. Determine tunnel's max PCIe gen via TB version + mode lookup
2. Walk PCI hierarchy below tunnel's downstream port via `pci_walk_bus`
3. For each bridge/device, write `LnkCtl2`:
   - bits[3:0] = tunnel max gen
   - bit 5 = 1 (Hardware Autonomous Speed Disable)
4. Trigger retrain via LnkCtl bit 5

Cap target by TB version:
- TB3/TB4: Gen3 ×4 (~25 Gbps useful, matches ~22-32 Gbps tunnel payload)
- TB5 symmetric: Gen3 ×4
- TB5 asymmetric: Gen4 ×4 (~51 Gbps useful, matches ~50-64 Gbps unidirectional)

Module parameter: `thunderbolt.pcie_clamp_downstream=Y` (default on,
disable for diagnostic only).

**Sovereign layer rationale**

L1 (Linux mainline) is the correct destination because:
- Topology-authoritative (TB driver knows the tunnel state)
- Vendor-agnostic across both host TB silicon and downstream device class
- OS-agnostic precedent (Windows TB stack does this functionally)
- Generalizes to future TB versions (single update site)
- Single source of truth (no per-vendor reinvention)

See architectural analysis in `docs/tb-pcie-cap-architecture.md` for
why other layers (PCI core quirks, vendor GPU drivers, userspace) are
suboptimal.

**Validation**

When upstreamed and merged:
- nvbandwidth H2D matches current cap-script behavior (~2.8 GB/s on TB4)
- Disable our userspace bridge-link-cap.service → no regression in
  reliability or bandwidth
- Test on n≥3 cold-cold-boots without our band-aid scripts active
- Measure across multiple kernel versions (LTS + mainline)

**Upstream path**

1. Survey linux-thunderbolt mailing list + LKML for prior art (task #51 covers)
2. RFC patch to `linux-thunderbolt@lists.linux.dev` and `linux-pci@vger.kernel.org`
3. Maintainer: Mika Westerberg
4. Subject: `[RFC PATCH] thunderbolt: clamp downstream PCIe link speed to tunnel capacity`

**Tasks:** to be added (upstream RFC drafting + prior-art survey)

---

### Lever V (FORMER) — host-side TB tunnel PCIe gen raise (RETIRED 2026-05-07)

**Class:** Prevention (performance + reliability)
**Status:** **RETIRED 2026-05-07 — hypothesis falsified by measurement**

**Why retired:** premise was that host-side TB tunnel was Gen1-limited.
nvbandwidth empirical test (2026-05-07) showed H2D = 2.80 GB/s = 22.4 Gbps,
which is at TB4 saturation (70% of 32 Gbps spec ceiling). The lspci
`LnkCap = Gen1` reading was virtual-bridge spoofing — TB controllers
virtualize PCIe registers, those reads do not reflect actual tunnel
throughput. There is no Gen1 ceiling to raise. See:
- Measurement methodology: `docs/cuda-bandwidth-methodology.md`
- Topology + diagram: `docs/tb4-pcie-topology.md`
- Investigation closure: `docs/tb4-tunnel-gen1-investigation.md` § Resolution
- Hypothesis ledger: H18 entry FALSIFIED
- Memory rule: `feedback_lspci_lnkcap_tb_virtual.md`

To exceed TB4 envelope: TB5 host hardware (Lunar Lake / Arrow Lake
successor) — out of project scope.

For cold-load perf improvements that ARE achievable: task #74
(async cuMemcpyHtoD pipelining), task #76 (system tuning).

**Original design preserved below as historical reference only:**

**Class:** Prevention (performance + reliability)
**Status (original):** DESIGN — investigation phase
**Sovereign layer:** L5 (kernel cmdline / module params) → potentially L1
(thunderbolt driver patch) if needed
**Hypothesis:** [H18](./reliability-hypothesis-ledger.md#h18)
**Pairs with:** Lever U (Lever U caps GPU↔hub link; Lever V raises
host↔TB-controller tunnel)

**Why it exists**

Host-side PCIe root port to TB controller link operates at Gen1 ×4 on
both NUC TB4 ports under both Linux and Windows (HWinfo64 + Linux lspci
both confirm Speed=2.5GT/s). TB4 spec allows tunneled PCIe up to Gen3 ×4
(~25 Gbps effective). Empirical impact: cold-load TTFT for 9.4 GiB
llama3.1:8b model = 8.0s on Windows, matching Gen1×4 saturation. Raising
host-side tunnel to Gen3 would yield ~3× cold-load speedup.

User constraint per memory feedback_no_bios_options_nuc15.md: BIOS toggles
unavailable; must fix via system / TB / kernel / driver.

**Mechanism (under investigation)**

Possible causes for Gen1 ceiling:
1. Linux thunderbolt driver doesn't request higher gen at tunnel setup
2. Intel Meteor Lake-P TB4 controller silicon caps tunneled PCIe at Gen1
3. NUC firmware sets host-side LnkCap before OS boots (if (3), L0/firmware fix)

Investigation plan: see docs/tb4-tunnel-gen1-investigation.md.

**Test order (cheapest first)**:
- Read-only telemetry: `boltctl list`, TB sysfs nvm/security/generation,
  dmesg TB negotiation events, kernel `thunderbolt` source review
- Experimental: thunderbolt module parameters (verbose dyndbg, host_reset
  modes, generation hints)
- If software-fixable: identify the right knob, validate gen rise
- If hardware-fixable: file Intel/Linux upstream report, document for
  future Meteor Lake successors

**Sovereign layer rationale**

L5 (cmdline) → L1 (kernel patch) progression. If thunderbolt driver patch
is required, this becomes upstreamable to Linux mainline benefiting all
TB-eGPU users on similar hardware. If silicon limitation, document and
move on.

**Validation**

- Gen3 host-side LnkCap on root port (`lspci -vv -s 00:07.{0,2}` shows
  Speed=8GT/s)
- Gen3 host-side LnkSta sustained
- Cold-load TTFT for llama3.1:8b drops to ~3s (3× improvement)
- Steady-state inference perf delta vs current baseline (likely small,
  since steady-state is VRAM-bound)

**Tasks:** new task to be added on investigation plan
EOF
echo "service-retirement-roadmap updated"
