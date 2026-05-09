# Event Capture Methodology

How to use `tools/event-capture/` for hypothesis-driven, deterministic
event analysis. Companion to `docs/state-capture-methodology.md`
(state) — events go here.

## Concept

A captured **event dossier** answers: "during this time window on this
machine, did each named hypothesis fire?"

The tool:
1. Captures the full kernel + journal log (raw)
2. Filters per-subsystem (one log per subsystem of interest)
3. Runs each hypothesis's signature patterns against the relevant filter
4. Generates per-hypothesis verdicts: **FIRED**, **NOT-FIRED**, **INCONCLUSIVE**
5. Rolls up a summary

Hypotheses and subsystem filters are **pluggable** — drop a new file
into `hypotheses/` or `subsystems/`.

## Run

```bash
sudo /root/aorus-5090-egpu/tools/event-capture/event-capture.sh \
    --experiment <name> \
    [--hypothesis h1,h2,...]    # default: all
    [--subsystem s1,s2,...]     # default: all
    [--since boot|<jrnl-spec>]  # default: boot
    [--changed key=value]       # repeat to record multiple changes
```

Output: `archive/event-captures/<name>-<timestamp>/`

## Compare two dossiers

```bash
/root/aorus-5090-egpu/tools/event-capture/event-capture-diff.sh \
    dossier_A \
    dossier_B
```

Prints verdict diff + count diff + suggested deep-dive commands.

## When to run

Run an event capture **after every test or environment change**:

| Scenario | Capture name |
|---|---|
| First boot of fresh setup | `baseline-portB` |
| After cmdline change | `B1-dyndbg-portA` |
| After kernel upgrade | `kernel-6.20-baseline` |
| After patch deployment | `lever-w-patch1-portA` |
| Reproduce someone else's bug | `<their-host>-<their-config>` |

The dossier name should encode which experiment + which environment.

## Adding a new hypothesis

1. Identify a behavior you want to detect: a kernel warning, a specific
   error message, a counter incrementing past a threshold.

2. Find the smoking-gun log signature: run grep on existing logs,
   identify the exact text or regex.

3. Copy a hypothesis file:
   ```bash
   cp hypotheses/h19-tb-port-wait-timeout.sh hypotheses/<your-id>.sh
   ```

4. Edit:
   - `HYPOTHESIS_ID` — unique short identifier
   - `HYPOTHESIS_DESC` — one-line description
   - `HYPOTHESIS_REF` — link to full doc reference
   - `HYPOTHESIS_SUBSYSTEM` — which `subsystems/<name>.sh` filter applies
   - `SIGNATURES_FIRED` — patterns whose match means "yes, this fired"
   - `SIGNATURES_NEGATIVE` — optional: patterns whose match means "no,
     ruled out" (otherwise verdict is INCONCLUSIVE if neither set fires)
   - `MIN_HITS_FIRED` — usually 1; higher for cascade-style signatures

5. Test:
   ```bash
   sudo ./event-capture.sh --experiment hypothesis-test --hypothesis <your-id>
   ```
   Inspect `<output>/30-hypotheses/<your-id>-evidence.txt`.

6. Add to `hypotheses/README.md` "Current hypotheses" table.

## Adding a new subsystem filter

Useful when investigating a new subsystem (a new driver, a new
userspace daemon, etc.).

1. Identify the journal pattern that uniquely identifies messages from
   the subsystem (driver name prefix, function name patterns, BDF
   ranges, etc.)

2. Copy a subsystem file:
   ```bash
   cp subsystems/thunderbolt.sh subsystems/<your-name>.sh
   ```

3. Edit `SUBSYSTEM_NAME`, `SUBSYSTEM_DESC`, `FILTER_PATTERNS`.

4. Test by running:
   ```bash
   sudo ./event-capture.sh --experiment subsystem-test --subsystem <your-name>
   wc -l <output>/20-filtered/<your-name>.log
   ```
   Expect a non-trivial number of lines if the filter matches real
   events; zero/very-few suggests filter is too narrow.

5. Add to `subsystems/README.md`.

## Verdict interpretation

| Verdict | Meaning | What to do |
|---|---|---|
| **FIRED** | At least `MIN_HITS_FIRED` matches against `SIGNATURES_FIRED` | Hypothesis confirmed in this scenario; investigate further |
| **NOT-FIRED** | Zero fired-signature matches AND ≥1 negative-signature match | Hypothesis ruled out for this scenario |
| **INCONCLUSIVE** | Zero matches against either set | Insufficient evidence; signatures may need refinement, OR scenario doesn't trigger this hypothesis |

## Testing methodology rule

Per memory `feedback_reliability_methodology`: **one variable per
test**. When running multiple captures to compare:

- Change exactly ONE thing (cmdline arg, kernel version, port, etc.)
- Capture before AND after with descriptive `--experiment` names
- Use `event-capture-diff.sh` to compare verdicts and counts
- A change that flips a verdict from NOT-FIRED to FIRED (or vice versa)
  is the signal you want

## Comparison patterns

### Same scenario, different ports
```bash
sudo ./event-capture.sh --experiment portB-stable --changed 'port=B'
# (reboot, swap to port A)
sudo ./event-capture.sh --experiment portA-fail --changed 'port=A'
./event-capture-diff.sh archive/event-captures/portB-stable-* archive/event-captures/portA-fail-*
```

### Before/after cmdline change
```bash
sudo ./event-capture.sh --experiment before-host-reset
# (grubby change, reboot)
sudo ./event-capture.sh --experiment after-host-reset \
    --changed 'cmdline-add=thunderbolt.host_reset=true'
./event-capture-diff.sh archive/event-captures/before-host-reset-* archive/event-captures/after-host-reset-*
```

### Cross-NUC reproduction
```bash
# On NUC #1
sudo ./event-capture.sh --experiment nuc1-baseline-portA
# Send dossier dir to NUC #2 via scp/rsync
# On NUC #2
sudo ./event-capture.sh --experiment nuc2-baseline-portA
./event-capture-diff.sh nuc1-baseline-portA-* nuc2-baseline-portA-*
```

## Pairing with state forensics

For a complete experimental record, run BOTH:

```bash
sudo /root/aorus-5090-egpu/tools/state-capture/state-capture.sh
sudo /root/aorus-5090-egpu/tools/event-capture/event-capture.sh \
    --experiment <name>
```

The two dossiers together (state + events) constitute the full
empirical record for the experiment.

## Specialised probes

For investigations that need an active trigger + state diff (not just
passive log analysis), purpose-built probe scripts compose state-capture
+ event-capture + a controlled action.

### Close-path probe (Patch 0029, 2026-05-08)

`tools/close-path-probe.sh` exercises the close-path on `/dev/nvidia0`
under controlled conditions and captures the full open→close→reopen
state diff using Patch 0029's close-path DIAG instrumentation.

```bash
sudo /root/aorus-5090-egpu/tools/close-path-probe.sh
```

Produces a dossier under `archive/close-path-probes/<run-id>/` containing:
- baseline state-capture + post-trigger state-capture
- pre/post dmesg snapshots and a filtered "delta-relevant" extract
- nvidia-smi exit code and output
- state-diff vs baseline
- event-capture run with `close-path-lifecycle` and `close-path-wedge-cycle`
  hypotheses evaluated

**When to run:** characterising the close-path bug behaviour on the
current driver build. After Patch 0029 lands, the dmesg delta will
include 4 close-path DIAG entries (`close-entry`, `pre-stop`,
`post-shutdown`, `close-exit`) on the LAST-CLOSE path, plus
[DIAG-AER2] state snapshots at each. Diffing these against the
preceding open-side DIAG entries reveals what the close path
mutates in PMC_BOOT_0 / WPR2 / LnkSta / AER state.

### UVM close-path probe (Patch 0030, 2026-05-08)

Sibling to close-path-probe.sh — exercises `/dev/nvidia-uvm`'s close
path with Patch 0030 instrumentation active.

```bash
sudo /root/aorus-5090-egpu/tools/uvm-close-path-probe.sh
```

Drains uvm-keepalive (and ollama, which can hold UVM via runners),
runs `tools/cuda-driver-api-smoke-test.py` (cuInit + cuCtxCreate +
cuMemAlloc + cleanup + exit — the exit closes /dev/nvidia-uvm), waits
20s for any teardown to settle, captures pre/post state-capture +
dmesg + diff. Output dossier under `archive/uvm-close-path-probes/`.

dmesg delta will include `[CLOSE]: site=uvm-open-entry`,
`uvm-release-entry`, `uvm-pre-destroy`, `uvm-post-destroy`,
`uvm-release-exit` markers. On LAST-CLOSE, full `[UVM-DIAG]` state
snapshot fires at each site — diff `uvm-pre-destroy` vs
`uvm-post-destroy` to see what `uvm_va_space_destroy` actually mutates
in GPU/firmware state. Hypothesis `uvm-close-path-lifecycle` evaluates
whether the LAST-CLOSE transition was exercised cleanly.

**Risk:** the trigger drives /dev/nvidia-uvm fd count to 0, which is
the historical Problem 4 unsafe transition. Lever M-recover does NOT
have a UVM-specific hook (it only catches /dev/nvidia0 side failures
via post-rmInit-FAIL); if the UVM close-path destabilises GSP/firmware
in a way that doesn't surface through nvidia.ko's open path, M-recover
won't catch it. Run during active observation. Have a reboot ready.

**Risk:** the trigger drops the open-count on `/dev/nvidia0` to zero,
which is the documented unsafe transition (architecture.md Problem 2).
Lever M-recover should catch any destabilisation; if it doesn't, host
freeze is possible. Run during active observation, not unattended.

## Tool maintenance

Both scripts are < 350 lines bash. Each hypothesis/subsystem file is
< 30 lines. Designed to be readable, modifiable by anyone touching
the project. No dependencies beyond standard Linux tools (`bash`,
`grep`, `journalctl`, `awk`).

When adding new hypotheses, the maintenance burden is per-hypothesis,
not per-tool — one signature file, no main-script changes needed.

## See also

- `state-capture-methodology.md` — STATE capture (companion)
- `thunderbolt-testing.md` — top-level TB testing entry point
- `reliability-hypothesis-ledger.md` — full hypothesis registry
