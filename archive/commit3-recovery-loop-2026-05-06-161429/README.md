# Forensic dossier — Commit 3 recovery loop + IOMMU/DMAR finding 2026-05-06 16:14

**Boot ID:** `ba10265a-052b-4062-a5e3-2746ffa3a0a2`
**Captured:** 2026-05-06 16:24 (~10 min after boot)
**Patch version:** 595.71.05-aorus.9 (binary; modinfo shows aorus.5 due to version.h cache)
**Patches applied:** 0001-0019, including Commit 3 (in-driver recovery action)

## Headline findings

### 1. Commit 3 detection + action mechanism WORKS

- Detection trigger fires correctly at `post-rmInit-FAIL` with WPR2 ≠ 0
- Recovery action (PCI remove + rescan + reset) executes cleanly
- Each cycle: ~700-3500 ms wall time (first faster, subsequent slower as system warms)
- Module-level dedup atomic correctly skips duplicate schedules ("recovery already in progress")
- userspace gets -EBUSY (not -EIO) — semantically correct
- L4 helper auto-skipped: ConditionPathExists=/sys/.../0000:04:00.0 fails during recovery's remove phase
- WPR2 register IS being cleared by each recovery cycle (verified via [DIAG] reads at startdev-entry showing WPR2_up=no immediately post-recovery)

### 2. Recovery loop is INFINITE on this hardware

After 21 attempts in ~9 minutes, no convergence. Each cycle:

```
recovery clears WPR2 → next rm_init_adapter fails with H14 → WPR2 set again →
  recovery fires → loops indefinitely
```

The PRIOR diagnostic boot (15:47:32, no Commit 3) eventually succeeded at 15:48:22
after ~50 seconds of natural persistenced retries. That suggests **patience would
have worked there but Commit 3's aggressive 10-second cycle prevented it**.

This boot's natural retries (after we disabled the lever) ALSO failed. Patience
alone is no longer enough — the GPU was driven into a deeper stuck state.

### 3. ★ HUGE FINDING — IOMMU/DMAR rejection during GSP boot ★

**524 DMAR fault entries this boot.** Every `rm_init_adapter` attempt produces:

```
DMAR: [DMA Write NO_PASID] Request device [04:00.0] fault addr 0xXXXXXXXX
      [fault reason 0x71] SM: Present bit in first-level paging entry is clear
```

Translation: GSP firmware tries to DMA-write to memory. IOMMU has no first-level
paging entry for that address. IOMMU rejects the access. GSP boot fails. WPR2
left set as side effect.

This is the **strongly-suggested root cause** of H14. It also pulls in
[H10 (IOMMU policy variation)](../../docs/reliability-hypothesis-ledger.md#h10),
which was previously untested. **The Commit 3 recovery storm exposed this signal
that would otherwise have been masked behind slow L4 helper retries.**

Fault address pattern across 60+ unique addresses (range 0xef2cf000 – 0xfb5d0000).
All from `04:00.0` (the GPU). Both DMA Read (`fault status reg 2`) and DMA Write
(`fault status reg 3`) faults. Reason `0x71` consistently — a Scalable-Mode
first-level paging entry not-present condition.

## Bugs in Commit 3 exposed by this boot (independent of root cause)

| # | Bug | Required fix |
|---|---|---|
| 1 | No `MaxAttempts` gate enforcement | Module param exists (`NVreg_AorusLeverMMaxAttempts=3`); add the check in `aorus_lever_m_handle_post_rmInit_fail` |
| 2 | No rate-limit between attempts | Track `last_attempt_jiffies`; reject re-fires within N seconds (e.g. 30s minimum) |
| 3 | Kill-switch reset by L4 helper modprobe-r/modprobe | NVreg_AorusLeverMRecoverEnable=0 was reset back to 1 because L4 helper unloads the module. Either make L4 helper preserve it, OR move kill-switch to non-module persistence (sysctl, sysfs file in /var/) |
| 4 | Aggressive recovery prevents natural GSP settling | Backoff timing — after first attempt, give GPU 30s+ before next attempt |
| 5 | `error_handler` returning DISCONNECT may interact poorly with reset | Smarter handler: when recovery is in progress, return CAN_RECOVER instead of DISCONNECT to let kernel's reset path complete cleanly |

These need fixing whether or not H10 (IOMMU prevention) lands. They're production-
quality concerns for any in-driver recovery mechanism.

## File index

| File | Lines | Content |
|---|---|---|
| `01-full-dmesg.log` | 4572 | Full kernel ring buffer this boot |
| `02-aorus-events.log` | 1062 | All AORUS / NVRM events |
| `03-diag-timeline.log` | 120 | All [DIAG] timeline reads |
| `04-recovery-action-events.log` | 116 | All RECOVERY ACTION starting/complete markers |
| `05-dmar-faults.log` | 524 | All DMAR fault entries (the big finding) |

## Implications for Lever M-recover

**Recovery layer is still needed regardless of IOMMU finding.** Lever M-recover
addresses recovery (Layer 3); H10/H14 IOMMU work addresses prevention (Layer 1).
Both are needed in a production driver. Even if H10 eliminates the WPR2-stuck
cycle for cold-cold-boot, runtime AER events / link drops / other failure modes
will still need recovery.

What this boot reveals about Commit 3 specifically:
- Action mechanism is correct
- Detection trigger is correct
- Lifecycle plumbing (refcount, dedup, unbind/rebind) is correct
- **Hardening is not** — needs MaxAttempts, rate-limit, kill-switch persistence

## Implications for Lever H10 (IOMMU policy)

**Massively elevated priority.** Previously untested hypothesis; now has direct
empirical evidence (524 DMAR faults) suggesting it could be the H14 root cause.
Test plan: boot with `iommu=pt` (passthrough mode) and observe whether H14
disappears.

## Cross-references

- Hypothesis ledger H13, H14, H10
- `docs/lever-M-recover-design.md` — Commit 3 status + bug list
- Patches 0019 (Commit 3) — needs hardening before re-deployment
- Task #93 (H10 IOMMU policy test) — promote priority
- Task #102 (H14 first-failure investigation) — IOMMU evidence added
- Task #62 (Phase 4 Lever M-recover) — Commit 3 hardening required
