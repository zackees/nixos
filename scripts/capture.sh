#!/usr/bin/env bash
# ── Pulls the machine's live state back into this repo ──
#
# Run after changing something by hand -- a KDE setting, a display
# arrangement -- so the repo stops drifting from reality. Review `git diff`
# afterwards, then commit.
#
# It deliberately does NOT touch system/. Since the flake migration, system/
# is the only copy that exists: `nixos-rebuild --flake` builds straight from
# this checkout and nothing is written to /etc/nixos, so there is no second
# copy that could be newer and nothing to capture back. The guard that used
# to stand here -- refusing to overwrite system/ with a stale /etc/nixos, and
# its --from-etc escape hatch -- protected against a hazard that no longer
# exists. See issue #3.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO"

case "${1:-}" in
  "")          ;;
  -h|--help)   sed -n '2,6p' "$0"; exit 0 ;;
  *)           echo "usage: $0" >&2; exit 2 ;;
esac

cp ~/.bashrc home/bash/bashrc
cp ~/.bash_profile home/bash/bash_profile
cp ~/dotfiles/kitty/kitty.conf ~/dotfiles/kitty/tab_bar.py \
   ~/dotfiles/kitty/keys.py ~/dotfiles/kitty/paste.py home/kitty/
cp ~/.config/voxtype/config.toml home/voxtype/config.toml
cp ~/.local/share/applications/voxtype-toggle.desktop home/applications/

for f in home/kde/*; do
  n="$(basename "$f")"
  [ -f "$f" ] || continue
  [ "$n" = dot-gtkrc-2.0 ] && { cp ~/.gtkrc-2.0 "$f"; continue; }
  [ -f "$HOME/.config/$n" ] && cp "$HOME/.config/$n" "$f"
done
cp ~/.config/gtk-3.0/* home/kde/gtk-3.0/ 2>/dev/null || true
cp ~/.config/gtk-4.0/* home/kde/gtk-4.0/ 2>/dev/null || true

# The Stream Deck's buttons. Boatswain names the file after the device serial
# and rewrites it whole on save and on quit, so this is captured, never
# generated -- same category as home/kde/. A different deck would land under a
# different name; the glob keeps that from silently capturing nothing.
cp ~/.local/share/CL22K1A01009.json home/streamdeck/ 2>/dev/null || true

cp ~/.clud/settings.json home/tools/clud-settings.json
cp ~/.claude/settings.json home/tools/claude-settings.json
cp ~/.config/gh/config.yml home/tools/gh-config.yml

# hardware inventory, regenerated so docs/hardware.md never goes stale
"$REPO/scripts/gen-hardware-doc.sh" > docs/hardware.md

echo
git status --short
echo
echo "Review the diff above, then commit."
