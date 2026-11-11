#!/usr/bin/env bash
# Device-free android-rebuild CLI contract tests (cli-safety check). Runs the
# raw CLI script and engine against fake `nix` and `adb` executables so
# argument forwarding, error messages, and the exit-code contract are pinned
# without Nix evaluation or a device.
set -euo pipefail

src=${1:?usage: test-cli.sh NIX_ANDROID_SRC BASH}
bash_bin=${2:?usage: test-cli.sh NIX_ANDROID_SRC BASH}
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fake=$tmp/bin
mkdir -p "$fake" "$tmp/resolver/bin" "$tmp/converge/bin"

# Fake nix: answers the handful of evals/builds android-rebuild issues and
# logs every call so tests can prove nothing was built.
cat >"$fake/nix" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$FAKE_NIX_LOG"
case "$*" in
*"--apply builtins.attrNames"*) printf '%s\n' "${FAKE_DEVICES:-[\"bench\"]}" ;;
*"c.device.name"*) echo bench ;;
*"inherit (c.device) abi"*)
  echo '{"abi":"x86_64","fdroid":{"packages":["org.example.a"],"repos":{}},"release":{}}' ;;
build*"#update-lock"*) printf '%s\n' "$FAKE_RESOLVER" ;;
build*".converge "*) printf '%s\n' "$FAKE_CONVERGE" ;;
*) echo "fake nix: unhandled: $*" >&2; exit 1 ;;
esac
EOF
# Fake resolver: records its argv one per line.
cat >"$tmp/resolver/bin/nix-android-update-lock" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" >"$FAKE_ARGV"
EOF
# Fake converge package: the real engine bound to a fixture manifest.
cat >"$tmp/converge/bin/nix-android-converge-bench" <<'EOF'
#!/usr/bin/env bash
exec "$FAKE_BASH" "$FAKE_SRC/engine/converge.sh" "$FAKE_MANIFEST" "$@"
EOF
# Fake adb: `adb devices` lists FAKE_ADB_DEVICES; shell reads describe an
# empty x86_64 device whose settings are all unset. Every call is logged.
cat >"$fake/adb" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$FAKE_ADB_LOG"
if [ "$*" = devices ]; then
  echo "List of devices attached"
  printf '%b' "${FAKE_ADB_DEVICES:-}"
  exit 0
fi
[ "$1" = -s ] && shift 2
[ "$1" = shell ] || exit 99
shift
case "$*" in
*getprop*) echo x86_64 ;;
*"'settings' 'get'"*) echo null ;;
*"'pm' 'list' 'packages' '-3'"*) printf '%b' "${FAKE_ADB_THIRD_PARTY:-}" ;;
*"'settings' 'put'"* | *"'pm' 'list' 'packages'"* | *"'ime' 'list'"* | *deviceidle*) ;;
*) echo "fake adb: unhandled shell $*" >&2; exit 99 ;;
esac
EOF
for f in "$fake/nix" "$fake/adb" "$tmp/resolver/bin/nix-android-update-lock" \
  "$tmp/converge/bin/nix-android-converge-bench"; do
  sed -i "1s|.*|#!$bash_bin|" "$f" # the build sandbox has no /usr/bin/env
  chmod +x "$f"
done

export FAKE_RESOLVER=$tmp/resolver FAKE_ARGV=$tmp/argv FAKE_NIX_LOG=$tmp/nix.log \
  FAKE_ADB_LOG=$tmp/adb.log FAKE_CONVERGE=$tmp/converge FAKE_BASH=$bash_bin FAKE_SRC=$src \
  XDG_STATE_HOME=$tmp/state
cli() {
  NIX_ANDROID_SRC=$src NIX_ANDROID_BASH=$bash_bin PATH="$fake:$PATH" \
    "$bash_bin" "$src/scripts/android-rebuild.sh" "$@"
}
engine() { PATH="$fake:$PATH" "$bash_bin" "$src/engine/converge.sh" "$@"; }
fail() { echo "test-cli: $*" >&2; exit 1; }

# update forwards --allow-signer-rotation to the resolver, after --replace.
cli update --flake x#bench --allow-signer-rotation org.example.a >/dev/null
grep -Fxq -- --replace "$tmp/argv" || fail "update did not pass --replace"
grep -A1 -Fx -- --allow-signer-rotation "$tmp/argv" | grep -Fxq org.example.a \
  || fail "update did not forward --allow-signer-rotation PKG"

# expect RC OUTPUT-SUBSTRING COMMAND...: exit code plus a message on stdout or
# stderr, never a raw jq/Nix error.
expect() {
  local want=$1 msg=$2 rc=0
  shift 2
  : >"$tmp/nix.log"
  : >"$tmp/adb.log"
  "$@" >"$tmp/out" 2>&1 || rc=$?
  [ "$rc" -eq "$want" ] || fail "$*: exit $rc, want $want: $(cat "$tmp/out")"
  grep -Fq -- "$msg" "$tmp/out" || fail "$*: output lacks '$msg': $(cat "$tmp/out")"
  ! grep -Eq '^(jq: error|error:)' "$tmp/out" || fail "$*: leaked a raw error: $(cat "$tmp/out")"
}
# ...and stopped before building a closure or touching the device.
untouched() {
  ! grep -q '^build' "$tmp/nix.log" || fail "built a closure before failing"
  ! grep -vqx devices "$tmp/adb.log" || fail "made a device-scoped adb call: $(cat "$tmp/adb.log")"
}

# Usage errors: exit 2.
expect 2 'only valid with update' cli plan --flake x#bench --serial s --allow-signer-rotation org.example.a
expect 2 '--serial is not valid with generations' cli generations --flake x#bench --serial s
expect 2 '--serial is not valid with build' cli build --flake x#bench --serial s
expect 2 'unknown arg' cli plan --flake x#bench --serial s --bogus

# Device selection: one line, exit 2, nothing built or contacted.
two='["bench","darwin-smoke"]'
FAKE_DEVICES=$two expect 2 "several devices; pass --flake 'x#NAME' (available: bench, darwin-smoke)" \
  cli plan --flake x --serial bogus-0000
untouched
FAKE_DEVICES=$two expect 2 "no device 'nope'; available: bench, darwin-smoke" \
  cli plan --flake x#nope --serial bogus-0000
untouched
FAKE_DEVICES=$two expect 2 "no device 'nope'" cli build --flake x#nope
untouched

# adb state of the named serial: one-line hint, exit 1, before any build.
FAKE_ADB_DEVICES='emulator-5554\tdevice\n' expect 1 \
  "adb device 'bogus-0000' not found (attached: emulator-5554)" cli plan --flake x#bench --serial bogus-0000
untouched
expect 1 "not found (attached: none)" cli switch --flake x#bench --serial bogus-0000
untouched
FAKE_ADB_DEVICES='bogus-0000\tunauthorized\n' expect 1 "accept the USB debugging prompt" \
  cli status --flake x#bench --serial bogus-0000
untouched
FAKE_ADB_DEVICES='bogus-0000\toffline\n' expect 1 "is offline" cli assist --flake x#bench --serial bogus-0000
untouched
FAKE_ADB_DEVICES='bogus-0000\trecovery\n' expect 1 "in state 'recovery'" \
  cli bootstrap --flake x#bench --serial bogus-0000
untouched
FAKE_ADB_DEVICES='bogus-0000\toffline\n' expect 1 "is offline" cli import --serial bogus-0000
untouched

# Exit-code contract on the engine: 0 in sync, 3 pending, 4 blocked, 0 applied.
jq -n '{
  manifestVersion: 4,
  device: {name: "bench", user: 0, abi: "x86_64"},
  apps: {cleanup: "none", attended: [], play: [], managed: []},
  android: {
    darkMode: null, disabled: [], deviceidleExempt: [], deviceidleUnexempt: [], roles: {},
    settings: {global: {}, secure: {}, system: {}},
    permissions: {}, appOps: {}, suspended: [], unsuspended: [],
    locales: {}, inputMethod: {enabled: [], disabled: [], default: null},
    dataSaver: {enabled: null}, appLinks: {}
  }
}' >"$tmp/sync.json"
jq '.android.settings.global.nix_android_test = "1"' "$tmp/sync.json" >"$tmp/one.json"
jq '.android.settings.global.nix_android_other = "2"' "$tmp/one.json" >"$tmp/two.json"
jq '.apps.play = ["org.example.play"]' "$tmp/one.json" >"$tmp/play.json"
jq '.apps.attended = ["org.example.attended"]' "$tmp/sync.json" >"$tmp/attended.json"
expect 0 '✓ device matches manifest' engine "$tmp/sync.json" --serial bogus-0000
# shellcheck disable=SC2016 # literal backticks in the expected message
expect 3 '-- plan only (1 change); run `android-rebuild switch` to apply' engine "$tmp/one.json" --serial bogus-0000
expect 3 '-- plan only (2 changes)' engine "$tmp/two.json" --serial bogus-0000
expect 4 '0 attended and 1 Play app(s) missing' engine "$tmp/play.json" --serial bogus-0000
expect 4 '1 attended and 0 Play app(s) missing' engine "$tmp/attended.json" --apply --serial bogus-0000
! grep -q "'settings' 'put'" "$tmp/adb.log" || fail "blocked apply wrote to the device"
expect 0 '✓ applied 1 change' engine "$tmp/one.json" --apply --serial bogus-0000
# Advisory notes print after the plan lines and before the verdict, even when
# the run is blocked.
jq '.apps.cleanup = "report"' "$tmp/play.json" >"$tmp/report.json"
FAKE_ADB_THIRD_PARTY='package:org.example.extra versionCode:1\n' expect 4 \
  'note: undeclared third-party package: org.example.extra' engine "$tmp/report.json" --serial bogus-0000
[ "$(grep -oE '^(setting|PLAY|note|✗)' "$tmp/out" | paste -sd' ' -)" = "setting PLAY note ✗" ] \
  || fail "notes out of plan order: $(cat "$tmp/out")"
expect 2 'unknown arg' engine "$tmp/one.json" --serial bogus-0000 --bogus
expect 2 'invalid or unsupported manifest' engine <(echo '{}') --serial bogus-0000

# ...and through the CLI, including status/generations with nothing recorded.
export FAKE_ADB_DEVICES='bogus-0000\tdevice\n'
expect 1 "no generations recorded for 'bench'" cli generations --flake x#bench
expect 1 "no recorded convergence for 'bench'" cli status --flake x#bench --serial bogus-0000
FAKE_MANIFEST=$tmp/one.json expect 3 '-- plan only (1 change)' cli plan --flake x#bench --serial bogus-0000
FAKE_MANIFEST=$tmp/play.json expect 4 'Play app(s) missing' cli switch --flake x#bench --serial bogus-0000
FAKE_MANIFEST=$tmp/one.json expect 0 '✓ applied 1 change' cli switch --flake x#bench --serial bogus-0000
expect 0 'generation 1' cli generations --flake x#bench
# The fake device never keeps the write, so the recorded generation drifts.
expect 3 '-- plan only (1 change)' cli status --flake x#bench --serial bogus-0000

echo "android-rebuild CLI contract tests passed"
