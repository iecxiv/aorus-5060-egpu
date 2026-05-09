# Thunderbolt eGPU Testing & Troubleshooting Guide (Linux)

A comprehensive, hardware-agnostic guide for validating and debugging
Thunderbolt-connected external GPUs on Linux. This is the **first-in
entry point** — read this before diving into any specific deep-dive doc.

**Audience:** anyone debugging TB-eGPU issues on Linux, whether on this
exact NUC 15 Pro+ + AORUS RTX 5090 setup or a different host/enclosure
combination.

**Scope:** TB3 / TB4 / TB5 (USB4 v1/v2) hosts running Linux with NVIDIA,
AMD, or Intel GPUs in TB-enclosed external boxes. Most workflows
generalize; sections marked **(this hardware)** are specific to our
NUC 15 Pro+ + AORUS RTX 5090 setup.

---

## Table of Contents

1. [Quick smoke test (60 seconds)](#1-quick-smoke-test-60-seconds)
2. [Mental model: the TB-eGPU stack](#2-mental-model-the-tb-egpu-stack)
3. [Diagnostic decision tree](#3-diagnostic-decision-tree)
4. [Tools catalog](#4-tools-catalog)
5. [Test workflows by category](#5-test-workflows-by-category)
6. [Common failure modes & remediations](#6-common-failure-modes--remediations)
7. [Known baselines (reference values)](#7-known-baselines-reference-values)
8. [Cross-platform comparison methodology](#8-cross-platform-comparison-methodology)
9. [Investigation methodology (when nothing fits)](#9-investigation-methodology-when-nothing-fits)
10. [Reference appendix](#10-reference-appendix)

---

## 1. Quick smoke test (60 seconds)

Run this anytime to answer "is my TB-eGPU healthy?" Passive reads only,
**does not touch `/dev/nvidia*`** (avoids close-path wedge — see
`feedback_avoid_nvidia_smi_for_state_checks.md`).

```bash
# 1. eGPU TB-side authorized?
boltctl list

# 2. eGPU PCIe-side enumerated? (vendor 0x10de = NVIDIA, 0x1002 = AMD, 0x8086 = Intel)
for d in /sys/bus/pci/devices/*; do
    [[ "$(<$d/vendor 2>/dev/null)" == "0x10de" ]] && \
        echo "GPU: $(basename $d) device=$(<$d/device)"
done

# 3. Driver bound?
gpu_bdf=$(for d in /sys/bus/pci/devices/*; do
    [[ "$(<$d/vendor 2>/dev/null)" == "0x10de" ]] && basename $d && break
done)
[[ -L /sys/bus/pci/devices/$gpu_bdf/driver ]] && \
    echo "Driver: $(basename $(readlink /sys/bus/pci/devices/$gpu_bdf/driver))"

# 4. Link state on parent bridge
br_bdf=$(basename "$(dirname "$(readlink -f /sys/bus/pci/devices/$gpu_bdf)")")
lspci -vv -s "$br_bdf" | grep -E "LnkSta:|LnkCtl2:" | head -2

# 5. Any GSP_LOCKDOWN events this boot?
journalctl -k -b 0 | grep -c GSP_LOCKDOWN_NOTICE
```

**Healthy result:**
- boltctl shows eGPU `authorized`
- GPU enumerated with vendor + device IDs
- Driver = `nvidia` (or your GPU vendor's driver)
- LnkSta speed matches expected (Gen3 ×4 typical for TB4)
- 0 GSP_LOCKDOWN_NOTICE

**Unhealthy results → jump to** [Diagnostic decision tree](#3-diagnostic-decision-tree).

---

## 2. Mental model: the TB-eGPU stack

```
┌─────────────────────────────────────────────────────────────────────────┐
│  HOST                                  │   eGPU ENCLOSURE              │
│                                        │                               │
│  ┌────────┐  ┌──────────┐  TB cable   │  ┌─────────┐  ┌────────┐       │
│  │  CPU   │──│  TB ctrl │═════════════│══│ TB hub  │──│  GPU   │       │
│  │        │  │ (NHI)    │             │  │         │  │        │       │
│  └────────┘  └──────────┘             │  └─────────┘  └────────┘       │
│       ↑           ↑          ↑         │       ↑           ↑           │
│  internal     virtual PCIe  TB        │  real PCIe    GPU PCIe IP      │
│  fabric       (often Gen1)  protocol  │  (bridge)                      │
│  (IOSF/IDI)   to OS         tunnel    │                                │
└─────────────────────────────────────────────────────────────────────────┘
```

Critical mental model facts (commonly misunderstood — see
`feedback_lspci_lnkcap_tb_virtual.md`):

- **lspci `LnkCap` on TB host root ports is VIRTUAL** — it's a register
  state TB controllers expose to the OS, often hardcoded to Gen1, NOT
  a measure of actual tunnel throughput
- **The TB cable carries TB protocol, not raw PCIe** — PCIe TLPs are
  encapsulated, transported, decapsulated
- **Internal eGPU PCIe link IS real** — between the TB hub's downstream
  port and the GPU; lspci on this link reports actual electrical state
- **`nvidia-smi pcie.link.gen.current`** reports the GPU's view of its
  IMMEDIATE upstream — which is the eGPU-internal link, NOT the
  end-to-end tunnel
- **End-to-end bandwidth must be MEASURED, not inferred** — use
  nvbandwidth (see `cuda-bandwidth-methodology.md`)

Per-version capacity (useful PCIe payload after protocol overhead):

| TB version | Useful PCIe payload (each direction) | Max eGPU-internal cap that matches |
|---|---|---|
| TB3 | ~22 Gbps | Gen3 ×4 |
| TB4 | ~22-25 Gbps | Gen3 ×4 |
| TB5 symmetric | ~32 Gbps | Gen3 ×4 |
| TB5 asymmetric | ~50-64 Gbps unidirectional | Gen4 ×4 |

Capping the eGPU-internal link to match tunnel capacity prevents
**rate mismatch** (downstream tries to push more than tunnel can carry
→ flow control churn → retraining → for NVIDIA GPUs, GSP_LOCKDOWN
cascades). See `tb-pcie-cap-architecture.md` for the architectural
rationale and `lever-catalog.md` Lever V-prime for the upstream-able
fix design.

---

## 3. Diagnostic decision tree

Start here when something is wrong.

```
START — eGPU not working
    │
    ├─ boltctl list shows the eGPU? ────────── NO → § 6.1 (TB connectivity)
    │           │
    │          YES
    │           │
    ├─ lspci shows the GPU? ──────────────────  NO → § 6.2 (PCIe enumeration)
    │           │
    │          YES
    │           │
    ├─ Driver bound? ────────────────────────── NO → § 6.3 (driver binding)
    │           │
    │          YES
    │           │
    ├─ Driver responds (CUDA/OpenGL test)? ───  NO → § 6.4 (rmInit/firmware boot)
    │           │
    │          YES
    │           │
    ├─ GSP_LOCKDOWN events in dmesg? ────────  YES → § 6.5 (GSP boot cascade)
    │           │
    │           NO
    │           │
    ├─ Bandwidth meets baseline? ─────────────  NO → § 6.6 (bandwidth regression)
    │           │
    │          YES
    │           │
    ├─ Stable under load? ──────────────────── NO → § 6.7 (workload reliability)
    │           │
    │          YES
    │           │
    └─ All checks pass → eGPU is healthy
```

Each numbered branch (§ 6.x) below has detailed remediation.

---

## 4. Tools catalog

### 4.1 Standard Linux tools (already installed)

| Tool | Purpose | Caveats |
|---|---|---|
| `lspci -vv -s <BDF>` | PCI device + bridge config (capabilities, AER, link state) | Reads config space; safe |
| `lspci -t` | Topology tree showing TB hierarchy | Visual aid; safe |
| `setpci -s <BDF> CAP_EXP+0x12.W` | Read PCIe LnkSta directly (no driver involvement) | Config-space only; safe |
| `boltctl list / info / config` | TB/USB4 daemon device list + properties | Userspace; safe |
| `cat /sys/bus/thunderbolt/devices/*/...` | TB device sysfs (rx/tx_speed, lanes, generation) | Read-only; safe |
| `cat /sys/kernel/debug/thunderbolt/*/regs` | TB router register dumps | Requires root; read-only without `CONFIG_USB4_DEBUGFS_WRITE` |
| `journalctl -k -b 0` | Kernel log this boot | Read-only |
| `dmesg` | Kernel ring buffer | Read-only |
| `lsmod / modinfo` | Module info + parameters | Read-only |
| `nvidia-smi` | NVIDIA's GPU query tool | ⚠️ **Triggers close-path wedge on idle eGPU** — costs ~17s recovery cycle. Use sparingly; prefer sysfs reads. |

### 4.2 Project-specific tools (this repo)

| Tool | Purpose | Doc |
|---|---|---|
| `tools/state-capture/state-capture.sh` | Capture full TB/PCIe state into diff-friendly dossier | `state-capture-methodology.md` |
| `nvbandwidth` (NVIDIA, build from source) | Measure end-to-end host↔GPU PCIe bandwidth via copy engines | `cuda-bandwidth-methodology.md` |
| `usr/local/sbin/aorus-egpu-bridge-link-cap` | Cap downstream PCIe LnkCtl2 before driver binds | Auto-detects parent bridge BDF |
| Patched NVIDIA driver `[DIAG]` telemetry | At-probe-time AER + LnkSta + ASPM + LBMS/LABS dumps | Built into our nvidia-open-src patches 0020/0021/0022 |
| M-recover sysfs counters (`/sys/bus/pci/devices/<gpu>/aorus_lever_m_*`) | Recovery state machine fire/success/surrender counts | Patches 0016/0017/0018 |
| Q-watchdog kthread + sysfs counters | Passive MMIO heartbeat, dead-bus detection | Patches 0014/0015 |
| `aorus-egpu-observability-watchdog` (passive) | SysRq capture on Mode B silent freeze | `service-retirement-roadmap.md` |

### 4.3 When to use which tool

| Need to know... | Use |
|---|---|
| Is GPU plugged in? | `boltctl list` |
| Is GPU enumerated as PCI? | sysfs vendor/device check (smoke test #2) |
| Is driver bound? | sysfs driver symlink check (smoke test #3) |
| Is rmInit succeeding? | `journalctl -k \| grep '\[DIAG\]'` (if patched driver) OR check for GSP_LOCKDOWN |
| Current link speed? | `lspci -vv` on parent bridge (LnkSta) — config-space, safe |
| GPU temp / power | `nvidia-smi --query-gpu=temperature.gpu,power.draw --format=csv` (accept the wedge cost) |
| Actual end-to-end bandwidth? | `nvbandwidth -t 0` (H2D), `-t 1` (D2H) — accept one wedge cycle |
| Compare two configs side-by-side? | `state-capture.sh` then `diff -r` |
| Why did probe fail? | `journalctl -k -b 0 \| grep -E 'NVRM\|nvidia\|thunderbolt\|GSP'` |

---

## 5. Test workflows by category

### 5.1 Connectivity test (TB cable + authorization)

**Goal:** confirm TB cable + enclosure are alive at the TB-protocol level
(before any PCIe consideration).

```bash
boltctl list
ls /sys/bus/thunderbolt/devices/
journalctl -k -b 0 | grep -iE "thunderbolt|new device|retimer" | head
```

**Expected:**
- boltctl shows eGPU device `authorized`
- sysfs has entries like `0-1` or `1-1` (domain-port pattern)
- kernel log shows `thunderbolt X-Y: <vendor> <model>`

**Common failures:**
- No boltctl entry → cable / enclosure power / TB controller issue
- Device shows but `authorized=0` → manual auth needed: `boltctl authorize <uuid>`
- Device flickers (connect/disconnect) → cable signal integrity, retimer issue

### 5.2 PCIe enumeration test

**Goal:** confirm the GPU appears as a PCI device with expected vendor/class.

```bash
# By vendor (NVIDIA = 10de, AMD = 1002)
for d in /sys/bus/pci/devices/*; do
    v=$(<"$d/vendor" 2>/dev/null)
    if [[ "$v" =~ ^0x(10de|1002)$ ]]; then
        echo "$(basename $d): vendor=$v device=$(<$d/device) class=$(<$d/class)"
    fi
done

# Topology
lspci -t
```

**Expected:**
- GPU at typical depth (root port → TB hub → downstream port → GPU)
- class `0x030000` (VGA) or `0x030200` (3D controller, compute-only)

**Common failures:**
- GPU not enumerated → bridge cap blocking too aggressively, or TB tunnel
  not bringing up PCIe portion
- GPU enumerated but config space dies (0xffff reads) → wedged after
  failed init

### 5.3 Driver binding test

```bash
gpu=$(for d in /sys/bus/pci/devices/*; do
    [[ "$(<$d/vendor 2>/dev/null)" == "0x10de" ]] && basename $d && break
done)
echo "Driver: $([[ -L /sys/bus/pci/devices/$gpu/driver ]] && \
    basename $(readlink /sys/bus/pci/devices/$gpu/driver) || echo 'UNBOUND')"
```

**Expected:** `nvidia` (or `nouveau` if not blacklisted; or `amdgpu` for AMD).

**Common failures:**
- `UNBOUND` → driver missing, blacklisted, or device blocklisted
- Bound but wrong driver (e.g., `nouveau` instead of `nvidia`) → blacklist
  setup wrong

### 5.4 rmInit / firmware boot test (NVIDIA-specific)

```bash
# With patched driver (this project): check [DIAG] entries
journalctl -k -b 0 | grep '\[DIAG\]' | grep -E "site=post-rmInit"

# Without patched driver: check generic NVRM messages
journalctl -k -b 0 | grep -iE "RmInitAdapter|GSP_INIT_DONE|GSP_LOCKDOWN"
```

**Expected:**
- `post-rmInit-OK` (patched driver) — clean boot, GPU ready
- `RmInitAdapter` succeeds without retries (stock driver)
- `GSP_INIT_DONE` (function 4097) seen in RPC, not LOCKDOWN_NOTICE

**Common failures:**
- `post-rmInit-FAIL` with WPR2 stuck → GSP firmware boot failed, see § 6.5
- Endless retry loop → recovery scaffold engaged but can't break free

### 5.5 Bandwidth test (end-to-end host↔GPU)

Build nvbandwidth once (per `cuda-bandwidth-methodology.md`):

```bash
sudo dnf install -y cuda-minimal-build-13-2 cuda-nvml-devel-13-2 cmake boost-devel
cd /root && git clone --depth 1 https://github.com/NVIDIA/nvbandwidth.git
cd nvbandwidth && mkdir -p build && cd build
PATH=/usr/local/cuda/bin:$PATH cmake .. -DCMAKE_BUILD_TYPE=Release
make -j$(nproc)
```

Run:

```bash
./nvbandwidth -t 0   # host → device (model loading)
./nvbandwidth -t 1   # device → host
./nvbandwidth -t 2   # bidirectional
```

**Interpretation:** see `cuda-bandwidth-methodology.md` and § 7 below.

### 5.6 Cross-port / cross-domain comparison (multi-port TB hosts)

If your host has multiple TB controllers/ports, capture and compare:

```bash
# Boot with eGPU on port A:
sudo /root/aorus-5090-egpu/tools/state-capture/state-capture.sh
# → archive/state-captures/<timestamp>-active0/

# Reboot with eGPU on port B:
sudo /root/aorus-5090-egpu/tools/state-capture/state-capture.sh
# → archive/state-captures/<timestamp>-active1/

# Diff:
diff -r dossier_A dossier_B | less
diff dossier_A/01-summary.txt dossier_B/01-summary.txt
cmp -l dossier_A/41-debugfs-drom-0-0.bin dossier_B/41-debugfs-drom-1-0.bin
```

**See:** `state-capture-methodology.md` for full methodology +
interpretation guide.

### 5.7 Cross-OS comparison (Linux vs Windows on same hardware)

The strongest discriminator for "is this hardware-fixable in Linux?"
is comparing Linux vs Windows on identical hardware/cable/port.

**Linux side:**
- Run all tests above, save results

**Windows side:**
- `nvidia-smi.exe --query-gpu=...` (see project `windows-test/`)
- HWinfo64 export (Bus → PCI Express → AORUS GPU device)
- Run same workload (e.g., ollama llama 8B) and capture timings

**If Windows works and Linux doesn't:** failure is Linux/driver-specific,
not hardware. See memory `feedback_dont_conflate_stack_failure_with_hardware_broken.md`.

---

## 6. Common failure modes & remediations

### 6.1 TB connectivity failure

**Symptoms:** boltctl doesn't show eGPU, or shows `authorized=0`, or
flickers connect/disconnect.

**Checks:**
```bash
boltctl list
journalctl -k -b 0 | grep -iE "thunderbolt|usb4_port|retimer|new device"
cat /sys/bus/thunderbolt/devices/*/authorized 2>/dev/null
```

**Remediations:**
1. **Cable:** swap to known-good TB-certified cable (short + thick = better)
2. **Enclosure power:** verify enclosure is fully powered before plugging cable
3. **Authorize manually:** `boltctl authorize <uuid>` if security policy blocks auto-auth
4. **Try other host port:** isolate cable/enclosure from host side
5. **Reboot:** sometimes TB stack needs a clean restart

### 6.2 PCIe enumeration failure (TB up, GPU not visible)

**Symptoms:** boltctl shows eGPU, but lspci doesn't show the GPU.

**Checks:**
```bash
lspci -t | grep -B5 "$(lspci | awk '/3D|VGA/{print $1}' | head)"
journalctl -k -b 0 | grep -E "thunderbolt|tunnel|new device"
```

**Remediations:**
1. **Wait longer:** TB tunnel + PCIe enumeration can take 5-10s after device auth
2. **PCI rescan:** `echo 1 > /sys/bus/pci/rescan` (forces re-enumeration)
3. **TB tunnel renegotiation:** `boltctl forget <uuid>` then `boltctl authorize <uuid>`
4. **Reset host TB controller:** `thunderbolt.host_reset=true` cmdline (default; we force false in this project — try removing if stuck)

### 6.3 Driver binding failure

**Symptoms:** GPU enumerated but `driver` symlink absent or wrong driver.

**Checks:**
```bash
gpu=$(...)  # from smoke test
ls /sys/bus/pci/devices/$gpu/driver 2>/dev/null
lsmod | grep -iE "nvidia|nouveau|amdgpu"
cat /etc/modprobe.d/*.conf | grep -iE "blacklist|install" | head
```

**Remediations:**
1. **Module loaded?** `modprobe nvidia` (or `amdgpu`)
2. **Blacklist conflict:** check `/etc/modprobe.d/` for `blacklist nvidia` entries
3. **Manual bind:** `echo "10de 2b85" > /sys/bus/pci/drivers/nvidia/new_id`
4. **Driver install:** verify driver is actually installed (`modinfo nvidia`)

### 6.4 rmInit failure (driver bound, but GPU non-functional)

**Symptoms:** Driver bound, but no `/dev/nvidia0`, or it exists but CUDA fails.

**Checks:**
```bash
ls -la /dev/nvidia*
journalctl -k -b 0 | grep -iE "RmInitAdapter|nvidia|NVRM" | tail -20
journalctl -k -b 0 | grep '\[DIAG\]' | grep "site=post-rmInit" | tail -5
```

**Remediations:** depends on what failed inside rmInit. Most common
is GSP_LOCKDOWN (§ 6.5).

### 6.5 GSP_LOCKDOWN cascade (NVIDIA-specific, the big one)

**Symptoms:** `journalctl -k | grep GSP_LOCKDOWN_NOTICE` returns >0;
GPU wedged; rmInit fails repeatedly; WPR2 stuck (`0x07f4a000` value).

This is the most common failure mode for Blackwell/RTX 50-series GPUs
on TB-tunneled hosts. Root mechanism: GPU PCIe link rate mismatch with
TB tunnel capacity → flow-control churn during GSP firmware boot →
GSP firmware refuses to boot, sets WPR2 to error value, signals lockdown.

**Verify with patched driver:**
```bash
journalctl -k -b 0 | grep '\[DIAG\]' | grep "site=post-rmInit-FAIL" | tail
# Look for: WPR2=0x07f4a000 WPR2_up=YES — confirms WPR2-stuck mechanism
```

**Remediations (in order of cheapness):**

1. **Cap downstream PCIe to match TB tunnel** — write parent bridge's
   `LnkCtl2` Target Link Speed to match TB version capacity:
   - TB3/TB4 → Gen3 ×4 (`LnkCtl2 = 0x0063` = Gen3 + Hardware Autonomous Speed Disable)
   - TB5 sym → Gen3 ×4 same
   - TB5 async → Gen4 ×4 (`LnkCtl2 = 0x0064`)
   ```bash
   # Find parent bridge of GPU (auto-detect):
   gpu=$(for d in /sys/bus/pci/devices/*; do
       [[ "$(<$d/vendor 2>/dev/null)" == "0x10de" ]] && basename $d && break
   done)
   br=$(basename "$(dirname "$(readlink -f /sys/bus/pci/devices/$gpu)")")
   # Read current
   setpci -s "$br" CAP_EXP+0x30.W
   # Write Gen3+bit5 (preserve high bits, clear low 6, OR in 0x63):
   cur=$(setpci -s "$br" CAP_EXP+0x30.W)
   new=$(printf '%04x' $(( (0x$cur & 0xffc0) | 0x63 )))
   setpci -s "$br" CAP_EXP+0x30.W="$new"
   # Trigger retrain
   lc=$(setpci -s "$br" CAP_EXP+0x10.W)
   setpci -s "$br" CAP_EXP+0x10.W=$(printf '%04x' $(( 0x$lc | 0x20 )))
   ```
   **MUST be done BEFORE nvidia driver binds** — once GSP boot fails
   and WPR2 is set, the cap won't help (firmware needs reset).

2. **Restart with cap applied at boot** — use a systemd one-shot service
   that runs before driver bind. See
   `usr/local/sbin/aorus-egpu-bridge-link-cap` and
   `etc/systemd/system/aorus-egpu-bridge-link-cap.service` for our
   reference implementation.

3. **In-driver cap** — Lever U / Lever V-prime patches (in development).
   See `lever-catalog.md`.

4. **Architectural fix** — Lever V-prime (kernel TB driver patch) is
   the upstream destination. See `tb-pcie-cap-architecture.md`.

5. **If cap is applied AND it's still failing on a specific port** —
   per-domain Linux issue. Capture forensic dossier for both ports
   (§ 5.6) and compare. May be a kernel TB driver per-domain bug
   (this project hit this on NUC 15 Pro+ — port A fails, port B works
   with identical config).

### 6.6 Bandwidth regression

**Symptoms:** nvbandwidth H2D below baseline (see § 7).

**Checks:**
```bash
./nvbandwidth -t 0
# Compare to expected for your TB version
```

**Remediations:**
1. **Verify cap is applied correctly** — check `LnkCtl2` matches expected
2. **Verify link is actually at expected gen** — check `LnkSta` Speed bits
3. **Check for active errors** — `lspci -vvv -s <bridge> | grep AER`;
   correctable error counters incrementing under load = degraded link
4. **Check for thermal throttling** — `nvidia-smi -q -d TEMPERATURE`;
   GPU >90°C may downclock
5. **Check for power state issues** — `nvidia-smi -q -d POWER`; if
   power.draw is far below power.limit during workload, likely a
   PCIe / DMA pipeline stall
6. **Compare to known-good port** — if multi-port host, run on each
   port to isolate

### 6.7 Workload reliability (works at idle, fails under load)

**Symptoms:** GPU passes smoke test but fails during sustained CUDA work.

**Checks:**
```bash
# Watch [DIAG] cycles during workload
journalctl -k -f | grep '\[DIAG\]'
# AER counters
watch -n1 "lspci -vvv -s $br | grep -A1 'Correctable'"
# M-recover counters
watch -n1 "cat /sys/bus/pci/devices/$gpu/aorus_lever_m_*"
```

**Remediations:**
1. **Check for periodic recovery cycles** — if [DIAG] events fire on a
   regular interval (e.g., 17s), some service is bouncing the GPU.
   See `feedback_avoid_nvidia_smi_for_state_checks.md` for a known
   cause (nvidia-smi polling)
2. **Check for thermal events** — sustained high temp triggers fall-back
3. **Verify Gen3 cap is sustained** — bridge `LnkSta` should stay at
   Gen3 throughout workload, not drop to Gen1
4. **Test with workload at lower intensity** — narrows whether it's
   bandwidth-saturation vs corrupted-config issue

---

## 7. Known baselines (reference values)

These are validated values for our specific setup; use as ballpark
targets when validating similar hardware.

### Hardware: NUC 15 Pro+ (Intel Meteor Lake-P) + AORUS RTX 5090 AI Box (TB4)

| Metric | Expected | Source |
|---|---|---|
| TB protocol | TB4 / USB4 v1, 40 Gb/s × 2 lanes per direction | `boltctl info` |
| Internal eGPU PCIe (capped) | Gen3 ×4 effective | LnkSta on bridge after cap |
| nvbandwidth H2D | 2.7-2.9 GB/s | TB4-saturated |
| nvbandwidth D2H | 3.2-3.4 GB/s | TB4-saturated |
| nvbandwidth bidirectional | 2.4-2.6 GB/s | TB4-saturated |
| Cold-load TTFT (llama3.1:8b, 9.4 GiB) | ~3-4s pure PCIe + ~4-5s filesystem/parse | Composite |
| llama3.1:8b decode (steady-state) | ~220 tok/s | Windows-equivalent |
| GSP_LOCKDOWN_NOTICE (healthy) | 0 | journalctl |
| AER Cor on GPU at probe-end (with UncMaskClear) | 0 (or stale 0x2000 if mask present) | [DIAG] telemetry |
| AER Cor on bridge at probe-end | 0 (with proper cap; 0x1 indicates Receiver Errors) | [DIAG] telemetry |
| GPU idle temp (room temp ambient) | ~40-50°C | nvidia-smi |
| GPU idle power | ~20-25W | nvidia-smi |

### Hardware: generic TB4 host + any TB4-class eGPU

| Metric | Expected range |
|---|---|
| nvbandwidth H2D | 2.5-3.1 GB/s |
| nvbandwidth D2H | 2.8-3.4 GB/s |
| Internal eGPU link cap target | Gen3 ×4 |

### Hardware: TB5 host + TB5-class eGPU

| Metric | Expected range |
|---|---|
| nvbandwidth H2D (sym mode) | 4-6 GB/s |
| nvbandwidth H2D (async mode) | up to 8 GB/s unidirectional |
| Internal eGPU link cap target | Gen3 ×4 sym, Gen4 ×4 async |

---

## 8. Cross-platform comparison methodology

When you suspect a Linux-specific issue, the gold standard is
side-by-side Windows comparison on identical hardware.

### 8.1 Linux capture

```bash
sudo /root/aorus-5090-egpu/tools/state-capture/state-capture.sh
# Plus:
nvbandwidth -t 0 > linux-bw.txt
nvbandwidth -t 1 >> linux-bw.txt
journalctl -k -b 0 | grep -E "thunderbolt|nvidia|GSP" > linux-events.txt
```

### 8.2 Windows capture (manual / parallel)

```powershell
# In PowerShell, admin
nvidia-smi.exe --query-gpu=name,pcie.link.gen.current,pcie.link.gen.max,pcie.link.width.current,pcie.link.width.max --format=csv
Get-PnpDevice -Class Display | Where-Object { $_.FriendlyName -match "RTX" } | Format-List *
Get-PnpDeviceProperty -InstanceId (Get-PnpDevice -Class Display | Where-Object { $_.FriendlyName -match "RTX" }).InstanceId | Format-Table KeyName, Data
```

Plus HWinfo64: navigate to **Bus → PCI Express → [GPU device]**;
screenshot the link state + AER counters.

If you can run nvbandwidth on Windows (yes, it builds — same source
tree, MSVC + cmake), do so for direct comparison.

### 8.3 Comparison decisions

| Linux result | Windows result | Conclusion |
|---|---|---|
| Fails | Works | Linux-specific bug — driver, kernel, configuration. NOT hardware. |
| Works | Works | Both fine, just validate the specific failure scenario |
| Fails | Fails | True hardware issue (rare) — check cable, enclosure, GPU |
| Works | Fails | Unusual; may be Windows driver issue (we don't usually debug this side) |

### 8.4 Reference: this project's Linux↔Windows comparison

Our forensic dossier on this hardware (May 2026):
- Both ports A and B work on Windows (RTX 5090, llama 8B, 220+ tok/s)
- Port B works on Linux with our stack
- **Port A fails on Linux** with same stack → Linux-specific bug
  (kernel TB driver per-domain handling; investigation in
  `reliability-hypothesis-ledger.md` H17)

---

## 9. Investigation methodology (when nothing fits)

When you have an unusual TB-eGPU failure not covered by § 6:

### 9.1 Establish reproducibility

- Can you reproduce the failure cold-cold-boot every time? Or intermittent?
- Same failure on multiple boots? Snapshot environment (cmdline, kernel,
  driver versions) — see `tools/state-capture/state-capture.sh`
- Number of cold-cold-boots needed to confirm the pattern (n≥3 standard
  per `feedback_reliability_methodology.md`)

### 9.2 Capture the full state at failure

```bash
# Full journal of failed boot
journalctl -k -b 0 > failed-boot-dmesg.txt

# Full forensic dossier
sudo /root/aorus-5090-egpu/tools/state-capture/state-capture.sh

# Patched driver telemetry (if available)
journalctl -k -b 0 | grep '\[DIAG\]' > failed-boot-diag.txt
journalctl -k -b 0 | grep '\[DIAG-AER\]' > failed-boot-diag-aer.txt

# AER state on all bridges in the chain
for bdf in $(lspci -t | grep -oE '[0-9a-f]+:[0-9a-f]+\.[0-9]'); do
    echo "=== $bdf ==="
    lspci -vv -s "$bdf" | grep -A30 "Advanced Error Reporting"
done > failed-boot-aer.txt
```

Archive everything to `archive/<failure-name>-<date>/`.

### 9.3 Discriminate the failure layer

For each "axis", isolate by changing only that axis:

| Axis | Test |
|---|---|
| OS | Boot Windows on same hardware → does it fail? |
| Kernel | Boot older/newer kernel → does it shift the failure? |
| Cable | Try different TB cable → does it change anything? |
| Port | Try different host TB port → does it change? |
| Driver | Stock vs patched → diff the behavior |
| Cmdline | Boot with minimal cmdline → does failure persist? |

The axis that changes the failure pattern is the layer to investigate.

### 9.4 Don't assume hardware is broken

Per memory `feedback_dont_conflate_stack_failure_with_hardware_broken.md`:
"our Linux fails" ≠ "hardware faulty". Always validate hardware-broken
claims by demonstrating failure under DIFFERENT software (other OS or
other driver) on the SAME hardware.

### 9.5 Don't trust lspci/kernel for bandwidth claims

Per memory `feedback_lspci_lnkcap_tb_virtual.md`: TB controllers
virtualize PCIe registers. The kernel "X Gb/s available bandwidth"
log is reading those virtualized values. Always MEASURE actual
throughput with nvbandwidth.

### 9.6 Don't file upstream prematurely

Per memory `feedback_no_premature_upstream_filing.md`: only file
upstream bug reports when you have a complete, tested, working fix
in hand. The workflow is:

1. Forensic capture (build the methodology if needed)
2. Source code analysis
3. Hypothesis formation
4. Experimentation
5. Write fix
6. Test fix (n≥3 across relevant scenarios)
7. **Then** file upstream with patch + evidence

This applies to Linux kernel, NVIDIA driver, vendor firmware, etc.

---

## 10. Reference appendix

### 10.1 Detailed docs (deep dives)

| Topic | Doc |
|---|---|
| TB-eGPU PCIe topology + diagram | `tb4-pcie-topology.md` |
| Why downstream cap is needed (architectural) | `tb-pcie-cap-architecture.md` |
| TB/boltctl flag audit results | `tb-flags-audit.md` |
| TB domain forensics tool usage | `state-capture-methodology.md` |
| nvbandwidth methodology | `cuda-bandwidth-methodology.md` |
| Reliability methodology | `feedback_reliability_methodology.md` (memory) |
| Reliability hypothesis ledger | `reliability-hypothesis-ledger.md` |
| Lever catalog (driver work) | `lever-catalog.md` |
| Service retirement roadmap | `service-retirement-roadmap.md` |
| H17.G3 (Gen3 cap) investigation | `h17-g3-gen3-investigation-2026-05-07.md` |
| H18 (TB tunnel Gen1) investigation | `tb4-tunnel-gen1-investigation.md` (closed: falsified) |

### 10.2 Memory entries (cross-session rules)

| Topic | File |
|---|---|
| nvidia-smi triggers wedge — use sysfs | `feedback_avoid_nvidia_smi_for_state_checks.md` |
| lspci LnkCap virtual on TB | `feedback_lspci_lnkcap_tb_virtual.md` |
| TB cap belongs in TB driver | `feedback_tb_pcie_cap_architecture.md` |
| Don't conflate stack failure with hardware broken | `feedback_dont_conflate_stack_failure_with_hardware_broken.md` |
| Don't file upstream prematurely | `feedback_no_premature_upstream_filing.md` |
| NUC 15 Pro+ has no BIOS options | `feedback_no_bios_options_nuc15.md` |
| Reliability methodology | `feedback_reliability_methodology.md` |

### 10.3 Glossary

| Term | Meaning |
|---|---|
| **NHI** | Native Host Interface — the PCI device that handles TB protocol on the host |
| **TB router** | A node in the TB fabric (host has one per NHI; eGPU has one or more) |
| **TB tunnel** | An encapsulated stream over TB carrying a specific protocol (PCIe, DP, USB) |
| **DROM** | Device ROM — TB device's firmware metadata blob |
| **GSP** | GPU System Processor — Blackwell's onboard firmware-execution CPU |
| **WPR2** | NVIDIA GPU's Write-Protected Region 2 — a memory region GSP firmware tracks |
| **LnkCtl2** | PCIe Express Capability register at offset 0x30; controls Target Link Speed |
| **LnkSta** | PCIe Express Capability register at offset 0x12; reports current link state |
| **AER** | Advanced Error Reporting — PCIe optional capability for error logging |
| **Cor / Unc** | Correctable / Uncorrectable error class in AER |
| **ECRC** | End-to-end CRC on TLPs (optional PCIe feature) |
| **ASPM** | Active State Power Management — PCIe link low-power states |
| **LBMS / LABS** | Link Bandwidth Management Status / Link Autonomous Bandwidth Status — bits in LnkSta indicating bandwidth changes |
| **CLx** | TB low-power link states (analogous to ASPM but for TB) |
| **rmInit** | NVIDIA driver's Resource Manager init phase — where GSP boot happens |

### 10.4 Useful command reference

```bash
# Find GPU BDF (no /dev access)
gpu_bdf=$(for d in /sys/bus/pci/devices/*; do
    [[ "$(<$d/vendor 2>/dev/null)" == "0x10de" && \
       "$(<$d/device 2>/dev/null)" == "0x2b85" ]] && basename $d && break
done)

# Find GPU's parent bridge
br_bdf=$(basename "$(dirname "$(readlink -f /sys/bus/pci/devices/$gpu_bdf)")")

# Read LnkCtl2 (Target Link Speed + bits)
setpci -s "$br_bdf" CAP_EXP+0x30.W

# Read LnkSta (current Speed/Width bits)
setpci -s "$br_bdf" CAP_EXP+0x12.W

# Read AER Cor / Unc (extended cap)
aer_pos=$(setpci -s "$br_bdf" ECAP0001.L 2>/dev/null | head)  # ECAP_AER ID
# Standard offsets: COR_STATUS=0x10, UNC_STATUS=0x04
setpci -s "$br_bdf" 0x110.L  # if AER cap is at offset 0x100

# All TB-related kernel events
journalctl -k -b 0 | grep -iE "thunderbolt|TBT|tunnel|router|retimer"

# All bolt activity
journalctl -u bolt.service -b 0

# Monitor TB events live
udevadm monitor --subsystem-match=thunderbolt
```

### 10.5 Hardware-agnostic principles

These apply regardless of TB version, eGPU brand, or Linux distribution:

1. **TB host root port lspci is virtual** — measure bandwidth, don't read it
2. **Cap downstream PCIe to match TB tunnel capacity** — prevents rate
   mismatch / GSP_LOCKDOWN class of bugs
3. **TB tunnel needs settle time** — give it 5-10s after device auth
   before driver init
4. **Per-domain init may be asymmetric** — kernel TB driver may
   handle multiple TB controllers in different orders
5. **Forensic dossier > anecdote** — capture machine-readable state
   with `state-capture.sh`, not screenshots
6. **Cross-OS validation isolates layer** — Windows working on same
   hardware definitively localizes failure to Linux/driver

---

## Document maintenance

This is a living document. Update sections when:
- New failure modes are discovered → add to § 6
- New baselines are measured → update § 7
- New tools are built → add to § 4
- New investigation patterns prove useful → add to § 9

Last updated: 2026-05-08.
Authoritative source: `aorus-5090-egpu/docs/thunderbolt-testing.md`.
Questions / corrections: file in this repo or extend with a PR-style commit.
