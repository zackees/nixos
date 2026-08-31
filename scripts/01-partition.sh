#!/usr/bin/env bash
# ── DESTRUCTIVE: wipes the target disk and lays down this machine's layout ──
#
# Run from the NixOS installer ISO, as root, BEFORE 02-install.sh.
# Skip this entirely if the disk is already partitioned and you only want to
# reinstall the OS onto the existing root filesystem.
#
# The layout reproduced here is the one captured in docs/hardware.md:
#   nvme0n1p1   2G    vfat   -> /boot   (EFI system partition)
#   nvme0n1p2   rest  ext4   -> /       (label "root")
#
# Filesystem UUIDs are forced to the originals so the committed
# hardware-configuration.nix matches without regeneration.
set -euo pipefail

DISK="${1:-}"
if [ -z "$DISK" ] || [ ! -b "$DISK" ]; then
  echo "usage: $0 /dev/nvme0n1" >&2
  echo >&2
  echo "Available block devices:" >&2
  lsblk -dpo NAME,SIZE,MODEL >&2
  exit 2
fi

BOOT_UUID="866F-1102"                              # vfat, 8.3 hex form
ROOT_UUID="ea0caf0b-ae20-413c-bb57-22a9bdc5719e"   # ext4

cat <<WARN

  ABOUT TO ERASE $DISK  --  every partition and all data on it.

WARN
lsblk -o NAME,SIZE,FSTYPE,LABEL,MOUNTPOINT "$DISK"
echo
read -rp "Type ERASE to continue: " confirm
[ "$confirm" = "ERASE" ] || { echo "aborted"; exit 1; }

wipefs -a "$DISK"
parted -s "$DISK" -- mklabel gpt
parted -s "$DISK" -- mkpart ESP fat32 1MiB 2GiB
parted -s "$DISK" -- set 1 esp on
parted -s "$DISK" -- mkpart root ext4 2GiB 100%

# NVMe partitions are p1/p2; SATA are 1/2.
case "$DISK" in
  *nvme*|*mmcblk*) P1="${DISK}p1"; P2="${DISK}p2" ;;
  *)               P1="${DISK}1";  P2="${DISK}2"  ;;
esac
udevadm settle

mkfs.fat -F 32 -n BOOT -i "${BOOT_UUID/-/}" "$P1"
mkfs.ext4 -L root -U "$ROOT_UUID" "$P2"

mount "$P2" /mnt
mkdir -p /mnt/boot
mount -o fmask=0077,dmask=0077 "$P1" /mnt/boot

echo
echo "Partitioned and mounted. Next: scripts/02-install.sh"
lsblk -o NAME,SIZE,FSTYPE,LABEL,UUID,MOUNTPOINT "$DISK"
