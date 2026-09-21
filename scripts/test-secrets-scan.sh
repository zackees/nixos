#!/usr/bin/env bash
# ── Proves the gitleaks gate in scripts/sync.sh actually catches something ──
#
# nixos#29: a scan that always reports "no leaks found" is indistinguishable
# from one that is silently broken -- wrong flags, an empty config, a typo
# in the invocation. This plants a known-fake credential in a throwaway git
# repo and asserts gitleaks refuses it, then asserts a clean file passes.
# Run standalone, or as the CI check in .github/workflows/secrets-scan.yml.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

git -C "$WORK" init -q
git -C "$WORK" config user.email test@example.com
git -C "$WORK" config user.name "secrets scan test"
cp "$REPO/.gitleaks.toml" "$WORK/.gitleaks.toml"

gitleaks() { nix run nixpkgs#gitleaks -- "$@"; }

fail=0

# 1. A planted secret must be caught.
#
# Deliberately NOT AKIAIOSFODNN7EXAMPLE (AWS's own published example access
# key ID): gitleaks' default ruleset explicitly allowlists it, precisely
# because it's the textbook placeholder every scanner special-cases out of
# doc/test noise -- using it here would make this test pass even if the
# gate were completely broken. Also must be exactly 36 chars after `ghp_`:
# gitleaks' github-pat rule requires a word boundary right after the match,
# so a same-shaped-but-wrong-length string silently fails to match too. Both
# traps were hit while writing this test -- see nixos#29.
#
# The subshell's own pipefail is off: `head -c36` closing its input early
# sends tr a SIGPIPE, which pipefail would otherwise report as the pipeline's
# (nonzero) exit status and abort this script under `set -e` -- for output
# we're discarding the exit status of anyway.
fake_token="ghp_$(set +o pipefail; tr -dc 'A-Za-z0-9' < /dev/urandom | head -c36)"
echo "token = \"$fake_token\"" > "$WORK/leaky.txt"
git -C "$WORK" add -A
if gitleaks protect --staged --redact --source "$WORK" --no-banner; then
  echo "FAIL: gitleaks did not catch the planted token -- the gate is broken" >&2
  fail=1
else
  echo "PASS: planted secret was caught"
fi
git -C "$WORK" reset >/dev/null
# `reset` only unstages -- leaky.txt is still sitting in the working tree,
# and a plain `git add -A` below would silently re-stage it alongside
# clean.txt, making a genuinely-broken gate look like it passed test 2.
rm -f "$WORK/leaky.txt"

# 2. An unrelated, secret-free change must still pass, so the gate isn't
#    just refusing everything.
echo "nothing sensitive here" > "$WORK/clean.txt"
git -C "$WORK" add -A
if gitleaks protect --staged --redact --source "$WORK" --no-banner; then
  echo "PASS: clean content was not flagged"
else
  echo "FAIL: gitleaks flagged content with no secret in it" >&2
  fail=1
fi
git -C "$WORK" reset >/dev/null

exit "$fail"
