# Reliability hypothesis ledger

> **Living document.** Tracks every open hypothesis about the eGPU
> reliability problem, the evidence for/against, and what test would
> resolve it. Updated as tests run.
>
> **Discipline:** No hypothesis is declared resolved on n=1.
> Minimum n=3 with consistent outcome to declare PROVEN or REJECTED.
>
> **Cross-references:**
> [`stability-roadmap.md`](./stability-roadmap.md) §Investigation methodology;
> [`freeze-2026-05-05-investigation.md`](./freeze-2026-05-05-investigation.md)
> for the originating freeze forensics.

---

## Status legend

| Status | Meaning |
|---|---|
| **OPEN** | Active hypothesis; tests pending or in progress |
| **SUPPORTED** | Evidence leans for; n insufficient to declare PROVEN |
| **PROVEN** | n≥3 consistent evidence; treat as fact |
| **REJECTED** | n≥3 contradictory evidence |
| **DEFERRED** | Lower priority; revisit after others resolved |

## Hypotheses

### H1 — Q-watchdog kthread MMIO probe converts Mode A → Mode B

| Field | Value |
|---|---|
| Status | **OPEN** |
| Stated | 2026-05-05 evening |
| Evidence FOR | Test 1 (Enable=1) was Mode B silent; Test 2 (Enable=0) was Mode A graceful with all reliability markers firing |
| Evidence AGAINST | n=1 each — within stochastic ~60/40 distribution noise |
| Resolution test | A/B run, n=3 each side, FLR off so failures don't pollute next iter |
| If supported | Default `NVreg_AorusWatchdogEnable=0` in modprobe.d; investigate why periodic MMIO reads suppress AER signaling |
| If rejected | Q-watchdog is innocent; restore default Enable=1 |

### H2 — Wrapper `remove+rescan+FLR` sequence wedges host with held fds

| Field | Value |
|---|---|
| Status | **OPEN** |
| Stated | 2026-05-05 evening |
| Evidence FOR | Test 2 wedged at `flr-triggering` step; no `04-flr/` directory created (mkdir didn't run); persistenced + uvm-keepalive hold device fds |
| Evidence AGAINST | `recovery-mechanism-findings.md` claimed FLR works (different conditions — clean GPU not Q-active-fired) |
| Resolution test | Add per-step `progress()` calls inside `trigger_flr` to pinpoint which sysfs write wedges |
| If supported | Wrapper must release fds before FLR (risky) OR skip remove+rescan entirely OR rely on M-recover (in-kernel) instead |
| If rejected | FLR is innocent; freeze locus is somewhere else in the recovery path |

### H3 — Cold-boot first-CUDA failure rate is ~60% Mode B / ~40% Mode A regardless of levers

| Field | Value |
|---|---|
| Status | **OPEN** |
| Stated | 2026-05-04, refined 2026-05-05 |
| Evidence FOR | Multi-day failure rate observed; freeze on first cold-boot CUDA fires often |
| Evidence AGAINST | Yesterday's 13/13 streak (but those were within a single boot, not all cold-boot first iters) |
| Resolution test | Track every cold-boot-first-iter outcome; running tally over N≥10 cold boots |
| If supported | Bug is intrinsic to cold-boot first-CUDA; preventing or warming up is the fix (Phase C3 #87) |
| If rejected | Some other variable explains the distribution |

### H4 — NMI watchdog cannot catch this class of freeze (deadlock, not CPU loop)

| Field | Value |
|---|---|
| Status | **PROVEN** |
| Stated | 2026-05-05 |
| Evidence FOR | 0/2 vmcores from kdump despite hardlockup_panic=1, softlockup_panic=1, panic_on_rcu_stall=1 all set; both freezes >60s |
| Evidence AGAINST | None |
| Implication | Hardware watchdog (Phase C4 #88, iTCO_wdt) is the only reliable last-resort recovery |

### H5 — Phase 1b reliability stack (Q-active + Q-passive + N + O) works correctly when fired

| Field | Value |
|---|---|
| Status | **PROVEN** |
| Stated | 2026-05-05 |
| Evidence FOR | Test 2 fired all 4 markers; AER captured 50 events; Xid 154 logged; host stayed alive 90+ s post-failure; wrapper completed full post-state telemetry |
| Evidence AGAINST | None |
| Implication | When the bug fires Mode A, our infrastructure handles it cleanly. Remaining work is on Mode B detection (Q-watchdog or alternatives) and recovery (M-recover) |

### H6 — Bare FLR (`echo 1 > /sys/.../reset` only, no remove+rescan) avoids wedge

| Field | Value |
|---|---|
| Status | **OPEN** |
| Stated | 2026-05-05 |
| Evidence FOR | `recovery-mechanism-findings.md` documented FLR working in some configurations; remove is the suspected culprit per H2 |
| Evidence AGAINST | Not directly tested today |
| Resolution test | After H2 instrumentation, run a recovery iter with bare FLR mode in wrapper |
| If supported | Wrapper recovery becomes minimal — single sysfs write |
| If rejected | All FLR variants wedge; need M-recover (in-driver) path |

### H7 — Stopping persistenced + uvm-keepalive before FLR avoids wedge

| Field | Value |
|---|---|
| Status | **DEFERRED** |
| Stated | 2026-05-05 |
| Notes | Persistenced is load-bearing per `architecture.md` (Problem 2 mitigation); stopping it during a recovery flow risks re-exposing the close-path freeze. Test only after exhausting H6 and H11. |

### H8 — DPC (Downstream Port Containment) enable + tune would catch Mode B

| Field | Value |
|---|---|
| Status | **REJECTED 2026-05-05** (audit, n=0 tests required) |
| Resolution | Hardware audit on 2026-05-05 found NO device on the eGPU path implements PCIe DPC capability: 0000:00:07.0, 0000:01:00.0, 0000:02:00.0, 0000:03:00.0, 0000:04:00.0 all lack DPC bits in `lspci -vv`; no `/sys/bus/pci/devices/.../dpc/` sysfs anywhere. Kernel `_OSC` granted DPC control but there's nothing to control on this stack. |
| Implication | DPC is unusable on TB-attached devices regardless of OS-side configuration. Pursue other L1 levers (H9 PCIe tuning, H10 IOMMU policy). |

### H9 — PCIe per-device tuning reduces error rate / converts Mode B → Mode A

**Status: NARROWED 2026-05-05 after audit.** Original H9 framed as "completion
timeout / MaxPayload tuning." Audit findings:

| Knob | Audit result | Tunable? |
|---|---|---|
| MaxPayload | All devices at 128B — at hardware floor (TB host port 00:07.0 DevCap caps at 128B) | NO |
| MaxReadReq | All at 128B; GPU DevCap up to 512B | YES on GPU only |
| Completion Timeout | host port + GPU support tuning (TimeoutDis+ in DevCap2) | YES |
| LTR | enabled all | YES |

H9 splits into three sub-hypotheses, each independently testable.

#### H9a — tightening completion timeout converts Mode B → Mode A

| Field | Value |
|---|---|
| Status | **REJECTED + RETIRED 2026-05-08** — empirically proven to cause 100% Port A boot failure (B4 vs B5 single-variable test). Service `aorus-egpu-pcie-tune.service` disabled and retired per `service-retirement-roadmap.md`. |
| Evidence (2026-05-08 retire) | B4 (H9a active on Port A): 36 GSP_LOCKDOWN, 18 rmInit FAIL, 0 OK. B5 (H9a disabled, Port A, single variable): 0 GSP_LOCKDOWN, 0 FAIL, 1 OK. Mechanism: H9a's CTV=2 (1ms-10ms) Completion Timeout was too tight for TB-tunneled config-space reads at probe time → reads time out, return 0xffffffff → driver classifies GPU as legacy PCI → rm_init fails. See `project_port_a_h9a_root_cause_2026_05_08.md`. |
| Evidence (original retraction) | CTV=2 iters: #1 Mode A, #2 Mode A, #3 success. CTV=0 iter #4: success. Couldn't distinguish CTV's effect from baseline failure rate. The "0/3 Mode B vs ~60% prior baseline" framing compared today's small sample to yesterday's small sample — neither statistically robust. |
| Mode B detection (now) | Lever Q-watchdog kthread provides direct AER-independent Mode B detection at runtime. H9a's intended mechanism (faster AER fire-time) was already moot on this stack — AER does not fire reliably on TB-tunneled GPU loss (`project_port_a_failure_invisible_to_aer_2026_05_08.md`). |
| Layer | L4 (helper) + L5 (systemd unit) — both delivered, both now retired |
| Lesson | "DEFENSIVE — no observed downside, possibly helpful" assessment was wrong. A change with no demonstrated benefit and unverified downside should not be productionised. Per `feedback_check_existing_guards_before_cmdline_experiments.md`: hardcoded BDFs in service scripts are a class of latent bug. |

#### H9b — disabling LTR changes failure characteristics

| Field | Value |
|---|---|
| Status | **OPEN** (lower priority) |
| Evidence FOR | LTR affects host arbitration and PCIe credit allocation timing; default-on means kernel/firmware can put devices into lower-power states based on advertised tolerance. Disabling forces consistent timing |
| Evidence AGAINST | LTR is mostly about power efficiency; reliability impact speculative |
| Resolution test | Disable LTR on per-device sysfs (`echo 0 > /sys/.../ltr`); n=3 iters; compare distribution |

#### H9c — raising MaxReadReq on GPU

| Field | Value |
|---|---|
| Status | **OPEN** (lowest priority — unlikely material reliability impact) |
| Evidence FOR | GPU DevCap supports up to 512B MaxReadReq |
| Evidence AGAINST | MaxPayload bottleneck at 128B means any read response gets split into 128B chunks anyway; benefit minimal even for perf, near-zero for reliability |
| Resolution test | `setpci` to raise MaxReadReq on 04:00.0; n=3 iters |

### H10 — IOMMU policy / Thunderbolt-untrusted-device handling causes DMA failures during GSP boot

| Field | Value |
|---|---|
| Status | **PARTIALLY PROVEN 2026-05-07 14:54** — `iommu=off intel_iommu=off` cmdline empirically eliminates DMAR faults (0 vs 48-524 prior). But GSP_LOCKDOWN still fires 18 times → IOMMU is a CONTRIBUTING cause, NOT the sole cause. Second trigger now tracked as [H16](#h16). See [`docs/iommu-gsp-lockdown-analysis.md`](./iommu-gsp-lockdown-analysis.md). |
| Stated | 2026-05-05 (original framing: DMA-path Mode B); REFINED 2026-05-06 16:24 |
| Evidence FOR (original) | Today's Mode B fingerprint suggests DMA-path wedge; IOMMU mediates DMA. |
| **Evidence FOR (2026-05-06 refined)** | **Direct empirical signal — 524 DMAR fault entries during Commit 3 recovery storm at 16:14:29 boot** (`archive/commit3-recovery-loop-2026-05-06-161429/05-dmar-faults.log`). Pattern: `DMAR: [DMA Read/Write NO_PASID] Request device [04:00.0] fault addr 0xXXXXXXXX [fault reason 0x71] SM: Present bit in first-level paging entry is clear`. Faults occur DURING every `rm_init_adapter` attempt. Strongly suggests IOMMU is rejecting GSP firmware DMA setup. |
| **Critical observation 2026-05-06** | `iommu=pt` is ALREADY on the kernel cmdline. Despite this, DMAR faults occur because: `iommu=pt` only puts trusted devices in passthrough; Thunderbolt-attached devices are marked "untrusted" by kernel TB security policy and DO use IOMMU translation. So the eGPU isn't actually being passthrough'd despite the cmdline. Need different approach. |
| Evidence AGAINST | None. The fault count and pattern are too clean to be noise. |
| Resolution test (refined) | **(a)** Boot with `iommu=off` — full IOMMU disable, definitive but insecure. Confirms or denies IOMMU as root cause. |
| (resolution test cont.) | **(b)** Mark eGPU as "trusted" via `pci=force_floppy=...` style mechanism, OR via Thunderbolt security level = `none` in `/sys/bus/thunderbolt/devices/0-1/authorized` — bypass the untrusted-device IOMMU enforcement. |
| (resolution test cont.) | **(c)** Investigate driver-side DMA map registration: NVIDIA driver may be missing `iommu_map` calls for GSP firmware regions. Compare with WSL2 path (where this bug doesn't fire). |
| (resolution test cont.) | **(d)** Try `intel_iommu=on,strict` vs `intel_iommu=on,lazy` — different invalidation modes might affect timing of map availability. |
| **EMPIRICAL TEST RESULTS 2026-05-06/07 (multiple boots)** | **(a) `intel_iommu=on,sm_off`** — TESTED. DMAR faults change reasons (0x71 SM → 0x05/0x06 legacy PTE) but still occur. SM mode is NOT the discriminator. Kept on cmdline as defensive aid (L4 helper succeeded 1/1 with sm_off vs 0/3 without — improves recovery reliability). |
| (continued) | **(b1) Loadable kernel module + DECLARE_PCI_FIXUP_HEADER/EARLY/FINAL** — TESTED. Built `aorus-egpu-trust.ko` at `kernel-modules/aorus-egpu-trust/`. Module loaded BUT fixups did NOT fire even via dracut initramfs `rd.driver.pre=aorus_egpu_trust`. Kernel scans PCI buses ~50ms BEFORE module load (eGPU enumerated at 00:39:50.771188; module loaded at 00:39:50.824826). Module-registered HEADER/EARLY fixups don't apply to already-enumerated devices. **Loadable-module quirk is structurally infeasible.** |
| (continued) | **(b2) `iommu_group/type=identity` write at runtime** — TESTED. EPERM (Operation not permitted). Kernel security rejects runtime IOMMU type changes for active devices. |
| (continued) | **REMAINING VIABLE PATHS** — (1) **Kernel patch + rebuild** (built-in pci-quirks.c entry — most surgical); (2) **`iommu=off` cmdline test** (definitive but blunt — may be overridden by "platform opt in"); (3) **Driver-side DMA map audit** (most upstream-correct, multi-day work); (4) **Accept recovery layer as architecture** — recovery is needed regardless for runtime AER and other failure modes. |
| Layer | L1 prevention (sovereign L5 — cmdline / driver / udev) |
| Cross-references | [H14](#h14) (root cause being investigated); `archive/commit3-recovery-loop-2026-05-06-161429/`; Lever G WSL2 evidence (closed driver doesn't show this); Task #93 |
| Priority | **HIGH** — could resolve H14 root cause and eliminate the entire WPR2-stuck cycle for cold-cold-boot |

### H11 — Phase 4 M-recover (in-kernel slot_reset/resume) avoids wrapper-FLR wedge

| Field | Value |
|---|---|
| Status | **OPEN** |
| Stated | 2026-05-05 |
| Evidence FOR | Kernel pci_error_handlers framework is the proper home for recovery — has the right locking, fd lifecycle, and ordering. Userspace orchestrating recovery into a half-disconnected device is fundamentally racy (see H2 evidence) |
| Evidence AGAINST | Not yet implemented; testing requires multi-day driver work |
| Resolution test | Implement M-recover patch (task #62), verify wrapper-FLR hack no longer needed |
| Layer | L1 sovereign (NVIDIA fork) — L3 reliability framework recovery |
| If supported | Wrapper-driven recovery deprecated; in-kernel recovery becomes default |
| Status note | This is the "right answer" destination per the project vision; everything else in recovery space is interim |

---

### H16 — PCIe link transient during GSP boot triggers GSP_LOCKDOWN independently of IOMMU

| Field | Value |
|---|---|
| Status | **PROBABLY-FALSIFIED 2026-05-08 — was likely H9a in disguise.** The 2026-05-07 evidence ("GSP_LOCKDOWN_NOTICE fires 18 times even with `iommu=off`") was generated *before* H9a (`aorus-egpu-pcie-tune.service` tightening DevCtl2 Range B too tight on Port A) was identified or retired. After H9a retirement on 2026-05-08 ~11:55 AEST: **9 consecutive cold-cold-boots show 0 GSP_LOCKDOWN events, 0 rm_init_adapter failures, 0 post-rmInit-FAIL** (verified via `archive/phase5-evidence/` and `/var/lib/aorus-egpu/wpr2-recoveries.log` `no-op,GPU healthy` records). Mechanism for the disguise: H9a's tight DevCtl2 timeout caused TB-tunneled config reads to time out, which the driver classified as PCI-not-PCIe → rm_init failed → GSP firmware saw host-side communication failure and tripped its lockdown. Same `0xffffffff` PMC_BOOT_0 read pattern that H16 attributed to a "PCIe link transient during GSP boot" was actually the config-read-timeout symptom of H9a. Confirmation gate: n≥10 consecutive clean boots (currently 9) closes this hypothesis as falsified. |
| Status (historical) | NEW 2026-05-07 14:54 — STRONGLY SUGGESTED at n=1 (`archive/iommu-off-test-2026-05-07-145453/`) |
| Discovered | 2026-05-07 14:54 cold-cold-boot with `iommu=off intel_iommu=off`. IOMMU truly disabled (DMAR: IOMMU disabled in dmesg, 0 DMAR faults). YET 18 GSP_LOCKDOWN_NOTICE events fired and 4 rm_init_adapter failures occurred before successful bind. |
| Evidence FOR | post-rmInit-FAIL diagnostic captured at 14:55:12: `PMC_BOOT_0=0xffffffff WPR2_ADDR_HI=0xffffffff` — the eGPU's PCIe bus reads as DEAD (0xff = electrical disconnect). IOMMU was disabled at this point so this can't be IOMMU-related. The brief bus-dead state implies a PCIe link transient during initial GSP boot. |
| Evidence AGAINST | None at n=1; need n>=3 cold-cold-boots to confirm pattern + that IOMMU=off doesn't introduce some unrelated transient. |
| Mechanism (hypothesis) | During GSP self-bootstrap, the eGPU's PCIe link to the upstream Thunderbolt switch goes through a brief state transition (link renegotiation, credit reallocation, power-state hiccup, or similar) that looks like "host link disappeared" from the GSP firmware's perspective. GSP firmware interprets host-link-loss during boot as a security violation, sends GSP_LOCKDOWN_NOTICE, and refuses to complete its self-bootstrap. WPR2 register is left set as side effect (GSP allocated it before locking down). |
| Relationship to prior hypotheses | Same family as Mode B silent freeze (Levers Q, H8, H9). Lever H9 tightened PCIe Completion Timeout to recover from runtime transients faster, but apparently doesn't prevent them at GSP-boot time. H16 is the GSP-boot specific manifestation of the same underlying class. |
| Resolution test | (a) Cold-cold-boot n>=3 with `iommu=off` and observe whether PMC_BOOT_0=0xffffffff transient is reproducible. (b) Capture lspci -vvv link state before/after the failed attempt. (c) Try further PCIe tuning (per-device CTV, ASPM disable on TB ports). (d) Compare with WSL2 path (where this bug doesn't fire) — closed driver may have internal retry logic that absorbs the transient. |
| Mitigation candidates | (a) **Recovery layer (Commit 3 hardened)** — patience-first design absorbs the transient via retry. (b) Tighten PCIe link parameters further. (c) Driver-side wait-and-retry on GSP self-bootstrap detection of host-link transient. |
| Layer | L1 (NVIDIA fork driver, RM-side GSP boot logic) for prevention; L4-L1 for recovery |
| Cross-references | [`docs/iommu-gsp-lockdown-analysis.md`](./iommu-gsp-lockdown-analysis.md), [`archive/iommu-off-test-2026-05-07-145453/`](../archive/iommu-off-test-2026-05-07-145453/), [H10](#h10), [H14](#h14), Lever Q-stack, Lever H8/H9, [H9a Port A root cause memory](../docs/) (project_port_a_h9a_root_cause_2026_05_08), `archive/phase5-evidence/` |
| Priority | **CLOSING.** ~~High — second known cause of cold-boot failure; investigation should follow IOMMU work.~~ Empirical falsification by H9a retirement is strong; investigation deprioritized. If the ledger ever sees a cold-boot failure with 0 GSP_LOCKDOWN events from H9a-controlled paths, reopen. |

### H15 — Commit 3 recovery action requires hardening (MaxAttempts gate + rate-limit + kill-switch persistence) before production-quality

| Field | Value |
|---|---|
| Status | **RESOLVED 2026-05-08** — Lever M-recover Commit 3 hardened reimplementation landed (patches 0024 + 0026 + 0027 + 0028); Phase 1-4 PASS; Phase 5 evidence collection ACTIVE (n≥10 PROVEN gate to retire `aorus-egpu-wpr2-recovery.service`). Storm pattern is mechanically prevented: H1 MaxAttempts gate is reachable in real recovery loops (verified 4-fire test surrendered at attempt 4 with `surrender after 4 attempts (max=3); emitting PERMANENT_FAIL`); H2 rate-limit defers fires <30s apart; H3 kill-switch file at `/var/lib/aorus-egpu/lever-m-killswitch` survives modprobe -r reload and overrides modprobe.d Enable=1 directives; H4 NEED_RESET path returns through err_handlers truth table. Originally PROVEN as a bug 2026-05-06 16:14 (21-attempt recovery storm); resolution required 4 hardening patches plus a sharpened design where attempt_count resets at post-rmInit-OK (verified end-to-end recovery), not at slot_reset_resume — without that fix the gate would still be unreachable in production. |
| Resolution patches | 0024 (Commit 3 + H1/H2/H3/H4 hardening, ~240 LoC C + ~105 LoC bash/udev); 0026 (sysfs `aorus_lever_m_force_trigger` for Phase 3 testing); 0027 (work handler explicitly dispatches slot_reset/resume after pci_reset_bus — `pci_reset_bus` doesn't go through err_handlers); 0028 (attempt_count resets only at post-rmInit-OK, not slot_reset_resume — makes H1 reachable in real storms). All landed and tested 2026-05-08. |
| Phase 5 evidence | `aorus-egpu-lever-m-phase5-snapshot.service` (oneshot, post-boot) writes `archive/phase5-evidence/<boot-iso>.log` with module identity + counters + dmesg events + verdict. n≥10 `M-RECOVER-FIRED-OK` snapshots (with post-rmInit-FAIL ≥ 1, proving WPR2-stuck was real) gate the L4 helper retirement. |
| Discovered | 2026-05-06 16:14:29 cold-cold-boot with patches 0001-0019 (Commit 3 active). 21 recovery attempts in ~9 minutes, no convergence, GPU driven into a state neither recovery nor patience could exit. |
| Bug 1 — No MaxAttempts enforcement | `NVreg_AorusLeverMMaxAttempts=3` module param exists since Commit 1 but `aorus_lever_m_handle_post_rmInit_fail` doesn't check it. Recovery fires unbounded. **Fix:** add `if (atomic_read(&aorus_lever_m_total_attempts) >= NVreg_AorusLeverMMaxAttempts) return false;` in trigger function. After surrender, propagate `-EIO` (not `-EBUSY`) to userspace; also increment `surrender_count`. |
| Bug 2 — No rate-limit / aggressive triggering interferes with NATURAL recovery | **Refined 2026-05-06 16:50 — much sharper now.** The 16:50:55 boot (Commit 3 disabled) showed: 7 sustained `rm_init_adapter` failures across 48 seconds → 8th attempt **NATURALLY SUCCEEDED with WPR2 still set**. Direct evidence in dmesg: GSP firmware sends `GSP_LOCKDOWN_NOTICE` repeatedly, eventually self-resolves. Commit 3's PCI churn every 10s was **interfering with firmware's self-recovery from lockdown.** **Fix (revised):** don't fire on ANY single failure. Track sustained-failure window (e.g., post-rmInit-FAIL count over last 5 minutes); only trigger recovery if count > 30 AND no `post-rmInit-OK` has fired. This targets ONLY the deep-stuck case where natural recovery isn't progressing. |
| Bug 3 — Kill-switch reset by L4 helper | `echo 0 > /sys/.../NVreg_AorusLeverMRecoverEnable` was reset back to 1 because L4 helper does `modprobe -r nvidia` + `modprobe nvidia` which reloads module with default param values. **Fix:** persist kill-switch outside module scope — sysfs file in `/var/lib/aorus-egpu/` OR systemd EnvironmentFile that L4 helper preserves. Alternative: have L4 helper read existing param value and re-apply after modprobe. |
| Bug 4 (suggested) — error_handler interaction with reset | M-base's `error_detected` returns `PCI_ERS_RESULT_DISCONNECT`. When recovery's `pci_reset_function` runs, the kernel invokes our error_handlers in the reset path. DISCONNECT may interfere with clean reset. **Fix:** make `error_detected` smarter — check `aorus_lever_m_recovery_in_progress`; if true, return `PCI_ERS_RESULT_CAN_RECOVER` instead of DISCONNECT. |
| Resolution path | ~~Patch 0020 hardens Commit 3 with all four fixes.~~ **Superseded:** the resolution shipped as patches 0024 + 0026 + 0027 + 0028 (see Resolution patches above). |
| Cross-references | `archive/commit3-recovery-loop-2026-05-06-161429/` (the storm forensic); patch 0019 (disabled — kept as falsified-but-documented historical record); patches 0024/0026/0027/0028 (resolution); `archive/phase5-evidence/` (ongoing PROVEN gate evidence); `docs/lever-m-recover-commit3-hardening-design.md`; `docs/lever-m-recover-commit3-handover.md`; task #62 |
| Priority | **CLOSED** — production posture is `Enable=1` (modprobe.d), kill-switch escape (`aorus-egpu-lever-m disable`) available, L4 helper remains as belt-and-braces backup until n≥10 PROVEN. |

### H14 — First rm_init_adapter on cold-cold-boot fails due to a transient bus state during initial GSP boot (root cause of H13's WPR2-stuck cycle)

| Field | Value |
|---|---|
| Status | **MULTI-CAUSE CONFIRMED 2026-05-07 14:54** — H14's "first rm_init_adapter failure" has at least TWO independent triggers: (1) IOMMU rejection (eliminated by `iommu=off`) and (2) PCIe link transient during GSP boot ([H16](#h16), independent of IOMMU). See [`docs/iommu-gsp-lockdown-analysis.md`](./iommu-gsp-lockdown-analysis.md) for the comprehensive analysis. |
| Discovered | 2026-05-06 15:47:34 — diagnostic patch 0018 captured `PMC_BOOT_0=0x00000000` at `post-rmInit-FAIL` site, vs `0x1b2000a1` at all other read sites in the same boot |
| Evidence FOR | At post-rmInit-FAIL site of the FIRST failed attempt: PMC_BOOT_0 reads 0 (not 0xFFFFFFFF — bus is electrically alive but the register is literally zero). At every subsequent read site (including post-rmInit-FAIL of retries): PMC_BOOT_0 = 0x1b2000a1 (normal value). The bus enters and exits a transient state during the first GSP boot attempt. |
| **Evidence FOR (refined 2026-05-06 16:24)** | **524 DMAR/IOMMU fault entries during the Commit 3 recovery storm.** Every `rm_init_adapter` attempt produces faults like `DMAR: [DMA Write NO_PASID] Request device [04:00.0] fault addr 0xXXXXXXXX [fault reason 0x71] SM: Present bit in first-level paging entry is clear`. Pattern: GSP firmware tries to DMA. IOMMU has no first-level paging entry for the address. IOMMU rejects. GSP boot fails. WPR2 left set. The PMC_BOOT_0=0 transient observed earlier is consistent with the GPU/GSP being in a stalled state during the failed DMA. |
| Evidence AGAINST | None observed; need n≥3 cold-cold-boots with diagnostic to confirm IOMMU pattern. |
| Mechanism (hypothesis, refined) | Initial GSP boot loads firmware, attempts DMA setup for its secure regions and runtime structures. The IOMMU (Intel VT-d, force-enabled per platform opt-in per dmesg `Intel-IOMMU force enabled due to platform opt in`) doesn't have those addresses mapped — either because: (a) NVIDIA driver isn't pre-registering them via `iommu_dma_map_*` before GSP boot tries to use them; (b) the IOMMU is in strict mode and the windows of validity are mismatched with GSP's expectations; (c) there's a race condition between IOMMU mapping setup and GSP firmware activation. IOMMU rejects → GSP DMA fails → GSP self-bootstrap fails → leaves WPR2 set in hardware → subsequent rm_init_adapter retries see "WPR2 already up" and refuse to retry. |
| **Mechanism (CRYSTAL CLEAR 2026-05-06 16:50)** | **GSP firmware enters LOCKDOWN mode** in response to DMA rejection. Direct evidence from kernel log RPC event history: GSP firmware sends `GSP_LOCKDOWN_NOTICE` (function 4124) repeatedly to host driver instead of `GSP_INIT_DONE` (function 4097). Host driver's `kgspWaitForRmInitDone` times out / sees lockdown → returns `NV_ERR_GPU_IS_LOST` → `_kgspBootGspRm` reports "WPR2 already up" → `rm_init_adapter` fails. The WPR2 register being set is a SIDE EFFECT of GSP allocating its secure region before locking down — not the cause of failure. The cause is the lockdown, triggered by IOMMU-rejected DMA. |
| **Self-resolution observation 2026-05-06 16:50** | With Commit 3 DISABLED (kill switch active), this boot showed: 7 sustained `rm_init_adapter` failures across ~48 seconds → 8th attempt SUCCEEDED with `post-rmInit-OK`, despite WPR2 register STILL being set at 0x07f4a000. Natural firmware-side recovery from lockdown happens within ~50 seconds for mild-stuck cases. The 16:14 boot's catastrophic 21-attempt non-recovery may have been because Commit 3's PCI churn every 10s disrupted whatever firmware-side progress was being made between retries. |
| Failure outcome | First rm_init_adapter returns NV_ERR (root cause of failure NOT YET LOCATED — could be conf-compute init, gpuSanityCheck flags=0x1, MMIO read failing, or other RM-side check seeing the transient). WPR2 register is left set at 0x07f4a000 (the normal-running value) but GSP isn't running. Subsequent rm_init_adapter retries see "WPR2 already up" and refuse to retry. → loops forever until something does a PCI reset (currently the L4 helper). |
| Resolution path | **★ PRIORITY ELEVATED 2026-05-06 16:24 — H10 (IOMMU policy) is the strongly-suggested root cause path; promote to next investigation.** |
| (resolution path cont.) | **(a) Test H10 first** — boot with `iommu=pt` (passthrough mode) or `intel_iommu=off` and observe whether DMAR faults disappear and rm_init_adapter succeeds on first call. This is the highest-impact single test we can run. |
| (resolution path cont.) | (b) If H10 resolves H14: dig into NVIDIA driver's IOMMU dma_map setup for GSP firmware regions — there may be a missing `dma_map_*` call or a race between map registration and GSP activation. Look at `os_alloc_mem`, `os_map_dma`, GSP runtime structure allocation. |
| (resolution path cont.) | (c) Read RM-side error code from rm_init_adapter (currently dropped — patch to log NV_STATUS). |
| (resolution path cont.) | (d) Bisect rm_init_adapter call graph: `confComputeConstructEngine`, `gpuSanityCheck_IMPL`, `osInitNvMapping`. With DMAR fault evidence, focus on functions that do DMA mapping. |
| (resolution path cont.) | (e) Try delaying first rm_init_adapter (e.g., add 100ms settle) — if a timing race, delay would help. |
| (resolution path cont.) | (f) Compare with WSL2: closed driver doesn't show this failure (Lever G). WSL2 may use VFIO passthrough which bypasses the IOMMU mapping issue, OR closed driver may pre-register DMA regions correctly. |
| Mitigation candidates (preventive) | Once root cause is identified, an in-driver fix could PREVENT the WPR2-stuck cycle entirely, rendering Lever M-recover's recovery action redundant for this specific failure mode. Recovery is still useful for OTHER failure modes that might leave the device dirty. |
| Layer | L1 (NVIDIA fork — RM-side rm_init_adapter call graph) |
| Cross-references | [H13](#h13) — H14 is the *root cause* of H13's symptom; [`docs/lever-M-recover-design.md`](./lever-M-recover-design.md) Open Question #6; [`archive/diag-telemetry-2026-05-06-154732/`](../archive/diag-telemetry-2026-05-06-154732/) |

### H13 — WPR2 register stuck blocks nvidia.ko init on cold-cold-boot

| Field | Value |
|---|---|
| Status | **MECHANISM REWRITTEN 2026-05-06 15:47 BY DIAGNOSTIC TELEMETRY.** Original framing ("WPR2 persists across reboots") FALSIFIED. Corrected mechanism: WPR2 register transitions from clear (0) to set (0x07f4a000) *during* the first failed `rm_init_adapter` call within a boot. Subsequent retries see "WPR2 already up" because the failed first attempt left it set. `0x07f4a000` is the **normal** running WPR2 value, not a stuck indicator on its own. The stuck condition is "WPR2 set, but rm_init_adapter just returned failure" — a state-mismatch, not boot-persistence. See [`archive/diag-telemetry-2026-05-06-154732/`](../archive/diag-telemetry-2026-05-06-154732/). New sub-hypothesis [H14](#h14) tracks the **first-failure root cause** (PMC_BOOT_0 transiently reads 0 during initial GSP boot). |
| Original status (now obsolete) | STRONGLY SUPPORTED 2026-05-06 (n=2 with definitive forensic evidence + recovery mechanism validated) |
| Discovered | 2026-05-06 07:46:14 cold-cold-boot after overnight power-off |
| Evidence FOR | n=2 cold-boot reproductions: 07:46:14 (first datum) + 09:00:55 (after 2-min full eGPU AC disconnect — second datum, REJECTING the prior `recovery-mechanism-findings.md` claim that AC unplug clears WPR2). All retry attempts in same boot fail at same WPR2-stuck wall. |
| Evidence AGAINST | None. The kernel error message is direct and unambiguous. |
| Trigger | Yesterday's session left GPU in declared-disconnected state at shutdown; WPR2 wasn't torn down cleanly; persists through host poweroff/poweron AND multi-minute eGPU AC disconnect. |
| Mechanism | GSP firmware's WPR2 (Write Protected Region 2) holds GSP runtime state. Once GSP enters lockdown, WPR2 retains the locked state across reboot/AC unplug. nvidia.ko's `_kgspBootGspRm` checks WPR2 status; if up, refuses to boot GSP. |
| Recovery — empirically validated 2026-05-06 09:14 | **`echo 1 > /sys/.../remove ; echo 1 > /sys/bus/pci/rescan ; echo 1 > /sys/.../reset` (the full sequence)** clears WPR2 reliably. Validated by sysfs experiment after Tier 1 v1/v2 attempts both failed: pcie_reset_flr forced but WPR2 stayed up; pci_reset_function returned -ENOTTY (kernel sees no methods). The remove+rescan changes the device's reset_methods state, after which reset succeeds. |
| Recovery — REJECTED mechanisms | Tier 1 v1: `pcie_reset_flr` alone ("PCI FLR might have failed" + WPR2 stays up). Tier 1 v2: `pci_reset_function` ("Inappropriate ioctl for device" / -ENOTTY). |
| Resolution path | **Lever R Tier 1 v3 (L4 userspace helper)** — pivoted from L1 to L4 after v1/v2 empirical failures. Helper runs after `aorus-egpu-compute-load-nvidia.service`, detects driver-bind-failed state via nvidia-smi failure + dmesg WPR2 pattern, executes the validated remove+rescan+reset sequence, re-runs compute-load-nvidia. Layer: L4 (helper) + L5 (systemd unit). See [`lever-R-design.md`](./lever-R-design.md). |
| Validation | Forensic dossier: `archive/boot-init-mode-b-2026-05-06-074608/`; sysfs experiment 09:14 demonstrating the working recovery sequence. **2026-05-06 11:08: Tier 1 v3 (L4 helper) SUPPORTED at n=1 under real cold-cold-boot WPR2-stuck conditions** — helper detected the failure, executed the 8-step recovery sequence, GPU restored to working state. End-to-end automatic recovery validated. Detection bug found+fixed during this run: `nvidia-smi -L` returns exit 0 even on "No devices found", so detection now parses stdout for `^GPU N:` pattern. **2026-05-06 12:33 — n=2 cold-cold-boot reproduction:** boot-time helper invocation FAILED first pass (post-recovery state showed conf-compute / gpuSanityCheck flags=0x1 — different failure mode than WPR2-stuck); manual second invocation 4 minutes later SUCCEEDED with identical sequence. Tier 2 PARTIAL retry-budget implemented (12:48): helper now retries up to MAX_ATTEMPTS=3 times with RETRY_DELAY_S=5 between, recording per-attempt history. **2026-05-06 12:56:48 — n=3 cold-cold-boot, ALL 3 attempts FAILED**: retry-budget triggered cleanly (Tier 2 plumbing validated structurally) but every attempt's verify reported no working GPU. Post-helper diagnostics in [`archive/boot-recovery-fail-2026-05-06-125648/`](../archive/boot-recovery-fail-2026-05-06-125648/) showed the kernel was looping in conf-compute mode every ~10s, source identified as `nvidia-persistenced` racing the helper's bind step. **2026-05-06 13:25 — manual rerun with persistenced STOPPED first SUCCEEDED on attempt 1 (13.7s)** — same code, same recovery sequence, only difference was no concurrent userspace authority touching `/dev/nvidia0`. **Race-condition hypothesis CONFIRMED.** Cumulative auto-recovery success: 1/4 (25%) — H13 status downgraded from STRONGLY-SUPPORTED to RACE-PROVEN: recovery sequence works in clean conditions, fails under userspace contention. **Resolution path PIVOTED to Lever M-recover** (in-driver state machine via `pci_error_handlers` + upstream bridge bus reset) — single arbiter, no race surface. See [`lever-M-recover-design.md`](./lever-M-recover-design.md). L4 helper remains as fallback during M-recover stabilization; retires upon M-recover PROVEN at n≥10. |

### H12 — CUDA process exit on declared-disconnected GPU spins worker threads in nvidia.ko close-path

| Field | Value |
|---|---|
| Status | **OPEN** (n=2 observed; awaiting next failure for forensic capture) |
| Stated | 2026-05-05 evening, recalibrated 2026-05-05 20:00 |
| Evidence FOR | n=2 observed: H9a iter #1 (192422) and iter #2 (195346) both produced post-cuMemAlloc-failure ollama runner zombie state with `Zl` STAT, 100% sustained CPU per `top`, NUC fan at full speed, accumulating CPU time confirmed via `top -bn2 -d1` (TIME+ incremented 1.00s in 1s wall). User-corrected my initial mis-call as "stale accounting" — multi-threaded process where leader is zombie but worker threads still running counts as `Zl` and CAN consume CPU. |
| Evidence AGAINST | None — pattern is consistent. (Iter #3 success didn't trigger because no failure occurred.) |
| Resolution test | Next iter that triggers Mode A failure: `capture_post_failure_threads` (added to wrapper) will dump `/proc/PID/task/*/stack` for each spinning thread. Stack will reveal which `nvidia.ko` function is the retry-loop locus (likely in close path / RM API teardown). |
| Mitigation candidates | (a) M-recover (Phase 4 / H11) — eliminates the dead-GPU state by recovering it; spin-trigger never occurs. (b) Direct fix: add GPU-lost shortcircuit in the close-path function the stacks reveal, same shape as Levers I, J-2, N, O. (c) Wrapper-side hack: detect 100% CPU on ollama-tagged process post-test, force kill -9 via SIGKILL aggressive enough to bypass close-path. |
| Layer | L1 (NVIDIA fork) for direct fix; L4 (wrapper) for workaround |
| Note | This is the same family as `architecture.md` Problem 4 (UVM close-path) — the close-path on this stack has unresolved deadlock cases when GPU state is bad. |

### H8 — DPC enable would catch Mode B (REJECTED 2026-05-05)

Hardware audit found no PCIe DPC capability on any device along the
eGPU path (00:07.0, 01:00.0, 02:00.0, 03:00.0, 04:00.0). Kernel `_OSC`
granted DPC control by firmware but there's nothing to control on this
TB-attached stack. Resolved at zero test cost via pure investigation.

---

## How to use this ledger

1. Before running a test: identify which hypothesis it resolves, and what outcome would shift its status
2. After running: update Evidence FOR / AGAINST in the relevant row, increment n, update status if threshold reached
3. When status reaches PROVEN / REJECTED: move to "Hypotheses retired" with the resolving evidence summary
4. Add new hypotheses as they emerge from data
5. Cross-reference each hypothesis with task IDs where relevant

## Update log

- **2026-05-05 evening** — initial publication; 11 hypotheses (H1–H11), 2 PROVEN
  (H4 NMI inadequate; H5 Phase 1b stack works), 1 DEFERRED (H7), 8 OPEN
- **2026-05-05 19:15 (Phase 1 audit)** — Read-only investigation of L1
  knobs. **H8 REJECTED** at hardware (no DPC capability on TB chain) —
  retired at zero test cost. **H9 NARROWED** into three sub-hypotheses
  (H9a completion timeout tightening, H9b LTR disable, H9c MaxReadReq
  raise) — MaxPayload confirmed at hardware floor (128B from TB host
  port). H10 IOMMU still open.
- **2026-05-05 20:00 — H9a SUPPORTED at n=3.** With CTV=2 applied at
  boot via systemd unit: iter #1 Mode A graceful, iter #2 Mode A
  graceful, iter #3 **success_inference** (clean Paris response in
  31.6s — first cold-boot success in this investigation). 0/3 Mode B
  silent freezes vs ~60% prior baseline. Productionised as
  `aorus-egpu-pcie-tune.service`. New hypothesis **H12** added:
  ollama runner exit while GPU declared-disconnected leaves worker
  threads spinning in nvidia.ko close-path retry loops (n=2 observed
  in iters #1 and #2; iter #3 success path didn't trigger).
  Forensic capture infrastructure (`capture_post_failure_threads`)
  added to wrapper — proven working but waiting for next failure to
  capture spin-locus stacks.
- **2026-05-05 20:12 — H9a retracted to OPEN.** Iter #4 with CTV=0
  (default) also produced success_inference — ruling out CTV as the
  load-bearing variable in this small sample. Methodology principle
  reinforced: n=3 is minimum but vulnerable to small-sample illusion.
  Total today: 5 iters (qwen2.5:0.5b ×4 + llama3.1:8b ×1), 0 Mode B
  silent, 2 Mode A graceful, 3 success. CTV systemd unit kept defensive.
- **2026-05-06 07:46 — H13 STRONGLY SUPPORTED on cold-cold-boot.**
  Overnight power-off, fresh boot at 07:46:08. nvidia.ko bind failed
  at GSP init with `_kgspBootGspRm: unexpected WPR2 already up`.
  WPR2 from yesterday's session persisted through poweroff/poweron.
  All 4 retry attempts in current boot fail at the same wall.
  Q-active fired correctly during the bus drop. Forensic dossier
  captured at `archive/boot-init-mode-b-2026-05-06-074608/`.
  This finding REFRAMES yesterday's "5/5 reliability" — the system
  was reliable WITHIN a session because GSP was happily running, but
  cold-cold-boot reveals the WPR2-stuck class of failure. New
  Lever R proposed: WPR2-stuck detection + auto-FLR at probe time.
  Current ledger state: 2 PROVEN (H4, H5), 1 REJECTED (H8),
  **1 STRONGLY SUPPORTED (H13)**, 1 DEFERRED (H7), 9 OPEN
  (H1, H2, H3, H6, H9a, H9b, H9c, H10, H11, H12).

### H17 — PCIe link speed instability during GSP boot is the H16 mechanism; capping bridge at Gen1 before nvidia bind eliminates the transient

| Field | Value |
|---|---|
| Status | **NEW 2026-05-07 15:18 — STRONGLY SUGGESTED** by Phase A telemetry (`archive/phase-A-telemetry-2026-05-07-151807/`) |
| Discovered | 2026-05-07 Phase A telemetry boot. Each post-rmInit-FAIL captured Bridge LnkSta showing speed=4 (Gen4), then speed=1 (Gen1), then speed=3 (Gen3). Success occurred when bridge settled at speed=1 (Gen1). GPU config space (LnkSta, AER) became unreadable (0x0000 / 0xffffffff) during failed attempts → real link transients, not just MMIO. |
| Evidence FOR | Phase A [DIAG] line at 15:18:07: `Br_LnkSta=0x7044 (Speed=4 Gen4)` at first failure; `Speed=1` at second failure; `Speed=3` at third; `Speed=1` at success. Bridge LnkCtl2 currently reads "Target Link Speed: 2.5GT/s (Gen1)" post-boot — implying the auto-downgrade or some earlier process settled it; success only happens AFTER it's settled. |
| Evidence AGAINST | n=1 only; need n>=3 to confirm pattern. Also need to confirm LnkCtl2 Target was actually higher than Gen1 during the failed attempts (not yet captured — Phase B telemetry could include LnkCtl2 reads too). |
| Mechanism (proposed) | At boot, bridge LnkCtl2 Target Link Speed defaults to maximum supported (Gen4 on this hardware). Link trains/negotiates to Gen4 initially. GSP firmware boot starts; the Gen4 link is unstable through TB4 (cable, retimers, signal integrity) and renegotiates down through Gen3, Gen1, etc. Each renegotiation is a brief link-training window during which the GPU is electrically partially-disconnected. GSP firmware sees these training events as "host link disappearing", interprets as security violation, sends GSP_LOCKDOWN_NOTICE. After the link finally stabilizes at Gen1 (or the kernel forces target=Gen1 due to repeated errors), subsequent GSP boot attempts succeed. |
| Resolution test | Pre-bind setpci write to bridge LnkCtl2 forcing Target=Gen1 BEFORE nvidia.ko binds. Implementation: systemd one-shot ordered Before=aorus-egpu-compute-load-nvidia.service. Falsifiable prediction: 0 GSP_LOCKDOWN_NOTICE on cold-cold-boot if hypothesis holds. |
| Layer | L4 (systemd helper) initially, possibly promote to L1 (NVIDIA driver-side) or L5 (cmdline) as production fix |
| Cross-references | [`docs/iommu-gsp-lockdown-analysis.md`](./iommu-gsp-lockdown-analysis.md), [`archive/phase-A-telemetry-2026-05-07-151807/`](../archive/phase-A-telemetry-2026-05-07-151807/), [H16](#h16) (H17 is the proposed mechanism for H16's symptom), [Lever H8/H9](../docs/lever-catalog.md) (same family, runtime version) |
| Priority | **HIGH** — the most actionable finding from Phase A. Single-test path to potential ZERO GSP_LOCKDOWN. |

| **2026-05-07 15:30 update** | Empirical test of Target=Gen3 cap REVEALED: hardware physically cannot sustain Gen3 on this TB4 path (2 retimers + cable + signal envelope force fallback to Gen1). Setting Target=Gen3 sticks (after retrain trigger) but actual LnkSta still reads Gen1. This means TB4-spec-ideal Gen3 is NOT achievable here — Gen1 IS the practical max. Implication: cap at Gen1 (Target=Gen1) is the correct test target. With Target=Gen1, kernel won't attempt renegotiation above Gen1 → no link transients → H17 trigger eliminated. Windows likely runs at Gen1 too on this hardware (Lever G WSL2 perf parity already validated at Gen1 link). |
| **2026-05-07 16:17 update** | Gen2 cap (`LnkCtl2=0x0042`) tested: 0 LOCKDOWN ✓, rmInit succeeds first try ✓. Empirical reliability ceiling = Gen2, not Gen1. Earlier "Gen1 is the practical max" was conflating LnkSta of Gen1 (post-failure downgrade) with what the link can sustain when cap is set in time. Gen2 is the new production cap. |
| **2026-05-07 16:51 update** | Gen3 cap (`LnkCtl2=0x0043`) tested with new G3-G AER Header Log telemetry: 36 LOCKDOWN ✗. Bridge sustained Gen3 through pre-rmInit; rmInit failed AT Gen3, link drop is downstream consequence. Forensic dossier: `archive/gen3-fail-2026-05-07-165158/`. |
| **2026-05-07 17:49 update — G3-E** | Gen3 + Hardware Autonomous Speed Disable (`LnkCtl2=0x0063`) tested: 36 LOCKDOWN ✗ (identical to plain Gen3). Bit 5 honored on speed-up but not speed-down on this TB silicon. **G3-E (autonomous Gen4 transient) hypothesis FALSIFIED.** |
| **2026-05-07 18:30 update — G3-G+G2** | New telemetry (ASPM, LBMS/LABS, AER Header Log + UncMsk + CapCtl) deployed. Findings: (1) ASPM=0 throughout — falsifies ASPM hypothesis; (2) `Br_AER_Cor=0x1` (Receiver Error / 8b/10b decode failure) set on bridge from FIRST DIAG site at Gen3 — physical-layer indicator; (3) GPU `UncMsk=0x00400000` (Uncorrectable Internal Error mask) explains `Cor=0x2000` source via demotion; (4) Header Log empty because masking suppresses UncStatus capture. **Gen3 fail mechanism = bridge Receiver Error from corrupted upstream signal + GPU Internal Error reaction, demoted to advisory.** Active investigation: docs/h17-g3-gen3-investigation-2026-05-07.md. |
| **2026-05-07 18:30 — H17.G3 next tests** | (1) Port swap to other NUC TB4 port — cheapest discriminator. (2) Windows host comparison via HWinfo64 + nvidia-smi.exe to learn closed-driver behaviour. (3) PCIe Link Equalisation Capability tuning — deferred, only if tests 1+2 leave Gen3 plausibly achievable. LnkCtl2 bit 6 (Selectable De-emphasis) is **Gen2-only** per spec §7.5.3.20; does NOT apply at Gen3. |
| **2026-05-07 19:50 — Port B Gen3 SUCCESS** | Cable swap to other NUC TB4 port (00:07.2 root, Barlow Ridge JHL9480 chain → 2d:00.0 → 2e:00.0). Gen3+bit5 cap → 0 LOCKDOWN, GPU bound at Gen3, rmInit succeeds first try. n=2 confirms port B works. **Port-A-fail vs port-B-success hypothesis: pending validation at n≥3 cold-cold-boots on each port.** |
| **2026-05-07 20:14 — Windows comparison** | Windows nvidia-smi.exe shows Gen4 internal LnkSta (between AORUS hub and GPU); HWinfo64 shows host-side LnkSta = 2.5 GT/s (Gen1) — **host TB tunnel is Gen1 on BOTH OSes**. Windows DEVPKEY_PciDevice_ECRC_Errors=160 cumulative (tolerated). Windows UncMask=0 vs Linux 0x00400000 (Linux silently demotes Internal Error to Cor=0x2000). Windows perf llama3.1:8b decode 220 tok/s, cold-load 8.0s (matches Gen1×4 PCIe saturation for 9.4GB model). |
| **2026-05-07 20:33 — G3-H UncMaskClear (patch 0022) + AER reframe** | Patch 0022 writes GPU AER UncMask=0 at probe time (matching Windows). Boot result: UncMask cleared ✓; expected Internal Error never fired (Cor=0x2000 was STALE bit from PCI enumeration, not active error). **Major reframe**: Br_AER_Cor=0x1 and GPU_Cor=0x2000 we'd been chasing as "active errors at Gen3" were stale RW1C bits accumulated during boot enumeration, NOT live signal-integrity events. Falsifies "Gen3 signal envelope" interpretation; the GSP boot failure on port A had a different cause (likely TB silicon-specific). HdrLog never populated — no Internal Error fired in operation. |
| **2026-05-07 20:33 — Recovery cycle root cause** | Periodic ~17s rmInit cycles on port B were caused by `aorus-egpu-observability-watchdog` polling `nvidia-smi -L` every 10s. Each nvidia-smi opens/closes /dev/nvidia0 → close-path wedge → link drop → M-recover transparent recovery. Watchdog redesigned 2026-05-07 (task #108) to use passive sysfs reads only. Post-redesign: 0 cycles, GPU stable at Gen3 internal indefinitely. **H17 is effectively resolved on port B**: Gen3+bit5 cap + UncMaskClear + passive watchdog + M-recover scaffold = stable. Port A still pending re-validation with this stack. |
| **2026-05-07 H17 status** | **PARTIALLY RESOLVED** (port B). Production cap = Gen3+bit5 (`LnkCtl2=0x0063`) on port B with M-recover enabled. Lever U design refined to target Gen3 (not Gen2) when on port B. Remaining: port A re-validation, host-side TB tunnel Gen1 → Gen3 (new H18). |
| **2026-05-07 22:16 — Port A re-validation FAILS with full Linux stack (REFRAMED)** | n=2 port A retest: cable swap to port A, full new stack (bridge-link-cap auto-detected `0000:03:00.0`, UncMaskClear active, passive watchdog, M-recover enabled). Result: **36 LOCKDOWN identical to original failure**, GPU wedged, 5 post-rmInit-FAIL cycles. WPR2 stuck (0x07f4a000) on first rmInit, GPU config space dies (LnkSta=0x0000, AER 0xffffffff) immediately after. Bridge cap was successfully applied (`LnkCtl2=0x0063`, link confirmed at Gen3 via retrain). UncMaskClear successfully wrote 0x00400000 → 0x00000000. **None of our software fixes restore port A.** **REFRAMED 2026-05-07: this is a LINUX-SPECIFIC failure, NOT hardware-specific.** User confirmed Windows/WSL runs llama3.1:8b successfully on port A on this same hardware → asymmetry is in our Linux stack (timing, ordering, driver behavior, cmdline params), not in NUC silicon/firmware. Initial conclusion of "hardware-broken" was premature; corrected. Candidate Linux-specific causes (none yet investigated): TB tunnel setup timing race with nvidia probe; bridge-link-cap.service ordering; open-driver fragility vs closed-driver tolerance; NUC ACPI/DSM differences per port; cmdline parameter interaction (`thunderbolt.host_reset=false`/`clx=0`/etc.); PCIe enumeration order edge case. **Port B is production until Linux-specific port-A cause is identified.** Lesson: don't conflate "our stack fails" with "hardware broken" — require evidence of behavior under different software (different OS) on the SAME hardware before concluding hardware-specific. |
| **2026-05-07 23:30 — TB domain forensics dossier diff: kernel-software cause confirmed by elimination** | Created reusable `tools/state-capture/state-capture.sh` + methodology doc; captured port-A and port-B dossiers (`archive/state-captures/2026-05-07T210031Z-active0/` + `2026-05-07T213415Z-active1/`); diffed across all surfaces. **Findings**: AORUS device sysfs BIT-IDENTICAL across boots. Retimer sysfs BIT-IDENTICAL. AORUS register dumps structurally identical (only session/timing register values differ). DROMs (all 3 routers across both boots) BIT-IDENTICAL via `cmp -l`. NHI sysfs differs only in PCI device-ID (0x7ec2 vs 0x7ec3) + kernel index — same revision, MSI-X count, IRQ, NUMA, subsystem. Cmdline + module params bit-identical between boots. ACPI paths identical. Bridge resource windows are simply assigned to whichever root port has the device (normal Linux PCI alloc). **By elimination: cause is in kernel TB driver per-domain initialization timing/order, NOT static config.** The two TB host controllers are bit-identical silicon (different PCI device IDs but functionally same chip). Fix domain: `drivers/thunderbolt/` — likely a race or order-of-operations issue when bringing up domain 0 vs domain 1, OR a probe-time race with nvidia driver init. Methodology: `docs/state-capture-methodology.md`. Tool reusable across N NUCs / N kernels for regression detection. **Strong empirical evidence base for Lever V-prime upstream RFC**: definitive proof the bug is in kernel software, not hardware. |
| **2026-05-08 09:37 — Port A boot with `thunderbolt.dyndbg=+pflm`: H19/H20/H21 ALL FALSIFIED, TB layer is NOT the failure surface** | Port A cold-boot, full verbose TB driver tracing on. Dossier: `archive/event-captures/B1-dyndbg-portA-2026-05-07T233951Z`. **TB driver came up cleanly**: `tb_wait_for_port: 0:1: link is up (state: 2)` — wait succeeded immediately (H19 falsified); zero `-ETIMEDOUT` / configuration_valid timeouts in raw kernel log (H20 falsified); zero `tunneled native ports are missing` warnings (H21 falsified, smoking gun absent). AORUS enumerated as `thunderbolt 0-1`, retimer found (NVM 26.85), USB4 link up, credits allocated, ACPI links created, switch configured. boltctl confirms TB tunnel up at 40 Gb/s × 2 lanes per direction (TB4 symmetric, identical to Port B). **The previous "kernel TB driver per-domain initialization timing/order" hypothesis (2026-05-07 23:30 entry) is empirically REJECTED at the TB driver layer.** The static-config diff was correct (TB state IS bit-identical between ports) but the inferred locus (TB driver init code) was wrong — TB driver behaves identically too. **Failure is downstream of TB**: same boot still produced 36 GSP_LOCKDOWN_NOTICE, 18 rmInit FAIL (0 OK), bridge demoted Gen3→Gen1, GSP RPC history contains 8 consecutive `GSP_LOCKDOWN_NOTICE` and never `GSP_INIT_DONE`. **Active causal locus must be at NVIDIA stack / GSP firmware boot / PCIe-tunneled bridge transient layer, NOT TB driver.** Failure pattern matches H16 (PCIe transient at GSP boot) more closely than any TB-driver hypothesis. Lever W (kernel TB driver per-domain init timing fixes) loses its empirical justification on Port A; needs re-evaluation. Open question: what makes Port A worse than Port B if both TB stacks behave identically and downstream transients fire on both? Possibilities to investigate: per-port retimer signal-integrity envelope (different physical traces despite identical silicon DROMs); per-port IDI/IOSF arbitration; per-port BIOS PCIe equalization; nvidia probe-vs-TB-tunnel-up race timing differing slightly per port. |
| **2026-05-08 10:48 — Port A boot with `thunderbolt.host_reset=true`: NOT VIABLE (BAR1 sizing breaks)** | Port A cold-boot with `host_reset=true` (was `false`). Hypothesis: TB host controller reset on probe might produce cleaner tunnel state and avoid GSP_LOCKDOWN. **Result**: experiment definitively **NOT VIABLE** as a mitigation. Two confounds + one fatal blocker discovered: (1) boltd refused auto-authorize (stored policy=`iommu`, but `iommu=off` cmdline → policy mismatch → device stuck `connected, authflags: none`); (2) `aorus-egpu-compute-load-nvidia.service` evaluated `ConditionPathExists` before TB authorized → didn't fire; (3) **FATAL**: After manual `echo 1 > /sys/bus/thunderbolt/devices/0-1/authorized` brought up the PCIe tunnel, GPU enumerated with **BAR1 = 256 MiB** (`0x4000000000-0x400fffffff`), not the required 32 GiB. The compute-load script's safety check fired with the explicit message: *"RTX 5090 BAR1 is smaller than 32 GiB; refusing to load NVIDIA. Confirm thunderbolt.host_reset=false is in /proc/cmdline and cold boot with the eGPU connected."* This is a **known, documented incompatibility** baked into the project's existing scripts — `host_reset=true` invalidates BAR1 sizing on this hardware. Cmdline reverted to `host_reset=false`. **Outcome**: `host_reset=true` is **eliminated as a viable mitigation knob** for the GSP_LOCKDOWN cascade. Dossier: `archive/event-captures/B2-host-reset-true-portA-2026-05-08T004927Z`. Lesson: existing project guard rails encode prior empirical findings; check `usr/local/sbin/aorus-*` script comments before proposing cmdline changes. |
| **2026-05-08 11:11 — B3-portB matched-pair forensics** | Captured Port B success-side dossier (B3) with full T1+T1.5+T1.6 instrumentation + monotonic timestamps + `NVreg_RmMsg="*"`. Manually triggered rm_init via `exec 3</dev/nvidia0` (after `nvidia-modprobe -c 0` to create the device node) so DIAG sites would fire matching B1's failure cycle. Result: rm_init OK, all 4 DIAG sites fired (probe-end, startdev-entry, pre-rmInit, post-rmInit-OK). Dossier: `archive/event-captures/B3-portB-success-WITH-rminit-2026-05-08T011624Z`. |
| **2026-05-08 11:46 — B4-portA matched-pair forensics + ROOT CAUSE IDENTIFIED** | Captured Port A failure-side dossier (B4) with same instrumentation, identical to B1 outcome (36 GSP_LOCKDOWN, 18 rmInit FAIL, 0 OK). Then ran structured A-vs-B diff: state, events, timeline, T1.5 PCIe Eq decoded, T1.6 NVIDIA procfs / TB counters / RAPL / thermal. **THE DISCRIMINATOR FOUND:** `/proc/driver/nvidia/gpus/.../information` shows Port A `Bus Type: PCI` + `Video BIOS: ??.??.??.??.??` + `GPU UUID: (missing)` + `GPU Firmware: N/A` — the open NVIDIA driver could NOT successfully read the GPU's PCI Express Capability at probe time. Port B (success) had all fields populated correctly. **The cause:** `lspci -vv` showed Port A GPU + root port DevCtl2 = `Completion Timeout: 1ms to 10ms` (Range B); Port B GPU + root port had `50us to 50ms` (Range A default). **Per-port asymmetric programming** comes from `aorus-egpu-pcie-tune.service` (Lever H9a) hardcoding Port A's BDFs (`0000:00:07.0` and `0000:04:00.0` at lines 50-51 of the script). Service runs at every boot and tightens DevCtl2 to Range B, which is too tight for TB-tunneled config space reads → reads time out, return 0xffffffff → driver classifies GPU as legacy PCI → rm_init fails → GSP_LOCKDOWN cascade. Falsifies all prior hypotheses (H17/H17.G3, H19/H20/H21, "hardware-broken Port A"). Memory: `project_port_a_h9a_root_cause_2026_05_08.md`. |
| **2026-05-08 11:55 — B5-portA-h9a-DISABLED CONFIRMS ROOT CAUSE** | Single-variable test: `systemctl disable aorus-egpu-pcie-tune.service`, cold-boot to Port A. **Result: 100% success.** All counters flipped: `gsp_lockdown_count` 36→0, `rminit_fail_count` 18→0, `rminit_ok_count` 0→1, `rminit_failed_msg_count` 9→0. `tb_wait_for_port_calls` unchanged (7→7 — confirms TB driver path identical, asymmetry was purely H9a). GPU info: `Bus Type: PCIe` (was PCI), `Video BIOS: 98.02.2e.80.5d` (was ??), `UUID: GPU-90b9424e-7236-fd4d-d903-44e565e1bd42` (matches Port B's UUID exactly — same physical GPU), `GPU Firmware: 595.71.05` (was N/A). Completion Timeout on root port + GPU = 50us-50ms (Range A default, untouched). Dossier: `archive/event-captures/B5-portA-h9a-DISABLED-SUCCESS-2026-05-08T015759Z`. **Lever H9a is the root cause of Port A failure. Fix path: redesign or retire H9a.** Outstanding: regression-test Port B with H9a disabled (Port B never used H9a's setting due to BDF mismatch, so should be unchanged); design replacement that preserves H9a's intent (faster Mode B silent-freeze detection) without breaking TB-tunneled reads. |

### H19 — `tb_wait_for_port()` 1-second cap is too short on cold-cold-boot with TB5/Barlow Ridge retimers (Thread A finding)

| Field | Value |
|---|---|
| Status | **FALSIFIED 2026-05-08 09:37 on Port A boot with `thunderbolt.dyndbg=+pflm`** — TB driver came up clean. |
| Mechanism | `drivers/thunderbolt/switch.c:501` `tb_wait_for_port()` hardcodes `retries=10` × 100ms = 1s ceiling. On cold-cold boot with TB5 + Barlow Ridge retimers in the chain, lane bring-up may exceed 1s. `tb_scan_port()` then aborts via `out_rpm_put`, leaving the AORUS box half-configured. Asymmetric cold-boot timing on domain 0 vs domain 1 could cross this threshold for one and not the other. |
| Evidence FOR | Source code shows hardcoded 1s cap; identifiable as a likely too-tight wait on TB5-class silicon. Per-domain timing variance is plausible (ACPI _DSM differences, ordering, etc.). |
| Evidence AGAINST | **2026-05-08 Port A cold-cold-boot with verbose dyndbg captured** (`archive/event-captures/B1-dyndbg-portA-2026-05-07T233951Z`): `tb_wait_for_port:537: 0:1: is connected, link is up (state: 2)` — wait succeeded immediately. Zero `-ETIMEDOUT` from thunderbolt subsystem. Retimer detected (`thunderbolt 0-0:1.1: NVM version 26.85`), USB4 link came up, AORUS device enumerated as `thunderbolt 0-1`. **The 1s cap did NOT fire on this Port A boot.** GSP_LOCKDOWN cascade still occurred (×36) → root cause is NOT TB driver init timing. |
| Resolution test | Original test obsolete (timeout doesn't fire). If H19 is to be re-tested in the future, would need to find a boot where TB *does* exhibit init timeout — none observed yet. |
| Layer | L1 (kernel thunderbolt driver patch) |
| Cross-references | `docs/tb-driver-source-analysis.md` § 3 H2/H5; Lever W status now needs re-evaluation given falsification |

### H20 — `usb4_switch_configuration_valid()` 50ms wait is too short for TB5 80G negotiation (Thread A finding)

| Field | Value |
|---|---|
| Status | **FALSIFIED 2026-05-08 09:37 on Port A boot with `thunderbolt.dyndbg=+pflm`** — no CR-bit timeout observed. |
| Mechanism | `drivers/thunderbolt/usb4.c:329` `tb_switch_wait_for_bit(..., ROUTER_CS_6_CR, 50)` — 50ms timeout for "Configuration Ready" bit. May be insufficient for TB5 80G symmetric negotiation, especially through the AORUS Barlow Ridge hub. |
| Evidence FOR | TB5 negotiation is more complex than TB4; 50ms looks tight by inspection. |
| Evidence AGAINST | **2026-05-08 Port A boot dossier**: zero matches for "configuration_valid", "ROUTER_CS_6", "CR.bit.*timeout", or "switch_wait_for_bit.*-ETIMED" in raw kernel log. `boltctl` confirms TB tunnel up at 40 Gb/s × 2 lanes (TB4 symmetric) — negotiation completed successfully. **The 50ms wait did NOT timeout on this Port A boot.** Per `boltctl` output the link is TB4 symmetric (not TB5 80G), so the TB5-specific concern doesn't apply on this hardware path. |
| Resolution test | Original test obsolete. If failure mode were ever observed where CR-bit takes >50ms, the patch would still be a defensible robustness improvement, but no evidence we currently hit it. |
| Layer | L1 (kernel thunderbolt driver patch) |
| Cross-references | `docs/tb-driver-source-analysis.md` § 3 H6 |

### H21 — Linux TB driver missing `tb_native_add_links()` causes asymmetric device-link guarding (Thread A finding)

| Field | Value |
|---|---|
| Status | **FALSIFIED 2026-05-08 09:37 on Port A boot** — smoking-gun warning is absent. |
| Mechanism | `drivers/thunderbolt/acpi.c:91` has `tb_acpi_add_links()` for Apple machines (CIO firmware). Non-Apple machines like our NUC rely on the kernel's per-device-link probing. If BIOS exposes the `usb4-host-interface` ACPI link asymmetrically between NHIs, one domain loses device-link guarding from downstream PCIe bridges, breaking PM-aware ordering. **Smoking gun:** `tb_warn(tb, "device links to tunneled native ports are missing!\n")` at `tb.c:3396` would fire for one NHI only if this is the cause. |
| Evidence FOR | Architecture-level: device links control PM ordering; missing guarding could plausibly fail PCIe tunnel + nvidia probe ordering on cold boot. |
| Evidence AGAINST | **2026-05-08 Port A boot dossier**: `grep -c "tunneled native ports are missing" full-kernel.log` = **0**. The smoking-gun warning did NOT fire on either NHI. Both `00:0d.2` (Port A NHI) and `00:0d.3` are observed creating TB ACPI links normally (`tb_acpi_add_link: created link from 0000:00:07.0` for `0d.2`). Per-domain ACPI device-link asymmetry is NOT present. |
| Resolution test | Original test executed and returned negative — H21 ruled out for this hardware/firmware combination. |
| Layer | L1 (kernel thunderbolt driver patch) |
| Cross-references | `docs/tb-driver-source-analysis.md` § 3 H1 |

### H18 — Host-side TB tunnel runs at PCIe Gen1 ×4 instead of TB4-spec Gen3 ×4

| Field | Value |
|---|---|
| Status | **NEW 2026-05-07 21:00** — observed across both NUC TB4 ports, both Linux and Windows |
| Discovered | 2026-05-07 cross-OS comparison: HWinfo64 on Windows shows host-side PCIe Link Speed = 2.5 GT/s (Gen1); Linux `lspci -vv -s 00:07.{0,2}` shows root port LnkCap = Speed 2.5GT/s. Both ports, both OSes consistent. |
| Evidence FOR | Two host root ports (00:07.0 port A, 00:07.2 port B) both LnkCap = Gen1 ×4 (~8 Gbps PCIe payload). Windows cold-load TTFT for 9.4 GiB llama3.1:8b model = 8.0 s, matching Gen1×4 saturation. TB4 spec allows PCIe Gen3 ×4 tunnels (~25 Gbps). NUC silicon is Meteor Lake-P with Intel "Gen14" TB4 controllers. AORUS box internal silicon is JHL9480 Barlow Ridge TB5-rated. Cable is NVIDIA-approved short TB5-rated. None of these support Gen1-only, so something is configuring the tunnel below capability. |
| Evidence AGAINST | None found yet. May turn out to be a Meteor Lake-P silicon limitation (some TB4 controllers ARE Gen1-only for tunneled PCIe), in which case it's not software-fixable. |
| Mechanism (proposed) | Host-side PCIe-over-TB tunnel is established with Gen1 ×4 link parameters. Could be: (a) Linux/Windows `thunderbolt` driver doesn't request higher gen at tunnel setup; (b) Intel TB controller silicon caps tunneled PCIe at Gen1; (c) NUC firmware/BIOS sets the host-side LnkCap before OS boots. (a) is fixable, (b)/(c) are not. |
| Resolution test | Per docs/tb4-tunnel-gen1-investigation.md: read-only audit (boltctl, TB sysfs, dmesg, kernel TB driver source) for negotiation logs; experimental TB module parameters; possibly TB tunnel teardown + renegotiation via boltctl. |
| Layer | L5 (kernel cmdline / module params) → L1 (kernel TB driver patch) if needed |
| Cross-references | feedback_no_bios_options_nuc15.md (BIOS toggles unavailable), [Lever V] (proposed), task #41 (BIOS IFR dump still pending), task #72 (Phase 7-native-A PCIe/TB tuning audit) |
| Priority | **HIGH** — 3× cold-load perf improvement potential. Direct Prevention win per project doctrine. User explicit priority 2026-05-07. |

| **2026-05-07 21:?? — H18 FALSIFIED** | nvbandwidth empirical measurement (NVIDIA's official tool, replaces deprecated bandwidthTest): **H2D = 2.80 GB/s = 22.4 Gbps useful payload**, D2H = 3.29 GB/s, bidirectional H2D = 2.47 GB/s. This is at TB4 saturation (70-82% of 32 Gbps spec ceiling, typical for real hardware). The lspci `LnkCap = Gen1` reading was virtual-bridge spoofing, NOT a real bandwidth limit. **There is no Gen1 ceiling to raise.** Lever V retired. Cold-load TTFT decomposition: pure PCIe portion ~3.4s (9.4 GB ÷ 2.8 GB/s); remaining ~4.6s of 8s observed is filesystem read + ollama deserialization + parse — task #74 (async pipelining) is the real cold-load lever. Methodology + diagram + measurement archived in `docs/cuda-bandwidth-methodology.md`, `docs/tb4-pcie-topology.md`, `docs/tb4-tunnel-gen1-investigation.md` (Resolution section). Memory entry `feedback_lspci_lnkcap_tb_virtual` saved for future sessions. **Lesson**: the OS-reported PCIe link state on TB-tunneled bridges is virtualized — measure with nvbandwidth before investigating software fixes. |

### H22 — Close-path bug class (architecture.md Problem 2) is empirically mitigated by the cumulative driver stack 2026-05-08

| Field | Value |
|---|---|
| Status | **PROVEN-MITIGATED 2026-05-08** at n=3 via `tools/close-path-probe.sh` (Patch 0029 instrumentation). The historical "second open of /dev/nvidia0 hangs the host" bug class no longer manifests on the current driver build with bridge-link-cap active. Recovery autonomous — Lever M-recover never had to fire. **Validation 2026-05-08 evening (Q2):** removing the bridge link cap re-introduced the failure (n=1 cap-disabled cold-boot wedged the GPU, 9 GSP_LOCKDOWN events, M-recover fired + surrendered cleanly because bus was beyond software recovery — `archive/close-path-probes/2026-05-08T21-49-58+10-00/`). Confirms cap is one of the load-bearing contributors to H22's mitigation. **First real-world Lever M-recover fire** — patches 0024+0026+0027+0028 production-validated. |
| Discovered | 2026-05-08 close-path-probe runs at 18:57, 19:01, 19:02 (back-to-back). Post-Patch 0029 build (aorus.11 / srcversion 4298F9B58C66AD1B0B825F6). Persistenced + uvm-keepalive drained before each run; `nvidia-smi -L` triggered LAST-CLOSE; 20s settle window; `aorus-egpu-lever-m-phase5-snapshot` captured each. |
| Empirical mechanics (from the probes) | **Close path runs an actual teardown:** WPR2 cleared 0x07f4a000 → 0; PCIe link demoted Gen3 → Gen1 (LnkSta 0x1043 → 0x1041); PMC_BOOT_0 stays healthy; zero AER. Duration ~629ms. **Next open recovers cleanly:** persistenced restart triggers `rm_init_adapter`; WPR2 re-set to 0x07f4a000; link retrains Gen1 → Gen3; post-rmInit-OK fires. ~1.3s wall-time cost. **Lever M-recover counters: fires=0, successes=0, surrenders=0** across all 3 probes. |
| Likely cumulative-mitigation contributors (no single-cause fit) | (1) **H9a retirement** (`aorus-egpu-pcie-tune.service` retired 2026-05-08): tightened DevCtl2 Range B (1ms-10ms) on Port A — without it, the default ~64ms timeout absorbs TB-tunneled config-read latency during Gen1↔Gen3 retrain and the second open succeeds. Strongest single contributor. (2) **Lever T cmdline** (`iommu=off intel_iommu=off`): eliminates IOMMU rejection of GSP DMA during boot; removed the H10/H14 root cause. (3) **Recovery levers I, J-2, N, O** (patches 0001-0008): convert "GPU lost ⇒ kernel deadlock" into "GPU lost ⇒ clean error code propagated" (Lever I, J-2, N, O). (4) **G3-H UncMaskClear** (patch 0022): matches Windows AER configuration; Internal Errors fire as Uncorrectable Non-Fatal (caught by err_handlers) instead of being demoted to Cor=0x2000 advisory (silent). (5) **Lever M-recover** (patches 0024-0028): ultimate safety net via post-rmInit-FAIL trigger + bus reset. Was not exercised in n=3 — acts as defense-in-depth, not primary path. |
| Operational implication | `nvidia-persistenced.service` is **reclassified from "load-bearing for stability" to "load-bearing for warmup latency"** — keep as performance optimization, not retire. ~1.3s GSP-boot tax per first-open after LAST-CLOSE if retired. See `docs/service-retirement-roadmap.md`. |
| UVM-side parallel | `aorus-egpu-uvm-keepalive.service` reclassification status PENDING — Patch 0029 instruments /dev/nvidia0's close path (in nvidia.ko) only. UVM lives in nvidia-uvm.ko with its own char device + handlers. UVM-side close-path bug class has not been re-tested with analogous instrumentation; presumptively load-bearing until probed. |
| Cross-references | `docs/architecture.md` Problem 2 (RECLASSIFIED 2026-05-08); `docs/lever-catalog.md` § Lever M-recover; `docs/service-retirement-roadmap.md` § persistenced (RECLASSIFIED) + uvm-keepalive (PENDING); `archive/close-path-probes/2026-05-08T18-57-32+10-00/`, `2026-05-08T19-01-17+10-00/`, `2026-05-08T19-02-01+10-00/`; patches 0024 + 0026 + 0027 + 0028 + 0029. |
| Priority | **CLOSED.** Production posture: persistenced + uvm-keepalive remain active as performance optimizations / pending UVM probe respectively. M-recover stands as insurance for any future regression. |
