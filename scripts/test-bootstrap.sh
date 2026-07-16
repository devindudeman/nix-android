#!/usr/bin/env bash
set -euo pipefail

bootstrap=${1:?usage: test-bootstrap.sh BOOTSTRAP_SCRIPT BASH}
bash_bin=${2:?usage: test-bootstrap.sh BOOTSTRAP_SCRIPT BASH}
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
mkdir -p "$tmp/src/engine" "$tmp/src/scripts" "$tmp/captures"

cat > "$tmp/src/engine/converge.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
manifest=$1
shift
count=0
[ ! -e "$TEST_COUNT" ] || count=$(cat "$TEST_COUNT")
count=$((count + 1))
printf '%s\n' "$count" > "$TEST_COUNT"
cp "$manifest" "$TEST_CAPTURES/engine-$count.json"
printf '%s\n' "$*" > "$TEST_CAPTURES/engine-$count.args"
if [ "${TEST_VALIDATE_FAIL:-0}" -eq 1 ] && [[ " $* " == *" --validate-only "* ]]; then
  exit 2
fi
EOF
cat > "$tmp/src/scripts/assist-play.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" > "$TEST_CAPTURES/assist.args"
[ "${TEST_ASSIST_FAIL:-0}" -eq 0 ]
EOF

jq -n '{
  manifestVersion: 3,
  device: {name: "fixture", user: 0, abi: "x86_64"},
  apps: {
    cleanup: "uninstall",
    attended: ["org.example.attended"],
    play: ["org.example.play"],
    managed: [{package: "org.example.managed", versionCode: 1, apk: "/fixture.apk"}]
  },
  android: {
    darkMode: true,
    disabled: ["org.example.managed"],
    suspended: [],
    unsuspended: [],
    deviceidleExempt: ["org.example.managed"],
    roles: {browser: "org.example.managed"},
    settings: {global: {example: "value"}, secure: {}, system: {}},
    permissions: {"org.example.managed": {grant: ["android.permission.CAMERA"], revoke: [], flags: {}}},
    appOps: {"org.example.managed": {RUN_IN_BACKGROUND: "ignore"}},
    locales: {"org.example.managed": ["en-US"]},
    inputMethod: {enabled: [], disabled: [], default: null},
    dataSaver: {enabled: true},
    appLinks: {"org.example.managed": {allowed: false, selected: ["example.com"], unselected: []}}
  }
}' > "$tmp/manifest.json"

export NIX_ANDROID_SRC=$tmp/src NIX_ANDROID_BASH=$bash_bin
export TEST_COUNT=$tmp/count TEST_CAPTURES=$tmp/captures
"$bash_bin" "$bootstrap" "$tmp/manifest.json" --serial fixture >/dev/null
[ "$(cat "$TEST_COUNT")" -eq 3 ]
grep -Fxq -- '--validate-only' "$tmp/captures/engine-1.args"
# Phase one (reduced scaffold) applies but must NOT record a generation;
# only phase three, the complete declared state, carries --record.
grep -Fxq -- '--apply --serial fixture' "$tmp/captures/engine-2.args"
grep -Fxq -- '--apply --record --serial fixture' "$tmp/captures/engine-3.args"
cmp "$tmp/manifest.json" "$tmp/captures/engine-1.json"
cmp "$tmp/manifest.json" "$tmp/captures/engine-3.json"
jq -e '
  .apps.managed == [{package: "org.example.managed", versionCode: 1, apk: "/fixture.apk"}]
  and .apps.attended == [] and .apps.play == [] and .apps.cleanup == "none"
  and .android == {
    settings: {global: {}, secure: {}, system: {}}, darkMode: null,
    roles: {}, disabled: [], suspended: [], unsuspended: [],
    permissions: {}, appOps: {}, locales: {},
    inputMethod: {enabled: [], disabled: [], default: null},
    dataSaver: {enabled: null}, appLinks: {}, deviceidleExempt: []
  }
' "$tmp/captures/engine-2.json" >/dev/null
grep -Fq "$tmp/manifest.json --serial fixture --watch" "$tmp/captures/assist.args"

rm -f "$TEST_COUNT" "$tmp/captures"/*
export TEST_ASSIST_FAIL=1
if "$bash_bin" "$bootstrap" "$tmp/manifest.json" --serial fixture >/dev/null 2>&1; then
  echo "bootstrap unexpectedly continued after an assist failure" >&2
  exit 1
fi
[ "$(cat "$TEST_COUNT")" -eq 2 ]
test ! -e "$tmp/captures/engine-3.json"

rm -f "$TEST_COUNT" "$tmp/captures"/*
export TEST_ASSIST_FAIL=0 TEST_VALIDATE_FAIL=1
if "$bash_bin" "$bootstrap" "$tmp/manifest.json" --serial fixture >/dev/null 2>&1; then
  echo "bootstrap unexpectedly continued after validation failure" >&2
  exit 1
fi
[ "$(cat "$TEST_COUNT")" -eq 1 ]
test ! -e "$tmp/captures/assist.args"
