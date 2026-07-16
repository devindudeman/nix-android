#!/usr/bin/env bash
# Rebuild a wiped device in resumable phases: managed APKs, consent-bound Play
# installs, then the complete manifest. Every mutation still goes through the
# convergence engine; phase one deliberately disables cleanup and Android state.
set -euo pipefail

manifest=${1:?usage: bootstrap.sh MANIFEST --serial SERIAL}
shift
serial=${ANDROID_SERIAL:-}
while [ $# -gt 0 ]; do
  case $1 in
  --serial)
    [ $# -ge 2 ] || { echo "--serial requires a value" >&2; exit 2; }
    serial=$2; shift 2
    ;;
  *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done
[ -n "$serial" ] || { echo "bootstrap requires --serial SERIAL (or ANDROID_SERIAL)" >&2; exit 2; }

src=${NIX_ANDROID_SRC:?NIX_ANDROID_SRC not set (use the packaged android-rebuild)}
bash_bin=${NIX_ANDROID_BASH:?NIX_ANDROID_BASH not set (use the packaged android-rebuild)}
engine=$src/engine/converge.sh
assist=$src/scripts/assist-play.sh

# Validate the complete input before deriving a deliberately smaller phase.
# --validate-only performs no adb call.
"$bash_bin" "$engine" "$manifest" --validate-only

phase=$(mktemp "${TMPDIR:-/tmp}/nix-android-bootstrap.XXXXXX.json")
trap 'rm -f -- "$phase"' EXIT
jq '
  .apps.attended = [] |
  .apps.play = [] |
  .apps.cleanup = "none" |
  .android = {
    settings: {global: {}, secure: {}, system: {}},
    darkMode: null,
    roles: {},
    disabled: [],
    suspended: [],
    unsuspended: [],
    permissions: {},
    appOps: {},
    locales: {},
    inputMethod: {enabled: [], disabled: [], default: null},
    dataSaver: {enabled: null},
    appLinks: {},
    deviceidleExempt: []
  }
' "$manifest" > "$phase"

echo "== phase 1/3: reproducible APKs =="
"$bash_bin" "$engine" "$phase" --apply --serial "$serial"

echo "== phase 2/3: Play consent queue =="
"$bash_bin" "$assist" "$manifest" --serial "$serial" --watch

echo "== phase 3/3: complete declared state =="
"$bash_bin" "$engine" "$manifest" --apply --serial "$serial"
