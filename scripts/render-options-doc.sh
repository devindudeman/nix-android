#!/usr/bin/env bash
# Render docs/OPTIONS.md from the nixosOptionsDoc CommonMark output. Single
# source of truth for the header, shared by `just options-doc` (regenerate) and
# the options-doc check (verify the committed file is current).
#
# Usage: render-options-doc.sh <options.md from .#options-doc>
set -euo pipefail

raw=${1:?usage: render-options-doc.sh <commonmark-file>}
[ -f "$raw" ] || { echo "render-options-doc: no such file: $raw" >&2; exit 1; }
# Read successfully before emitting anything: `just options-doc` redirects this
# script over the committed file, which must not become a header-only document.
content=$(cat "$raw")

cat <<'EOF'
# nix-android option reference

<!-- Generated from modules/options.nix — do not edit by hand.
     Regenerate with `just options-doc`. -->

Device-state options map to adb primitives with executed read/write/read-back
evidence in [PRIMITIVES.md](./PRIMITIVES.md); source and device-identity options
are controller-side. Managed-key semantics throughout: converge only touches
what you declare and never reverts undeclared device state. App version pins
are floors — converge installs/upgrades to at least the locked version and never
downgrades.

EOF

# $(...) strips trailing newlines; printf restores exactly one, so the file has
# no blank line at EOF (git diff --check).
printf '%s\n' "$content"
