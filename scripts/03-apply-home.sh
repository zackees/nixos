#!/usr/bin/env bash
# ── Restores per-user state that NixOS does not manage ──
#
# Run as niteris, not root, on a machine whose system config is already
# active: from 02-install.sh during a restore, where this is step 5 of
# RESTORE.md, or already running, in which case nothing needed applying.
# Idempotent: safe to re-run.
#
# What NixOS/home-manager already own, and this script therefore skips:
#   - every package, font, alias and environment variable  (configuration.nix)
#   - the Plasma panel                                     (plasma-manager)
# Everything below is state those two cannot reach.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BACKUP="$HOME/.config-backup-$(date +%Y%m%d-%H%M%S)"

say() { printf '\n== %s\n' "$1"; }

# Move an existing real file out of the way before we replace it, so a
# re-run on a live machine never silently destroys newer local changes.
keep() {
  local dest="$1"
  if [ -e "$dest" ] && [ ! -L "$dest" ]; then
    mkdir -p "$BACKUP/$(dirname "${dest#"$HOME"/}")"
    cp -a "$dest" "$BACKUP/${dest#"$HOME"/}"
  fi
}

say "shell"
for f in bashrc bash_profile; do
  keep "$HOME/.$f"; cp "$REPO/home/bash/$f" "$HOME/.$f"
done

say "dotfiles checkout + kitty symlinks"
# kitty.conf points at absolute paths under ~/dotfiles, so the files live
# there and ~/.config/kitty holds symlinks -- matching the original setup.
mkdir -p "$HOME/dotfiles/kitty" "$HOME/.config/kitty"
cp "$REPO"/home/kitty/* "$HOME/dotfiles/kitty/"
for f in kitty.conf tab_bar.py keys.py paste.py; do
  ln -sfn "$HOME/dotfiles/kitty/$f" "$HOME/.config/kitty/$f"
done

say "voxtype dictation"
mkdir -p "$HOME/.config/voxtype" "$HOME/.local/share/applications"
keep "$HOME/.config/voxtype/config.toml"
cp "$REPO/home/voxtype/config.toml" "$HOME/.config/voxtype/config.toml"
# Meta+H is NOT bound to this entry any more -- push-to-talk needs a key
# release event, which KGlobalAccel does not have, so the hotkey moved into
# voxtype's own evdev reader (see [hotkey] in config.toml). The entry stays
# only as a menu/KRunner way to toggle dictation without the hotkey.
cp "$REPO/home/applications/voxtype-toggle.desktop" "$HOME/.local/share/applications/"

# Models are not in the repo: ggml-base.en.bin is 141 MB and the VAD model
# comes from HuggingFace. Without them voxtype starts fine and then fails at
# the first transcription, which is a confusing way to find out. Both
# commands are no-ops once the file is on disk.
if command -v voxtype >/dev/null 2>&1; then
  voxtype setup --download --model base.en --no-post-install
  voxtype setup vad
fi

say "KDE / Plasma user state"
# KDE rewrites these files at runtime, so they are captured rather than
# generated. Restore them with Plasma STOPPED (a TTY, or before first login);
# a running plasmashell holds its own copy in memory and will overwrite them
# on exit.
if pgrep -x plasmashell >/dev/null 2>&1; then
  cat <<'WARN'

  plasmashell is running. KDE will overwrite these files when it exits, so
  the restore would not stick. Either:
    - log out, switch to a TTY (ctrl+alt+F3), and re-run this script, or
    - re-run with KDE_FORCE=1 and log out immediately afterwards.

WARN
  [ "${KDE_FORCE:-0}" = 1 ] || { echo "skipping KDE state"; SKIP_KDE=1; }
fi

if [ "${SKIP_KDE:-0}" != 1 ]; then
  mkdir -p "$HOME/.config/gtk-3.0" "$HOME/.config/gtk-4.0"
  for f in "$REPO"/home/kde/*; do
    [ -f "$f" ] || continue
    n="$(basename "$f")"
    [ "$n" = dot-gtkrc-2.0 ] && continue
    keep "$HOME/.config/$n"; cp "$f" "$HOME/.config/$n"
  done
  cp "$REPO"/home/kde/gtk-3.0/* "$HOME/.config/gtk-3.0/"
  cp "$REPO"/home/kde/gtk-4.0/* "$HOME/.config/gtk-4.0/"
  keep "$HOME/.gtkrc-2.0"; cp "$REPO/home/kde/dot-gtkrc-2.0" "$HOME/.gtkrc-2.0"
fi

say "user-level CLI tools"
# uv itself comes from the nix profile, not configuration.nix, because the
# pinned nixpkgs lags behind and these tools track PyPI.
#
# nixpkgs-unstable is named in full rather than written `nixpkgs#uv`. Since
# the flake migration the system registry maps the bare `nixpkgs` id to THIS
# repo's locked nixpkgs, so `nixpkgs#uv` would quietly install the pinned
# 26.05 uv -- the exact outcome this profile install exists to avoid. Naming
# the URL depends on no registry at all.
#
# Test for the profile copy specifically rather than `command -v uv`: anything
# that puts uv on PATH -- a systemPackages entry added in good faith, a stray
# shim -- satisfies a PATH test, skips this install, and silently leaves the
# machine on whatever older uv it found. That has happened once already.
if [ ! -x "$HOME/.nix-profile/bin/uv" ]; then
  nix profile add "https://channels.nixos.org/nixpkgs-unstable/nixexprs.tar.xz#uv"
fi
export PATH="$HOME/.local/bin:$PATH"
uv tool install --force clud
uv tool install --force soldr

say "claude + clud settings"
mkdir -p "$HOME/.claude" "$HOME/.clud" "$HOME/.config/gh"
keep "$HOME/.claude/settings.json"
cp "$REPO/home/tools/claude-settings.json" "$HOME/.claude/settings.json"
keep "$HOME/.clud/settings.json"
cp "$REPO/home/tools/clud-settings.json" "$HOME/.clud/settings.json"
keep "$HOME/.config/gh/config.yml"
cp "$REPO/home/tools/gh-config.yml" "$HOME/.config/gh/config.yml"

[ -d "$BACKUP" ] && echo && echo "replaced files backed up under $BACKUP"

cat <<'DONE'

== remaining, and interactive by nature -- see docs/manual-state.md
  gh auth login                 GitHub token (kwallet-backed; not in this repo)
  claude                        prompts for Anthropic sign-in on first run
  log out and back in           picks up the ydotool group and Meta+H

DONE
