#!/usr/bin/env bash
# nix-android converge engine: manifest.json → device, over adb at uid 2000.
#
# PLAN by default (prints what would change, touches nothing); --apply executes.
# Safety posture (docs/PLAN.md): pins are floors — installs and upgrades only,
# never downgrades; removals only when the manifest says cleanup=uninstall.
#
# Usage: converge.sh <manifest.json> [--apply] [--serial <adb-serial>]
set -euo pipefail

manifest=${1:?usage: converge.sh <manifest.json> [--apply] [--serial S]}
shift
apply=0
serial=${ANDROID_SERIAL:-}
while [ $# -gt 0 ]; do
  case $1 in
  --apply) apply=1; shift ;;
  --serial) serial=$2; shift 2 ;;
  *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

adb_base=(adb)
[ -n "$serial" ] && adb_base=(adb -s "$serial")
# Wrapper: adb MUST read from /dev/null. `adb shell` otherwise drains the
# enclosing `while read` loop's stdin, so only the first item iterates — the
# silent bug behind partial plans. Every adb call goes through this.
adb() { command "${adb_base[@]}" "$@" </dev/null; }
# Tuple field separator. NOT a tab: `IFS=$'\t' read` treats tab as
# whitespace-class and collapses empty interior fields (an unset `cur` would
# shift `want` out of existence → `settings put key ''`). US (\037) is never
# whitespace and never appears in package names / setting values.
US=$'\037'
user=$(jq -r '.device.user' "$manifest")

# Device reality: user-installed packages with versionCodes.
installed=$(adb shell pm list packages -3 --show-versioncode --user "$user" | tr -d '\r')
current_code() { # -> versionCode or empty
  sed -n "s/^package:$1 versionCode:\([0-9]*\).*/\1/p" <<<"$installed" | head -1
}

todo_install=()
todo_upgrade=()
todo_remove=()
missing_attended=()
declare -A declared=()

# F-Droid apps: install missing, upgrade below-floor.
while IFS=$'\t' read -r pkg code apk; do
  declared[$pkg]=1
  cur=$(current_code "$pkg")
  if [ -z "$cur" ]; then
    todo_install+=("$pkg"$US"$code"$US"$apk")
  elif [ "$cur" -lt "$code" ]; then
    todo_upgrade+=("$pkg"$US"$cur→$code"$US"$apk")
  fi
done < <(jq -r '.apps.managed[] | [.package, .versionCode, .apk] | @tsv' "$manifest")

# Attended apps: assert presence only.
while read -r pkg; do
  [ -z "$pkg" ] && continue
  declared[$pkg]=1
  [ -n "$(current_code "$pkg")" ] || missing_attended+=("$pkg")
done < <(jq -r '.apps.attended[]' "$manifest")

# Cleanup: undeclared user apps (only in uninstall mode).
if [ "$(jq -r '.apps.cleanup' "$manifest")" = "uninstall" ]; then
  while read -r pkg; do
    [ -n "${declared[$pkg]:-}" ] || todo_remove+=("$pkg")
  done < <(sed -n 's/^package:\([^ ]*\) .*/\1/p' <<<"$installed")
fi

# ---- Phase-2 categories: managed keys only, read → diff → plan → apply ----
todo_setting=()   # ns \t key \t cur \t want
todo_dark=()      # want (yes|no)
todo_role=()      # roleName \t cur \t wantPkg
todo_disable=()   # pkg
todo_grant=()     # pkg \t perm
todo_revoke=()    # pkg \t perm
todo_idle=()      # pkg

for ns in global secure system; do
  while IFS=$'\t' read -r key want; do
    cur=$(adb shell settings get "$ns" "$key" | tr -d '\r')
    [ "$cur" = "null" ] && cur=""
    [ "$cur" = "$want" ] || todo_setting+=("$ns"$US"$key"$US"$cur"$US"$want")
  done < <(jq -r --arg ns "$ns" '.android.settings[$ns] // {} | to_entries[] | [.key, .value] | @tsv' "$manifest")
done

dark=$(jq -r '.android.darkMode' "$manifest")
if [ "$dark" != "null" ]; then
  want=$([ "$dark" = "true" ] && echo yes || echo no)
  cur=$(adb shell cmd uimode night | tr -d '\r' | sed 's/Night mode: //')
  [ "$cur" = "$want" ] || todo_dark+=("$want")
fi

role_id() { # browser|sms|dialer|home → android role id
  case $1 in
  browser) echo android.app.role.BROWSER ;;
  sms) echo android.app.role.SMS ;;
  dialer) echo android.app.role.DIALER ;;
  home) echo android.app.role.HOME ;;
  esac
}
while IFS=$'\t' read -r role want; do
  cur=$(adb shell cmd role get-role-holders --user "$user" "$(role_id "$role")" | tr -d '\r')
  [ "$cur" = "$want" ] || todo_role+=("$role"$US"$cur"$US"$want")
done < <(jq -r '.android.roles // {} | to_entries[] | [.key, .value] | @tsv' "$manifest")

disabled_now=$(adb shell pm list packages -d --user "$user" | tr -d '\r')
while read -r pkg; do
  [ -z "$pkg" ] && continue
  if ! grep -q "^package:$pkg$" <<<"$disabled_now"; then
    # only meaningful if the package exists for this user at all
    if adb shell pm list packages --user "$user" "$pkg" | tr -d '\r' | grep -q "^package:$pkg$"; then
      todo_disable+=("$pkg")
    else
      echo "note: android.packages.disabled: $pkg not installed for user $user — skipping" >&2
    fi
  fi
done < <(jq -r '.android.disabled // [] | .[]' "$manifest")

# ponytail: permission read = grep dumpsys for "<perm>: granted=" — coarse
# (not per-user-sectioned), fine for the single managed user; ceiling noted.
while IFS=$'\t' read -r pkg perm action; do
  granted=$(adb shell dumpsys package "$pkg" | tr -d '\r' | grep -m1 "  $perm: granted=" | sed 's/.*granted=\([a-z]*\).*/\1/' || true)
  if [ "$action" = grant ] && [ "$granted" != "true" ]; then
    todo_grant+=("$pkg"$US"$perm")
  elif [ "$action" = revoke ] && [ "$granted" = "true" ]; then
    todo_revoke+=("$pkg"$US"$perm")
  fi
done < <(jq -r '.android.permissions // {} | to_entries[] | .key as $p | ((.value.grant[] | [$p, ., "grant"]), (.value.revoke[] | [$p, ., "revoke"])) | @tsv' "$manifest")

idle_now=$(adb shell cmd deviceidle whitelist | tr -d '\r')
while read -r pkg; do
  [ -z "$pkg" ] && continue
  grep -q ",$pkg," <<<"$idle_now" || todo_idle+=("$pkg")
done < <(jq -r '.android.deviceidleExempt // [] | .[]' "$manifest")

plan_lines=$(( ${#todo_install[@]} + ${#todo_upgrade[@]} + ${#todo_remove[@]} \
  + ${#todo_setting[@]} + ${#todo_dark[@]} + ${#todo_role[@]} + ${#todo_disable[@]} \
  + ${#todo_grant[@]} + ${#todo_revoke[@]} + ${#todo_idle[@]} ))
for t in "${todo_install[@]}"; do IFS=$US read -r p c _ <<<"$t"; echo "install  $p ($c)"; done
for t in "${todo_upgrade[@]}"; do IFS=$US read -r p c _ <<<"$t"; echo "upgrade  $p ($c)"; done
for t in "${todo_remove[@]}";  do echo "remove   $t"; done
for t in "${todo_setting[@]}"; do IFS=$US read -r ns k c w <<<"$t"; echo "setting  $ns/$k (${c:-unset} → $w)"; done
for t in "${todo_dark[@]}";    do echo "darkmode → $t"; done
for t in "${todo_role[@]}";    do IFS=$US read -r r c w <<<"$t"; echo "role     $r (${c:-none} → $w)"; done
for t in "${todo_disable[@]}"; do echo "disable  $t"; done
for t in "${todo_grant[@]}";   do IFS=$US read -r p m <<<"$t"; echo "grant    $p $m"; done
for t in "${todo_revoke[@]}";  do IFS=$US read -r p m <<<"$t"; echo "revoke   $p $m"; done
for t in "${todo_idle[@]}";    do echo "idle-ok  $t (battery-optimization exempt)"; done
for p in "${missing_attended[@]}"; do echo "ATTENDED $p — install by hand (Play/Aurora)"; done

if [ "$plan_lines" -eq 0 ]; then
  echo "✓ device matches manifest (${#missing_attended[@]} attended missing)"
  exit 0
fi

if [ "$apply" -eq 0 ]; then
  echo "-- plan only ($plan_lines changes); re-run with --apply"
  exit 0
fi

for t in "${todo_install[@]}" "${todo_upgrade[@]}"; do
  IFS=$US read -r pkg _ apk <<<"$t"
  echo "installing $pkg…"
  adb install -r --user "$user" "$apk" >/dev/null
done
for pkg in "${todo_remove[@]}"; do
  echo "uninstalling $pkg…"
  adb uninstall --user "$user" "$pkg" >/dev/null
done
for t in "${todo_setting[@]}"; do
  IFS=$US read -r ns k _ w <<<"$t"
  adb shell settings put "$ns" "$k" "$w"
done
for t in "${todo_dark[@]}"; do
  adb shell cmd uimode night "$t" >/dev/null
done
for t in "${todo_role[@]}"; do
  IFS=$US read -r r _ w <<<"$t"
  adb shell cmd role add-role-holder --user "$user" "$(role_id "$r")" "$w"
done
for pkg in "${todo_disable[@]}"; do
  adb shell pm disable-user --user "$user" "$pkg" >/dev/null
done
for t in "${todo_grant[@]}"; do
  IFS=$US read -r p m <<<"$t"
  adb shell pm grant --user "$user" "$p" "$m"
done
for t in "${todo_revoke[@]}"; do
  IFS=$US read -r p m <<<"$t"
  adb shell pm revoke --user "$user" "$p" "$m"
done
for pkg in "${todo_idle[@]}"; do
  adb shell cmd deviceidle whitelist "+$pkg" >/dev/null
done
echo "✓ applied $plan_lines changes"
