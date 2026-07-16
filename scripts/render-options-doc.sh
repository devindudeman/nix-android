#!/usr/bin/env bash
# Render docs/OPTIONS.md from the nixosOptionsDoc CommonMark output. Single
# source of truth for the header, shared by `just options-doc` (regenerate) and
# the options-doc check (verify the committed file is current).
#
# Usage: render-options-doc.sh <options.md from .#options-doc>
set -euo pipefail

raw=${1:?usage: render-options-doc.sh <commonmark-file>}
[ -f "$raw" ] || { echo "render-options-doc: no such file: $raw" >&2; exit 1; }

cat <<'EOF'
# nix-android option reference

<!-- Generated from modules/options.nix — do not edit by hand.
     Regenerate with `just options-doc`. -->

Most options map to an adb device primitive with executed read/write/read-back
evidence; [PRIMITIVES.md](./PRIMITIVES.md) is that evidence matrix. A few are
controller-side only (e.g. device identity). Managed-key semantics throughout:
converge only touches what you declare and never reverts undeclared device
state. App version pins are floors — converge installs/upgrades to at least the
locked version and never downgrades.

EOF

# $(...) strips trailing newlines; printf restores exactly one, so the file has
# no blank line at EOF (git diff --check). Assign first so a read failure aborts
# under errexit instead of silently emitting a header-only document.
content=$(cat "$raw")
printf '%s\n' "$content"
