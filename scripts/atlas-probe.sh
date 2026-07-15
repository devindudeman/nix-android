#!/usr/bin/env bash
# Atlas raw capture: walk every `cmd` service on the connected device and
# record its shell-command help text, plus the settings namespaces and the
# device identity. READ-ONLY by construction — `cmd <svc> help` and `settings
# list` only. Output feeds the hand-classified docs/PRIMITIVES.md.
#
# Usage: atlas-probe.sh <output-dir> <adb-serial>
set -euo pipefail

out=${1:?usage: atlas-probe.sh <output-dir> <adb-serial>}
serial=${2:?usage: atlas-probe.sh <output-dir> <adb-serial>}
adb=(adb -s "$serial")

mkdir -p "$out"

# shellcheck disable=SC2016 # command substitutions intentionally run on Android
"${adb[@]}" shell 'echo "model=$(getprop ro.product.model)
build=$(getprop ro.build.display.id)
sdk=$(getprop ro.build.version.sdk)
patch=$(getprop ro.build.version.security_patch)"' </dev/null > "$out/device.txt"

for ns in global secure system; do
  "${adb[@]}" shell settings list "$ns" </dev/null > "$out/settings-$ns.txt"
done

"${adb[@]}" shell cmd -l </dev/null | tr -d '\r' | sort > "$out/services.txt"

while read -r svc; do
  printf '===== %s\n' "$svc"
  timeout 6 "${adb[@]}" shell cmd "$svc" help </dev/null 2>&1 | head -80 || true
done < "$out/services.txt" > "$out/cmd-help.txt"

echo "atlas capture → $out ($(wc -l < "$out/services.txt") services)"
