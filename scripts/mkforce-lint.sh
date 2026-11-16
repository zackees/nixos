#!/usr/bin/env bash
# Readable report from the mkforce-discards lint (checks/mkforce-discards.nix):
# every mkForce / mkOverride < 100 in this repo that throws away another
# module's definition of the same option, with the discarded values and the
# files they came from.
#
#   scripts/mkforce-lint.sh      exit 0 clean, 1 on an unallowlisted finding
#
# Same evaluation `nix flake check` runs as checks.x86_64-linux.mkforce-discards,
# printed instead of built. Like every flake command it sees tracked files
# only, including their uncommitted edits; a new .nix file needs `git add`.
# To accept a deliberate discard, end the line that holds the override with
# `# mkforce-ok: <why>` (or put that comment alone on the line above it).
set -euo pipefail

cd "$(dirname "$0")/.."

# One evaluation for both the count and the text: the first line is the
# number of findings, the rest is the report.
out=$(nix eval --raw .#checks.x86_64-linux.mkforce-discards \
  --apply 'd: "${toString d.findings}\n${d.report}"')

count=${out%%$'\n'*}
printf '%s\n' "${out#*$'\n'}"

if [ "$count" != 0 ]; then
  echo "mkforce-lint: $count unallowlisted finding(s)" >&2
  exit 1
fi
