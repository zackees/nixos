#!/usr/bin/env bash
# ── Pulls the machine's live state back into this repo ──
#
# The inverse of 03/04-apply. Run it after changing something by hand (a KDE
# setting, the system config) so the repo stops drifting from
# reality, then review `git diff` and commit.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO"

sudo cat /etc/nixos/configuration.nix > system/configuration.nix
sudo cat /etc/nixos/hardware-configuration.nix > system/hardware-configuration.nix

# Guard: /etc/nixos may carry a local secrets.nix that this repo must not.
# Strip the import if one has crept in, and never copy the file itself.
if grep -q 'secrets\.nix' system/configuration.nix; then
  sed -i '/secrets\.nix/d' system/configuration.nix
  echo "note: dropped a ./secrets.nix import -- credentials stay out of this repo"
fi

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

cp ~/.clud/settings.json home/tools/clud-settings.json
cp ~/.claude/settings.json home/tools/claude-settings.json
cp ~/.config/gh/config.yml home/tools/gh-config.yml

# hardware inventory, regenerated so docs/hardware.md never goes stale
"$REPO/scripts/gen-hardware-doc.sh" > docs/hardware.md

echo
git status --short
echo
echo "Review the diff above, then commit."
