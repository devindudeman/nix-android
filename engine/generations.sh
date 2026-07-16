# shellcheck shell=bash
# Controller-side generation ledger, sourced by the converge engine.
#
# A "generation" is a receipt of reachable state nix-android converged onto a
# device: a copy of the applied manifest plus a JSONL log line. It lets `status`
# report how the device has drifted since the last switch, and gives the config
# a history the way home-manager's profile generations do.
#
# It is NOT a NixOS bootable snapshot: it cannot restore app data, downgrade an
# app, or invert an ensure-only entry the device later dropped. Re-applying an
# older generation converges reachable state only, with the same floors-not-pins
# caveats as any switch.
#
# Uses the ambient $manifest and $serial from the converge engine's scope.
# shellcheck disable=SC2154  # $manifest and $serial come from the sourcing engine
record_generation() { # $1 = applied change count
  local changes=$1 name state gens n
  name=$(jq -r '.device.name' "$manifest")
  state="${XDG_STATE_HOME:-$HOME/.local/state}/nix-android/${name}"
  gens="$state/generations"
  mkdir -p "$gens" || { echo "warning: could not write generation ledger under $state" >&2; return 0; }
  # Number from the ledger's max, not a file count: a hand-deleted generation
  # file must never make a new switch reuse a live number.
  local last=0
  [ -f "$state/log.jsonl" ] && last=$(jq -s 'map(.generation) | max // 0' "$state/log.jsonl")
  n=$(( last + 1 ))
  # The callers invoke this via `&&`, which suppresses errexit inside; a failed
  # step must not fall through and leave a ledger entry pointing at a manifest
  # that was never written. Copy first, build the whole line, and only then
  # append — a receipt is either complete or absent.
  local line
  if ! cp "$manifest" "$gens/${n}.json"; then
    echo "warning: could not copy manifest for generation ${n}; not recording" >&2
    return 0
  fi
  if ! line=$(jq -cn --argjson gen "$n" --arg time "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg serial "$serial" --arg name "$name" --arg manifest "$manifest" --argjson changes "$changes" \
    '{generation: $gen, time: $time, serial: $serial, device: $name, manifest: $manifest, changes: $changes}'); then
    echo "warning: could not build generation ${n} ledger entry; not recording" >&2
    rm -f "$gens/${n}.json"
    return 0
  fi
  if ! printf '%s\n' "$line" >> "$state/log.jsonl"; then
    echo "warning: could not append generation ${n} to the ledger; not recording" >&2
    rm -f "$gens/${n}.json"
    return 0
  fi
  echo "recorded generation ${n} for '${name}'" >&2
}
