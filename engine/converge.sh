#!/usr/bin/env bash
# nix-android converge engine: manifest.json → device, over adb at uid 2000.
#
# PLAN by default (prints what would change, touches nothing); --apply executes.
# Safety posture (docs/PLAN.md): pins are floors — installs and upgrades only,
# never downgrades; removals only when the manifest says cleanup=uninstall.
#
# Usage: converge.sh <manifest.json> [--apply] [--serial <adb-serial>]
#        converge.sh <manifest.json> --validate-only
set -euo pipefail

manifest=${1:?usage: converge.sh <manifest.json> [--apply] [--serial S]}
shift
apply=0
validate_only=0
serial=${ANDROID_SERIAL:-}
while [ $# -gt 0 ]; do
  case $1 in
  --apply) apply=1; shift ;;
  --validate-only) validate_only=1; shift ;;
  --serial)
    [ $# -ge 2 ] || { echo "--serial requires a value" >&2; exit 2; }
    serial=$2; shift 2
    ;;
  *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

# The engine is also a standalone trust boundary. Validate the complete shape
# before the first device read; process-substitution failures do not trigger
# `set -e`, and an empty declaration set must never reach cleanup=uninstall.
if ! jq -e '
  def strings: type == "array" and all(.[]; type == "string");
  def package: type == "string" and test("^[A-Za-z0-9_]+([.][A-Za-z0-9_]+)+\\z");
  def permission: type == "string" and test("^[A-Za-z0-9_.]+\\z");
  def packages: strings and all(.[]; package);
  def is_unique: length == (unique | length);
  (keys == ["android", "apps", "device", "manifestVersion"])
  and .manifestVersion == 2
  and (.device | type == "object"
    and (keys == ["abi", "name", "user"])
    and (.name | type == "string" and test("^[A-Za-z0-9._-]+\\z"))
    and .user == 0
    and (.abi | IN("arm64-v8a", "armeabi-v7a", "x86_64")))
  and (.apps | type == "object"
    and (keys == ["attended", "cleanup", "managed", "play"])
    and (.cleanup | IN("none", "uninstall"))
    and (.attended | packages)
    and (.play | packages)
    and (.managed | type == "array" and all(.[];
      type == "object"
      and (keys == ["apk", "package", "versionCode"])
      and (.package | package)
      and (.versionCode | type == "number" and . >= 0 and floor == .)
      and (.apk | type == "string" and startswith("/")))))
  and (.android | type == "object"
    and (keys == ["darkMode", "deviceidleExempt", "disabled", "permissions", "roles", "settings"])
    and (.darkMode | . == null or type == "boolean")
    and (.disabled | packages)
    and (.deviceidleExempt | packages)
    and (.roles | type == "object" and all(to_entries[];
      (.key | IN("browser", "sms", "dialer", "home"))
      and (.value | package)))
    and (.settings | type == "object"
      and (keys == ["global", "secure", "system"])
      and all(to_entries[];
      (.key | IN("global", "secure", "system"))
      and (.value | type == "object" and all(to_entries[];
        (.key | type == "string" and test("^[A-Za-z0-9_.-]+\\z"))
        and (.value | type == "string" and length > 0 and . != "null"
          and (contains("\u0000") | not)
          and (contains("\n") | not)
          and (contains("\r") | not)
          and (contains("\u001f") | not))))))
    and (.permissions | type == "object" and all(to_entries[];
      (.key | package)
      and (.value | type == "object"
        and (keys == ["grant", "revoke"])
        and (.grant | strings and all(.[]; permission))
        and (.revoke | strings and all(.[]; permission))
        and ((.grant + .revoke) | is_unique)))))
  and (([.apps.managed[].package] + .apps.attended + .apps.play) | is_unique)
' "$manifest" >/dev/null; then
  echo "invalid or unsupported manifest: $manifest" >&2
  exit 2
fi

if [ "$validate_only" -eq 1 ]; then
  [ "$apply" -eq 0 ] || { echo "--validate-only cannot be combined with --apply" >&2; exit 2; }
  exit 0
fi

[ -n "$serial" ] || { echo "converge requires --serial SERIAL (or ANDROID_SERIAL)" >&2; exit 2; }
adb_base=(adb -s "$serial")
# Wrapper: adb MUST read from /dev/null. `adb shell` otherwise drains the
# enclosing `while read` loop's stdin, so only the first item iterates — the
# silent bug behind partial plans. Every adb call goes through this.
adb() { command "${adb_base[@]}" "$@" </dev/null; }
# `adb shell ARG...` joins arguments with spaces before handing them to the
# device shell; local quoting is not preserved. Build one single-quoted remote
# command so spaces and metacharacters remain data.
adb_shell() {
  local arg quoted remote=""
  for arg in "$@"; do
    printf -v quoted "'%s'" "${arg//\'/\'\\\'\'}"
    remote+="${remote:+ }$quoted"
  done
  adb shell "$remote"
}
# Tuple field separator. NOT a tab: `IFS=$'\t' read` treats tab as
# whitespace-class and collapses empty interior fields (an unset `cur` would
# shift `want` out of existence → `settings put key ''`). US (\037) is never
# whitespace and never appears in package names / setting values.
US=$'\037'

user=$(jq -r '.device.user' "$manifest")
[ "$user" = 0 ] || { echo "public v1 supports device.user = 0 only" >&2; exit 2; }
expected_abi=$(jq -r '.device.abi' "$manifest")
actual_abi=$(adb_shell getprop ro.product.cpu.abi | tr -d '\r')
[ "$actual_abi" = "$expected_abi" ] || {
  echo "target ABI mismatch: config expects $expected_abi, $serial reports $actual_abi" >&2
  exit 2
}

# Device reality. Presence assertions include preinstalled/system Play apps;
# destructive cleanup remains limited to third-party owner-user packages.
installed=$(adb_shell pm list packages --show-versioncode --user "$user" | tr -d '\r')
installed_third_party=$(adb_shell pm list packages -3 --show-versioncode --user "$user" | tr -d '\r')
current_code() { # -> versionCode or empty
  local wanted=$1 line package
  while IFS= read -r line; do
    package=${line#package:}
    package=${package%% *}
    if [ "$package" = "$wanted" ]; then
      printf '%s\n' "${line##* versionCode:}"
      return
    fi
  done <<<"$installed"
}

todo_install=()
todo_upgrade=()
todo_remove=()
missing_attended=()
missing_play=()
declare -A declared=()
declare -A managed=()
declare -A presence=()
declare -A changing=()

# F-Droid apps: install missing, upgrade below-floor.
while IFS=$'\t' read -r pkg code apk; do
  declared[$pkg]=1
  managed[$pkg]=1
  cur=$(current_code "$pkg")
  if [ -z "$cur" ]; then
    changing[$pkg]=1
    todo_install+=("${pkg}${US}${code}${US}${apk}")
  elif [ "$cur" -lt "$code" ]; then
    changing[$pkg]=1
    todo_upgrade+=("${pkg}${US}${cur}→${code}${US}${apk}")
  fi
done < <(jq -r '.apps.managed[] | [.package, .versionCode, .apk] | @tsv' "$manifest")

# Attended apps: assert presence only.
while read -r pkg; do
  [ -z "$pkg" ] && continue
  declared[$pkg]=1
  presence[$pkg]=1
  [ -n "$(current_code "$pkg")" ] || missing_attended+=("$pkg")
done < <(jq -r '.apps.attended[]' "$manifest")

# Play apps are still presence assertions, but retain their source identity so
# the CLI can offer an explicit, user-confirmed installation path.
while read -r pkg; do
  [ -z "$pkg" ] && continue
  declared[$pkg]=1
  presence[$pkg]=1
  [ -n "$(current_code "$pkg")" ] || missing_play+=("$pkg")
done < <(jq -r '.apps.play[]' "$manifest")

# Packages referenced by a role/permission/disable/idle option are declarations
# too: cleanup must preserve them. External targets must already exist unless
# their installation is explicitly declared through attended or Play state;
# managed targets may be installed by this run before later actions are applied.
missing_referenced=()
while read -r pkg; do
  [ -z "$pkg" ] && continue
  declared[$pkg]=1
  if [ -z "${managed[$pkg]:-}" ] && [ -z "${presence[$pkg]:-}" ]; then
    package_query=$(adb_shell pm list packages --user "$user" "$pkg" | tr -d '\r')
    grep -Fqx "package:$pkg" <<<"$package_query" || missing_referenced+=("$pkg")
  fi
done < <(jq -r '[.android.disabled[], .android.deviceidleExempt[], (.android.roles | values[]), (.android.permissions | keys[])] | unique[]' "$manifest")

if [ "${#missing_referenced[@]}" -gt 0 ]; then
  printf 'referenced package is neither installed nor declared as an app: %s\n' "${missing_referenced[@]}" >&2
  exit 1
fi

# Cleanup: undeclared user apps (only in uninstall mode).
if [ "$(jq -r '.apps.cleanup' "$manifest")" = "uninstall" ]; then
  while read -r pkg; do
    [ -n "${declared[$pkg]:-}" ] || todo_remove+=("$pkg")
  done < <(sed -n 's/^package:\([^ ]*\) .*/\1/p' <<<"$installed_third_party")
fi

# ---- Phase-2 categories: managed keys only, read → diff → plan → apply ----
todo_setting=()   # base64(JSON [namespace, key, current, wanted])
todo_dark=()      # want (yes|no)
todo_role=()      # roleName \t cur \t wantPkg
todo_disable=()   # pkg
todo_grant=()     # pkg \t perm
todo_revoke=()    # pkg \t perm
todo_idle=()      # pkg

for ns in global secure system; do
  while IFS=$US read -r key want; do
    cur=$(adb_shell settings get --user "$user" "$ns" "$key" | tr -d '\r')
    [ "$cur" = "null" ] && cur=""
    if [ "$cur" != "$want" ]; then
      todo_setting+=("$(jq -cnr --arg ns "$ns" --arg key "$key" --arg cur "$cur" --arg want "$want" \
        '[$ns, $key, $cur, $want] | @base64')")
    fi
  done < <(jq -r --arg ns "$ns" '.android.settings[$ns] // {} | to_entries[] | [.key, .value] | join("\u001f")' "$manifest")
done

dark=$(jq -r '.android.darkMode' "$manifest")
if [ "$dark" != "null" ]; then
  want=$([ "$dark" = "true" ] && echo yes || echo no)
  cur=$(adb_shell cmd uimode night | tr -d '\r' | sed 's/Night mode: //')
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
  cur=$(adb_shell cmd role get-role-holders --user "$user" "$(role_id "$role")" | tr -d '\r')
  [ "$cur" = "$want" ] || todo_role+=("${role}${US}${cur}${US}${want}")
done < <(jq -r '.android.roles // {} | to_entries[] | [.key, .value] | @tsv' "$manifest")

disabled_now=$(adb_shell pm list packages -d --user "$user" | tr -d '\r')
while read -r pkg; do
  [ -z "$pkg" ] && continue
  if ! grep -Fqx "package:$pkg" <<<"$disabled_now"; then
    # only meaningful if the package exists for this user at all
    package_query=$(adb_shell pm list packages --user "$user" "$pkg" | tr -d '\r')
    if grep -Fqx "package:$pkg" <<<"$package_query" \
      || [ -n "${managed[$pkg]:-}" ] || [ -n "${presence[$pkg]:-}" ]; then
      todo_disable+=("$pkg")
    else
      echo "note: android.packages.disabled: $pkg not installed for user $user — skipping" >&2
    fi
  fi
done < <(jq -r '.android.disabled // [] | .[]' "$manifest")

declare -A permission_checked=()
declare -A permission_present=()
declare -A permission_dump=()
# ponytail: permission read = one cached dumpsys per referenced package, then
# grep "<perm>: granted=" — coarse (not per-user-sectioned), fine for the
# single managed user. Replace with a structured API if Android exposes one.
while IFS=$'\t' read -r pkg perm action; do
  if [ -z "${permission_checked[$pkg]+x}" ]; then
    permission_checked[$pkg]=1
    if [ -n "$(current_code "$pkg")" ]; then
      permission_present[$pkg]=1
      permission_dump[$pkg]=$(adb_shell dumpsys package "$pkg" | tr -d '\r')
    else
      permission_present[$pkg]=0
      permission_dump[$pkg]=
    fi
  fi
  package_present=${permission_present[$pkg]}
  granted=$(grep -F -m1 "  $perm: granted=" <<<"${permission_dump[$pkg]}" | sed 's/.*granted=\([a-z]*\).*/\1/' || true)
  if [ "$action" = grant ] && { [ "$granted" != "true" ] || [ -n "${changing[$pkg]:-}" ]; }; then
    todo_grant+=("${pkg}${US}${perm}")
  elif [ "$action" = revoke ] \
    && { [ "$granted" = "true" ] || [ "$package_present" -eq 0 ] || [ -n "${changing[$pkg]:-}" ]; }; then
    # A missing target is either managed or presence-declared: the latter makes
    # the attended/Play preflight below abort before apply. Managed installs and
    # upgrades happen before permissions, so reassert revoke intent afterward.
    todo_revoke+=("${pkg}${US}${perm}")
  fi
done < <(jq -r '.android.permissions // {} | to_entries[] | .key as $p | ((.value.grant[] | [$p, ., "grant"]), (.value.revoke[] | [$p, ., "revoke"])) | @tsv' "$manifest")

idle_now=$(adb_shell cmd deviceidle whitelist | tr -d '\r')
while read -r pkg; do
  [ -z "$pkg" ] && continue
  grep -Fq ",$pkg," <<<"$idle_now" || todo_idle+=("$pkg")
done < <(jq -r '.android.deviceidleExempt // [] | .[]' "$manifest")

plan_lines=$(( ${#todo_install[@]} + ${#todo_upgrade[@]} + ${#todo_remove[@]} \
  + ${#todo_setting[@]} + ${#todo_dark[@]} + ${#todo_role[@]} + ${#todo_disable[@]} \
  + ${#todo_grant[@]} + ${#todo_revoke[@]} + ${#todo_idle[@]} ))
for t in "${todo_install[@]}"; do IFS=$US read -r p c _ <<<"$t"; echo "install  $p ($c)"; done
for t in "${todo_upgrade[@]}"; do IFS=$US read -r p c _ <<<"$t"; echo "upgrade  $p ($c)"; done
for t in "${todo_remove[@]}";  do echo "remove   $t"; done
setting_field() { jq -Rr --argjson i "$2" '@base64d | fromjson | .[$i]' <<<"$1"; }
for t in "${todo_setting[@]}"; do
  ns=$(setting_field "$t" 0) k=$(setting_field "$t" 1)
  c=$(setting_field "$t" 2) w=$(setting_field "$t" 3)
  echo "setting  $ns/$k (${c:-unset} → $w)"
done
for t in "${todo_dark[@]}";    do echo "darkmode → $t"; done
for t in "${todo_role[@]}";    do IFS=$US read -r r c w <<<"$t"; echo "role     $r (${c:-none} → $w)"; done
for t in "${todo_disable[@]}"; do echo "disable  $t"; done
for t in "${todo_grant[@]}";   do IFS=$US read -r p m <<<"$t"; echo "grant    $p $m"; done
for t in "${todo_revoke[@]}";  do IFS=$US read -r p m <<<"$t"; echo "revoke   $p $m"; done
for t in "${todo_idle[@]}";    do echo "idle-ok  $t (battery-optimization exempt)"; done
for p in "${missing_attended[@]}"; do echo "ATTENDED $p — install from its declared human source"; done
for p in "${missing_play[@]}"; do echo "PLAY     $p — run android-rebuild assist"; done

if [ $(( ${#missing_attended[@]} + ${#missing_play[@]} )) -gt 0 ]; then
  echo "✗ ${#missing_attended[@]} attended and ${#missing_play[@]} Play app(s) missing; device does not match manifest" >&2
  exit 1
fi

if [ "$plan_lines" -eq 0 ]; then
  echo "✓ device matches manifest"
  exit 0
fi

if [ "$apply" -eq 0 ]; then
  echo "-- plan only ($plan_lines changes); re-run with --apply"
  exit 0
fi

for t in "${todo_install[@]}" "${todo_upgrade[@]}"; do
  IFS=$US read -r pkg _ apk <<<"$t"
  echo "installing $pkg..."
  adb install -r --user "$user" "$apk" >/dev/null
done
for t in "${todo_setting[@]}"; do
  ns=$(setting_field "$t" 0) k=$(setting_field "$t" 1) w=$(setting_field "$t" 3)
  adb_shell settings put --user "$user" "$ns" "$k" "$w"
done
for t in "${todo_dark[@]}"; do
  adb_shell cmd uimode night "$t" >/dev/null
done
for t in "${todo_role[@]}"; do
  IFS=$US read -r r _ w <<<"$t"
  adb_shell cmd role add-role-holder --user "$user" "$(role_id "$r")" "$w"
done
for pkg in "${todo_disable[@]}"; do
  adb_shell pm disable-user --user "$user" "$pkg" >/dev/null
done
for t in "${todo_grant[@]}"; do
  IFS=$US read -r p m <<<"$t"
  adb_shell pm grant --user "$user" "$p" "$m"
done
for t in "${todo_revoke[@]}"; do
  IFS=$US read -r p m <<<"$t"
  adb_shell pm revoke --user "$user" "$p" "$m"
done
for pkg in "${todo_idle[@]}"; do
  adb_shell cmd deviceidle whitelist "+$pkg" >/dev/null
done
for pkg in "${todo_remove[@]}"; do
  echo "uninstalling $pkg..."
  adb uninstall --user "$user" "$pkg" >/dev/null
done
echo "✓ applied $plan_lines changes"
