# Lever R — design document

> **Three-tier implementation strategy.** Tier 1 ships now and addresses
> the immediate boot-fail-loop. Tiers 2 and 3 are designed in this
> document but deferred to follow-up patches. All three tiers compose;
> later tiers add to but do not replace earlier ones.
>
> **2026-05-06 09:15 — Tier 1 v1 and v2 EMPIRICALLY INSUFFICIENT.** Tier 1
> v3 design pivoted from L1 (NVIDIA fork) to L4 (userspace helper) —
> see [Tier 1 v3 architectural pivot](#tier-1-v3-architectural-pivot)
> below. The L4 design is the genuinely superior architecture; v1/v2
> are retained in this document only as historical record of why we
> arrived at v3.
>
> **Status:** Tier 1 v1 RETIRED (pcie_reset_flr insufficient).
> Tier 1 v2 RETIRED (pci_reset_function returns ENOTTY pre-rescan).
> **Tier 1 v3 LANDED + SUPPORTED at n=1 (L4 helper using validated
> remove+rescan+reset sequence).**
> **Tier 2 PARTIAL LANDED 2026-05-06 12:48 — retry budget only.**
> Tier 2 remaining (kobject_uevent, kill-switch, per-step watchdog,
> sysfs counters) DESIGNED, implementation FUTURE.
> Tier 3 design APPROVED, implementation FUTURE (retires the L4 helper).
>
> **Hypothesis:** [H13](./reliability-hypothesis-ledger.md#h13) STRONGLY SUPPORTED
> **Forensic dossier:** [`archive/boot-init-mode-b-2026-05-06-074608/`](../archive/boot-init-mode-b-2026-05-06-074608/)
> **Catalog entry:** [`lever-catalog.md#lever-r`](./lever-catalog.md#lever-r--wpr2-stuck-detection--auto-flr-at-probe)
> **Last updated:** 2026-05-06 12:48

---

## Problem statement

> **2026-05-06 mechanism CORRECTION:** Earlier wording in this section
> said "WPR2-stuck state persists across reboots". Diagnostic telemetry
> (`archive/diag-telemetry-2026-05-06-154732/`) showed WPR2 reads 0
> (clear) at cold-boot probe AND at pre-rmInit, then transitions to
> 0x07f4a000 *during* the first failed `rm_init_adapter` call.
> Subsequent retries see the leftover WPR2 setting. Lever R's recovery
> mechanism (remove + rescan + reset) still works correctly; only the
> framing of *why the recovery is needed* changed. See
> [H13 / H14 in the ledger](./reliability-hypothesis-ledger.md#h13-h14)
> and `lever-M-recover-design.md` "Mechanism (corrected)" for the full
> empirical analysis.

NVIDIA open driver `_kgspBootGspRm` (in `kernel_gsp.c`) checks
`kgspIsWpr2Up_HAL` early; if WPR2 is already up, returns
`NV_ERR_INVALID_STATE` and prints "the GPU is likely in a bad state and
may need to be reset." Driver bind fails permanently until external
intervention clears WPR2.

The original "WPR2 persists across reboots" reading of the symptom was
inaccurate. Corrected mechanism:

- Cold boot starts; WPR2 register reads 0 (clear)
- First `rm_init_adapter` call attempts GSP boot; GSP boot SETS WPR2 = 0x07f4a000 in hardware
- That call then FAILS for some other reason (root cause = H14, deferred investigation)
- WPR2 stays set, but GSP isn't running
- Subsequent `rm_init_adapter` calls see "WPR2 already up" and fail
- This loops until a PCI reset clears WPR2

The "stuck across reboots" appearance comes from the loop inside a single
boot, not actual persistence through poweroff. (Empirical recheck of the
2-min AC disconnect test: needs re-running with the diagnostic build to
verify whether AC disconnect ALONE clears WPR2 from a previous session,
or whether the failure cycle resumes immediately on the next session's
first `rm_init_adapter`.)

It only clears via:
- Function Level Reset (FLR) via `/sys/.../reset` — the only mechanism
  empirically validated to work
- Possibly: longer AC disconnect, FLR-equivalent power sequencing — not
  yet validated; today's 2-min disconnect did not clear it

The closed Windows driver does not exhibit this failure on the same
hardware (per `feedback_project_scope_path_a` Lever G WSL2 evidence).
Implication: closed driver has equivalent recovery built in. Open
driver lacks it. **Lever R fills the gap.**

---

## Tier 1 v1 — RETIRED 2026-05-06 09:00

> **Status:** EMPIRICALLY REJECTED. `pcie_reset_flr` (NVIDIA's existing
> `os_pci_trigger_flr` wrapper) was forced (despite pending transactions)
> but did NOT clear WPR2 on this hardware. Kernel logged "PCI FLR might
> have failed."

Approach was: Lever R logic at `_kgspBootGspRm` calls `os_pci_trigger_flr`
on WPR2 detection. Validation showed Lever R logic works (markers fire
correctly, conditional flow correct), but the FLR primitive itself is
insufficient.

## Tier 1 v2 — RETIRED 2026-05-06 09:09

> **Status:** EMPIRICALLY REJECTED. `pci_reset_function` returns
> `-ENOTTY` (-25) when called from `_kgspBootGspRm` probe context —
> kernel reports `dev->reset_fn=0` despite `cat reset_method` showing
> `flr bus` available. State-context mismatch.

Approach was: same as v1 but using a new `os_pci_reset_function` wrapper
around `pci_reset_function` (which escalates FLR → PM → slot → bus).
Theory: multi-mechanism escalation would succeed where FLR alone failed.
Reality: kernel never tries any method because it sees `reset_fn=0` at
that probe context.

## Tier 1 v3 — Architectural pivot {#tier-1-v3-architectural-pivot}

> **Goal:** the GPU recovers automatically from WPR2-stuck state on
> next boot, without manual user intervention.
> **Status:** PROPOSED, pivoted to L4 (userspace helper) instead of L1
> (NVIDIA fork) per architectural superiority criteria.
> **Effort estimate:** ~2 hours (helper + systemd + udev + validate).

### Why L4 is the PRAGMATIC choice today (not the architectural ideal)

> **2026-05-06 update — corrected framing.** I previously described L4
> as "the superior architectural approach." That was wrong. L4 is the
> **pragmatic landing for now**; native in-driver recovery is the
> architectural destination. Tier 3 (below) is now concrete plan to
> get there.

The validation cycle of Tier 1 v1 and v2 revealed two things:

1. **The empirical recovery sequence on this hardware is PCI
   remove + rescan + reset** (validated by sysfs experiment 09:14)
2. **This sequence cannot be cleanly executed from inside
   `_kgspBootGspRm` probe context** without async orchestration
   (workqueue + `-EPROBE_DEFER` pattern)

L4 ships today because:
- It uses the validated public sysfs interface
- Zero rebase debt against NVIDIA source
- Tests in seconds (no DKMS rebuild)
- Gets us functional reliability NOW

L4 is NOT the architectural ideal because:
- Adds yet another userspace workaround service to a stack that
  already has too many (persistenced load-bearing, uvm-keepalive,
  compute-load-nvidia, pcie-tune, now wpr2-recovery)
- Fragments recovery logic across kernel + userspace
- Doesn't match what NVIDIA's closed Windows driver does (Windows
  doesn't need any of these workarounds)
- The "perfect end state" of this project is **zero workaround
  services** — every recovery happens inside the driver

**Tier 1 v3 is a BRIDGE.** It gets the system reliable while Tier 3
builds the destination.

### Mechanism

Sequence at boot (orchestrated by systemd):

```
1. Standard boot
   ├─ aorus-egpu-compute-load-nvidia.service (existing — driver bind)
   │  └─ if WPR2 stuck: driver bind fails, RmInitAdapter returns error
   └─ aorus-egpu-wpr2-recovery.service (NEW)
      └─ runs after compute-load-nvidia, validates state
         ├─ if `nvidia-smi` succeeds: exit 0 (no recovery needed)
         └─ if `nvidia-smi` fails:
            ├─ stop nvidia-persistenced.service + uvm-keepalive.service
            ├─ modprobe -r nvidia_uvm nvidia
            ├─ echo 1 > /sys/bus/pci/devices/0000:04:00.0/remove
            ├─ echo 1 > /sys/bus/pci/rescan
            ├─ echo 1 > /sys/bus/pci/devices/0000:04:00.0/reset
            ├─ systemctl restart aorus-egpu-compute-load-nvidia.service
            └─ restart persistenced + uvm-keepalive
2. Subsequent compute workload — clean GPU state
```

### Code surface

| File | Change | Lines |
|---|---|---|
| `usr/local/sbin/aorus-egpu-wpr2-recovery` | New shell helper | ~60 |
| `etc/systemd/system/aorus-egpu-wpr2-recovery.service` | New unit, ordered after compute-load-nvidia | ~30 |
| Total | | ~90 (all userspace, no kernel) |

### Test plan

| Step | Action | Pass criterion |
|---|---|---|
| 1 | Install helper + service, enable | `systemctl is-enabled` returns enabled |
| 2 | Reboot into clean state (WPR2 already cleared) | Service runs, `nvidia-smi` works first try, recovery NOT triggered (idempotent no-op) |
| 3 | Force WPR2-stuck state (Mode A failure + shutdown), reboot | Service runs, detects nvidia-smi failure, executes recovery sequence, re-runs compute-load-nvidia, `nvidia-smi` then works |
| 4 | Repeat n=3 cycles | Each cold-boot recovers cleanly without manual intervention |
| 5 | Force a state where remove+rescan+reset doesn't help (degenerate) | Service times out / surrenders cleanly with diagnostic; no infinite loops |

### Architectural advantages of Tier 1 v3 (L4) vs v1/v2 (L1)

| Property | v1/v2 (L1 NVIDIA fork) | **v3 (L4 userspace helper)** |
|---|---|---|
| Rebase debt against NVIDIA source | YES — every NVIDIA driver release means rebasing | **None — pure userspace** |
| Coupling to NVIDIA-internal state | YES — uses NV_GET_NV_STATE, kgspIsWpr2Up_HAL | **None — uses public sysfs** |
| Validation mechanism | Required custom kernel build | **systemctl + bash** |
| Composability with other recovery | Awkward — would have to extend kernel patches | **Composes with Phase B3 watchdog daemon, future M-recover** |
| Reversibility | Edit patch + rebuild + reboot | **Disable systemd unit** |
| Upstream-readiness | LOW (would need to convince NVIDIA) | **MEDIUM — could be a documented operational pattern, not an upstream PR target** |
| Failure isolation | Driver failure can wedge probe path | **Service failure isolated to its own process** |
| Test surface | Multi-day cycle (build/reboot) | **Minutes (run helper, observe)** |

### What we keep from v1/v2 work

The **validation mechanism** in `_kgspBootGspRm` (the `kgspIsWpr2Up_HAL`
check that's been there since stock NVIDIA) is what produces the
diagnostic NVRM messages. Our L4 helper detects via `nvidia-smi` failure
+ dmesg pattern matching for "_kgspBootGspRm: unexpected WPR2" — direct
inspection of the same signal NVIDIA's code already emits. Zero
modification to NVIDIA code; we just observe and react.

### Cleanup of v1/v2 patches

Patch `0015-Lever-R-wpr2-stuck-recovery.patch` (currently containing v2
code) will be **removed** before next build. Version bump from aorus.5
back to aorus.4 (or a fresh aorus.6 with v1/v2 reverted but Q-watchdog
+ all other levers retained).

The L4 v3 implementation is the WHOLE Tier 1 deliverable. No L1 patch
ships for Lever R.

### Tier 1 v3 graduation criteria — move to Tier 2 when:

- v3 PROVEN across n≥3 cold-cold-boot cycles, AND
- We want richer telemetry (counter exposure, journal-structured logs)

Tier 2 design (telemetry + retries + watchdog) translates naturally
to L4 — it's just adding more shell helper logic. Cleaner than the
L1 Tier 2 design we'd been planning.

### Tier 1 v3 graduation criteria — move to Tier 3 when:

- v3 demonstrably insufficient (e.g., remove+rescan+reset itself
  fails — not yet observed but possible)
- OR we want to investigate WHY Linux's shutdown leaves WPR2 stuck
  (the actual root cause work, separate from recovery)

### Mechanism

At the existing `_kgspBootGspRm` WPR2 check (kernel_gsp.c:4717),
extend the if-branch to attempt recovery before surrendering:

```c
if (kgspIsWpr2Up_HAL(pGpu, pKernelGsp) &&
    !pGpu->getProperty(pGpu, PDB_PROP_GPU_PREINITIALIZED_WPR_REGION))
{
    nv_state_t *nv = NV_GET_NV_STATE(pGpu);

    NV_PRINTF(LEVEL_ERROR,
        "AORUS Lever R: WPR2-stuck detected at probe — attempting FLR\n");

    if (os_pci_reset_function(nv->handle) == NV_OK)
    {
        // Settle delay (FLR completes in ~100ms per recovery-findings)
        os_delay(100);

        if (!kgspIsWpr2Up_HAL(pGpu, pKernelGsp))
        {
            NV_PRINTF(LEVEL_ERROR,
                "AORUS Lever R: WPR2 cleared by FLR — proceeding with GSP boot\n");
            // fall through to GSP boot below
        }
        else
        {
            NV_PRINTF(LEVEL_ERROR,
                "AORUS Lever R: FLR did NOT clear WPR2 — surrendering\n");
            return NV_ERR_INVALID_STATE;
        }
    }
    else
    {
        NV_PRINTF(LEVEL_ERROR,
            "AORUS Lever R: os_pci_reset_function returned error — surrendering\n");
        return NV_ERR_INVALID_STATE;
    }
}
```

### Code surface

| File | Change | Lines |
|---|---|---|
| `kernel-open/common/inc/os-interface.h` | Declare `os_pci_reset_function` | +1 |
| `kernel-open/nvidia/os-pci.c` | Implement `os_pci_reset_function` wrapping `pci_reset_function()` | +20 |
| `src/nvidia/arch/nvalloc/unix/include/os-interface.h` | RM-side declaration mirror | +1 |
| `src/nvidia/src/kernel/gpu/gsp/kernel_gsp.c` | Lever R logic at line 4717 | ~25 |
| Total | | ~50 |

### Patch numbering

`patches/0015-Lever-R-wpr2-stuck-recovery.patch`. Bump version mark in
patch 0005 to `aorus.4`.

### Test plan

| Step | Action | Pass criterion |
|---|---|---|
| 1 | Build & install patched driver via `tools/build-patched-driver.sh` | DKMS reports success; `modinfo nvidia` shows `595.71.05-aorus.4` |
| 2 | Reboot into aorus.4 (current state has WPR2 stuck — validation immediate) | At boot, dmesg shows `AORUS Lever R: WPR2-stuck detected at probe — attempting FLR` |
| 3 | Same boot, dmesg follow-up | Either: `AORUS Lever R: WPR2 cleared by FLR — proceeding with GSP boot` (success path) OR `surrendering` (failure path) |
| 4 | If success path: `nvidia-smi` works on first attempt | `nvidia-smi` returns RTX 5090 details, exit 0 |
| 5 | Subsequent clean reboot (no Mode A failure first) | dmesg shows NO Lever R fire — check skipped because WPR2 was clean |
| 6 | Force a Mode A failure (run a workload that triggers Q-active), shutdown, power-on | dmesg shows Lever R fire AND clean recovery (full cycle test) |

### Pass/fail outcomes for the tier

| Outcome | Conclusion |
|---|---|
| Step 2-4 all succeed | Tier 1 SUPPORTED; productionise |
| Step 2 fires marker but step 3 says FLR didn't clear WPR2 | Tier 1 design partially correct — FLR is insufficient on this hardware. Escalate to Tier 2 (multiple reset variants) |
| Step 5 fires Lever R when WPR2 was clean | Bug in WPR2 check or pre-init state issue — back to design |
| Step 6 succeeds across n=3 cold-boot cycles | Tier 1 PROVEN |

### Risks

| Risk | Mitigation |
|---|---|
| FLR itself wedges the host | os_delay timeout; if FLR hangs >5s, kernel watchdog should fire (panic + auto-reboot via Phase 1c B2) |
| `os_pci_reset_function` behaviour varies across kernel versions | Use the most-stable API (`pci_reset_function`); test on running 6.19.14 |
| FLR clears more than WPR2 (loses driver state) | At probe time there's no driver state yet — clean slate. No risk. |
| WPR2 transiently flickers to "up" during normal init (false positive) | Per source review, `kgspIsWpr2Up_HAL` reads a non-volatile register; unlikely to be transient. Validate via Step 5 (clean boot doesn't trigger Lever R). |

### Graduation criteria — move to Tier 2 when:

- Tier 1 proven across n≥3 cold-boot cycles (recovery works consistently), AND
- We want telemetry beyond dmesg, OR
- We observe edge cases Tier 1 doesn't handle (FLR insufficient, runaway recovery loops)

---

## Tier 2 — Telemetry, safety, configurability (follow-up)

> **Goal:** Lever R becomes observable, configurable, robust against edge cases.
> **Status:** **PARTIAL LANDED 2026-05-06 12:48** — retry budget shipped
> in the L4 helper. Remaining features (kobject_uevent, kill-switch env
> var, per-step watchdog, sysfs counters) DESIGNED, implementation FUTURE.
> **Effort estimate (remaining):** ~2 hours.
> **Pre-requisite:** Tier 1 v3 SUPPORTED at n=1 (2026-05-06 11:08, 12:33).
>
> ### Tier 2 PARTIAL — what landed (2026-05-06 12:48)
>
> Driven by 2026-05-06 12:33 cold-cold-boot evidence: boot-time helper
> invocation FAILED first pass (bind blocked in conf-compute /
> gpuSanityCheck flags=0x1, distinct from initial WPR2-stuck mode);
> manual second invocation 4 minutes later SUCCEEDED with identical
> sequence. Single-attempt design was insufficient.
>
> **Implementation in `usr/local/sbin/aorus-egpu-wpr2-recovery`:**
>
> - Recovery sequence (steps 1-8) extracted into `do_recovery_pass(attempt)`
>   function returning 0 on success / 1 on failure
> - Outer loop iterates up to `MAX_ATTEMPTS` (default 3)
> - `RETRY_DELAY_S` (default 5s) sleep between attempts
> - Per-attempt history-log entries: `attempt-started`, `attempt-succeeded`,
>   `attempt-failed`
> - Final outcome: `recovery-success` (with `attempts=N`) or
>   `recovery-failed` (with `attempts=MAX_ATTEMPTS`)
> - Configurable via env vars (`MAX_ATTEMPTS`, `RETRY_DELAY_S`)
>
> **Why this is not debt:** the partial implementation is a clean SUBSET
> of the full Tier 2 design. Each deferred feature adds to the helper
> without ripping out the retry-budget structure:
>
> | Tier 2 feature | Equivalent in helper | Status |
> |---|---|---|
> | `NVreg_AorusLeverRMaxAttempts` | `MAX_ATTEMPTS` env var | LANDED |
> | Retry loop with surrender | outer for-loop + final exit 1 | LANDED |
> | Per-attempt counter increments | history-log `attempt-*` events | LANDED |
> | `NVreg_AorusLeverREnable` kill switch | future: `ENABLE_LEVER_R=0` env var | DEFERRED |
> | `kobject_uevent` on fire | future: emit via `udevadm trigger` or systemd notify | DEFERRED |
> | Per-step watchdog timer | future: per-`do_recovery_pass` `timeout` wrapper | DEFERRED |
> | sysfs counters | future: counter file in `$STATE_DIR/counters/` | DEFERRED |
>
> The helper file's history log already provides the cumulative-fire and
> per-attempt visibility that sysfs counters would surface. The DEFERRED
> features only become necessary if (a) we need to gate the helper at
> runtime without removing it from systemd graph (kill-switch), or
> (b) recovery itself wedges (per-step watchdog), or (c) we observe
> repeated firing patterns warranting external alerting (uevent).
>
> ---
>
> ### Tier 2 — Original full design (for L1 implementation; remaining work)

### Mechanism additions

#### Module parameters (kill switches + tuning)

```c
static unsigned int NVreg_AorusLeverREnable = 1;
module_param(NVreg_AorusLeverREnable, uint, 0644);
MODULE_PARM_DESC(NVreg_AorusLeverREnable,
    "AORUS Lever R: enable WPR2-stuck FLR recovery (1=on default, 0=off)");

static unsigned int NVreg_AorusLeverRMaxAttempts = 3;
module_param(NVreg_AorusLeverRMaxAttempts, uint, 0644);
MODULE_PARM_DESC(NVreg_AorusLeverRMaxAttempts,
    "AORUS Lever R: max FLR attempts before surrendering (default 3)");

static unsigned int NVreg_AorusLeverRWatchdogMs = 5000;
module_param(NVreg_AorusLeverRWatchdogMs, uint, 0644);
MODULE_PARM_DESC(NVreg_AorusLeverRWatchdogMs,
    "AORUS Lever R: per-FLR watchdog timeout in ms (default 5000)");
```

#### Counter tracking

Add to `nv_linux_state_t`:
```c
struct aorus_lever_r {
    atomic_t fire_count;        // total Lever R activations across boots? or this-boot?
    atomic_t flr_attempts;      // total FLR attempts
    atomic_t flr_successes;     // FLRs that cleared WPR2
    atomic_t surrender_count;   // times we gave up
    u64 last_fire_jiffies;
    u32 last_attempt_count;
};
```

Counters exposed via sysfs:
- `/sys/module/nvidia/parameters/aorus_lever_r_fires` (current boot)
- `/sys/module/nvidia/parameters/aorus_lever_r_flr_attempts`
- `/sys/module/nvidia/parameters/aorus_lever_r_flr_successes`
- `/sys/module/nvidia/parameters/aorus_lever_r_surrenders`

#### Multiple retry attempts

Replace single FLR call with retry loop:
```c
for (attempt = 1; attempt <= NVreg_AorusLeverRMaxAttempts; attempt++) {
    if (os_pci_reset_function(nv->handle) == NV_OK) {
        os_delay(100);
        if (!kgspIsWpr2Up_HAL(...)) {
            NV_PRINTF(...success on attempt N...);
            atomic_inc(&qwd->flr_successes);
            break;
        }
    }
    NV_PRINTF(...attempt N failed, retrying...);
}
if (kgspIsWpr2Up_HAL(...))
    return NV_ERR_INVALID_STATE;  // surrendered after all attempts
```

#### kobject_uevent on fire

Emit udev event:
```c
char *envp[] = { "AORUS_LEVER_R=fired", "WPR2_RECOVERED=yes", NULL };
kobject_uevent_env(&pdev->dev.kobj, KOBJ_CHANGE, envp);
```

Allows a userspace daemon (Phase B3 #83) to:
- Log to a structured file
- Alert if Lever R fires repeatedly
- Trigger external recovery if our FLR fails (e.g. send IPMI signal)

#### FLR watchdog (protect against FLR-induced wedge)

Wrap the `os_pci_reset_function` call with a kernel timer. If the call
doesn't return within `NVreg_AorusLeverRWatchdogMs`, log "FLR call wedged"
and surrender (kernel-side panic via NMI watchdog will reboot the host
per Phase 1c B2 sysctls).

This is defensive against H2 (wrapper-FLR-wedge family) — even if FLR
itself hangs, we don't lose the host indefinitely.

### Code surface

| File | Change | Lines |
|---|---|---|
| `kernel-open/nvidia/nv-qwatchdog.c` (or new nv-lever-r.c) | Module params + counters | +50 |
| `kernel-open/common/inc/nv-linux.h` | Add `aorus_lever_r` struct | +10 |
| `src/nvidia/src/kernel/gpu/gsp/kernel_gsp.c` | Retry loop + uevent | +30 |
| Total | | ~90 additional |

### Test plan

| Step | Action | Pass criterion |
|---|---|---|
| 1 | Reboot with NVreg_AorusLeverREnable=0 | Lever R doesn't fire even on stuck WPR2; original failure path runs |
| 2 | Reboot with default config | Lever R fires; counter increments; uevent visible in journalctl |
| 3 | Force WPR2-stuck condition where FLR is unreliable (need to find test) | retry loop tries up to 3 times; correct counter increments |
| 4 | Watchdog test: simulate FLR-wedge (extreme case, may need mock) | After 5s, kernel watchdog fires; system reboots cleanly |
| 5 | Enable=0 + clean boot | Lever R completely silent; no perf impact |

### Graduation criteria — move to Tier 3 when:

- Tier 2 PROVEN, AND
- Need root-cause investigation (why does WPR2 persist?)
- OR need to compare reset mechanisms (FLR vs slot reset vs bus reset)

---

## Tier 3 — Native in-driver async recovery (THE DESTINATION)

> **Goal:** move WPR2-stuck recovery into the driver. Retire the L4
> userspace helper. Match what NVIDIA's closed Windows driver does
> structurally (driver self-heals, no userspace orchestration).
> **Status:** APPROVED design, FUTURE implementation.
> **Effort estimate:** Multi-day engineering — concurrency, lock
> ordering, lifetime management, test coverage. Substantially larger
> than Tier 1 v3.
> **Pre-requisite:** Tier 1 v3 PROVEN at n≥3 (we know what works);
> Tier 2 may be skipped if Tier 3 lands directly.

### What this tier delivers

When implemented:

1. `aorus-egpu-wpr2-recovery.service` is **DISABLED and REMOVED** from
   the project repo
2. WPR2-stuck condition is detected and recovered **entirely inside
   nvidia.ko**, without external orchestration
3. From userspace observability, `nvidia-smi` works on first cold
   boot every time (just slower if recovery fired)
4. dmesg shows AORUS Lever R markers; the recovery is transparent
   to applications

This matches the structural property of NVIDIA's closed Windows driver
on this same hardware (per Lever G evidence): the driver handles
recovery internally; there are no userspace workaround services on
Windows.

### Mechanism — async recovery via deferred probe

Three-step state machine triggered by WPR2-stuck detection at
`_kgspBootGspRm`:

```
Probe attempt 1:
  _kgspBootGspRm called
  kgspIsWpr2Up_HAL → true (stuck)
  ↓
  AORUS Lever R: schedule async recovery work
  schedule_work(&aorus_lever_r_work)
  ↓
  return -EPROBE_DEFER  (kernel will retry probe later)

Async work runs (in workqueue context, no probe locks held):
  pci_stop_and_remove_bus_device(pdev)  ← unbinds + removes
  pci_rescan_bus(pdev->bus)              ← re-enumerates
  ↓ rescan triggers fresh probe via standard kernel path

Probe attempt 2:
  _kgspBootGspRm called against fresh device state
  kgspIsWpr2Up_HAL → false (rescan refreshed state, reset cleared WPR2)
  ↓
  Continue to normal GSP boot
  ↓
  return NV_OK
```

Concurrency notes:
- Workqueue runs OUTSIDE probe context — safe to call
  `pci_stop_and_remove_bus_device`
- The `pdev` reference must be held with `pci_dev_get` before probe
  returns -EPROBE_DEFER, released when work runs
- A flag in `nv_linux_state_t` prevents recovery being scheduled
  recursively
- After the second probe succeeds, the flag clears

### Code surface estimate

| File | Change | Lines |
|---|---|---|
| `kernel-open/nvidia/nv-pci.c` | Add work_struct, schedule_work, EPROBE_DEFER return | +60 |
| `kernel-open/nvidia/nv-aorus-lever-r.c` (new) | Recovery work function | ~80 |
| `kernel-open/common/inc/nv-linux.h` | aorus_lever_r state in nv_linux_state_t | +5 |
| `src/nvidia/src/kernel/gpu/gsp/kernel_gsp.c` | Detection at _kgspBootGspRm + signal scheduling | ~30 |
| Total | | ~175 (vs L4's ~165 lines of shell+systemd) |

Comparable LOC; structurally different layer.

### Test plan

| Step | Action | Pass criterion |
|---|---|---|
| 1 | Build, install, reboot into Tier 3 driver | `dmesg \| grep "AORUS Lever R"` shows kernel markers, NOT userspace logger output |
| 2 | Force WPR2-stuck (Mode A failure → shutdown), reboot | dmesg shows "Lever R: WPR2-stuck — scheduling recovery; deferring probe" → "Lever R: rescan complete; probe will re-fire" → "Lever R: probe re-fire successful" |
| 3 | `nvidia-smi` works without manual intervention or userspace service firing | systemctl status aorus-egpu-wpr2-recovery shows it ran but exited 0 (no-op needed) |
| 4 | Disable the L4 service entirely, reboot, force WPR2-stuck again | Recovery fires entirely from kernel; no userspace involvement |
| 5 | Run n=3 cold-cold-boot cycles | Each recovers cleanly without manual intervention |
| 6 | Service retirement validation | Disable + remove `aorus-egpu-wpr2-recovery.service`; confirm no functional regression |

### Architectural advantages of Tier 3 over Tier 1 v3 (L4)

| Property | Tier 1 v3 (L4 userspace) | **Tier 3 (in-driver)** |
|---|---|---|
| Recovery latency | seconds (service ordering + bash execution) | ~1 second (kernel-internal) |
| Visibility to user | nvidia-smi fails THEN service runs THEN works | Transparent — nvidia-smi just works |
| Workaround service count | +1 (wpr2-recovery.service) | -1 (it goes away) |
| NVIDIA Windows-driver parity | NO — Windows has no equivalent | YES — Windows does this internally |
| Upstream-readiness | Low — userspace tooling, not driver code | Higher — proper driver feature |
| Logging | logger -t aorus-wpr2-recover | NVRM kernel log — same place as other levers |
| Fragility to system changes | systemd ordering, modprobe success, etc. | Single code path inside driver |

### Hard problems Tier 3 must solve

1. **Probe re-entry safety**: how does the kernel handle repeated probe of the same device after rescan? Need to ensure no resource leaks between attempts.
2. **Lock ordering**: probe holds device locks; workqueue calls into PCI subsystem which takes its own. Need to release probe locks before scheduling work.
3. **Failure mode**: if rescan-then-probe ALSO fails (e.g., recovery sequence didn't clear WPR2), what's the surrender path? Set a counter, give up after N attempts, surface to userspace via uevent.
4. **Compatibility**: Linux kernel API for `pci_stop_and_remove_bus_device` + `pci_rescan_bus` — verify availability across kernel versions in our support matrix.

### Service retirement criterion

Tier 3 is COMPLETE when:
- Tier 3 PROVEN across n≥3 cold-cold-boot cycles
- AND `aorus-egpu-wpr2-recovery.service` has been disabled for n≥3 boots without any functional regression
- AT WHICH POINT the L4 service is removed from the project repo

### Why this is "permanent resolution"

This implements the user's stated requirement (2026-05-06):
**"native in-driver hardening is indeed our goal."**

Tier 3 puts the recovery WHERE IT BELONGS — inside the driver,
co-located with the detection, using kernel-native primitives.
Userspace becomes the application layer it should be, not the
fix-the-driver-bugs layer it currently is.

### Cross-references

- [`service-retirement-roadmap.md`](./service-retirement-roadmap.md) — tracks all userspace workaround services + their driver-side replacements
- Phase 4 M-recover (#62) — uses related kernel infrastructure (pci_error_handlers)
- `feedback_native_in_driver_hardening` memory note

### Research questions

#### Q1 — Why does WPR2 persist across power loss?

GSP firmware lives in volatile GPU memory. Power-off should clear all
GSP state. Yet 2-minute AC disconnect did NOT clear WPR2 today. What
gives?

Hypotheses to investigate:
- **eGPU has standby power**: even with AC disconnected, capacitors or
  battery-backed memory keep GSP region powered for some time
- **TB controller keeps GPU partially powered**: if host stays on with
  TB cable connected, the TB tunnel might keep eGPU's TB controller
  + adjacent GPU state powered through the TB cable's bus power
- **WPR2 status is in non-volatile memory**: less likely but possible if
  GSP firmware persists state to NVRAM/EEPROM
- **The check itself is misleading**: `NV_PFB_PRI_MMU_WPR2_ADDR_HI` might
  read non-zero for reasons other than "GSP runtime is alive"

**Tests:**
- Disconnect TB cable AND eGPU AC; wait varying durations (5min, 30min,
  overnight); measure how long it takes for WPR2 to clear naturally
- Read register before driver bind on a fresh power-up — what's the
  default state?
- Compare register read against GSP heartbeat indicators (other registers)

#### Q2 — Is there a more surgical reset than FLR?

FLR resets the entire PCIe function. NVIDIA may have:
- **GSP-specific reset register**: e.g. NV_PMC_GSP_FALCON_ENGINE_RESET
  or similar
- **WPR2-specific scrub command**: a GSP RPC to tear down WPR2 cleanly
- **Signed shutdown command**: same path Windows shutdown uses

**Source review targets:**
- `kgspBootstrap_HAL` and surrounding init code
- `gpuRecoveryAction_*` paths
- `falconReset_*` for GSP falcon
- `kgspTeardown_*` if exists

If found, Lever R could try the surgical reset first, falling back to
FLR only if surgical fails.

#### Q3 — Can we prevent WPR2 from sticking on shutdown?

If we add a clean-shutdown path that tears WPR2 down properly before
poweroff, the next boot wouldn't need recovery. This would be a
**Lever S — clean GSP teardown on shutdown** (separate lever, separate
catalog entry).

Implementation site: nvidia.ko `nv_pci_remove` plus a systemd "stop"
hook that runs before shutdown.

#### Q4 — What does GSP_LOCKDOWN_NOTICE actually mean?

In our forensic dossier, GSP fired 8 lockdown notices BEFORE the WPR2
check failed. Lockdown is the GSP saying "I'm protecting state because
something bad happened."

If we can identify what triggers lockdown, we might prevent it. The
lockdown trigger could be:
- AER event (PCIe error) detected by GSP
- Voltage/temperature sensor anomaly
- Internal sanity check failure (memory corruption, etc.)
- TB-side glitch the GPU saw differently than the host

**Investigation:**
- Source review of GSP lockdown firing code
- Compare LOCKDOWN_NOTICE data fields (`data0=0x0` vs `data0=0x1` —
  some pattern)
- Cross-reference with kernel AER events, TB controller events

### Code surface

Tier 3 is mostly investigation; deliverables vary by what's found:
- Possibly: a **Lever R-surgical** patch using NVIDIA-specific reset
- Possibly: a **Lever S** patch for clean shutdown teardown
- Possibly: documentation that "WPR2-stuck is intrinsic; FLR is the
  only mitigation; Tier 1+2 is the final form"

### Test plan

Driven by what's discovered. At minimum:
- Document all reset mechanisms tested with pass/fail
- Document the WPR2 persistence characteristics measured
- Update `recovery-mechanism-findings.md` with corrected facts

### Graduation criteria — Tier 3 complete when:

- Each research question (Q1-Q4) has a documented answer (even if "no
  better mechanism exists" is the answer)
- `recovery-mechanism-findings.md` is updated with empirically-validated facts
- Any additional levers identified (Lever S, Lever R-surgical) have
  their own catalog entries

---

## Cross-tier considerations

### Reproducibility

All tiers apply against `NVIDIA/open-gpu-kernel-modules` tag `595.71.05`.
Tier 2 + Tier 3 build on Tier 1 — apply tiers in order.

### Upstream-readiness by tier

| Tier | Upstream-ready? | Notes |
|---|---|---|
| 1 | LOW | Useful as a debugging tool; NVIDIA reviewers would want telemetry + retry budget |
| 1+2 | MEDIUM | Has telemetry + safety; matches what production drivers usually have |
| 1+2+3 | HIGH | Has telemetry + research-backed rationale + alternative mechanisms documented |

For eventual upstream PR: ship all three tiers as a series, with the
PR description summarising what was tried and why this design.

### Validation across tiers

After Tier 1 lands and is PROVEN, Tier 2 implementation should be a
NO-OP for healthy boots — the telemetry counters increment but
behaviour matches Tier 1. After Tier 2 lands, it's PROVEN when the
counter behaviour matches expected and edge cases (kill switch, max
attempts) work correctly.

After Tier 3, Lever R may be REPLACED entirely if Tier 3 finds a
better mechanism. In that case, the catalog entry transitions to
historical documentation of the journey.

---

## Cross-references

- Catalog: [`lever-catalog.md#lever-r`](./lever-catalog.md)
- Hypothesis: [H13](./reliability-hypothesis-ledger.md#h13)
- Forensic evidence: [`archive/boot-init-mode-b-2026-05-06-074608/`](../archive/boot-init-mode-b-2026-05-06-074608/)
- Recovery mechanism foundation: [`recovery-mechanism-findings.md`](./recovery-mechanism-findings.md) — needs update per 2026-05-06 evidence
- Task: #96
- Modularity: [`architecture-and-modularity.md`](./architecture-and-modularity.md) — Lever R Tier 1 v3 is L4+L5 (userspace bridge); Tier 3 destination is L1 (NVIDIA fork)
- Methodology: [`feedback_reliability_methodology`](../../.claude/projects/-root/memory/feedback_reliability_methodology.md) — tiered design follows the "design before implement" discipline

## Update log

- **2026-05-06 morning** — initial publication. Three-tier design captured
  in full per user request: "Can we 'design' all 3 tiers, but only
  implement our first one?" Tier 1 is the immediate-implementation
  target; Tier 2 + 3 stay open in the catalog as future work with
  full design specifications.
- **2026-05-06 09:14** — Tier 1 v1 (`pcie_reset_flr`) and v2
  (`pci_reset_function` from probe context) RETIRED with empirical
  evidence: bare FLR variants insufficient on this hardware. Validated
  the working recovery sequence is `PCI remove + rescan + reset` via
  sysfs experiment.
- **2026-05-06 10:30** — Tier 1 v3 ARCHITECTURAL PIVOT to L4 userspace
  helper. Tier 3 reframed from "research" to concrete in-driver async
  recovery (workqueue + EPROBE_DEFER pattern) as the destination that
  retires the L4 service. Service-retirement-roadmap published to
  track all userspace workaround services + driver work that retires
  each.
- **2026-05-06 11:08** — **Tier 1 v3 SUPPORTED at n=1 under real
  conditions.** Cold-cold-boot reproduced WPR2-stuck naturally; helper
  detected the failure, executed the full 8-step recovery sequence,
  GPU restored end-to-end. Detection bug found+fixed during validation:
  `nvidia-smi -L` returns exit 0 even on "No devices found" output —
  detection now parses stdout for `^GPU N:` pattern instead of relying
  on exit code alone. End-to-end automatic boot recovery now works.
  Need n≥3 cold-cold-boot reproductions for full PROVEN status.
