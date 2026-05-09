# Per-service documentation

Each file in this directory is the **canonical entry point** for a single service in the AORUS RTX 5090 eGPU stack. Use these to understand:
- What the service does and why
- How to verify it's working
- All configuration knobs (module params, env vars, sysfs files, kernel cmdline, hardcoded values)
- Retirement criteria + procedure (when applicable)
- Resurrection procedure (for retired services)

If you're picking up retirement work or trying to understand a service in isolation, **start here.** The other docs (`architecture.md`, `lever-catalog.md`, `service-retirement-roadmap.md`) provide cross-cutting context but are not the per-service reference.

## Inventory (status as of 2026-05-08)

| Service | Status | Doc |
|---|---|---|
| `aorus-egpu-bridge-link-cap.service` | Active | [bridge-link-cap.md](./bridge-link-cap.md) |
| `aorus-egpu-compute-load-nvidia.service` | Active | [compute-load-nvidia.md](./compute-load-nvidia.md) |
| `aorus-egpu-observability-watchdog.service` | Active | [observability-watchdog.md](./observability-watchdog.md) |
| `aorus-egpu-lever-m-phase5-snapshot.service` | Active | [lever-m-phase5-snapshot.md](./lever-m-phase5-snapshot.md) |
| `nvidia-persistenced.service` (drop-in) | Reclassified 2026-05-08 | [nvidia-persistenced.md](./nvidia-persistenced.md) |
| `aorus-egpu-wpr2-recovery.service` | Pending retirement (Phase 5 gate) | [wpr2-recovery.md](./wpr2-recovery.md) |
| `aorus-egpu-uvm-keepalive.service` | Retired 2026-05-08 | [uvm-keepalive.md](./uvm-keepalive.md) |
| `aorus-egpu-pcie-tune.service` (Lever H9a) | Retired 2026-05-08 | [pcie-tune.md](./pcie-tune.md) |
| `aorus-egpu-link-monitor.service` | Retired 2026-05-07 | [link-monitor.md](./link-monitor.md) |
| `ollama.service` (drop-in) | Active (drop-in only) | [ollama.md](./ollama.md) |

## Document template

All service docs follow this structure:

```
# Service: <name>

**Status:** ACTIVE | RETIRED | RECLASSIFIED | PENDING_RETIREMENT
**Layer:** L4-L5 etc.
**Lifecycle since:** <date introduced>

## Purpose
## Mechanism
## Why we need it today
## Configuration and tuning      ← all knobs
## Dependencies
## Lifecycle (boot / runtime / shutdown)
## Verification
## Architectural destination
## Retirement criteria
## Retirement procedure
## Resurrection procedure
## Files installed / consumed
## Cross-references
```

## When to update

- Adding a new service: create a new file, add to inventory above
- Changing service behaviour or tuning: update the relevant doc
- Retiring a service: change status header + fill out retirement procedure + add resurrection procedure
- Resurrecting a retired service: change status header + note in cross-references which retirement-record was reverted

The per-service docs are the source of truth for service-level questions. `service-retirement-roadmap.md` carries the cross-cutting status table and retirement methodology; per-service detail lives here.
