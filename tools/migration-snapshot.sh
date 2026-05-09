#!/usr/bin/env bash
# Take a read-only btrfs snapshot of the root subvolume for pre-migration
# rollback. Snapshot lives at the top of the btrfs filesystem as a sibling
# to 'root' (next to 'home', 'var/lib/machines').
#
# Usage:
#   sudo /root/aorus-5090-egpu/tools/migration-snapshot.sh [name-suffix]
#
# Default suffix: pre-F43-YYYY-MM-DD-HHMM
#
# After taking the snapshot the script prints the rollback procedure.

set -euo pipefail

if [[ "$EUID" -ne 0 ]]; then
    echo "Must run as root." >&2
    exit 1
fi

suffix="${1:-pre-F43-$(date +%Y-%m-%d-%H%M)}"
target="root_${suffix}"
mp="/mnt/btrfs-toplevel-$$"

# Find the btrfs device
device=$(findmnt -no SOURCE / | sed 's/\[.*\]$//')
if [[ -z "$device" ]]; then
    echo "Could not determine root device from findmnt /" >&2
    exit 1
fi

# Sanity: confirm we're on btrfs and on the 'root' subvol
fstype=$(findmnt -no FSTYPE /)
if [[ "$fstype" != "btrfs" ]]; then
    echo "Root filesystem is $fstype, not btrfs. This script only works for btrfs." >&2
    exit 1
fi

mount_subvol=$(findmnt -no SOURCE / | grep -oE '\[/[^]]*\]' | tr -d '[]/')
if [[ "$mount_subvol" != "root" ]]; then
    echo "WARNING: root mount is from subvol '$mount_subvol', expected 'root'."
    echo "Snapshot target name will still be '$target' but verify it makes sense." >&2
fi

echo "btrfs device: $device"
echo "snapshot target name: $target"
echo

# Mount top-level (subvolid=5 is the FS_TREE root)
mkdir -p "$mp"
mount -o subvolid=5 "$device" "$mp"
trap 'umount "$mp" 2>/dev/null; rmdir "$mp" 2>/dev/null' EXIT

# Sanity: 'root' subvol must exist at top level
if [[ ! -d "$mp/root" ]]; then
    echo "Top-level mount missing 'root' subvolume - layout unexpected" >&2
    exit 1
fi

# Refuse to clobber an existing snapshot
if [[ -e "$mp/$target" ]]; then
    echo "Snapshot already exists: $mp/$target" >&2
    echo "Pick a different suffix or remove the existing one first:" >&2
    echo "  sudo btrfs subvolume delete $mp/$target" >&2
    exit 1
fi

# Take the snapshot (read-only)
btrfs subvolume snapshot -r "$mp/root" "$mp/$target"
echo
echo "=== snapshot created ==="
btrfs subvolume show "$mp/$target" | head -10

# Generate a rollback companion script
recovery_script="/root/aorus-5090-egpu/archive/migration-rollback-${suffix}.sh"
mkdir -p "$(dirname "$recovery_script")"
cat > "$recovery_script" <<EOF
#!/usr/bin/env bash
# Rollback to btrfs snapshot taken $(date -Is): $target
# Run this from a Fedora live USB or rescue console - NOT from the running system.
set -euo pipefail
if [[ "\$EUID" -ne 0 ]]; then echo "must be root" >&2; exit 1; fi

mkdir -p /mnt/btrfs-rb
mount -o subvolid=5 $device /mnt/btrfs-rb

# Save the broken root for forensics
broken="root_broken_\$(date +%Y%m%d-%H%M)"
echo "saving broken root as \$broken"
btrfs subvolume snapshot /mnt/btrfs-rb/root /mnt/btrfs-rb/\$broken

# Replace root with a writable copy of the snapshot
echo "deleting current root and replacing with $target"
btrfs subvolume delete /mnt/btrfs-rb/root
btrfs subvolume snapshot /mnt/btrfs-rb/$target /mnt/btrfs-rb/root

umount /mnt/btrfs-rb
echo "rollback complete - reboot the host"
EOF
chmod 0755 "$recovery_script"

cat <<EOF

=== rollback procedure ===

Companion rollback script written to:
  $recovery_script

To roll back (after a broken upgrade):

  1. Boot from a Fedora live USB or rescue console.
  2. Copy the rollback script onto the live system, or recreate from this output.
  3. Run it as root:

       sudo bash $recovery_script

  4. Reboot - system comes up on the snapshotted state.

The snapshot itself lives at btrfs subvolid path '$target' on $device.
Verify with: sudo btrfs subvolume list /

EOF
