#!/usr/bin/env bash
# Render docs/OPTIONS.md from the nixosOptionsDoc CommonMark output. Single
# source of truth for the header, shared by `just options-doc` (regenerate) and
# the options-doc check (verify the committed file is current).
#
# Usage: render-options-doc.sh <options.md from .#options-doc>
set -euo pipefail

raw=${1:?usage: render-options-doc.sh <commonmark-file>}

cat <<'EOF'
# nix-android option reference

<!-- Generated from modules/options.nix — do not edit by hand.
     Regenerate with `just options-doc`. -->

Every option maps to an adb primitive with executed read/write/read-back
evidence (see [PRIMITIVES.md](./PRIMITIVES.md)); the citation lives in each
option's description below. Managed-key semantics throughout: converge only
touches what you declare and never reverts undeclared device state. App version
pins are floors — converge installs/upgrades to at least the locked version and
never downgrades.

EOF

cat "$raw"
