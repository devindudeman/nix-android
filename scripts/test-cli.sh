#!/usr/bin/env bash
# Device-free android-rebuild CLI contract tests (cli-safety check). Runs the
# raw CLI script against fake `nix` and `adb` executables so argument
# forwarding, error messages, and exit codes are pinned without Nix
# evaluation or a device.
set -euo pipefail

src=${1:?usage: test-cli.sh NIX_ANDROID_SRC BASH}
bash_bin=${2:?usage: test-cli.sh NIX_ANDROID_SRC BASH}
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fake=$tmp/bin
mkdir -p "$fake" "$tmp/resolver/bin"

# Fake nix: answers the handful of evals/builds android-rebuild issues and
# logs every call so tests can prove nothing was built.
cat >"$fake/nix" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$FAKE_NIX_LOG"
case "$*" in
*"--apply builtins.attrNames"*) printf '%s\n' "${FAKE_DEVICES:-[\"bench\"]}" ;;
*"inherit (c.device) abi"*)
  echo '{"abi":"x86_64","fdroid":{"packages":["org.example.a"],"repos":{}},"release":{}}' ;;
build*"#update-lock"*) printf '%s\n' "$FAKE_RESOLVER" ;;
*) echo "fake nix: unhandled: $*" >&2; exit 1 ;;
esac
EOF
# Fake resolver: records its argv one per line.
cat >"$tmp/resolver/bin/nix-android-update-lock" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" >"$FAKE_ARGV"
EOF
# Fake adb: only discovery (`adb devices`) is answered; any device-scoped
# call fails the test, since these paths must stop before touching a target.
cat >"$fake/adb" <<'EOF'
#!/usr/bin/env bash
if [ "$*" = devices ]; then
  echo "List of devices attached"
  printf '%b' "${FAKE_ADB_DEVICES:-}"
  exit 0
fi
echo "fake adb: unexpected device call: $*" >&2
exit 99
EOF
for f in "$fake/nix" "$fake/adb" "$tmp/resolver/bin/nix-android-update-lock"; do
  sed -i "1s|.*|#!$bash_bin|" "$f" # the build sandbox has no /usr/bin/env
  chmod +x "$f"
done

cli() {
  NIX_ANDROID_SRC=$src NIX_ANDROID_BASH=$bash_bin PATH="$fake:$PATH" \
    FAKE_RESOLVER=$tmp/resolver FAKE_ARGV=$tmp/argv FAKE_NIX_LOG=$tmp/nix.log \
    "$bash_bin" "$src/scripts/android-rebuild.sh" "$@"
}
fail() { echo "test-cli: $*" >&2; exit 1; }

# update forwards --allow-signer-rotation to the resolver, after --replace.
cli update --flake x#bench --allow-signer-rotation org.example.a >/dev/null
grep -Fxq -- --replace "$tmp/argv" || fail "update did not pass --replace"
grep -A1 -Fx -- --allow-signer-rotation "$tmp/argv" | grep -Fxq org.example.a \
  || fail "update did not forward --allow-signer-rotation PKG"
rc=0; cli plan --flake x#bench --serial s --allow-signer-rotation org.example.a >/dev/null 2>"$tmp/err" || rc=$?
[ "$rc" -eq 2 ] && grep -q 'only valid with update' "$tmp/err" \
  || fail "--allow-signer-rotation outside update: rc=$rc"

# expect RC STDERR-SUBSTRING ARGS...: exit code and a one-line message, never
# a raw jq/Nix error, and no closure build.
expect() {
  local want=$1 msg=$2 rc=0
  shift 2
  : >"$tmp/nix.log"
  cli "$@" >/dev/null 2>"$tmp/err" || rc=$?
  [ "$rc" -eq "$want" ] || fail "$*: exit $rc, want $want: $(cat "$tmp/err")"
  grep -Fq -- "$msg" "$tmp/err" || fail "$*: stderr lacks '$msg': $(cat "$tmp/err")"
  ! grep -Eq '^(jq: error|error:)' "$tmp/err" || fail "$*: leaked a raw error: $(cat "$tmp/err")"
  ! grep -q '^build' "$tmp/nix.log" || fail "$*: built a closure before failing"
}
two='["bench","darwin-smoke"]'
FAKE_DEVICES=$two expect 2 "several devices; pass --flake 'x#NAME' (available: bench, darwin-smoke)" \
  plan --flake x --serial bogus-0000
FAKE_DEVICES=$two expect 2 "no device 'nope'; available: bench, darwin-smoke" \
  plan --flake x#nope --serial bogus-0000
FAKE_DEVICES=$two expect 2 "no device 'nope'" build --flake x#nope
FAKE_ADB_DEVICES='emulator-5554\tdevice\n' expect 1 \
  "adb device 'bogus-0000' not found (attached: emulator-5554)" plan --flake x#bench --serial bogus-0000
expect 1 "not found (attached: none)" switch --flake x#bench --serial bogus-0000
FAKE_ADB_DEVICES='bogus-0000\tunauthorized\n' expect 1 "accept the USB debugging prompt" \
  status --flake x#bench --serial bogus-0000
FAKE_ADB_DEVICES='bogus-0000\toffline\n' expect 1 "is offline" assist --flake x#bench --serial bogus-0000
FAKE_ADB_DEVICES='bogus-0000\trecovery\n' expect 1 "in state 'recovery'" bootstrap --flake x#bench --serial bogus-0000
FAKE_ADB_DEVICES='bogus-0000\toffline\n' expect 1 "is offline" import --serial bogus-0000

echo "android-rebuild CLI contract tests passed"
