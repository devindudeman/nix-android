#!/usr/bin/env bash
# Open missing apps.play declarations in the official Play Store. With --watch,
# advance after Android reports that the user installed the current package.
# This never clicks, installs, or confirms anything; the user owns Play.
set -euo pipefail

manifest=${1:?usage: assist-play.sh MANIFEST --serial SERIAL [--watch]}
shift
serial=${ANDROID_SERIAL:-}
watch=0
while [ $# -gt 0 ]; do
  case $1 in
  --serial)
    [ $# -ge 2 ] || { echo "--serial requires a value" >&2; exit 2; }
    serial=$2; shift 2
    ;;
  --watch) watch=1; shift ;;
  *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done
[ -n "$serial" ] || { echo "assist requires --serial SERIAL (or ANDROID_SERIAL)" >&2; exit 2; }

# Validate every field this helper consumes before the first adb call.
if ! jq -e '
  def package: type == "string" and test("^[A-Za-z0-9_]+([.][A-Za-z0-9_]+)+\\z");
  .manifestVersion == 2
  and .device.user == 0
  and (.device.abi | IN("arm64-v8a", "armeabi-v7a", "x86_64"))
  and (.apps.play | type == "array" and all(.[]; package)
    and length == (unique | length))
' "$manifest" >/dev/null; then
  echo "invalid or unsupported manifest: $manifest" >&2
  exit 2
fi

adb_base=(adb -s "$serial")
adb() { command "${adb_base[@]}" "$@" </dev/null; }
adb_shell() {
  local arg quoted remote=""
  for arg in "$@"; do
    printf -v quoted "'%s'" "${arg//\'/\'\\\'\'}"
    remote+="${remote:+ }$quoted"
  done
  adb shell "$remote"
}

user=$(jq -r '.device.user' "$manifest")
desired_abi=$(jq -r '.device.abi' "$manifest")
actual_abi=$(adb_shell getprop ro.product.cpu.abi | tr -d '\r')
[ "$actual_abi" = "$desired_abi" ] || {
  echo "target ABI mismatch for serial $serial: device reports '$actual_abi', manifest requires '$desired_abi'" >&2
  exit 2
}
installed=
refresh_installed() { installed=$(adb_shell pm list packages --user "$user" | tr -d '\r'); }
present() { grep -Fqx "package:$1" <<<"$installed"; }

timeout=${NIX_ANDROID_ASSIST_TIMEOUT_SECONDS:-1800}
poll=${NIX_ANDROID_ASSIST_POLL_SECONDS:-2}
[[ $timeout =~ ^[1-9][0-9]*$ ]] || { echo "NIX_ANDROID_ASSIST_TIMEOUT_SECONDS must be a positive integer" >&2; exit 2; }
[[ $poll =~ ^[1-9][0-9]*$ ]] || { echo "NIX_ANDROID_ASSIST_POLL_SECONDS must be a positive integer" >&2; exit 2; }

while true; do
  refresh_installed
  missing=()
  while read -r package; do
    [ -z "$package" ] || present "$package" || missing+=("$package")
  done < <(jq -r '.apps.play[]' "$manifest")

  if [ "${#missing[@]}" -eq 0 ]; then
    echo "✓ all declared Play apps are installed"
    exit 0
  fi

  if ! present com.android.vending; then
    echo "Google Play Store (com.android.vending) is not installed for user $user" >&2
    echo "cannot assist ${missing[0]}; install/configure Play Store first" >&2
    exit 1
  fi

  package=${missing[0]}
  url="https://play.google.com/store/apps/details?id=$package"
  echo "opening Play Store for $package"
  adb_shell am start-activity --user "$user" -a android.intent.action.VIEW -d "$url" com.android.vending >/dev/null

  if [ "$watch" -eq 0 ]; then
    if [ "${#missing[@]}" -gt 1 ]; then
      echo "$(( ${#missing[@]} - 1 )) more Play app(s) remain; install this one, then rerun assist"
    else
      echo "install it with your on-device Play account, then rerun plan"
    fi
    exit 0
  fi

  echo "waiting for $package to be installed on-device (Ctrl-C to stop)"
  deadline=$((SECONDS + timeout))
  while true; do
    refresh_installed
    if present "$package"; then
      echo "detected $package"
      break
    fi
    if [ "$SECONDS" -ge "$deadline" ]; then
      echo "timed out after ${timeout}s waiting for $package; rerun assist --watch to resume" >&2
      exit 1
    fi
    sleep "$poll"
  done
done
