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

# Fake nix: answers the handful of evals/builds android-rebuild issues.
cat >"$fake/nix" <<'EOF'
#!/usr/bin/env bash
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
for f in "$fake/nix" "$tmp/resolver/bin/nix-android-update-lock"; do
  sed -i "1s|.*|#!$bash_bin|" "$f" # the build sandbox has no /usr/bin/env
  chmod +x "$f"
done

cli() {
  NIX_ANDROID_SRC=$src NIX_ANDROID_BASH=$bash_bin PATH="$fake:$PATH" \
    FAKE_RESOLVER=$tmp/resolver FAKE_ARGV=$tmp/argv \
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

echo "android-rebuild CLI contract tests passed"
