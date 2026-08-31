#!/usr/bin/env bash
# ── Applies system/ to a RUNNING NixOS machine ──
#
# Copies this repo's system configuration into /etc/nixos and rebuilds.
# Use this after editing anything under system/.
#
# This is the everyday path, not a restore step. RESTORE.md never calls it:
# a fresh machine gets its system from 02-install.sh (step 4), which runs
# nixos-install against system/ directly and then reboots.
#
# --build   evaluate and build only; do not activate (safe dry run)
# --boot    activate on next boot rather than immediately
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ACTION=switch
case "${1:-}" in
  --build) ACTION=build ;;
  --boot)  ACTION=boot ;;
  "")      ;;
  *)       echo "usage: $0 [--build|--boot]" >&2; exit 2 ;;
esac

# The config pins nixpkgs 26.05 by channel, not by flake, so the channel has
# to be right or the build resolves against whatever else is subscribed.
sudo nix-channel --list | grep -q 'nixos-26.05' || {
  echo "adding the nixos-26.05 channel"
  sudo nix-channel --add https://channels.nixos.org/nixos-26.05 nixos
  sudo nix-channel --update
}

sudo mkdir -p /etc/nixos
sudo cp "$REPO"/system/configuration.nix \
        "$REPO"/system/hardware-configuration.nix \
        /etc/nixos/

sudo nixos-rebuild "$ACTION"

if [ "$ACTION" = switch ]; then
  echo
  echo "Rebuilt. Group membership (ydotool) and KDE global shortcuts need a"
  echo "fresh session -- log out and back in if this was a first apply."
fi
