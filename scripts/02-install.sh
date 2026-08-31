#!/usr/bin/env bash
# ── Installs NixOS from this repo onto /mnt ──
#
# Run from the installer ISO, as root, with the target already partitioned
# and mounted at /mnt (01-partition.sh does that, or mount it yourself).
#
# This installs straight from the flake in this checkout and then prompts for
# the root and niteris passwords -- no credentials are stored in this repo.
# Nothing is copied into /mnt/etc/nixos: flake.lock pins nixpkgs by revision,
# so the installed system is the one this commit describes rather than
# whatever a channel served today. That was the point of issue #3.
#
# It does NOT regenerate hardware-configuration.nix: the committed one already
# describes this machine, and 01-partition.sh restores the UUIDs it names. If
# you are installing onto DIFFERENT hardware or a different disk layout, pass
# --regen-hardware to scan the live machine instead.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REGEN=0
[ "${1:-}" = "--regen-hardware" ] && REGEN=1

mountpoint -q /mnt || { echo "nothing mounted at /mnt -- run 01-partition.sh first" >&2; exit 1; }
mountpoint -q /mnt/boot || { echo "nothing mounted at /mnt/boot" >&2; exit 1; }

if [ "$REGEN" = 1 ]; then
  # Written into the repo, not /mnt/etc/nixos, because the flake builds from
  # this checkout. hardware-configuration.nix is a tracked file, so overwriting
  # it is visible to the flake; a NEW untracked file would not be -- flakes
  # only see what git tracks.
  echo "regenerating hardware-configuration.nix for this machine"
  nixos-generate-config --root /mnt --show-hardware-config \
    > "$REPO"/system/hardware-configuration.nix
fi

# No credentials are stored in this repo, so both account passwords are set
# here, interactively. nixos-install prompts for root's on its way out.
#
# The ISO decides its own nix settings, and an older one may not have flakes
# switched on, so ask for them explicitly rather than depending on the image.
nixos-install --flake "$REPO#nixos" \
  --option extra-experimental-features 'nix-command flakes'

# niteris is created by configuration.nix but has no password until one is
# set, and an account with no password cannot log in at SDDM. Setting it now,
# inside the installed system, means the machine boots straight to a usable
# login instead of needing a console rescue after the first reboot.
echo
echo "Set a password for the niteris account:"
until nixos-enter --root /mnt -c 'passwd niteris'; do
  echo "passwd failed -- try again (ctrl+c to skip and fix it after boot)"
done

cat <<'DONE'

System installed. Now:
  1. reboot into the new system
  2. log in as niteris with the password you just set
  3. clone this repo and run scripts/03-apply-home.sh

DONE
