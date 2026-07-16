#!/usr/bin/env bash
# android-rebuild import — nixos-generate-config for phones. READ-ONLY.
# Reads a connected device's structured package state and emits a starter
# device.nix on stdout. Play installer evidence becomes apps.play; other source
# evidence is emitted only as commented curation hints.
set -euo pipefail

serial=${ANDROID_SERIAL:-}
snapshot_out=
report_out=
obtainium_export=
app_manager_export=
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
  --obtainium-export)
    [ $# -ge 2 ] || { echo "--obtainium-export requires a value" >&2; exit 2; }
    obtainium_export=$2; shift 2
    ;;
  --app-manager-export)
    [ $# -ge 2 ] || { echo "--app-manager-export requires a value" >&2; exit 2; }
    app_manager_export=$2; shift 2
    ;;
  *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done
[ -n "$serial" ] || { echo "import requires --serial SERIAL (or ANDROID_SERIAL)" >&2; exit 2; }
[ -z "$obtainium_export" ] || [ -r "$obtainium_export" ] || {
  echo "cannot read Obtainium export: $obtainium_export" >&2
  exit 2
}
[ -z "$app_manager_export" ] || [ -r "$app_manager_export" ] || {
  echo "cannot read App Manager export: $app_manager_export" >&2
  exit 2
}
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
"${adb[@]}" shell dumpsys package permissions </dev/null \
  | tr -d '\r' > "$work/permission-restrictions.txt"
: > "$work/permission-details.txt"
while IFS= read -r package_line; do
  package=${package_line#package:}
  [[ $package =~ ^[A-Za-z0-9_]+([.][A-Za-z0-9_]+)+$ ]] || {
    echo "invalid package in third-party inventory: $package" >&2
    exit 1
  }
  printf '### nix-android package %s\n' "$package" >> "$work/permission-details.txt"
  "${adb[@]}" shell dumpsys package "$package" </dev/null \
    | tr -d '\r' >> "$work/permission-details.txt"
done < "$work/third-party.txt"
"${adb[@]}" shell dumpsys appops </dev/null \
  | tr -d '\r' > "$work/app-ops.txt"
"${adb[@]}" shell ime list -s --user 0 </dev/null \
  | tr -d '\r' > "$work/ime-enabled.txt"
"${adb[@]}" shell settings get --user 0 secure default_input_method </dev/null \
  | tr -d '\r' > "$work/ime-default.txt"
"${adb[@]}" shell cmd netpolicy get restrict-background </dev/null \
  | tr -d '\r' > "$work/data-saver.txt"
"${adb[@]}" shell cmd netpolicy list restrict-background-blacklist </dev/null \
  | tr -d '\r' > "$work/data-restricted.txt"
"${adb[@]}" shell cmd netpolicy list restrict-background-whitelist </dev/null \
  | tr -d '\r' > "$work/data-exempt.txt"
: > "$work/app-locales.txt"
: > "$work/app-links.txt"
while IFS= read -r package_line; do
  package=${package_line#package:}
  printf '### nix-android package %s\n' "$package" >> "$work/app-locales.txt"
  "${adb[@]}" shell cmd locale get-app-locales "$package" --user 0 </dev/null \
    | tr -d '\r' >> "$work/app-locales.txt"
  printf '### nix-android package %s\n' "$package" >> "$work/app-links.txt"
  "${adb[@]}" shell pm get-app-links --user 0 "$package" </dev/null \
    | tr -d '\r' >> "$work/app-links.txt"
done < "$work/third-party.txt"
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
  --permission-restrictions "$work/permission-restrictions.txt" \
  --permission-details "$work/permission-details.txt" \
  --app-ops "$work/app-ops.txt" \
  --app-locales "$work/app-locales.txt" \
  --ime-enabled "$work/ime-enabled.txt" \
  --ime-default "$work/ime-default.txt" \
  --data-saver "$work/data-saver.txt" \
  --data-restricted "$work/data-restricted.txt" \
  --data-exempt "$work/data-exempt.txt" \
  --app-links "$work/app-links.txt" \
  > "$work/snapshot.json"

adapter_args=(--snapshot "$work/snapshot.json")
[ -z "$obtainium_export" ] || adapter_args+=(--obtainium "$obtainium_export")
[ -z "$app_manager_export" ] || adapter_args+=(--app-manager "$app_manager_export")
if [ "${#adapter_args[@]}" -gt 2 ]; then
  python3 "$NIX_ANDROID_SRC/scripts/provenance-adapters.py" "${adapter_args[@]}" \
    > "$work/enriched-snapshot.json"
  mv -- "$work/enriched-snapshot.json" "$work/snapshot.json"
fi

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
