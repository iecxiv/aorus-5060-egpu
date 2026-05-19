# Sourced by egpu-stack helpers. Do not run directly.
#
# Provides EGPU_* variables from /etc/aorus-egpu/config.env (written
# by aorus-egpu-detect-config). Falls back to project-default values for
# THIS hardware (NUC 15 Pro+ + AORUS RTX 5060 Ti 16GB) if the config file is
# missing — on first install or before aorus-egpu-detect-config has run.
#
# Variables exported:
#   EGPU_VENDOR_ID         (NVIDIA = 0x10de)
#   EGPU_DEVICE_ID         (RTX 5060 Ti = 0x2d04; varies by GPU model)
#   EGPU_BDF               (e.g. 0000:04:00.0)
#   EGPU_AUDIO_DEVICE_ID   (HDMI audio function device ID)
#   EGPU_AUDIO_BDF         (e.g. 0000:04:00.1)
#   EGPU_BRIDGE_BDF        (parent PCIe bridge of the GPU)
#   TB_HOST_VENDOR_DEVICES (bash array of "vendor:device" pairs for the upstream TB chain)
#   LINK_CAP_TARGET_SPEED  (LnkCtl2 target speed bits, default 0x3 = Gen3)
#   LINK_CAP_HW_AUTO_DISABLE (LnkCtl2 bit 5, default 1 = autonomous shifts disabled)

EGPU_CONFIG="${EGPU_CONFIG:-/etc/aorus-egpu/config.env}"

if [[ -r "$EGPU_CONFIG" ]]; then
    # shellcheck disable=SC1090
    source "$EGPU_CONFIG"
else
    # Fallback for first install / pre-detection. Run aorus-egpu-detect-config
    # to refresh once the system is up.
    EGPU_VENDOR_ID="0x10de"
    EGPU_DEVICE_ID="0x2d04"
    EGPU_BDF="0000:04:00.0"
    EGPU_AUDIO_DEVICE_ID="0x22eb"
    EGPU_AUDIO_BDF="0000:04:00.1"
    EGPU_BRIDGE_BDF="0000:03:00.0"
    TB_HOST_VENDOR_DEVICES=("0x8086:0x7ec4" "0x8086:0x5786")
    LINK_CAP_TARGET_SPEED="0x3"
    LINK_CAP_HW_AUTO_DISABLE="1"
fi
