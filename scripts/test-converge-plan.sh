#!/usr/bin/env bash
# jq filters below are deliberately single-quoted: $pkg/$apk are jq --arg names.
# shellcheck disable=SC2016
# Device-free plan/apply tests for engine/converge.sh permission validity and
# the disabled-package skip. A fake adb serves fixture `pm list` and
# `dumpsys package` output and logs every write, so a test can prove a plan
# failed before any mutation. Run from the manifest-safety check.
set -euo pipefail

converge=${1:?usage: test-converge-plan.sh CONVERGE_SH BASH}
bash_bin=${2:?usage: test-converge-plan.sh CONVERGE_SH BASH}
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
mkdir "$tmp/fakebin"

fail() {
  echo "test-converge-plan: $1" >&2
  [ ! -s "$tmp/err" ] || sed 's/^/  stderr: /' "$tmp/err" >&2
  exit 1
}

printf '#!%s\n' "$bash_bin" > "$tmp/fakebin/adb"
cat >> "$tmp/fakebin/adb" <<'EOF'
set -euo pipefail
# argv: -s SERIAL (shell 'quoted remote' | install ...)
shift 2
if [ "$1" = install ]; then
  echo "install" >> "$T/writes"
  # The install swaps in the post-install dump, when the case provides one.
  for f in "$T"/post.*; do [ -e "$f" ] && mv "$f" "$T/dump.${f##*/post.}"; done
  exit 0
fi
[ "$1" = shell ] || exit 99
cmd=$(printf '%s' "$2" | tr -d "'")
case $cmd in
"getprop ro.product.cpu.abi") echo x86_64 ;;
"pm list packages --show-versioncode --user 0") cat "$T/packages" ;;
"pm list packages -3 --show-versioncode --user 0") cat "$T/packages" ;;
"pm list packages -d --user 0") cat "$T/disabled" ;;
"pm list packages --user 0 "*)
  pkg=${cmd##* }
  grep "^package:$pkg " "$T/packages" | sed 's/ .*//' || true
  ;;
"dumpsys package "*) cat "$T/dump.${cmd##* }" ;;
"ime list -s --user 0" | "cmd deviceidle whitelist") ;;
"pm grant "* | "pm revoke "*)
  echo "$cmd" >> "$T/writes"
  echo "Exception occurred while executing: java.lang.SecurityException: has not requested permission" >&2
  exit 255
  ;;
*) echo "$cmd" >> "$T/writes" ;;
esac
EOF
chmod +x "$tmp/fakebin/adb"
export T=$tmp
touch "$tmp/stub.apk"

pkg=org.example.app
dump() { # $1 = runtime permission lines (8-space indented)
  printf '%s\n' \
    "Packages:" \
    "  Package [$pkg] (1a2b3c):" \
    "    versionCode=5 minSdk=26 targetSdk=34" \
    "    install permissions:" \
    "      android.permission.INTERNET: granted=true" \
    "    User 0: ceDataInode=1 installed=true hidden=false suspended=false enabled=0" \
    "      runtime permissions:"
  [ -z "$1" ] || printf '%s\n' "$1"
}
requested='        android.permission.POST_NOTIFICATIONS: granted=false, flags=[ USER_SET ]'

# Fresh device state + manifest. $1 = jq filter over the base manifest.
setup() {
  rm -f "$tmp"/writes "$tmp"/dump.* "$tmp"/post.* "$tmp/err"
  printf 'package:%s versionCode:5\n' "$pkg" > "$tmp/packages"
  : > "$tmp/disabled"
  dump "$requested" > "$tmp/dump.$pkg"
  jq -n --arg apk "$tmp/stub.apk" '{
    manifestVersion: 4,
    device: {name: "test", user: 0, abi: "x86_64"},
    apps: {cleanup: "none", attended: [], play: [], managed: []},
    android: {
      darkMode: null, disabled: [], deviceidleExempt: [], deviceidleUnexempt: [], roles: {},
      settings: {global: {}, secure: {}, system: {}},
      permissions: {}, appOps: {}, suspended: [], unsuspended: [],
      locales: {}, inputMethod: {enabled: [], disabled: [], default: null},
      dataSaver: {enabled: null}, appLinks: {}
    }
  }' | jq --arg apk "$tmp/stub.apk" --arg pkg "$pkg" "$1" > "$tmp/manifest.json"
}
run() { # extra converge args; sets $status, stdout in $tmp/out
  status=0
  PATH="$tmp/fakebin:$PATH" "$bash_bin" "$converge" "$tmp/manifest.json" \
    --serial fake-serial "$@" >"$tmp/out" 2>"$tmp/err" || status=$?
}
perm() { # grant revoke flags → permissions.<pkg>
  printf '.android.permissions[$pkg] = {grant: %s, revoke: %s, flags: %s}' "$1" "$2" "$3"
}
manage() { printf '.apps.managed = [{package: $pkg, versionCode: 6, apk: $apk}]'; }

# 1. Grant of a non-requested permission on an installed, unchanged package
#    fails the plan, and --apply writes nothing (the queued disable included).
setup "$(perm '["android.permission.CAMERA"]' '[]' '{}') | .android.disabled = [\$pkg]"
run --apply
[ "$status" -eq 1 ] || fail "non-requested grant: expected exit 1, got $status"
grep -Fq "$pkg does not request android.permission.CAMERA" "$tmp/err" \
  || fail "non-requested grant: missing 'does not request' message"
[ ! -e "$tmp/writes" ] || fail "non-requested grant: wrote before failing: $(cat "$tmp/writes")"

# Control: a requested-but-ungranted runtime permission still plans a grant.
setup "$(perm '["android.permission.POST_NOTIFICATIONS"]' '[]' '{}')"
run
[ "$status" -eq 3 ] || fail "requested grant: pending plan should exit 3, got $status"
grep -Fq "grant    $pkg android.permission.POST_NOTIFICATIONS" "$tmp/out" \
  || fail "requested grant: plan line missing"

# 3. Permission flags on a non-requested permission fail the plan.
setup "$(perm '[]' '[]' '{"android.permission.CAMERA": ["user-set"]}')"
run
[ "$status" -eq 1 ] || fail "non-requested flags: expected exit 1, got $status"
grep -Fq "$pkg does not request android.permission.CAMERA" "$tmp/err" \
  || fail "non-requested flags: missing 'does not request' message"

# Revoke of a non-requested permission on an unchanged package is a no-op.
setup "$(perm '[]' '["android.permission.CAMERA"]' '{}')"
run
if [ "$status" -ne 0 ] || ! grep -Fq "device matches manifest" "$tmp/out"; then
  fail "non-requested revoke on unchanged package should be in sync"
fi

# 2. Revoke after an upgrade whose APK does not request the permission: the
#    pm revoke failure is classified as already satisfied, apply completes.
setup "$(manage) | $(perm '[]' '["android.permission.CAMERA"]' '{}')"
dump "" > "$tmp/post.$pkg"
run --apply
[ "$status" -eq 0 ] || fail "post-upgrade revoke: expected exit 0, got $status"
grep -Fq "note: $pkg does not request android.permission.CAMERA; revoke already satisfied" "$tmp/err" \
  || fail "post-upgrade revoke: missing satisfied note"

# Post-upgrade grant of a still-unrequested permission names the cause.
setup "$(manage) | $(perm '["android.permission.CAMERA"]' '[]' '{}')"
dump "" > "$tmp/post.$pkg"
run --apply
[ "$status" -eq 1 ] || fail "post-upgrade grant: expected exit 1, got $status"
grep -Fq "pm grant failed: $pkg does not request android.permission.CAMERA after its install/upgrade" "$tmp/err" \
  || fail "post-upgrade grant: missing 'does not request' message"

# 4. A disabled entry absent from this device is skipped with a note, not a
#    failed plan; a present disabled third-party entry survives cleanup.
setup '.android.disabled = ["com.example.absent", $pkg] | .apps.cleanup = "uninstall"'
printf 'package:%s\n' "$pkg" > "$tmp/disabled"
run
[ "$status" -eq 0 ] || fail "absent disabled: expected exit 0, got $status"
grep -Fq "note: android.packages.disabled: com.example.absent not installed for user 0" "$tmp/err" \
  || fail "absent disabled: missing skip note"
grep -q "^remove" "$tmp/out" && fail "disabled third-party package was queued for cleanup"

echo "test-converge-plan: ok"
