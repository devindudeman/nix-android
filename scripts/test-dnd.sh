#!/usr/bin/env bash
# Fake-device tests for the Do Not Disturb primitive (android.doNotDisturb.mode).
# No phone is enumerated or changed. The fake keeps one number, Settings.Global.zen_mode,
# and implements `cmd notification set_dnd`; it can also model a device without that command
# and a device that silently ignores writes (what Android does to a shell `settings put`).
# Real values come from the AOSP bench (Android 15, 2026-10-06): set_dnd priority -> 1,
# alarms -> 3, none -> 2, off -> 0, with the setting and the system's own state in agreement.
set -euo pipefail

src=${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}
bash_bin=${2:-$(command -v bash)}
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
fail() { echo "test-dnd: $1" >&2; exit 1; }

# --- pure parsers -------------------------------------------------------------
# shellcheck source-path=SCRIPTDIR/../engine
# shellcheck source=../engine/read-state.sh
source "$src/engine/read-state.sh"
for pair in '0:off' 'null:off' '1:priority' '2:total' '3:alarms' $'1\r:priority' ' 3 :alarms'; do
  got=$(printf '%s\n' "${pair%%:*}" | zen_mode_name)
  [ "$got" = "${pair#*:}" ] || fail "zen_mode_name '${pair%%:*}' gave '$got', wanted '${pair#*:}'"
done
for bad in '' '4' '-1' 'on' '1 2' 'Error: boom' '1;rm'; do
  if printf '%s\n' "$bad" | zen_mode_name >/dev/null; then fail "zen_mode_name accepted '$bad'"; fi
done
[ "$(dnd_command_argument off)" = off ] && [ "$(dnd_command_argument priority)" = priority ] \
  && [ "$(dnd_command_argument alarms)" = alarms ] && [ "$(dnd_command_argument total)" = none ] \
  || fail 'dnd_command_argument mapping is wrong'
for bad in none on all '' 'off;reboot'; do
  if dnd_command_argument "$bad" >/dev/null; then fail "dnd_command_argument accepted '$bad'"; fi
done

# --- the engine against a stateful fake ------------------------------------------
export TEST_LOG=$tmp/adb.log TEST_ZEN=$tmp/zen TEST_WRITES=$tmp/writes
fake="$tmp/fake adb"
printf '#!%s\n' "$bash_bin" > "$fake"
cat >> "$fake" <<'FAKE'
set -euo pipefail
[ "$1" = -s ] && [ "$2" = fixture ] || exit 92
shift 2
printf '%s\n' "$*" >> "$TEST_LOG"
case $* in
*ro.product.cpu.abi*) printf 'x86_64\n' ;;
*"'cmd' 'notification' 'help'"*)
  if [ "${TEST_NO_DND:-0}" = 1 ]; then printf '/system/bin/sh: cmd: not found\n'; exit 127; fi
  printf 'usage: cmd notification SUBCMD [args]\n  set_dnd [on|none (same as on)|priority|alarms|all|off (same as all)]\n  allow_dnd PACKAGE\n'
  ;;
*"'settings' 'get' '--user' '0' 'global' 'zen_mode'"*) cat "$TEST_ZEN" ;;
*"'cmd' 'notification' 'set_dnd' "*)
  all=$*; arg=${all##* }; arg=${arg//\'/}
  printf '%s\n' "$arg" >> "$TEST_WRITES"
  [ "${TEST_IGNORE_WRITES:-0}" = 1 ] && exit 0
  case $arg in off | all) echo 0 ;; priority) echo 1 ;; none | on) echo 2 ;; alarms) echo 3 ;; *) echo "fake: bad dnd argument '$arg'" >&2; exit 93 ;; esac > "$TEST_ZEN"
  ;;
*) exit 99 ;;
esac
FAKE
chmod +x "$fake"
export NIX_ANDROID_ADB="$fake"

jq -n '{
  manifestVersion: 6, device: {name: "test", abi: "x86_64", user: 0},
  apps: {cleanup: "none", attended: [], play: [], managed: [], reown: false},
  android: {
    settings: {global: {}, secure: {}, system: {}}, darkMode: null,
    roles: {}, disabled: [], suspended: [], unsuspended: [], permissions: {},
    appOps: {}, locales: {}, inputMethod: {enabled: [], disabled: [], default: null},
    dataSaver: {enabled: null}, appLinks: {}, deviceidleExempt: [], deviceidleUnexempt: [],
    doNotDisturb: {mode: null}
  }
}' > "$tmp/base.json"
with_mode() { jq --arg m "$1" '.android.doNotDisturb.mode = $m' "$tmp/base.json" > "$tmp/$1.json"; }
converge() { "$bash_bin" "$src/engine/converge.sh" "$@" --serial fixture; }
reset() { : > "$TEST_LOG"; : > "$TEST_WRITES"; printf '%s\n' "$1" > "$TEST_ZEN"; }
writes() { paste -sd, "$TEST_WRITES"; }

# 1. every (current, wanted) pair: plan is read-only, apply writes once with the right argument, a second apply is a no-op
for want in off priority alarms total; do
  with_mode "$want"
  case $want in off) want_value=0 arg=off ;; priority) want_value=1 arg=priority ;; alarms) want_value=3 arg=alarms ;; total) want_value=2 arg=none ;; esac
  for start in 0 1 2 3; do
    [ "$start" != "$want_value" ] || continue
    case $start in 0) from=off ;; 1) from=priority ;; 2) from=total ;; 3) from=alarms ;; esac
    reset "$start"
    # a pending plan exits 3 (exit-code contract, USING.md)
    status=0; converge "$tmp/$want.json" > "$tmp/plan" || status=$?
    [ "$status" -eq 3 ] || fail "plan for $from -> $want: expected exit 3, got $status"
    grep -Fxq "dnd      ($from → $want)" "$tmp/plan" || fail "plan for $from -> $want: $(cat "$tmp/plan")"
    [ -z "$(writes)" ] || fail "plan wrote: $(writes)"
    converge "$tmp/$want.json" --apply > /dev/null
    [ "$(writes)" = "$arg" ] || fail "$from -> $want issued '$(writes)', wanted '$arg'"
    [ "$(cat "$TEST_ZEN")" = "$want_value" ] || fail "state after $from -> $want is $(cat "$TEST_ZEN")"
    converge "$tmp/$want.json" --apply > "$tmp/second"
    grep -Fq 'device matches manifest' "$tmp/second" || fail "second apply for $want was not a no-op"
    [ "$(wc -l < "$TEST_WRITES")" -eq 1 ] || fail "second apply wrote again for $want"
  done
done

# 2. an unset key means off (the framework default): off on `null` is converged, and costs no write
with_mode off; reset null
converge "$tmp/off.json" --apply > "$tmp/out"
grep -Fq 'device matches manifest' "$tmp/out" || fail 'off on an unset key was not converged'
[ -z "$(writes)" ] || fail 'off on an unset key wrote'

# 3. unmanaged (null): no Do Not Disturb traffic at all
reset 1
converge "$tmp/base.json" --apply > /dev/null
! grep -Fq notification "$TEST_LOG" || fail 'an unmanaged mode still touched cmd notification'
! grep -Fq zen_mode "$TEST_LOG" || fail 'an unmanaged mode still read zen_mode'

# 4. an unreadable state fails the plan and writes nothing
with_mode priority
for bad in '' '9' 'Error: boom'; do
  reset "$bad"
  status=0; converge "$tmp/priority.json" > /dev/null 2> "$tmp/err" || status=$?
  [ "$status" -ne 0 ] || fail "unreadable state '$bad' accepted"
  grep -Fq 'unable to read Do Not Disturb state' "$tmp/err" || fail "no diagnostic for '$bad': $(cat "$tmp/err")"
  [ -z "$(writes)" ] || fail "unreadable state '$bad' wrote"
done

# 5. a device without the command fails loudly, never "applies" a change it cannot make
reset 0
status=0; TEST_NO_DND=1 converge "$tmp/priority.json" --apply > /dev/null 2> "$tmp/err" || status=$?
[ "$status" -ne 0 ] || fail 'a device without set_dnd was accepted'
grep -Fq "needs 'cmd notification set_dnd'" "$tmp/err" || fail "no diagnostic: $(cat "$tmp/err")"
[ -z "$(writes)" ] || fail 'wrote on a device without set_dnd'
# ...but a device without it is untouched when the mode is unmanaged
TEST_NO_DND=1 converge "$tmp/base.json" > /dev/null || fail 'an unmanaged mode needlessly required set_dnd'

# 6. a device that silently ignores the write is not reported as converged
reset 0
TEST_IGNORE_WRITES=1 converge "$tmp/priority.json" --apply > /dev/null
converge "$tmp/priority.json" > "$tmp/after"
grep -Fxq 'dnd      (off → priority)' "$tmp/after" || fail 'an ignored write was reported as converged'

# 7. validation: bad modes and a missing key are rejected before any device contact
for expr in '.android.doNotDisturb.mode = "none"' '.android.doNotDisturb.mode = "Priority"' '.android.doNotDisturb.mode = 1' \
  'del(.android.doNotDisturb)' '.android.doNotDisturb.extra = true' '.android.doNotDisturb = null' '.manifestVersion = 4'; do
  jq "$expr" "$tmp/priority.json" > "$tmp/bad.json"
  : > "$TEST_LOG"
  status=0; converge "$tmp/bad.json" > /dev/null 2>&1 || status=$?
  [ "$status" -eq 2 ] || fail "'$expr' was not rejected as invalid (status $status)"
  [ ! -s "$TEST_LOG" ] || fail "'$expr' reached the device"
done

# 8. older manifests (no doNotDisturb, version 4) still plan, and never touch the new primitive
jq 'del(.android.doNotDisturb) | .manifestVersion = 4' "$tmp/base.json" > "$tmp/v4.json"
reset 1
converge "$tmp/v4.json" > "$tmp/v4plan"
grep -Fq 'device matches manifest' "$tmp/v4plan" || fail 'a version-4 manifest no longer plans'
! grep -Fq notification "$TEST_LOG" || fail 'a version-4 manifest touched cmd notification'

echo 'Do Not Disturb checks passed'
