#!/usr/bin/env bash
set -euo pipefail

assist=${1:?usage: test-assist-play.sh ASSIST_SCRIPT}
bash_bin=${2:?usage: test-assist-play.sh ASSIST_SCRIPT BASH}
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
mkdir "$tmp/fakebin"

printf '#!%s\n' "$bash_bin" > "$tmp/fakebin/adb"
cat >> "$tmp/fakebin/adb" <<'EOF'
set -euo pipefail
touch "$TEST_CONTACTED"
case $* in
*"getprop"*"ro.product.cpu.abi"*)
  printf '%s\n' x86_64
  ;;
*"pm"*"list"*"packages"*)
  if [ -e "$TEST_PENDING" ]; then
    cat "$TEST_PENDING" >> "$TEST_INSTALLED"
    rm -f "$TEST_PENDING"
  fi
  printf '%s\n' "$TEST_PACKAGES"
  [ ! -e "$TEST_INSTALLED" ] || cat "$TEST_INSTALLED"
  ;;
*"am"*"start-activity"*)
  [ ! -e "$TEST_PENDING" ] || {
    echo "opened another listing before observing the previous install" >&2
    exit 98
  }
  printf '%s\n' "$*" >> "$TEST_LAUNCH"
  if [ "${TEST_AUTO_INSTALL:-0}" -eq 1 ]; then
    [[ $* =~ id=([A-Za-z0-9_.]+) ]]
    package=${BASH_REMATCH[1]}
    printf 'package:%s\n' "$package" > "$TEST_PENDING"
  fi
  ;;
*) exit 99 ;;
esac
EOF
chmod +x "$tmp/fakebin/adb"

manifest() {
  jq -n --argjson play "$1" '{
    manifestVersion: 2,
    device: {user: 0, abi: "x86_64"},
    apps: {play: $play}
  }' > "$tmp/manifest.json"
}

export TEST_CONTACTED=$tmp/contacted TEST_LAUNCH=$tmp/launch
export TEST_INSTALLED=$tmp/installed TEST_PENDING=$tmp/pending
export TEST_PACKAGES=$'package:com.android.vending\npackage:org.example.present'
manifest '["org.example.present"]'
PATH="$tmp/fakebin:$PATH" "$bash_bin" "$assist" "$tmp/manifest.json" --serial fixture \
  | grep -q 'all declared Play apps are installed'
test ! -e "$TEST_LAUNCH"

rm -f "$TEST_CONTACTED"
manifest '["org.example.missing", "org.example.second"]'
PATH="$tmp/fakebin:$PATH" "$bash_bin" "$assist" "$tmp/manifest.json" --serial fixture \
  | grep -q '1 more Play app'
grep -Fq 'https://play.google.com/store/apps/details?id=org.example.missing' "$TEST_LAUNCH"
grep -Fq 'com.android.vending' "$TEST_LAUNCH"
[ "$(wc -l < "$TEST_LAUNCH")" -eq 1 ]

rm -f "$TEST_CONTACTED" "$TEST_LAUNCH" "$TEST_INSTALLED" "$TEST_PENDING"
export TEST_AUTO_INSTALL=1
manifest '["org.example.first", "org.example.second"]'
PATH="$tmp/fakebin:$PATH" "$bash_bin" "$assist" "$tmp/manifest.json" --serial fixture --watch \
  | grep -q 'all declared Play apps are installed'
[ "$(wc -l < "$TEST_LAUNCH")" -eq 2 ]
sed -n '1p' "$TEST_LAUNCH" | grep -Fq 'id=org.example.first'
sed -n '2p' "$TEST_LAUNCH" | grep -Fq 'id=org.example.second'
export TEST_AUTO_INSTALL=0

rm -f "$TEST_CONTACTED" "$TEST_LAUNCH" "$TEST_INSTALLED" "$TEST_PENDING"
manifest '["org.example.timeout"]'
if NIX_ANDROID_ASSIST_TIMEOUT_SECONDS=1 NIX_ANDROID_ASSIST_POLL_SECONDS=1 \
  PATH="$tmp/fakebin:$PATH" "$bash_bin" "$assist" "$tmp/manifest.json" --serial fixture --watch \
  >"$tmp/timeout.out" 2>&1; then
  echo "watch unexpectedly succeeded without an installation" >&2
  exit 1
fi
grep -q 'timed out after 1s waiting for org.example.timeout' "$tmp/timeout.out"
[ "$(wc -l < "$TEST_LAUNCH")" -eq 1 ]

rm -f "$TEST_CONTACTED" "$TEST_LAUNCH" "$TEST_INSTALLED" "$TEST_PENDING"
export TEST_PACKAGES=$'package:com.android.vending\npackage:org.example.present'
manifest '["org.example.missing"]'
jq '.device.abi = "arm64-v8a"' "$tmp/manifest.json" > "$tmp/wrong-abi.json"
if PATH="$tmp/fakebin:$PATH" "$bash_bin" "$assist" "$tmp/wrong-abi.json" --serial fixture \
  >"$tmp/wrong-abi.out" 2>&1; then
  echo "wrong target ABI unexpectedly launched an app" >&2
  exit 1
fi
grep -q 'target ABI mismatch' "$tmp/wrong-abi.out"
test ! -e "$TEST_LAUNCH"

rm -f "$TEST_CONTACTED" "$TEST_LAUNCH" "$TEST_INSTALLED" "$TEST_PENDING"
export TEST_PACKAGES=package:org.example.present
manifest '["org.example.missing"]'
if PATH="$tmp/fakebin:$PATH" "$bash_bin" "$assist" "$tmp/manifest.json" --serial fixture \
  >"$tmp/no-store.out" 2>&1; then
  echo "missing Play Store unexpectedly launched an app" >&2
  exit 1
fi
grep -q 'Google Play Store.*is not installed' "$tmp/no-store.out"
test ! -e "$TEST_LAUNCH"

rm -f "$TEST_CONTACTED" "$TEST_LAUNCH" "$TEST_INSTALLED" "$TEST_PENDING"
manifest '["org.example.bad;touch /tmp/nope"]'
if PATH="$tmp/fakebin:$PATH" "$bash_bin" "$assist" "$tmp/manifest.json" --serial fixture \
  >/dev/null 2>&1; then
  echo "unsafe Play package unexpectedly accepted" >&2
  exit 1
fi
test ! -e "$TEST_CONTACTED"
