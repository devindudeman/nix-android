#!/usr/bin/env bash
# Repeat the full mutation/persistence gate on fresh emulator userdata.
set -Eeuo pipefail

runs=${1:-2}
[[ $runs =~ ^[1-9][0-9]*$ ]] || { echo "runs must be a positive integer" >&2; exit 2; }
serial=emulator-5554
tmp=$(mktemp -d)
launcher_pid=
log=

on_error() {
  local rc=$1 line=$2
  trap - ERR
  set +e
  echo "bench-e2e failed at line $line (rc=$rc); stack: ${FUNCNAME[*]} / ${BASH_LINENO[*]}" >&2
  command adb devices -l >&2
  [ -z "$log" ] || tail -80 "$log" >&2
  exit "$rc"
}
trap 'on_error $? $LINENO' ERR

adb() { command adb -s "$serial" "$@" </dev/null; }
cleanup() {
  trap - ERR
  set +e
  adb emu kill >/dev/null 2>&1
  if [ -n "$launcher_pid" ]; then
    kill "$launcher_pid" 2>/dev/null
    wait "$launcher_pid" 2>/dev/null
  fi
  rm -rf -- "$tmp"
}
trap cleanup EXIT
trap 'exit 130' HUP INT TERM

wait_ready() {
  local old_boot=${1:-} deadline=$((SECONDS + 300)) boot pm
  while [ "$SECONDS" -lt "$deadline" ]; do
    boot=$(adb shell cat /proc/sys/kernel/random/boot_id 2>/dev/null | tr -d '\r' || true)
    pm=$(adb shell pm path android 2>/dev/null || true)
    if [ -n "$boot" ] && [ "$boot" != "$old_boot" ] \
      && [ "$(adb shell getprop sys.boot_completed 2>/dev/null | tr -d '\r' || true)" = 1 ] \
      && grep -q '^package:' <<<"$pm"; then
      adb shell cmd package wait-for-handler --timeout 60000 >/dev/null
      printf '%s\n' "$boot"
      return
    fi
    kill -0 "$launcher_pid" 2>/dev/null || {
      echo "emulator launcher exited before readiness" >&2
      tail -80 "$log" >&2
      return 1
    }
    sleep 2
  done
  echo "emulator readiness timed out after five minutes" >&2
  tail -80 "$log" >&2
  return 1
}

role_id() {
  case $1 in
  browser) echo android.app.role.BROWSER ;;
  sms) echo android.app.role.SMS ;;
  dialer) echo android.app.role.DIALER ;;
  home) echo android.app.role.HOME ;;
  esac
}

verify_state() {
  local manifest=$1 pkg want got ns key permission role dump packages line found
  while IFS=$'\t' read -r pkg want; do
    packages=$(adb shell pm list packages --show-versioncode --user 0 "$pkg" | tr -d '\r')
    got=
    while IFS= read -r line; do
      found=${line#package:}
      found=${found%% *}
      [ "$found" = "$pkg" ] && got=${line##* versionCode:}
    done <<<"$packages"
    [ "$got" = "$want" ] || { echo "$pkg versionCode: got '$got', want '$want'" >&2; return 1; }
  done < <(jq -r '.apps.managed[] | [.package, (.versionCode | tostring)] | @tsv' "$manifest")

  while IFS=$'\037' read -r ns key want; do
    got=$(adb shell settings get --user 0 "$ns" "$key" | tr -d '\r')
    [ "$got" = "$want" ] || { echo "$ns/$key: got '$got', want '$want'" >&2; return 1; }
  done < <(jq -r '.android.settings | to_entries[] as $ns | $ns.value | to_entries[] | [$ns.key, .key, .value] | join("\u001f")' "$manifest")
  if adb shell test -e /data/local/tmp/nix_android_injected; then
    echo "setting value executed as shell syntax" >&2
    return 1
  fi

  want=$(jq -r '.android.darkMode' "$manifest")
  if [ "$want" != null ]; then
    [ "$want" = true ] && want=yes || want=no
    got=$(adb shell cmd uimode night | tr -d '\r' | sed 's/^Night mode: //')
    [ "$got" = "$want" ] || { echo "dark mode: got '$got', want '$want'" >&2; return 1; }
  fi

  while read -r pkg; do
    packages=$(adb shell pm list packages -d --user 0 | tr -d '\r')
    grep -Fqx "package:$pkg" <<<"$packages"
  done < <(jq -r '.android.disabled[]' "$manifest")
  while IFS=$'\t' read -r pkg permission; do
    dump=$(adb shell dumpsys package "$pkg" | tr -d '\r')
    grep -F -m1 "  $permission: granted=true" <<<"$dump" >/dev/null
  done < <(jq -r '.android.permissions | to_entries[] | .key as $p | .value.grant[] | [$p, .] | @tsv' "$manifest")
  while IFS=$'\t' read -r pkg permission; do
    dump=$(adb shell dumpsys package "$pkg" | tr -d '\r')
    if grep -F -m1 "  $permission: granted=true" <<<"$dump" >/dev/null; then
      echo "$pkg unexpectedly has $permission" >&2
      return 1
    fi
  done < <(jq -r '.android.permissions | to_entries[] | .key as $p | .value.revoke[] | [$p, .] | @tsv' "$manifest")
  while read -r pkg; do
    packages=$(adb shell cmd deviceidle whitelist | tr -d '\r')
    grep -Fq ",$pkg," <<<"$packages"
  done < <(jq -r '.android.deviceidleExempt[]' "$manifest")
  while IFS=$'\t' read -r role pkg; do
    got=$(adb shell cmd role get-role-holders --user 0 "$(role_id "$role")" | tr -d '\r')
    [ "$got" = "$pkg" ] || { echo "role $role: got '$got', want '$pkg'" >&2; return 1; }
  done < <(jq -r '.android.roles | to_entries[] | [.key, .value] | @tsv' "$manifest")
}

devices=$(adb devices)
if grep -q "^${serial}[[:space:]]" <<<"$devices"; then
  echo "$serial is already running; stop it before the repeatability gate" >&2
  exit 1
fi
manifest=$(nix build .#androidConfigurations.bench.manifest --accept-flake-config --no-link --print-out-paths)

for run in $(seq 1 "$runs"); do
  echo "== fresh emulator cycle $run/$runs =="
  root_file=$tmp/root-$run
  log=$tmp/emulator-$run.log
  NIX_ANDROID_RUN_ROOT_FILE=$root_file nix run .#emulator --accept-flake-config >"$log" 2>&1 &
  launcher_pid=$!
  wait_ready >/dev/null

  adb shell settings put --user 0 global stay_on_while_plugged_in 77
  jq '.device.abi = "arm64-v8a"' "$manifest" > "$tmp/wrong-abi-$run.json"
  if bash engine/converge.sh "$tmp/wrong-abi-$run.json" --apply --serial "$serial" \
    >"$tmp/wrong-abi-$run.out" 2>&1; then
    echo "ABI mismatch unexpectedly applied" >&2
    exit 1
  fi
  grep -q 'target ABI mismatch' "$tmp/wrong-abi-$run.out"

  jq '.apps.attended += ["org.example.missing"]' "$manifest" > "$tmp/missing-attended-$run.json"
  if bash engine/converge.sh "$tmp/missing-attended-$run.json" --apply --serial "$serial" \
    >"$tmp/missing-attended-$run.out" 2>&1; then
    echo "missing attended package unexpectedly applied" >&2
    exit 1
  fi
  grep -q 'attended app(s) missing' "$tmp/missing-attended-$run.out"
  while read -r pkg; do
    packages=$(adb shell pm list packages --user 0 "$pkg" | tr -d '\r')
    if grep -Fqx "package:$pkg" <<<"$packages"; then
      echo "$pkg was installed by a failed preflight" >&2
      exit 1
    fi
  done < <(jq -r '.apps.managed[].package' "$manifest")
  got=$(adb shell settings get --user 0 global stay_on_while_plugged_in | tr -d '\r')
  [ "$got" = 77 ] || { echo "failed preflight wrote stay_on_while_plugged_in=$got" >&2; exit 1; }

  # Current device values are untrusted too. A Unit Separator used to corrupt
  # the engine's internal tuple even though desired values correctly reject it.
  adb shell settings put --user 0 global nix_android_quote_test $'current\037value'

  plan=$(nix run .#android-rebuild --accept-flake-config -- plan --flake .#bench --serial "$serial")
  grep -q -- '-- plan only (' <<<"$plan" || { echo "fresh device unexpectedly had no plan" >&2; exit 1; }
  nix run .#android-rebuild --accept-flake-config -- switch --flake .#bench --serial "$serial"
  verify_state "$manifest"
  [ "$(nix run .#android-rebuild --accept-flake-config -- plan --flake .#bench --serial "$serial")" = "✓ device matches manifest" ]

  old_boot=$(adb shell cat /proc/sys/kernel/random/boot_id | tr -d '\r')
  # adbd may disconnect before returning the command status. The new boot ID
  # below is the authoritative proof that the request was accepted.
  adb shell svc power reboot userrequested || true
  wait_ready "$old_boot" >/dev/null
  verify_state "$manifest"
  [ "$(nix run .#android-rebuild --accept-flake-config -- plan --flake .#bench --serial "$serial")" = "✓ device matches manifest" ]

  # Import must survive the real AOSP package proto and represent every
  # managed-user third-party app conservatively as attended.
  imported=$tmp/imported-$run.nix
  snapshot=$tmp/snapshot-$run.json
  nix run .#android-rebuild --accept-flake-config -- \
    import --serial "$serial" --snapshot-out "$snapshot" > "$imported"
  jq -e '.schemaVersion == 1 and .device.abi == "x86_64"' "$snapshot" >/dev/null
  jq -S '[.packages[] | select(.thirdPartyForManagedUser) | .name]' \
    "$snapshot" > "$tmp/snapshot-attended-$run.json"
  nix eval --impure --json --expr "(import $imported).apps.attended" \
    > "$tmp/generated-attended-$run.json"
  jq -S . "$tmp/generated-attended-$run.json" > "$tmp/generated-attended-sorted-$run.json"
  cmp "$tmp/snapshot-attended-$run.json" "$tmp/generated-attended-sorted-$run.json"

  run_root=$(cat "$root_file")
  adb emu kill >/dev/null
  wait "$launcher_pid"
  launcher_pid=
  [ ! -e "$run_root" ] || { echo "emulator userdata leaked at $run_root" >&2; exit 1; }
  deadline=$((SECONDS + 30))
  while [ "$SECONDS" -lt "$deadline" ]; do
    devices=$(adb devices)
    grep -q "^${serial}[[:space:]]" <<<"$devices" || break
    sleep 1
  done
  devices=$(adb devices)
  if grep -q "^${serial}[[:space:]]" <<<"$devices"; then
    echo "$serial remained attached after teardown" >&2
    exit 1
  fi
done

echo "✓ $runs fresh emulator cycles passed apply, reboot persistence, no-op, and cleanup"
