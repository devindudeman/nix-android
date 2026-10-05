#!/usr/bin/env bash
# Explicit client selection must survive the packaged controller's PATH.
# All clients here are fake; no phone is enumerated or changed.
set -euo pipefail

src=${1:?usage: test-adb-client.sh SOURCE BASH CLI CONVERGE}
bash_bin=${2:?missing Bash interpreter}
cli=${3:?missing packaged CLI}
converge=${4:?missing packaged converge executable}
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
mkdir "$tmp/defaultbin"
export TEST_ADB_LOG=$tmp/selected.log TEST_DEFAULT_LOG=$tmp/default.log

printf '#!%s\n' "$bash_bin" > "$tmp/defaultbin/adb"
cat >> "$tmp/defaultbin/adb" <<'EOF'
printf 'unexpected default client\n' >> "$TEST_DEFAULT_LOG"
exit 91
EOF

# Include a space in the executable name: it is one argv value, not shell code.
selected="$tmp/selected adb"
printf '#!%s\n' "$bash_bin" > "$selected"
cat >> "$selected" <<'EOF'
set -euo pipefail
[ "$1" = -s ] && [ "$2" = fixture ] || exit 92
shift 2
printf '%s\n' "$*" >> "$TEST_ADB_LOG"
[ "${TEST_STOP_FIRST:-0}" = 0 ] || exit 77
case $* in
*ro.product.cpu.abi*) printf 'x86_64\n' ;;
*) ;;
esac
EOF
chmod +x "$selected" "$tmp/defaultbin/adb"
export PATH="$tmp/defaultbin:$PATH" NIX_ANDROID_ADB="$selected"

jq -n '{
  manifestVersion: 4, device: {name: "test", abi: "x86_64", user: 0},
  apps: {cleanup: "none", attended: [], play: [], managed: []},
  android: {
    settings: {global: {}, secure: {}, system: {}}, darkMode: null,
    roles: {}, disabled: [], suspended: [], unsuspended: [], permissions: {},
    appOps: {}, locales: {}, inputMethod: {enabled: [], disabled: [], default: null},
    dataSaver: {enabled: null}, appLinks: {}, deviceidleExempt: [], deviceidleUnexempt: []
  }
}' > "$tmp/manifest.json"

"$bash_bin" "$src/engine/converge.sh" "$tmp/manifest.json" --serial fixture > /dev/null
"$converge" --serial fixture > /dev/null
"$bash_bin" "$src/scripts/assist-play.sh" "$tmp/manifest.json" --serial fixture > /dev/null
"$bash_bin" "$src/scripts/atlas-probe.sh" "$tmp/atlas" fixture > /dev/null

# Stop import at its first device read; no synthetic structured state is needed.
status=0
TEST_STOP_FIRST=1 "$cli" import --serial fixture > /dev/null 2>&1 || status=$?
[ "$status" = 77 ] || { echo "packaged import ignored selected client: $status" >&2; exit 1; }
test -s "$TEST_ADB_LOG"
test ! -e "$TEST_DEFAULT_LOG"

# A bad override must fail, never fall back to a different server/client.
status=0
NIX_ANDROID_ADB="$tmp/missing" "$converge" --serial fixture > /dev/null 2>&1 || status=$?
[ "$status" -ne 0 ] || { echo 'invalid override succeeded' >&2; exit 1; }
test ! -e "$TEST_DEFAULT_LOG"

# Neither client should be consulted when manifest validation fails.
rm -f "$TEST_ADB_LOG"
printf '{}\n' > "$tmp/invalid.json"
status=0
"$bash_bin" "$src/engine/converge.sh" "$tmp/invalid.json" --serial fixture > /dev/null 2>&1 || status=$?
[ "$status" -eq 2 ]
test ! -e "$TEST_ADB_LOG"
test ! -e "$TEST_DEFAULT_LOG"
echo 'explicit ADB client checks passed'
