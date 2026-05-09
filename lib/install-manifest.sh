# lib/install-manifest.sh — single source of truth for the install surface.
#
# Sourced by apply.sh, status.sh, remove.sh so all three stay in sync. Adding
# or removing a file in the project is a single edit here. Each script then
# iterates the relevant arrays for its operation (install / check / remove).
#
# Conventions:
#   - Arrays hold BASENAMES; the destination prefix is determined by category
#     (binaries → /usr/local/sbin/, services → /etc/systemd/system/, etc.).
#   - Drop-ins and templates use SUBPATHS where directory structure matters.
#   - LEGACY_* are pre-rename names (aorus-5090-*, aorus-lever-m-*) consulted
#     by apply.sh's migration step and remove.sh's defensive cleanup. Never
#     installed; only ever stopped + removed.
#
# Source as: source "$(dirname "$0")/lib/install-manifest.sh"
# Or: source /path/to/repo/lib/install-manifest.sh

# ---------------------------------------------------------------- BINARIES --
# All scripts in repo's usr/local/sbin/. Mode 0755. Installed to /usr/local/sbin/.
EGPU_BINARIES=(
    aorus-egpu-detect-config
    aorus-egpu-compute-load-nvidia
    aorus-egpu-disable-audio
    aorus-egpu-status
    aorus-egpu-bridge-link-cap
    aorus-egpu-wpr2-recovery
    aorus-egpu-observability-watchdog
    aorus-egpu-uvm-keepalive
    aorus-egpu-link-monitor
    aorus-egpu-pcie-tune
    aorus-egpu-lever-m
    aorus-egpu-lever-m-killswitch-restore
    aorus-egpu-lever-m-phase5-snapshot
)

# ---------------------------------------------------------- SHARED LIBRARY --
# Sourced by binaries above. Mode 0644. Installed to /usr/local/lib/aorus-egpu/.
EGPU_LIBS=(
    common.sh
)

# --------------------------------------------------------------- SERVICES --
# Active services — apply.sh installs the unit file AND `systemctl enable`s it.
# Mode 0644. Installed to /etc/systemd/system/.
EGPU_SERVICES_ACTIVE=(
    aorus-egpu-compute-load-nvidia.service
    aorus-egpu-bridge-link-cap.service
    aorus-egpu-wpr2-recovery.service
    aorus-egpu-observability-watchdog.service
    aorus-egpu-lever-m-phase5-snapshot.service
)

# Retired services — apply.sh installs the unit file as historical archive
# but leaves it `systemctl disable`d. Resurrection is a single
# `systemctl enable --now <service>`. See docs/service-retirement-roadmap.md.
EGPU_SERVICES_RETIRED=(
    aorus-egpu-uvm-keepalive.service
    aorus-egpu-link-monitor.service
    aorus-egpu-pcie-tune.service
)

# Drop-ins — paths relative to /etc/systemd/system/.
EGPU_DROP_INS=(
    nvidia-persistenced.service.d/aorus-egpu.conf
    ollama.service.d/aorus-egpu.conf
)

# ------------------------------------------------------------- UDEV RULES --
# Static — copied verbatim. Installed to /etc/udev/rules.d/.
EGPU_UDEV_STATIC=(
    82-aorus-egpu-nvidia-permissions.rules
    82-aorus-egpu-lever-m-killswitch.rules
)

# Templated — apply.sh sources /etc/aorus-egpu/config.env and renders
# .template into the corresponding .rules file at /etc/udev/rules.d/.
# Array values are the OUTPUT basenames (without .template suffix).
EGPU_UDEV_TEMPLATED=(
    79-aorus-egpu-no-autoload.rules
    81-aorus-egpu-compute-power.rules
)

# ------------------------------------------------------- MODPROBE CONFIGS --
# Mode 0644. Installed to /etc/modprobe.d/.
EGPU_MODPROBE_CONFS=(
    aorus-egpu-compute-only.conf
    aorus-egpu-lever-m.conf
    blacklist-nouveau.conf
    nvidia-power-management.conf
    nvidia.conf
)

# --------------------------------------------------------- SYSCTL CONFIGS --
# Mode 0644. Installed to /etc/sysctl.d/.
EGPU_SYSCTL_CONFS=(
    aorus-egpu-watchdog.conf
)

# ----------------------------------------------------- RUNTIME DIRECTORIES --
# Created by apply.sh / helpers at runtime. Removed by remove.sh.
EGPU_RUNTIME_DIRS=(
    /etc/aorus-egpu
    /var/lib/aorus-egpu
    /usr/local/lib/aorus-egpu
)

# =================================================================
# LEGACY (pre-rename) names — for backward-compat cleanup ONLY.
# Q3 Tier 2 (2026-05-09): aorus-5090-* / aorus-lever-m-* → aorus-egpu-*.
# These arrays exist so apply.sh's migration step + remove.sh can clean
# up old installs. They are NEVER targets of installation.
# =================================================================

LEGACY_BINARIES=(
    aorus-5090-bridge-link-cap
    aorus-5090-compute-load-nvidia
    aorus-5090-disable-audio
    aorus-5090-link-monitor
    aorus-5090-pcie-tune
    aorus-5090-status
    aorus-5090-uvm-keepalive
    aorus-5090-wpr2-recovery
    aorus-lever-m
    aorus-lever-m-killswitch-restore
    aorus-lever-m-phase5-snapshot
    egpu-detect-config
)

LEGACY_SERVICES=(
    aorus-5090-bridge-link-cap.service
    aorus-5090-compute-load-nvidia.service
    aorus-5090-link-monitor.service
    aorus-5090-pcie-tune.service
    aorus-5090-uvm-keepalive.service
    aorus-5090-wpr2-recovery.service
    aorus-lever-m-phase5-snapshot.service
)

LEGACY_UDEV=(
    79-aorus-5090-no-autoload.rules
    81-aorus-5090-compute-power.rules
    82-aorus-5090-nvidia-permissions.rules
)

LEGACY_MODPROBE=(
    aorus-5090-compute-only.conf
    aorus-lever-m.conf
)

LEGACY_SYSCTL=(
    aorus-5090-watchdog.conf
)

# Pre-rename vestigial markers (older than Q3 Tier 2 — these came from the
# original Fedora 42 / RPMFusion / collect-pci-layout era). apply.sh + remove.sh
# remove these defensively if they exist.
LEGACY_VESTIGIAL_FILES=(
    /etc/aorus-5090-allow-compute-load
    /etc/aorus-5090-collect-pci-layout
    /etc/systemd/system/aorus-5090-collect-pci-layout.service
    /usr/local/sbin/aorus-5090-collect-pci-layout
    /usr/local/bin/aorus-5090-collect-pci-layout
)
LEGACY_VESTIGIAL_SERVICES=(
    aorus-5090-collect-pci-layout.service
)

# -------------------------------------------------------- HELPER FUNCTIONS --
# Shared accessors that compute install paths from a basename + category.
# Sourced helpers can use these for consistency without each script open-coding
# the prefix.

egpu_path_binary()   { printf '/usr/local/sbin/%s\n' "$1"; }
egpu_path_lib()      { printf '/usr/local/lib/aorus-egpu/%s\n' "$1"; }
egpu_path_service()  { printf '/etc/systemd/system/%s\n' "$1"; }
egpu_path_dropin()   { printf '/etc/systemd/system/%s\n' "$1"; }
egpu_path_udev()     { printf '/etc/udev/rules.d/%s\n' "$1"; }
egpu_path_modprobe() { printf '/etc/modprobe.d/%s\n' "$1"; }
egpu_path_sysctl()   { printf '/etc/sysctl.d/%s\n' "$1"; }
