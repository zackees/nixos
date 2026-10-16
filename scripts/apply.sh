#!/usr/bin/env bash
# ── Applies this configuration with the newest docker-vm and soldr ──
#
#     scripts/apply.sh              update pins, build, then switch (sudo)
#     scripts/apply.sh --build      update pins and build only; no activation
#
# Nix needs a hash for every download, so "latest" is a pin refresh that runs
# before the build, not something the build does:
#   1. docker-vm  -> newest commit on main (nix flake update docker-vm)
#   2. soldr      -> newest GitHub release, via docker-vm's scripts/update-soldr,
#                    written to soldr.json (version, url, sha256)
# The build's exit code is checked before anything is activated.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO"

SWITCH=1
case "${1:-}" in
  "") ;;
  --build) SWITCH=0 ;;
  -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
  *) echo "unknown argument: $1" >&2; exit 2 ;;
esac

nix flake update docker-vm
docker_vm_src=$(nix flake archive --json | python3 -c 'import json, sys; print(json.load(sys.stdin)["inputs"]["docker-vm"]["path"])')
bash "$docker_vm_src/scripts/update-soldr" "$REPO/soldr.json"

log=$(mktemp -t nixos-apply.XXXXXX.log)
if ! nixos-rebuild build --flake .#nixos >"$log" 2>&1; then
  tail -40 "$log" >&2
  echo "build failed; nothing activated. Full log: $log" >&2
  exit 1
fi
echo "build ok ($(readlink -f result))"

if [ "$SWITCH" = 1 ]; then
  sudo nixos-rebuild switch --flake .#nixos
fi
