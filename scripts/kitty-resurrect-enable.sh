#!/usr/bin/env bash
# Switch in kitty-resurrect + its watchdog and turn it on, verifying each step.
# Any failure re-masks the service: nothing may be left running unattended.
# See docs/kitty-resurrect-watchdog.md section 5.
set -uo pipefail
cd "$(dirname "$0")/.."
unit=kitty-resurrect
remask() { echo "FAIL: $*; re-masking $unit" >&2
           systemctl --user mask --now "$unit" >/dev/null 2>&1; exit 1; }

log=$(mktemp); trap 'rm -f "$log"' EXIT
# Bound only the password dialog: a timeout around the switch itself could
# kill activation half-way.
timeout 120 sudo -A true || remask "no sudo (nobody at the dialog?)"
sudo nixos-rebuild switch --flake .#nixos >"$log" 2>&1 || { tail -20 "$log"; remask "switch failed"; }
want=$(readlink -f result 2>/dev/null || true)
nixos-rebuild build --flake .#nixos >"$log" 2>&1 || remask "build for verification failed"
[ "$(readlink -f /run/current-system)" = "$(readlink -f result)" ] || remask "current-system is not the new generation"
echo "generation: $(readlink -f /run/current-system) ${want:+(was result: $want)}"

since=$(date +%s)
systemctl --user unmask "$unit" && systemctl --user daemon-reload
# Not `enable`: that links the unit into ~/.config, shadowing every later
# NixOS unit. wantedBy = graphical-session.target already enables it.
systemctl --user start "$unit" || remask "start failed"
sleep 20
systemctl --user is-active -q "$unit" || remask "service not active"
journal=$(journalctl --user -u "$unit" -u plasma-kwin_wayland --since "@$since" -o cat --no-pager)
grep -q "kitty-resurrect KWin script loaded" <<<"$journal" || remask "script did not load"
grep -q "LogicalOutput" <<<"$journal" && remask "LogicalOutput error in journal"
grep -Eq "atomic commit failed|Applying output configuration failed" <<<"$journal" && remask "KWin output errors"

sid=$(loginctl show-user "$(id -u)" -p Display --value)
[ "$(loginctl show-session "$sid" -p Active --value)" = yes ] || remask "session not active"
shot=${XDG_RUNTIME_DIR:-/tmp}/kitty-resurrect-verify.png
# Idle DPMS-off outputs capture as fully transparent (lit 0), which is
# power saving, not a black screen: wake them first.
kscreen-doctor --dpms on >/dev/null 2>&1; sleep 4
spectacle -f -b -n -o "$shot" || remask "screenshot failed"
# Fraction of pixels brighter than 10%. The gaps between monitors come out
# pure white, so they are blacked first or they alone pass a mean check;
# a dark wallpaper plus a clock still lights ~0.7%, a dead frame 0.
lit=$(magick "$shot" -fill black -opaque white -colorspace Gray -threshold 10% -format '%[fx:mean]' info:)
echo "screenshot $shot lit fraction $lit"
awk -v m="$lit" 'BEGIN{exit !(m > 0.001)}' || remask "screenshot is black"
# Optional single, bounded restore check: pass a saved state (e.g. a retired one).
if [ -n "${1:-}" ]; then
  kitty-resurrect "$1" | tee /dev/stderr | grep -q '^restoring' || remask "restore refused"
  sleep 15
  [ "$(loginctl show-session "$sid" -p Active --value)" = yes ] || remask "session lost after restore"
  journalctl --user -u plasma-kwin_wayland --since "@$since" -o cat --no-pager |
    grep -Eq "atomic commit failed|LogicalOutput" && remask "KWin errors after restore"
fi
echo "OK: $unit enabled; rollback: systemctl --user mask --now $unit"
