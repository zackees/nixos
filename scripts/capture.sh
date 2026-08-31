#!/usr/bin/env bash
# ── Pulls the machine's live state back into this repo ──
#
# The inverse of 03/04-apply. Run it after changing something by hand (a KDE
# setting, the system config) so the repo stops drifting from
# reality, then review `git diff` and commit.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO"

FROM_ETC=0
case "${1:-}" in
  --from-etc)  FROM_ETC=1 ;;
  "")          ;;
  -h|--help)   sed -n '2,6p' "$0"; exit 0 ;;
  *)           echo "usage: $0 [--from-etc]" >&2; exit 2 ;;
esac

# ── Guard: refuse to capture a stale /etc/nixos over a newer system/ ──
# The copy below overwrites system/configuration.nix wholesale, which is only
# safe when /etc/nixos is the NEWER of the two. It is not after
#
#     nixos-rebuild switch -I nixos-config="$PWD/system/configuration.nix"
#
# which builds and activates straight from the repo and never writes
# /etc/nixos. The machine then runs exactly what system/ says while
# /etc/nixos sits at whatever 03-apply-system.sh last put there -- so
# capturing would overwrite the repo with the older file and produce a commit
# that silently REVERTS the change you just applied and booted. sync.sh runs
# this script before it commits and pushes, so the revert would go straight
# to origin looking like an ordinary sync.
#
# The fix is scripts/03-apply-system.sh: it copies system/ into /etc/nixos
# and rebuilds, after which the two agree and this check passes. --from-etc
# is the escape hatch for the genuine opposite case, where someone edited
# /etc/nixos by hand and wants that pulled back into the repo.
#
# secrets.nix imports are stripped from the captured file further down, so a
# local secrets import is not a real disagreement -- ignore that line here.
etc_side() { sudo cat /etc/nixos/configuration.nix | grep -v 'secrets\.nix'; }
repo_side() { grep -v 'secrets\.nix' system/configuration.nix; }

if [ "$FROM_ETC" != 1 ] && [ -f /etc/nixos/configuration.nix ]; then
  if ! diff -q <(etc_side) <(repo_side) >/dev/null; then
    echo "REFUSING TO CAPTURE -- /etc/nixos/configuration.nix disagrees with system/" >&2
    echo >&2
    { diff -u <(etc_side) <(repo_side) || true; } \
      | sed -n '3,$p' | head -40 | sed 's/^/  /' >&2
    cat >&2 <<'WARN'

  (- is /etc/nixos, + is this repo; truncated to 40 lines)

Capturing would copy /etc/nixos over system/configuration.nix and throw the
+ lines away. If the repo is the newer side -- the usual case, and always so
after a rebuild run with -I nixos-config=... -- apply it first:

    scripts/03-apply-system.sh

If /etc/nixos really is the newer side, pull it in deliberately:

    scripts/capture.sh --from-etc
WARN
    exit 1
  fi
fi

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
