#!/usr/bin/env bash
# droidnix converge engine: manifest.json → device, over adb at uid 2000.
#
# PLAN by default (prints what would change, touches nothing); --apply executes.
# Safety posture (docs/PLAN.md): pins are floors — installs and upgrades only,
# never downgrades; removals only when the manifest says cleanup=uninstall.
#
# Usage: converge.sh <manifest.json> [--apply] [--serial <adb-serial>]
set -euo pipefail

manifest=${1:?usage: converge.sh <manifest.json> [--apply] [--serial S]}
shift
apply=0
serial=${ANDROID_SERIAL:-}
while [ $# -gt 0 ]; do
  case $1 in
  --apply) apply=1; shift ;;
  --serial) serial=$2; shift 2 ;;
  *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

adb=(adb)
[ -n "$serial" ] && adb=(adb -s "$serial")
user=$(jq -r '.device.user' "$manifest")

# Device reality: user-installed packages with versionCodes.
installed=$("${adb[@]}" shell pm list packages -3 --show-versioncode --user "$user" | tr -d '\r')
current_code() { # -> versionCode or empty
  sed -n "s/^package:$1 versionCode:\([0-9]*\).*/\1/p" <<<"$installed" | head -1
}

todo_install=()
todo_upgrade=()
todo_remove=()
missing_attended=()
declare -A declared=()

# F-Droid apps: install missing, upgrade below-floor.
while IFS=$'\t' read -r pkg code apk; do
  declared[$pkg]=1
  cur=$(current_code "$pkg")
  if [ -z "$cur" ]; then
    todo_install+=("$pkg"$'\t'"$code"$'\t'"$apk")
  elif [ "$cur" -lt "$code" ]; then
    todo_upgrade+=("$pkg"$'\t'"$cur→$code"$'\t'"$apk")
  fi
done < <(jq -r '.apps.fdroid[] | [.package, .versionCode, .apk] | @tsv' "$manifest")

# Attended apps: assert presence only.
while read -r pkg; do
  [ -z "$pkg" ] && continue
  declared[$pkg]=1
  [ -n "$(current_code "$pkg")" ] || missing_attended+=("$pkg")
done < <(jq -r '.apps.attended[]' "$manifest")

# Cleanup: undeclared user apps (only in uninstall mode).
if [ "$(jq -r '.apps.cleanup' "$manifest")" = "uninstall" ]; then
  while read -r pkg; do
    [ -n "${declared[$pkg]:-}" ] || todo_remove+=("$pkg")
  done < <(sed -n 's/^package:\([^ ]*\) .*/\1/p' <<<"$installed")
fi

plan_lines=$(( ${#todo_install[@]} + ${#todo_upgrade[@]} + ${#todo_remove[@]} ))
for t in "${todo_install[@]}"; do IFS=$'\t' read -r p c _ <<<"$t"; echo "install  $p ($c)"; done
for t in "${todo_upgrade[@]}"; do IFS=$'\t' read -r p c _ <<<"$t"; echo "upgrade  $p ($c)"; done
for t in "${todo_remove[@]}";  do echo "remove   $t"; done
for p in "${missing_attended[@]}"; do echo "ATTENDED $p — install by hand (Play/Aurora)"; done

if [ "$plan_lines" -eq 0 ]; then
  echo "✓ device matches manifest (${#missing_attended[@]} attended missing)"
  exit 0
fi

if [ "$apply" -eq 0 ]; then
  echo "-- plan only ($plan_lines changes); re-run with --apply"
  exit 0
fi

for t in "${todo_install[@]}" "${todo_upgrade[@]}"; do
  IFS=$'\t' read -r pkg _ apk <<<"$t"
  echo "installing $pkg…"
  "${adb[@]}" install -r --user "$user" "$apk" >/dev/null
done
for pkg in "${todo_remove[@]}"; do
  echo "uninstalling $pkg…"
  "${adb[@]}" uninstall --user "$user" "$pkg" >/dev/null
done
echo "✓ applied $plan_lines changes"
