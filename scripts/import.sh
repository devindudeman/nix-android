#!/usr/bin/env bash
# android-rebuild import — nixos-generate-config for phones. READ-ONLY.
# Reads a connected device's structured package state and emits a starter
# device.nix on stdout. Play installer evidence becomes apps.play; other source
# evidence is emitted only as commented curation hints.
set -euo pipefail

serial=${ANDROID_SERIAL:-}
snapshot_out=
report_out=
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
  --report-out)
    [ $# -ge 2 ] || { echo "--report-out requires a value" >&2; exit 2; }
    report_out=$2; shift 2
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
"${adb[@]}" shell pm list packages --user 0 | tr -d '\r' > "$work/installed.txt"
"${adb[@]}" shell pm list packages -3 --user 0 | tr -d '\r' > "$work/third-party.txt"
"${adb[@]}" shell cmd uimode night </dev/null | tr -d '\r' > "$work/night-mode.txt"
"${adb[@]}" shell settings get --user 0 global private_dns_mode </dev/null \
  | tr -d '\r' > "$work/private-dns-mode.txt"
"${adb[@]}" shell settings get --user 0 global private_dns_specifier </dev/null \
  | tr -d '\r' > "$work/private-dns-specifier.txt"
: > "$work/roles.txt"
for role in browser sms dialer home; do
  case $role in
  browser) role_id=android.app.role.BROWSER ;;
  sms) role_id=android.app.role.SMS ;;
  dialer) role_id=android.app.role.DIALER ;;
  home) role_id=android.app.role.HOME ;;
  esac
  holders=$("${adb[@]}" shell cmd role get-role-holders --user 0 "$role_id" </dev/null | tr -d '\r')
  while IFS= read -r holder; do
    [ -z "$holder" ] || printf '%s\t%s\n' "$role" "$holder" >> "$work/roles.txt"
  done <<< "$holders"
done
"${adb[@]}" shell pm list packages -d --user 0 </dev/null \
  | tr -d '\r' > "$work/disabled.txt"
"${adb[@]}" shell cmd deviceidle whitelist </dev/null \
  | tr -d '\r' > "$work/device-idle.txt"
"${adb[@]}" shell pm list permissions -d -g -f </dev/null \
  | tr -d '\r' > "$work/permission-definitions.txt"
python3 "$NIX_ANDROID_SRC/scripts/package-snapshot.py" \
  --proto "$work/package.pb" \
  --installed "$work/installed.txt" \
  --third-party "$work/third-party.txt" \
  --model "$model" \
  --product "$product" \
  --abi "$abi" \
  --sdk "$sdk" \
  --security-patch "$security_patch" \
  --night-mode "$work/night-mode.txt" \
  --private-dns-mode "$work/private-dns-mode.txt" \
  --private-dns-specifier "$work/private-dns-specifier.txt" \
  --roles "$work/roles.txt" \
  --disabled "$work/disabled.txt" \
  --device-idle "$work/device-idle.txt" \
  --permission-definitions "$work/permission-definitions.txt" \
  > "$work/snapshot.json"

if [ -n "$snapshot_out" ]; then
  snapshot_dir=$(dirname -- "$snapshot_out")
  [ -d "$snapshot_dir" ] || { echo "snapshot directory does not exist: $snapshot_dir" >&2; exit 2; }
  snapshot_tmp=$(mktemp "$snapshot_out.tmp.XXXXXX")
  cp -- "$work/snapshot.json" "$snapshot_tmp"
  mv -- "$snapshot_tmp" "$snapshot_out"
fi

render_args=()
if [ -n "$report_out" ]; then
  report_dir=$(dirname -- "$report_out")
  [ -d "$report_dir" ] || { echo "report directory does not exist: $report_dir" >&2; exit 2; }
  render_args+=(--report-out "$work/report.json")
fi
python3 "$NIX_ANDROID_SRC/scripts/render-import.py" "$work/snapshot.json" "${render_args[@]}"
if [ -n "$report_out" ]; then
  report_tmp=$(mktemp "$report_out.tmp.XXXXXX")
  cp -- "$work/report.json" "$report_tmp"
  mv -- "$report_tmp" "$report_out"
fi
