#!/usr/bin/env bash
# android-rebuild import — nixos-generate-config for phones. READ-ONLY.
# Reads a connected device's structured package state and emits a starter
# device.nix on stdout. Play installer evidence becomes apps.play; other source
# evidence is emitted only as commented curation hints.
set -euo pipefail

serial=${ANDROID_SERIAL:-}
snapshot_out=
while [ $# -gt 0 ]; do
  case $1 in
  --serial)
    [ $# -ge 2 ] || { echo "--serial requires a value" >&2; exit 2; }
    serial=$2; shift 2
    ;;
  --snapshot-out)
    [ $# -ge 2 ] || { echo "--snapshot-out requires a value" >&2; exit 2; }
    snapshot_out=$2; shift 2
    ;;
  *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done
[ -n "$serial" ] || { echo "import requires --serial SERIAL (or ANDROID_SERIAL)" >&2; exit 2; }
adb=(adb -s "$serial")

umask 077
work=$(mktemp -d "${TMPDIR:-/tmp}/nix-android-import.XXXXXX")
trap 'rm -rf -- "$work"' EXIT

model=$("${adb[@]}" shell getprop ro.product.model | tr -d '\r')
product=$("${adb[@]}" shell getprop ro.product.device | tr -d '\r')
abi=$("${adb[@]}" shell getprop ro.product.cpu.abi | tr -d '\r')
sdk=$("${adb[@]}" shell getprop ro.build.version.sdk | tr -d '\r')
security_patch=$("${adb[@]}" shell getprop ro.build.version.security_patch | tr -d '\r')
"${adb[@]}" exec-out dumpsys package --proto > "$work/package.pb"
"${adb[@]}" shell pm list packages -3 --user 0 | tr -d '\r' > "$work/third-party.txt"
python3 "$NIX_ANDROID_SRC/scripts/package-snapshot.py" \
  --proto "$work/package.pb" \
  --third-party "$work/third-party.txt" \
  --model "$model" \
  --product "$product" \
  --abi "$abi" \
  --sdk "$sdk" \
  --security-patch "$security_patch" \
  > "$work/snapshot.json"

if [ -n "$snapshot_out" ]; then
  snapshot_dir=$(dirname -- "$snapshot_out")
  [ -d "$snapshot_dir" ] || { echo "snapshot directory does not exist: $snapshot_dir" >&2; exit 2; }
  snapshot_tmp=$(mktemp "$snapshot_out.tmp.XXXXXX")
  cp -- "$work/snapshot.json" "$snapshot_tmp"
  mv -- "$snapshot_tmp" "$snapshot_out"
fi

python3 "$NIX_ANDROID_SRC/scripts/render-import.py" "$work/snapshot.json"
