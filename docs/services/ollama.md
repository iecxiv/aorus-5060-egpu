# Service: ollama.service (with project drop-in)

**Status:** ACTIVE — application service, drop-in adjusts ordering and dependencies
**Layer:** L7 (application; we don't manage the binary) consumed via L5 drop-in
**Lifecycle since:** project inception

## Purpose

Long-running OLLama HTTP daemon serving CUDA inference (llama.cpp under the hood). Project drop-in `etc/systemd/system/ollama.service.d/aorus-egpu.conf` ensures it starts only after the eGPU is bound and persistenced is up, and only when the eGPU is actually present.

## Mechanism

- `ollama.service` (vendor) — runs `/usr/local/bin/ollama serve` as user `ollama`, listens on port 11434
- Project drop-in adds dependency ordering and condition guards

## Why we need the drop-in today

Without the drop-in:
- ollama could start before `compute-load-nvidia` binds the GPU → ollama would fail discovery, crash, retry, eventually succeed but with leaked partial state
- ollama could start with the eGPU disconnected → fail loudly with no ConditionPathExists guard
- Without `Requires=persistenced`, ollama runner subprocesses would be the first openers of `/dev/nvidia0` → each would pay the ~1.3s GSP-boot warmup tax

The drop-in is **architectural correctness** for a compute-only-eGPU stack, not a bug workaround.

## Configuration and tuning

### Project drop-in directives

| Directive | Effect |
|---|---|
| `After=aorus-egpu-compute-load-nvidia.service` | Ordering — wait until GPU is bound |
| `After=nvidia-persistenced.service` | Ordering — wait until persistenced has fds open |
| `Requires=aorus-egpu-compute-load-nvidia.service` | Hard dep — fail loud if loader didn't run |
| `Requires=nvidia-persistenced.service` | Hard dep — fail loud if persistenced isn't up |
| `ConditionPathExists=/sys/bus/pci/devices/0000:04:00.0` | Skip cleanly if eGPU disconnected |

### Removed 2026-05-08 (was a bug)

| Directive | Why removed |
|---|---|
| `After=aorus-egpu-uvm-keepalive.service` | uvm-keepalive RETIRED |
| `Requires=aorus-egpu-uvm-keepalive.service` | Was pulling in the retired service whenever ollama started — silently defeated the retirement until removed |

This was caught during the 2026-05-08 retirement audit. Lesson: when retiring a service, audit ALL `Requires=` and `After=` references across the stack — `systemctl disable` does not block dependency-driven startup.

### vendor-side knobs (env vars, set in vendor unit or drop-in)

| Variable | Default | Effect |
|---|---|---|
| `OLLAMA_HOST` | `127.0.0.1:11434` | Bind address + port |
| `OLLAMA_MODELS` | `/usr/share/ollama/.ollama/models` | Where models are stored |
| `OLLAMA_KEEP_ALIVE` | `5m` | How long a loaded model stays in GPU memory after last request |

For perf tuning of model loading, see [`/root/vllm/docs/perf-roadmap.md`](/root/vllm/docs/perf-roadmap.md) (vLLM-side investigation; some learnings transfer).

## Dependencies

**Requires + After:**
- `aorus-egpu-compute-load-nvidia.service` (GPU bound)
- `nvidia-persistenced.service` (warmup latency optimisation)

**ConditionPathExists:**
- `/sys/bus/pci/devices/0000:04:00.0`

## Lifecycle (boot / runtime / shutdown)

| Phase | Action |
|---|---|
| Boot | Starts after bound + persistenced; opens HTTP listener |
| Runtime | Long-running daemon; spawns short-lived `ollama runner` subprocesses per inference |
| Shutdown | systemd-shutdown sends SIGTERM; ollama drains in-flight requests then exits |

## Verification

```bash
systemctl is-active ollama
# active (running)

curl -s http://localhost:11434/api/tags | python3 -m json.tool | head
# Lists available models

# Functional: end-to-end inference
/root/aorus-5090-egpu/tools/cuda-driver-api-smoke-test.py
# cuda_smoke=pass

# Or: full ITERATION=1 8b loop
sudo ITERATIONS=1 MODEL=llama3.1:8b /root/ollama/tools/loop-with-flr.sh
# Expected: outcome=success_inference, fires=0
```

## Architectural destination

ollama itself is application-layer; we don't aim to retire it. The **drop-in** can simplify if/when:
- `compute-load-nvidia` retires (won't — architectural)
- persistenced reclassification means we no longer need warmup dependency (potentially, if M-preserve patch lands; would remove the `Requires=persistenced` line)

## Retirement criteria

**ollama itself:** N/A.

**Drop-in simplification:** if M-preserve patch lands and persistenced becomes truly optional even for warmup, the `Requires=nvidia-persistenced.service` line could be relaxed to `After=`. Simplification only.

## Resurrection procedure

If ollama service is somehow disabled / failing:

```bash
systemctl status ollama
systemctl restart ollama
journalctl -u ollama -b 0 | tail
```

If the drop-in is missing or out of date: re-run `bash apply.sh` from the repo (drop-in is now project-managed via `apply.sh` since 2026-05-08).

## Files installed / consumed

**Installed by `apply.sh`** (since 2026-05-08):
- `/etc/systemd/system/ollama.service.d/aorus-egpu.conf` (drop-in only)

**NOT installed by us:**
- `/usr/local/bin/ollama` (vendor)
- `/usr/lib/systemd/system/ollama.service` (vendor)

## Cross-references

- The 2026-05-08 retirement audit that caught the stale `Requires=uvm-keepalive`: memory `project_uvm_keepalive_retired_2026_05_08`
- Persistenced reclassification context: [`nvidia-persistenced.md`](./nvidia-persistenced.md)
- vLLM perf roadmap (some learnings transfer): `/root/vllm/docs/perf-roadmap.md`
