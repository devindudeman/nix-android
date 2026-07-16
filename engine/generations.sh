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
  local changes=$1 name state gens log last n saved manifest_tmp log_tmp line
  if ! name=$(jq -er '.device.name | select(type == "string" and length > 0)' "$manifest"); then
    echo "warning: could not read device name for generation receipt; not recording" >&2
    return 0
  fi
  state="${XDG_STATE_HOME:-$HOME/.local/state}/nix-android/${name}"
  gens="$state/generations"
  mkdir -p "$gens" || { echo "warning: could not write generation ledger under $state" >&2; return 0; }
  # Number from the ledger's max, not a file count: a hand-deleted generation
  # file must never make a new switch reuse a live number.
  log="$state/log.jsonl"
  last=0
  if [ -e "$log" ]; then
    if [ ! -f "$log" ] || ! last=$(jq -se '
      if all(.[];
        type == "object"
        and (.generation | type == "number")
        and .generation >= 1
        and (.generation | floor) == .generation)
      then (map(.generation) | max // 0)
      else error("invalid generation ledger")
      end
    ' "$log"); then
      echo "warning: generation ledger is unreadable or invalid; not recording" >&2
      return 0
    fi
  fi
  n=$(( last + 1 ))
  saved="$gens/${n}.json"
  if [ -e "$saved" ]; then
    echo "warning: generation ${n} already exists; not recording" >&2
    return 0
  fi

  # The callers invoke this via `&&`, which suppresses errexit inside. Stage the
  # complete receipt first, hard-link the manifest into place so an existing
  # generation can never be overwritten, then atomically replace the ledger.
  # A crash can leave an unreferenced manifest, never a log entry without one.
  if ! manifest_tmp=$(mktemp "$gens/.generation-${n}.XXXXXX"); then
    echo "warning: could not stage generation ${n} manifest; not recording" >&2
    return 0
  fi
  if ! cp "$manifest" "$manifest_tmp"; then
    echo "warning: could not copy manifest for generation ${n}; not recording" >&2
    rm -f "$manifest_tmp"
    return 0
  fi
  if ! line=$(jq -cn --argjson gen "$n" --arg time "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg serial "$serial" --arg name "$name" --arg manifest "$saved" --argjson changes "$changes" \
    '{generation: $gen, time: $time, serial: $serial, device: $name, manifest: $manifest, changes: $changes}'); then
    echo "warning: could not build generation ${n} ledger entry; not recording" >&2
    rm -f "$manifest_tmp"
    return 0
  fi
  if ! log_tmp=$(mktemp "$state/.log.jsonl.XXXXXX"); then
    echo "warning: could not stage generation ${n} ledger entry; not recording" >&2
    rm -f "$manifest_tmp"
    return 0
  fi
  if [ -f "$log" ] && ! cp "$log" "$log_tmp"; then
    echo "warning: could not copy generation ledger; not recording" >&2
    rm -f "$manifest_tmp" "$log_tmp"
    return 0
  fi
  if ! printf '%s\n' "$line" >> "$log_tmp"; then
    echo "warning: could not stage generation ${n} ledger entry; not recording" >&2
    rm -f "$manifest_tmp" "$log_tmp"
    return 0
  fi
  if ! ln "$manifest_tmp" "$saved"; then
    echo "warning: could not commit generation ${n} manifest; not recording" >&2
    rm -f "$manifest_tmp" "$log_tmp"
    return 0
  fi
  rm -f "$manifest_tmp"
  if ! mv "$log_tmp" "$log"; then
    echo "warning: could not commit generation ${n} ledger entry; not recording" >&2
    rm -f "$saved" "$log_tmp"
    return 0
  fi
  echo "recorded generation ${n} for '${name}'" >&2
}
