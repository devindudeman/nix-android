#!/usr/bin/env bash
# Unit tests for engine/generations.sh — the switch-receipt ledger that backs
# `android-rebuild status`. Device-free: drives record_generation directly with
# ambient $manifest/$serial, exactly as the converge engine does.
set -euo pipefail

# shellcheck source-path=SCRIPTDIR/../engine
# shellcheck source=../engine/generations.sh
source "$(dirname "${BASH_SOURCE[0]}")/../engine/generations.sh"

fail() {
  echo "test-generations: $1" >&2
  exit 1
}

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
export XDG_STATE_HOME="$tmp/state"

manifest="$tmp/manifest.json"
serial="emulator-5554"
printf '%s' '{"device":{"name":"bench","user":0,"abi":"x86_64"},"apps":{"managed":[]}}' >"$manifest"
state="$XDG_STATE_HOME/nix-android/bench"
log="$state/log.jsonl"

# --- first switch records generation 1 ---------------------------------------
record_generation 3 2>/dev/null
[ -f "$state/generations/1.json" ] || fail "generation 1 manifest not copied"
[ -s "$log" ] || fail "ledger not written"
[ "$(jq -r '.generation' "$log")" = 1 ] || fail "first generation should be 1"
[ "$(jq -r '.changes' "$log")" = 3 ] || fail "change count not recorded"
[ "$(jq -r '.device' "$log")" = bench ] || fail "device name not recorded"
[ "$(jq -r '.serial' "$log")" = emulator-5554 ] || fail "serial not recorded"

# saved manifest is a faithful copy (status re-plans it)
diff -q "$manifest" "$state/generations/1.json" >/dev/null || fail "saved manifest differs from applied"

# --- second switch increments to 2 -------------------------------------------
record_generation 0 2>/dev/null
[ "$(wc -l <"$log")" -eq 2 ] || fail "ledger should have two lines"
[ "$(tail -n1 "$log" | jq -r '.generation')" = 2 ] || fail "second generation should be 2"
[ -f "$state/generations/2.json" ] || fail "generation 2 manifest not copied"

# --- numbering follows the ledger max, not a live file count -----------------
# A hand-deleted generation file must not make the next switch reuse a number.
rm -f "$state/generations/1.json"
record_generation 1 2>/dev/null
[ "$(tail -n1 "$log" | jq -r '.generation')" = 3 ] || fail "deleting a file must not lower the next number"

echo "test-generations: ok"
