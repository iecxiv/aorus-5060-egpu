#!/usr/bin/env bash
#
# build-patched-driver.sh — Lever I (and future J-2) build harness.
#
# Builds the NVIDIA open kernel modules from the cloned source at
# /root/nvidia-open-src with our patch series applied, then installs
# the resulting nvidia.ko (xz-compressed) into the same location the
# dnf-managed kmod-nvidia-open-dkms uses, after backing up the stock
# module to a sibling file.
#
# Idempotent: safe to re-run. Detects already-applied patches via
# `git apply --check`.
#
# DOES NOT REBOOT. After this script finishes, run:
#     sudo /usr/local/sbin/aorus-5090-status
#     sudo reboot
# and then verify the patched build is loaded:
#     modinfo nvidia | grep -E '^(version|srcversion):'
#     dmesg | grep -i 'AORUS Lever'
#
# Rollback:
#     sudo cp /lib/modules/$(uname -r)/extra/nvidia.ko.xz.dnf-stock-* \
#             /lib/modules/$(uname -r)/extra/nvidia.ko.xz
#     sudo depmod -a
#     sudo reboot
#
# Maintenance:
# - On `dnf update kmod-nvidia-open-dkms` or kernel upgrade, the dnf-
#   managed module overwrites our patched build. Re-run this script.
# - This script does NOT integrate with DKMS auto-rebuild. That's a
#   separate followup if/when Lever I proves itself.

set -euo pipefail

if [[ "$EUID" -ne 0 ]]; then
    echo "build-patched-driver.sh must be run as root" >&2
    exit 1
fi

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
SRC_DIR="${SRC_DIR:-/root/nvidia-open-src}"
PATCH_DIR="$REPO_ROOT/patches"
KVER="$(uname -r)"
INSTALL_DIR="/lib/modules/$KVER/extra"

green() { printf '\033[32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }
red() { printf '\033[31m%s\033[0m\n' "$*" >&2; }
step() { printf '\n=== %s ===\n' "$*"; }

step "preflight"

[[ -d "$SRC_DIR" ]] || { red "SRC_DIR=$SRC_DIR not found. Clone NVIDIA/open-gpu-kernel-modules first."; exit 1; }
[[ -d "$SRC_DIR/.git" ]] || { red "$SRC_DIR is not a git checkout."; exit 1; }
[[ -d "$PATCH_DIR" ]] || { red "PATCH_DIR=$PATCH_DIR not found."; exit 1; }

# Confirm we're on the expected tag
TAG="$(git -C "$SRC_DIR" describe --tags --exact-match 2>/dev/null || echo unknown)"
if [[ "$TAG" != "595.71.05" ]]; then
    yellow "WARNING: source is at tag '$TAG', expected '595.71.05'."
    yellow "  Patch was authored against 595.71.05. Continuing anyway -- review hunks if conflicts arise."
fi

# Confirm kernel headers available
[[ -d "/lib/modules/$KVER/build" ]] || { red "kernel-headers for $KVER not found at /lib/modules/$KVER/build"; exit 1; }

step "reset source to clean state"

# Discard any in-tree changes (e.g., prior patch applications) so we re-apply cleanly
git -C "$SRC_DIR" checkout -- src kernel-open 2>/dev/null || true

step "apply patch series"

shopt -s nullglob
PATCHES=("$PATCH_DIR"/*.patch)
shopt -u nullglob

if [[ ${#PATCHES[@]} -eq 0 ]]; then
    yellow "No patches found in $PATCH_DIR; building stock source"
else
    for p in "${PATCHES[@]}"; do
        printf '  applying: %s\n' "$(basename "$p")"
        if ! git -C "$SRC_DIR" apply --check "$p" 2>/dev/null; then
            # If it's already applied, --check fails but applying -R --check should pass
            if git -C "$SRC_DIR" apply -R --check "$p" 2>/dev/null; then
                yellow "    already applied; skipping"
                continue
            else
                red "    cannot apply (conflicts with current source)"
                exit 1
            fi
        fi
        git -C "$SRC_DIR" apply "$p"
    done
fi

step "build modules ($KVER, $(nproc) parallel jobs)"

# IGNORE_CC_MISMATCH=1 is sometimes needed when the kernel was built with a
# different gcc minor version than userspace. Harmless if not needed.
make -C "$SRC_DIR" -j"$(nproc)" modules SYSSRC="/lib/modules/$KVER/build" \
    IGNORE_CC_MISMATCH=1 \
    > /tmp/build-patched-driver.log 2>&1 || {
        red "build failed; tail of log follows:"
        tail -40 /tmp/build-patched-driver.log >&2
        exit 1
    }

green "build OK; module artifacts:"
ls -la "$SRC_DIR"/kernel-open/*.ko

step "back up stock modules + install patched"

mkdir -p "$INSTALL_DIR"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"

for ko in "$SRC_DIR"/kernel-open/*.ko; do
    name="$(basename "$ko")"
    dst="$INSTALL_DIR/$name.xz"
    bak="$dst.dnf-stock-$TIMESTAMP"

    if [[ -f "$dst" ]]; then
        cp -a "$dst" "$bak"
        printf '  backed up: %s -> %s\n' "$dst" "$bak"
    fi

    # NVIDIA dnf packaging compresses with xz; match that.
    xz -c -k -- "$ko" > "$dst.tmp"
    mv -f "$dst.tmp" "$dst"
    chmod 0644 "$dst"
    printf '  installed: %s\n' "$dst"
done

step "depmod"

depmod -a "$KVER"

step "summary"

green "Patched modules installed at $INSTALL_DIR"
green "Stock modules backed up with suffix .dnf-stock-$TIMESTAMP"
echo
echo "Next:"
echo "  1. sudo reboot"
echo "  2. After reboot, verify the patched build is loaded:"
echo "       modinfo nvidia | grep -E '^(version|srcversion|filename):'"
echo "       (srcversion should differ from stock '58D233B8E3F4A2973D73151')"
echo "  3. Run lite test and watch for the patch's NV_DBG_ERRORS marker:"
echo "       dmesg | grep -i 'AORUS Lever'"
echo "  4. If a transient was caught, you'll see:"
echo "       AORUS Lever I: PCIe transient cleared after N retries (Nus) - GPU not lost"
echo
echo "Rollback:"
echo "  sudo cp $INSTALL_DIR/nvidia.ko.xz.dnf-stock-$TIMESTAMP $INSTALL_DIR/nvidia.ko.xz"
echo "  sudo depmod -a"
echo "  sudo reboot"
