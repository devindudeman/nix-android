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
  local old_boot=${1:-} deadline=$((SECONDS + 300)) boot pm netpolicy
  while [ "$SECONDS" -lt "$deadline" ]; do
    boot=$(adb shell cat /proc/sys/kernel/random/boot_id 2>/dev/null | tr -d '\r' || true)
    pm=$(adb shell pm path android 2>/dev/null || true)
    netpolicy=$(adb shell cmd netpolicy get restrict-background 2>/dev/null || true)
    if [ -n "$boot" ] && [ "$boot" != "$old_boot" ] \
      && [ "$(adb shell getprop sys.boot_completed 2>/dev/null | tr -d '\r' || true)" = 1 ] \
      && grep -q '^package:' <<<"$pm" \
      && grep -q '^Restrict background status:' <<<"$netpolicy"; then
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

# The oracle reads the device through the engine's own parsers so the two
# sides cannot silently drift. Because a shared parser bug would make the
# implementation and the oracle agree incorrectly, every shared parser is
# pinned against raw-output golden fixtures first (also a `just check` gate).
bash "$(dirname "${BASH_SOURCE[0]}")/test-read-state.sh" >/dev/null
# shellcheck source-path=SCRIPTDIR/../engine
# shellcheck source=read-state.sh
source "$(dirname "${BASH_SOURCE[0]}")/../engine/read-state.sh"

verify_state() {
  local manifest=$1 pkg want got ns key permission role dump packages line found component domain links selected enabled_imes
  local want_csv raw_flags appop_output user_state install_state
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
    # A declared grant is satisfied by runtime state (user block) or by an
    # already-granted install-time permission (package block).
    dump=$(adb shell dumpsys package "$pkg" | tr -d '\r')
    user_state=$(permission_user_block 0 <<<"$dump") \
      || { echo "cannot read user 0 package state for $pkg" >&2; return 1; }
    install_state=$(install_permission_block <<<"$dump")
    grep -Fq "  $permission: granted=true" <<<"$user_state"$'\n'"$install_state"
  done < <(jq -r '.android.permissions | to_entries[] | .key as $p | .value.grant[] | [$p, .] | @tsv' "$manifest")
  while IFS=$'\t' read -r pkg permission; do
    dump=$(adb shell dumpsys package "$pkg" | tr -d '\r' | permission_user_block 0)
    if grep -F -m1 "  $permission: granted=true" <<<"$dump" >/dev/null; then
      echo "$pkg unexpectedly has $permission" >&2
      return 1
    fi
  done < <(jq -r '.android.permissions | to_entries[] | .key as $p | .value.revoke[] | [$p, .] | @tsv' "$manifest")
  while IFS=$'\t' read -r pkg permission want_csv; do
    dump=$(adb shell dumpsys package "$pkg" | tr -d '\r' | permission_user_block 0)
    raw_flags=$(grep -F -m1 "  $permission: granted=" <<<"$dump" \
      | sed -n 's/.*flags=\[ *\([^]]*\) *\].*/\1/p')
    got=$(writable_flags_csv "$raw_flags")
    [ "$got" = "$want_csv" ] \
      || { echo "permission flags $pkg $permission: got '$got', want '$want_csv'" >&2; return 1; }
  done < <(jq -r '.android.permissions | to_entries[] | .key as $p | .value.flags | to_entries[] | [$p, .key, (.value | sort | join(","))] | @tsv' "$manifest")
  while IFS=$'\t' read -r pkg operation mode; do
    appop_output=$(adb shell appops get --user 0 "$pkg" "$operation" | tr -d '\r')
    got=$(appop_mode_from_output "$operation" <<<"$appop_output") \
      || { echo "unable to read app-op $pkg $operation" >&2; return 1; }
    [ "$got" = "$mode" ] || { echo "app-op $pkg $operation: got '$got', want '$mode'" >&2; return 1; }
  done < <(jq -r '.android.appOps | to_entries[] | .key as $p | .value | to_entries[] | [$p, .key, .value] | @tsv' "$manifest")
  while read -r pkg; do
    packages=$(adb shell cmd deviceidle whitelist | tr -d '\r')
    grep -Fq ",$pkg," <<<"$packages"
  done < <(jq -r '.android.deviceidleExempt[]' "$manifest")
  while read -r pkg; do
    [ -z "$pkg" ] && continue
    packages=$(adb shell cmd deviceidle whitelist | tr -d '\r')
    if grep -Eq "^user,$pkg," <<<"$packages"; then
      echo "unexempt package $pkg is still user-battery-whitelisted" >&2
      return 1
    fi
  done < <(jq -r '.android.deviceidleUnexempt // [] | .[]' "$manifest")
  while IFS=$'\t' read -r role pkg; do
    got=$(adb shell cmd role get-role-holders --user 0 "$(role_id "$role")" | tr -d '\r')
    [ "$got" = "$pkg" ] || { echo "role $role: got '$got', want '$pkg'" >&2; return 1; }
  done < <(jq -r '.android.roles | to_entries[] | [.key, .value] | @tsv' "$manifest")
  while read -r pkg; do
    dump=$(adb shell dumpsys package "$pkg" | tr -d '\r')
    has_shell_suspension_in_dump 0 <<<"$dump" \
      || { echo "$pkg not suspended by adb shell" >&2; return 1; }
  done < <(jq -r '.android.suspended[]' "$manifest")
  while read -r pkg; do
    dump=$(adb shell dumpsys package "$pkg" | tr -d '\r')
    if has_shell_suspension_in_dump 0 <<<"$dump"; then
      echo "$pkg remained suspended by adb shell" >&2
      return 1
    fi
  done < <(jq -r '.android.unsuspended[]' "$manifest")
  while IFS=$'\t' read -r pkg want; do
    got=$(adb shell cmd locale get-app-locales "$pkg" --user 0 | tr -d '\r' \
      | sed -n 's/^Locales for .* for user 0 are \[\(.*\)\]$/\1/p')
    [ "$got" = "$want" ] || { echo "locales $pkg: got '$got', want '$want'" >&2; return 1; }
  done < <(jq -r '.android.locales | to_entries[] | [.key, (.value | join(","))] | @tsv' "$manifest")
  enabled_imes=$(adb shell ime list -s --user 0 | tr -d '\r')
  while read -r component; do
    grep -Fqx "$component" <<<"$enabled_imes"
  done < <(jq -r '.android.inputMethod.enabled[]' "$manifest")
  while read -r component; do
    if grep -Fqx "$component" <<<"$enabled_imes"; then
      echo "input method remained enabled: $component" >&2
      return 1
    fi
  done < <(jq -r '.android.inputMethod.disabled[]' "$manifest")
  want=$(jq -r '.android.inputMethod.default' "$manifest")
  if [ "$want" != null ]; then
    got=$(adb shell settings get --user 0 secure default_input_method | tr -d '\r')
    [ "$got" = "$want" ] || { echo "default input method: got '$got', want '$want'" >&2; return 1; }
  fi
  want=$(jq -r '.android.dataSaver.enabled' "$manifest")
  if [ "$want" != null ]; then
    [ "$want" = true ] && want=enabled || want=disabled
    got=$(adb shell cmd netpolicy get restrict-background | tr -d '\r' \
      | sed -n 's/^Restrict background status: //p')
    [ "$got" = "$want" ] || { echo "Data Saver: got '$got', want '$want'" >&2; return 1; }
  fi
  while IFS=$'\t' read -r pkg want; do
    links=$(adb shell pm get-app-links --user 0 "$pkg" | tr -d '\r')
    if [ "$want" != null ]; then
      got=$(sed -n 's/^      Verification link handling allowed: //p' <<<"$links")
      [ "$got" = "$want" ] || { echo "app links allowed $pkg: got '$got', want '$want'" >&2; return 1; }
    fi
    selected=$(app_link_selected_domains <<<"$links")
    while read -r domain; do
      grep -Fqx "$domain" <<<"$selected"
    done < <(jq -r --arg p "$pkg" '.android.appLinks[$p].selected[]' "$manifest")
    while read -r domain; do
      if grep -Fqx "$domain" <<<"$selected"; then
        echo "app link remained selected: $pkg $domain" >&2
        return 1
      fi
    done < <(jq -r --arg p "$pkg" '.android.appLinks[$p].unselected[]' "$manifest")
  done < <(jq -r '.android.appLinks | to_entries[] | [.key, (.value.allowed | tostring)] | @tsv' "$manifest")
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

  # Use a private test key as the write sentinel. Android's power manager can
  # asynchronously normalize stay_on_while_plugged_in during early boot.
  adb shell settings put --user 0 global nix_android_quote_test preflight-sentinel
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
  grep -q '1 attended and 0 Play app(s) missing' "$tmp/missing-attended-$run.out"
  while read -r pkg; do
    packages=$(adb shell pm list packages --user 0 "$pkg" | tr -d '\r')
    if grep -Fqx "package:$pkg" <<<"$packages"; then
      echo "$pkg was installed by a failed preflight" >&2
      exit 1
    fi
  done < <(jq -r '.apps.managed[].package' "$manifest")
  got=$(adb shell settings get --user 0 global nix_android_quote_test | tr -d '\r')
  [ "$got" = preflight-sentinel ] || { echo "failed attended preflight wrote nix_android_quote_test=$got" >&2; exit 1; }

  jq '
    .apps.play += ["org.example.play"] |
    .android.disabled += ["org.example.play"] |
    .android.deviceidleExempt += ["org.example.play"] |
    .android.permissions."org.example.play" = {
      grant: ["android.permission.POST_NOTIFICATIONS"], revoke: [], flags: {}
    }
  ' "$manifest" > "$tmp/missing-play-$run.json"
  if bash engine/converge.sh "$tmp/missing-play-$run.json" --apply --serial "$serial" \
    > "$tmp/missing-play-$run.out" 2>&1; then
    echo "missing Play package unexpectedly applied" >&2
    exit 1
  fi
  grep -q 'PLAY     org.example.play' "$tmp/missing-play-$run.out"
  grep -q 'disable  org.example.play' "$tmp/missing-play-$run.out"
  grep -q 'grant    org.example.play android.permission.POST_NOTIFICATIONS' "$tmp/missing-play-$run.out"
  grep -q 'idle-ok  org.example.play' "$tmp/missing-play-$run.out"
  grep -q '1 Play app(s) missing' "$tmp/missing-play-$run.out"
  got=$(adb shell settings get --user 0 global nix_android_quote_test | tr -d '\r')
  [ "$got" = preflight-sentinel ] || { echo "failed Play preflight wrote nix_android_quote_test=$got" >&2; exit 1; }

  # Current device values are untrusted too. A Unit Separator used to corrupt
  # the engine's internal tuple even though desired values correctly reject it.
  adb shell settings put --user 0 global nix_android_quote_test $'current\037value'

  plan=$(nix run .#android-rebuild --accept-flake-config -- plan --flake .#bench --serial "$serial")
  grep -q -- '-- plan only (' <<<"$plan" || { echo "fresh device unexpectedly had no plan" >&2; exit 1; }
  # On a wiped device every managed app is a fresh install, so its grants are
  # reasserted after that install — plan must annotate the induced effect.
  grep -q 'grant    org.fdroid.fdroid android.permission.POST_NOTIFICATIONS (after install)' <<<"$plan" \
    || { echo "fresh-device plan did not annotate the install-induced grant" >&2; exit 1; }
  # bootstrap must record exactly one generation (its final phase), never the
  # reduced phase-one scaffold — an interrupted bootstrap must not leave a
  # partial manifest as the latest converged state.
  gen_log="${XDG_STATE_HOME:-$HOME/.local/state}/nix-android/bench/log.jsonl"
  gens_before=$( [ -f "$gen_log" ] && wc -l <"$gen_log" || echo 0)
  nix run .#android-rebuild --accept-flake-config -- bootstrap --flake .#bench --serial "$serial"
  gens_after=$( [ -f "$gen_log" ] && wc -l <"$gen_log" || echo 0)
  [ "$((gens_after - gens_before))" -eq 1 ] \
    || { echo "bootstrap recorded $((gens_after - gens_before)) generations; only the final phase may record" >&2; exit 1; }
  verify_state "$manifest"
  [ "$(nix run .#android-rebuild --accept-flake-config -- plan --flake .#bench --serial "$serial")" = "✓ device matches manifest" ]

  # Ensure-absent exercise: seed the (now installed) unexempt package into the
  # USER whitelist; converge must plan and apply the removal, and the rest of
  # the cycle (inverse, reboot, no-op) keeps it removed via verify_state.
  while read -r pkg; do
    [ -z "$pkg" ] && continue
    adb shell cmd deviceidle whitelist "+$pkg" >/dev/null
  done < <(jq -r '.android.deviceidleUnexempt // [] | .[]' "$manifest")
  unexempt_out=$(bash engine/converge.sh "$manifest" --apply --serial "$serial")
  grep -q 'idle-no  org.fdroid.fdroid' <<<"$unexempt_out" \
    || { echo "seeded unexempt package did not plan an idle-no removal" >&2; exit 1; }
  verify_state "$manifest"
  [ "$(nix run .#android-rebuild --accept-flake-config -- plan --flake .#bench --serial "$serial")" = "✓ device matches manifest" ]

  # Exercise every safe inverse branch, persist it, then restore the declared
  # bench state. The second IME is a reproducible managed APK, so both
  # selection and disablement are real mutations rather than preexisting state.
  jq '
    .android.permissions."org.fdroid.fdroid".flags."android.permission.POST_NOTIFICATIONS" = [] |
    .android.permissions."com.termux".flags."android.permission.POST_NOTIFICATIONS" = [] |
    .android.appOps."org.fdroid.fdroid".RUN_IN_BACKGROUND = "default" |
    .android.appOps."com.termux".VIBRATE = "default" |
    .android.suspended = [] |
    .android.unsuspended = ["dev.imranr.obtainium.fdroid"] |
    .android.locales."org.fdroid.fdroid" = [] |
    .android.inputMethod = {
      enabled: ["com.android.inputmethod.latin/.LatinIME"],
      disabled: ["helium314.keyboard/.latin.LatinIME"],
      default: "com.android.inputmethod.latin/.LatinIME"
    } |
    .android.dataSaver.enabled = false |
    .android.appLinks."org.fdroid.fdroid" = {
      allowed: true, selected: [], unselected: ["f-droid.org"]
    }
  ' "$manifest" > "$tmp/inverse-$run.json"
  bash engine/converge.sh "$tmp/inverse-$run.json" --apply --serial "$serial"
  verify_state "$tmp/inverse-$run.json"
  [ "$(bash engine/converge.sh "$tmp/inverse-$run.json" --serial "$serial")" = "✓ device matches manifest" ]
  inverse_boot=$(adb shell cat /proc/sys/kernel/random/boot_id | tr -d '\r')
  adb shell svc power reboot userrequested || true
  wait_ready "$inverse_boot" >/dev/null
  verify_state "$tmp/inverse-$run.json"
  [ "$(bash engine/converge.sh "$tmp/inverse-$run.json" --serial "$serial")" = "✓ device matches manifest" ]
  bash engine/converge.sh "$manifest" --apply --serial "$serial"
  verify_state "$manifest"
  [ "$(bash engine/converge.sh "$manifest" --serial "$serial")" = "✓ device matches manifest" ]

  # A Play declaration must protect an installed third-party package from
  # explicit cleanup even though no APK is attached to that declaration.
  jq '.apps.play += [.apps.managed[0].package] |
    .apps.managed = .apps.managed[1:] | .apps.cleanup = "uninstall"' \
    "$manifest" > "$tmp/play-cleanup-$run.json"
  [ "$(bash engine/converge.sh "$tmp/play-cleanup-$run.json" --serial "$serial")" = "✓ device matches manifest" ]

  old_boot=$(adb shell cat /proc/sys/kernel/random/boot_id | tr -d '\r')
  # adbd may disconnect before returning the command status. The new boot ID
  # below is the authoritative proof that the request was accepted.
  adb shell svc power reboot userrequested || true
  wait_ready "$old_boot" >/dev/null
  verify_state "$manifest"
  [ "$(nix run .#android-rebuild --accept-flake-config -- plan --flake .#bench --serial "$serial")" = "✓ device matches manifest" ]

  # Import must survive the real AOSP package proto and represent every
  # managed-user third-party app conservatively as Play or attended.
  imported=$tmp/imported-$run.nix
  snapshot=$tmp/snapshot-$run.json
  coverage=$tmp/coverage-$run.json
  nix run .#android-rebuild --accept-flake-config -- \
    import --serial "$serial" --snapshot-out "$snapshot" --report-out "$coverage" > "$imported"
  jq -e '.schemaVersion == 2 and .device.abi == "x86_64"' "$snapshot" >/dev/null
  jq -e '
    .schemaVersion == 1
    and (.summary | keys == ["ambiguous", "declarable", "observed-only", "unreachable"])
    and ([.facts[].status] | all(. == "ambiguous" or . == "declarable" or . == "observed-only" or . == "unreachable"))
    and ((.device | has("serial")) | not)
  ' "$coverage" >/dev/null
  jq -S '[.packages[] | select(.thirdPartyForManagedUser) | .name]' \
    "$snapshot" > "$tmp/snapshot-attended-$run.json"
  nix eval --impure --json --expr \
    "let c = import $imported; in c.apps.attended ++ c.apps.play" \
    > "$tmp/generated-attended-$run.json"
  jq -S 'sort' "$tmp/generated-attended-$run.json" > "$tmp/generated-attended-sorted-$run.json"
  cmp "$tmp/snapshot-attended-$run.json" "$tmp/generated-attended-sorted-$run.json"
  imported_manifest=$(nix build --no-link --print-out-paths --impure --expr "
    let
      project = builtins.getFlake (toString ./.);
      device = project.lib.mkDevice {
        system = \"x86_64-linux\";
        modules = [ (import $imported) ];
        lockFile = builtins.toFile \"import-roundtrip-lock.json\" (builtins.toJSON {
          abi = \"x86_64\";
          lockedAt = 0;
          packages = {};
        });
      };
    in device.manifest")
  [ "$(bash engine/converge.sh "$imported_manifest" --serial "$serial")" = "✓ device matches manifest" ]

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

echo "✓ $runs fresh emulator cycles passed bootstrap, reboot persistence, no-op, and cleanup"
