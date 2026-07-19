#!/usr/bin/env bash
# nix-android converge engine: manifest.json → device, over adb at uid 2000.
#
# PLAN by default (prints what would change, touches nothing); --apply executes.
# Safety posture (docs/PLAN.md): pins are floors — installs and upgrades only,
# never downgrades; removals only when the manifest says cleanup=uninstall.
#
# Usage: converge.sh <manifest.json> [--apply] [--record] [--serial <adb-serial>]
#        converge.sh <manifest.json> --validate-only
#
# --record (only valid with --apply) writes a generation receipt. It is opt-in
# so intermediate applies — notably bootstrap's reduced phase-one manifest —
# never register as the latest converged state; only a full switch or bootstrap's
# final phase records.
set -euo pipefail

manifest=${1:?usage: converge.sh <manifest.json> [--apply] [--serial S]}
shift
apply=0
record=0
validate_only=0
serial=${ANDROID_SERIAL:-}
while [ $# -gt 0 ]; do
  case $1 in
  --apply) apply=1; shift ;;
  --record) record=1; shift ;;
  --validate-only) validate_only=1; shift ;;
  --serial)
    [ $# -ge 2 ] || { echo "--serial requires a value" >&2; exit 2; }
    serial=$2; shift 2
    ;;
  *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done
[ "$record" -eq 0 ] || [ "$apply" -eq 1 ] || { echo "--record requires --apply" >&2; exit 2; }

# Shared device-output parsers (also sourced by the bench oracle so the two
# sides cannot drift). Defines writable_permission_flags.
# shellcheck source-path=SCRIPTDIR
# shellcheck source=read-state.sh
source "$(dirname "${BASH_SOURCE[0]}")/read-state.sh"
writable_permission_flags_json=$(printf '%s\n' "${writable_permission_flags[@]}" | jq -cRn '[inputs]')

# The engine is also a standalone trust boundary. Validate the complete shape
# before the first device read; process-substitution failures do not trigger
# `set -e`, and an empty declaration set must never reach cleanup=uninstall.
if ! jq -e --argjson writableFlags "$writable_permission_flags_json" '
  def strings: type == "array" and all(.[]; type == "string");
  def package: type == "string" and test("^[A-Za-z0-9_]+([.][A-Za-z0-9_]+)+\\z");
  def permission: type == "string" and test("^[A-Za-z0-9_.]+\\z");
  def appop: type == "string" and test("^[A-Z][A-Z0-9_]*\\z");
  def component: type == "string" and test("^[A-Za-z0-9_]+([.][A-Za-z0-9_]+)+/[.]?[A-Za-z0-9_$]+([.][A-Za-z0-9_$]+)*\\z");
  def locale: type == "string" and length <= 100 and test("^[a-z]{2,8}(-[A-Z][a-z]{3})?(-([A-Z]{2}|[0-9]{3}))?(-([a-z0-9]{5,8}|[0-9][a-z0-9]{3}))*(-[0-9a-wy-z](-[a-z0-9]{2,8})+)*(-x(-[a-z0-9]{1,8})+)?\\z");
  def domain: type == "string" and length <= 253 and test("^(\\*\\.)?[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?([.][a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)+\\z");
  def packages: strings and all(.[]; package);
  def is_unique: length == (unique | length);
  (keys == ["android", "apps", "device", "manifestVersion"])
  and (.manifestVersion == 3 or .manifestVersion == 4)
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
    and (keys == ["appLinks", "appOps", "darkMode", "dataSaver", "deviceidleExempt", "disabled", "inputMethod", "locales", "permissions", "roles", "settings", "suspended", "unsuspended"]
      or keys == ["appLinks", "appOps", "darkMode", "dataSaver", "deviceidleExempt", "deviceidleUnexempt", "disabled", "inputMethod", "locales", "permissions", "roles", "settings", "suspended", "unsuspended"])
    and (.darkMode | . == null or type == "boolean")
    and (.disabled | packages and is_unique)
    and (.suspended | packages and is_unique)
    and (.unsuspended | packages and is_unique)
    and ((.suspended + .unsuspended) | is_unique)
    and (.deviceidleExempt | packages and is_unique)
    and ((.deviceidleUnexempt // []) | packages and is_unique)
    and ((.deviceidleExempt + (.deviceidleUnexempt // [])) | is_unique)
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
        and (keys == ["flags", "grant", "revoke"])
        and (.grant | strings and all(.[]; permission))
        and (.revoke | strings and all(.[]; permission))
        and ((.grant + .revoke) | is_unique)
        and (.flags | type == "object" and all(to_entries[];
          (.key | permission)
          and (.value | strings and is_unique and all(.[];
            IN($writableFlags[]))))))))
    and (.appOps | type == "object" and all(to_entries[];
      (.key | package)
      and (.value | type == "object" and all(to_entries[];
        (.key | appop)
        and (.value | IN("allow", "ignore", "deny", "default", "foreground"))))))
    and (.locales | type == "object" and all(to_entries[];
      (.key | package) and (.value | strings and is_unique and all(.[]; locale))))
    and (.inputMethod | type == "object"
      and (keys == ["default", "disabled", "enabled"])
      and (.default | . == null or component)
      and (.enabled | strings and is_unique and all(.[]; component))
      and (.disabled | strings and is_unique and all(.[]; component))
      and ((.enabled + .disabled) | is_unique)
      and (.default as $default | $default == null or (.enabled | index($default)) != null))
    and (.dataSaver | type == "object"
      and (keys == ["enabled"])
      and (.enabled | . == null or type == "boolean"))
    and (.appLinks | type == "object" and all(to_entries[];
      (.key | package)
      and (.value | type == "object"
        and (keys == ["allowed", "selected", "unselected"])
        and (.allowed | . == null or type == "boolean")
        and (.selected | strings and is_unique and all(.[]; domain))
        and (.unselected | strings and is_unique and all(.[]; domain))
        and ((.selected + .unselected) | is_unique))))
    and ([.appLinks[].selected[]] | is_unique))
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

# record_generation: writes a switch receipt so `status` can report drift.
# shellcheck source-path=SCRIPTDIR
# shellcheck source=generations.sh
source "$(dirname "${BASH_SOURCE[0]}")/generations.sh"
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
    # Value doubles as the induced-effect verb for plan annotation; every other
    # reader tests it with `-n`, so a non-empty string keeps that behaviour.
    changing[$pkg]=install
    todo_install+=("${pkg}${US}${code}${US}${apk}")
  elif [ "$cur" -lt "$code" ]; then
    changing[$pkg]=upgrade
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
done < <(jq -r '
  [
    .android.disabled[], .android.suspended[], .android.unsuspended[],
    .android.deviceidleExempt[],
    (.android.roles | values[]),
    (.android.permissions | keys[]),
    (.android.appOps | keys[]),
    (.android.locales | keys[]),
    (.android.appLinks | keys[]),
    ((.android.inputMethod.enabled + .android.inputMethod.disabled
      + (if .android.inputMethod.default == null then [] else [.android.inputMethod.default] end))[]
      | split("/")[0])
  ] | unique[]
' "$manifest")

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
todo_permflag=()  # pkg US perm US current-csv US wanted-csv
todo_appop=()     # pkg US op US current US wanted
todo_suspend=()   # pkg
todo_unsuspend=() # pkg
todo_locale=()    # pkg US current-csv US wanted-csv
todo_ime_enable=()  # component
todo_ime_disable=() # component
todo_ime_default=() # current US wanted
todo_data_saver=()  # current US wanted
todo_link_allowed=()    # pkg US current US wanted
todo_link_selected=()   # pkg US domain
todo_link_unselected=() # pkg US domain
todo_idle=()
todo_unidle=()      # pkg

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
declare -A permission_install=()
declare -A permission_suspended=()
declare -A permission_changing=()
declare -A permission_package_changing=()
# One cached, explicitly owner-user-scoped package dump per referenced package.
# The package-level install-permissions block is cached alongside it: a grant
# of an already-granted install-time permission (e.g. INTERNET on stock
# Android) must read as satisfied, not as a forever-replanned pm grant.
load_permission_package() {
  local pkg=$1 full_dump scoped_dump
  if [ -z "${permission_checked[$pkg]+x}" ]; then
    permission_checked[$pkg]=1
    if [ -n "$(current_code "$pkg")" ]; then
      permission_present[$pkg]=1
      full_dump=$(adb_shell dumpsys package "$pkg" | tr -d '\r')
      if ! scoped_dump=$(permission_user_block "$user" <<<"$full_dump"); then
        echo "cannot locate User $user permission state for installed package $pkg" >&2
        exit 2
      fi
      permission_dump[$pkg]=$scoped_dump
      permission_install[$pkg]=$(install_permission_block <<<"$full_dump")
      if has_shell_suspension_in_dump "$user" <<<"$full_dump"; then
        permission_suspended[$pkg]=1
      else
        permission_suspended[$pkg]=0
      fi
    else
      permission_present[$pkg]=0
      permission_dump[$pkg]=
      permission_install[$pkg]=
      permission_suspended[$pkg]=0
    fi
  fi
}
while IFS=$'\t' read -r pkg perm action; do
  load_permission_package "$pkg"
  package_present=${permission_present[$pkg]}
  granted=$(grep -F -m1 "  $perm: granted=" <<<"${permission_dump[$pkg]}" | sed 's/.*granted=\([a-z]*\).*/\1/' || true)
  install_line=$(grep -F -m1 "  $perm: granted=" <<<"${permission_install[$pkg]}" || true)
  if [ "$action" = grant ]; then
    if [ -z "$granted" ] && [ -n "$install_line" ]; then
      # Install-time permission: pm grant cannot change it. granted=true is
      # already-satisfied intent (it survives upgrades); granted=false cannot
      # be granted by adb shell at all, so fail before any mutation.
      if ! grep -Fq 'granted=true' <<<"$install_line"; then
        echo "cannot grant install-time permission $perm for $pkg: not runtime-changeable" >&2
        exit 1
      fi
    elif [ "$granted" != "true" ] || [ -n "${changing[$pkg]:-}" ]; then
      todo_grant+=("${pkg}${US}${perm}")
      permission_changing["$pkg/$perm"]=1
      permission_package_changing[$pkg]=1
    fi
  elif [ "$action" = revoke ]; then
    if [ -n "$install_line" ] && [ -z "$granted" ]; then
      echo "cannot revoke install-time permission $perm for $pkg: not runtime-changeable" >&2
      exit 1
    fi
    if [ "$granted" = "true" ] || [ "$package_present" -eq 0 ] || [ -n "${changing[$pkg]:-}" ]; then
      # A missing target is either managed or presence-declared: the latter makes
      # the attended/Play preflight below abort before apply. Managed installs and
      # upgrades happen before permissions, so reassert revoke intent afterward.
      todo_revoke+=("${pkg}${US}${perm}")
      permission_changing["$pkg/$perm"]=1
      permission_package_changing[$pkg]=1
    fi
  fi
done < <(jq -r '.android.permissions // {} | to_entries[] | .key as $p | ((.value.grant[] | [$p, ., "grant"]), (.value.revoke[] | [$p, ., "revoke"])) | @tsv' "$manifest")

while IFS=$US read -r pkg perm want_csv; do
  load_permission_package "$pkg"
  permission_line=$(grep -F -m1 "  $perm: granted=" <<<"${permission_dump[$pkg]}" || true)
  raw_flags=$(sed -n 's/.*flags=\[ *\([^]]*\) *\].*/\1/p' <<<"$permission_line")
  cur_csv=$(writable_flags_csv "$raw_flags")
  if [ "$cur_csv" != "$want_csv" ] \
    || [ -n "${changing[$pkg]:-}" ] \
    || [ -n "${permission_changing[$pkg/$perm]:-}" ]; then
    todo_permflag+=("${pkg}${US}${perm}${US}${cur_csv}${US}${want_csv}")
  fi
done < <(jq -r '.android.permissions | to_entries[] | .key as $p | .value.flags | to_entries[] | [$p, .key, (.value | sort | join(","))] | join("\u001f")' "$manifest")

while IFS=$US read -r pkg op want; do
  if [ -n "$(current_code "$pkg")" ]; then
    appop_output=$(adb_shell appops get --user "$user" "$pkg" "$op" | tr -d '\r')
    cur=$(appop_mode_from_output "$op" <<<"$appop_output") \
      || { echo "unable to read app-op $pkg $op" >&2; exit 1; }
  else
    cur=absent
  fi
  if [ "$cur" != "$want" ] \
    || [ -n "${changing[$pkg]:-}" ] \
    || [ -n "${permission_package_changing[$pkg]:-}" ]; then
    todo_appop+=("${pkg}${US}${op}${US}${cur}${US}${want}")
  fi
done < <(jq -r '.android.appOps | to_entries[] | .key as $p | .value | to_entries[] | [$p, .key, .value] | join("\u001f")' "$manifest")

# Suspension is read from the same cached full dump as permission state (see
# has_shell_suspension_in_dump); load_permission_package computed it once.
has_shell_suspension() {
  local pkg=$1
  load_permission_package "$pkg"
  [ "${permission_suspended[$pkg]}" = 1 ]
}
while read -r pkg; do
  [ -z "$pkg" ] && continue
  has_shell_suspension "$pkg" || todo_suspend+=("$pkg")
done < <(jq -r '.android.suspended[]' "$manifest")
while read -r pkg; do
  [ -z "$pkg" ] && continue
  has_shell_suspension "$pkg" && todo_unsuspend+=("$pkg")
done < <(jq -r '.android.unsuspended[]' "$manifest")

while IFS=$US read -r pkg want; do
  if [ -n "$(current_code "$pkg")" ]; then
    locale_output=$(adb_shell cmd locale get-app-locales "$pkg" --user "$user" | tr -d '\r')
    locale_prefix="Locales for $pkg for user $user are ["
    if [[ $locale_output == "$locale_prefix"*"]" && $locale_output != *$'\n'* ]]; then
      cur=${locale_output#"$locale_prefix"}
      cur=${cur%]}
    else
      echo "unable to read app locales for $pkg" >&2
      exit 1
    fi
  else
    cur=
  fi
  [ "$cur" = "$want" ] || todo_locale+=("${pkg}${US}${cur}${US}${want}")
done < <(jq -r '.android.locales | to_entries[] | [.key, (.value | join(","))] | join("\u001f")' "$manifest")

enabled_imes=$(adb_shell ime list -s --user "$user" | tr -d '\r')
while read -r component; do
  [ -z "$component" ] && continue
  grep -Fqx "$component" <<<"$enabled_imes" || todo_ime_enable+=("$component")
done < <(jq -r '.android.inputMethod.enabled[]' "$manifest")
while read -r component; do
  [ -z "$component" ] && continue
  grep -Fqx "$component" <<<"$enabled_imes" && todo_ime_disable+=("$component")
done < <(jq -r '.android.inputMethod.disabled[]' "$manifest")
want_ime=$(jq -r '.android.inputMethod.default' "$manifest")
if [ "$want_ime" != null ]; then
  cur_ime=$(adb_shell settings get --user "$user" secure default_input_method | tr -d '\r')
  [ "$cur_ime" = null ] && cur_ime=
  [ "$cur_ime" = "$want_ime" ] || todo_ime_default+=("${cur_ime}${US}${want_ime}")
fi

want_data_saver=$(jq -r '.android.dataSaver.enabled' "$manifest")
if [ "$want_data_saver" != null ]; then
  data_saver_output=$(adb_shell cmd netpolicy get restrict-background | tr -d '\r')
  cur_data_saver=$(sed -n 's/^Restrict background status: \(enabled\|disabled\)$/\1/p' <<<"$data_saver_output")
  [ -n "$cur_data_saver" ] || { echo "unable to read Data Saver state" >&2; exit 1; }
  [ "$want_data_saver" = true ] && want_data_saver=enabled || want_data_saver=disabled
  [ "$cur_data_saver" = "$want_data_saver" ] \
    || todo_data_saver+=("${cur_data_saver}${US}${want_data_saver}")
fi
while IFS=$US read -r pkg allowed; do
  if [ -n "$(current_code "$pkg")" ]; then
    links=$(adb_shell pm get-app-links --user "$user" "$pkg" | tr -d '\r')
    cur_allowed=$(sed -n 's/^      Verification link handling allowed: \(true\|false\)$/\1/p' <<<"$links")
    [ -n "$cur_allowed" ] || { echo "unable to read app-link user state for $pkg" >&2; exit 1; }
    grep -Fqx '      Selection state:' <<<"$links" \
      || { echo "unable to read app-link selection state for $pkg" >&2; exit 1; }
    grep -Eq '^        (Enabled|Disabled):$' <<<"$links" \
      || { echo "unable to read app-link domain sections for $pkg" >&2; exit 1; }
    selected=$(app_link_selected_domains <<<"$links")
  else
    cur_allowed=true
    selected=
  fi
  if [ "$allowed" != null ] && [ "$cur_allowed" != "$allowed" ]; then
    todo_link_allowed+=("${pkg}${US}${cur_allowed}${US}${allowed}")
  fi
  while read -r domain; do
    [ -z "$domain" ] && continue
    grep -Fqx "$domain" <<<"$selected" || todo_link_selected+=("${pkg}${US}${domain}")
  done < <(jq -r --arg p "$pkg" '.android.appLinks[$p].selected[]' "$manifest")
  while read -r domain; do
    [ -z "$domain" ] && continue
    grep -Fqx "$domain" <<<"$selected" && todo_link_unselected+=("${pkg}${US}${domain}")
  done < <(jq -r --arg p "$pkg" '.android.appLinks[$p].unselected[]' "$manifest")
done < <(jq -r '.android.appLinks | to_entries[] | [.key, (.value.allowed | tostring)] | join("\u001f")' "$manifest")

idle_now=$(adb_shell cmd deviceidle whitelist | tr -d '\r')
while read -r pkg; do
  [ -z "$pkg" ] && continue
  grep -Fq ",$pkg," <<<"$idle_now" || todo_idle+=("$pkg")
done < <(jq -r '.android.deviceidleExempt // [] | .[]' "$manifest")
# Ensure-absent scopes to the USER whitelist class only: `-pkg` cannot touch
# system/system-excidle entries, so matching them would demand an impossible
# removal and drift forever. (Exempt's broad match is fine — system-exempt
# satisfies "must be exempt".)
while read -r pkg; do
  [ -z "$pkg" ] && continue
  grep -Eq "^user,$(printf '%s' "$pkg" | sed 's/[.[\*^$]/\\&/g')," <<<"$idle_now" && todo_unidle+=("$pkg")
done < <(jq -r '.android.deviceidleUnexempt // [] | .[]' "$manifest")

plan_lines=$(( ${#todo_install[@]} + ${#todo_upgrade[@]} + ${#todo_remove[@]} \
  + ${#todo_setting[@]} + ${#todo_dark[@]} + ${#todo_role[@]} + ${#todo_disable[@]} \
  + ${#todo_grant[@]} + ${#todo_revoke[@]} + ${#todo_permflag[@]} \
  + ${#todo_appop[@]} + ${#todo_suspend[@]} + ${#todo_unsuspend[@]} \
  + ${#todo_locale[@]} + ${#todo_ime_enable[@]} + ${#todo_ime_disable[@]} \
  + ${#todo_ime_default[@]} + ${#todo_data_saver[@]} \
  + ${#todo_link_allowed[@]} + ${#todo_link_selected[@]} + ${#todo_link_unselected[@]} \
  + ${#todo_idle[@]} + ${#todo_unidle[@]} ))
for t in "${todo_install[@]}"; do IFS=$US read -r p c _ <<<"$t"; echo "install  $p ($c)"; done
for t in "${todo_upgrade[@]}"; do IFS=$US read -r p c _ <<<"$t"; echo "upgrade  $p ($c)"; done
# Signer preflight for pending upgrades. Exact when possible: the manifest APK
# is a local store path and the installed copy is one `adb pull` away, so
# comparing their apksigner digest sets turns "might fail" into a verdict —
# overlapping sets upgrade in place (Android checks the same thing), disjoint
# sets WILL fail with INSTALL_FAILED_UPDATE_INCOMPATIBLE. When apksigner is
# absent (standalone engine) or the pull fails, fall back to the installer
# provenance heuristic: a Play-ecosystem installer usually means a Play-signed
# copy that a differently-signed repo build cannot upgrade. Managed installs
# cannot mismatch (nothing to conflict with).
installed_signer_digests() { # $1=package → digest lines, non-zero when unknown
  local rpath tmpdir digests
  rpath=$(adb_shell pm path "$1" | tr -d '\r' | sed -n '1s/^package://p')
  [ -n "$rpath" ] || return 1
  tmpdir=$(mktemp -d) || return 1
  if ! "${adb_base[@]}" pull "$rpath" "$tmpdir/installed.apk" >/dev/null 2>&1; then
    rm -rf "$tmpdir"
    return 1
  fi
  digests=$(apksigner verify --print-certs "$tmpdir/installed.apk" 2>/dev/null | apk_signer_digests)
  rm -rf "$tmpdir"
  [ -n "$digests" ] || return 1
  printf '%s\n' "$digests"
}
for t in "${todo_upgrade[@]}"; do
  IFS=$US read -r p _ apk <<<"$t"
  verdict=unknown
  if command -v apksigner >/dev/null 2>&1; then
    new_signers=$(apksigner verify --print-certs "$apk" 2>/dev/null | apk_signer_digests || true)
    inst_signers=$(installed_signer_digests "$p" || true)
    if [ -n "$new_signers" ] && [ -n "$inst_signers" ]; then
      if grep -Fxq -f <(printf '%s\n' "$new_signers") <(printf '%s\n' "$inst_signers"); then
        verdict=match
      else
        verdict=mismatch
      fi
    fi
  fi
  case $verdict in
  match) ;; # verified: same signing lineage, in-place upgrade will be accepted
  mismatch)
    echo "note: $p upgrade WILL fail: the installed copy's verified signer differs from the declared source's — uninstall it first or reclassify its lane" >&2
    ;;
  unknown)
    installer=$(adb_shell dumpsys package "$p" | tr -d '\r' | installer_package_from_dump)
    case $installer in
    com.android.vending | com.aurora.store)
      echo "note: $p upgrade will likely fail: the installed copy came from $installer (Play-signed) and the declared source is signed differently — uninstall it first or reclassify it to apps.play" >&2
      ;;
    esac
    ;;
  esac
done
for t in "${todo_remove[@]}";  do echo "remove   $t"; done
setting_field() { jq -Rr --argjson i "$2" '@base64d | fromjson | .[$i]' <<<"$1"; }
# A permission/appop line for a package this run installs or upgrades is
# reasserted *after* the install (which can reset that state), not independent
# drift. Annotate it so the plan reads as a trustworthy pre-switch preview.
induced() { [ -n "${changing[$1]:-}" ] && printf ' (after %s)' "${changing[$1]}"; return 0; }
for t in "${todo_setting[@]}"; do
  ns=$(setting_field "$t" 0) k=$(setting_field "$t" 1)
  c=$(setting_field "$t" 2) w=$(setting_field "$t" 3)
  echo "setting  $ns/$k (${c:-unset} → $w)"
done
for t in "${todo_dark[@]}";    do echo "darkmode → $t"; done
for t in "${todo_role[@]}";    do IFS=$US read -r r c w <<<"$t"; echo "role     $r (${c:-none} → $w)"; done
for t in "${todo_disable[@]}"; do echo "disable  $t"; done
for t in "${todo_grant[@]}";   do IFS=$US read -r p m <<<"$t"; echo "grant    $p $m$(induced "$p")"; done
for t in "${todo_revoke[@]}";  do IFS=$US read -r p m <<<"$t"; echo "revoke   $p $m$(induced "$p")"; done
for t in "${todo_permflag[@]}"; do
  IFS=$US read -r p m c w <<<"$t"
  echo "permflag $p $m (${c:-none} → ${w:-none})$(induced "$p")"
done
for t in "${todo_appop[@]}"; do
  IFS=$US read -r p o c w <<<"$t"
  echo "appop    $p $o ($c → $w)$(induced "$p")"
done
for p in "${todo_suspend[@]}"; do echo "suspend  $p (adb-shell authority)"; done
for p in "${todo_unsuspend[@]}"; do echo "unsuspend $p (remove adb-shell authority)"; done
for t in "${todo_locale[@]}"; do
  IFS=$US read -r p c w <<<"$t"
  echo "locales  $p (${c:-system} → ${w:-system})"
done
for c in "${todo_ime_enable[@]}"; do echo "ime-on   $c"; done
for c in "${todo_ime_disable[@]}"; do echo "ime-off  $c"; done
for t in "${todo_ime_default[@]}"; do IFS=$US read -r c w <<<"$t"; echo "ime      default (${c:-none} → $w)"; done
for t in "${todo_data_saver[@]}"; do IFS=$US read -r c w <<<"$t"; echo "datasaver ($c → $w)"; done
for t in "${todo_link_allowed[@]}"; do IFS=$US read -r p c w <<<"$t"; echo "link-ok  $p ($c → $w)"; done
for t in "${todo_link_selected[@]}"; do IFS=$US read -r p d <<<"$t"; echo "link+    $p $d"; done
for t in "${todo_link_unselected[@]}"; do IFS=$US read -r p d <<<"$t"; echo "link-    $p $d"; done
for t in "${todo_idle[@]}";    do echo "idle-ok  $t (battery-optimization exempt)"; done
for t in "${todo_unidle[@]}";  do echo "idle-no  $t (battery-optimization unexempt)"; done
for p in "${missing_attended[@]}"; do echo "ATTENDED $p — install from its declared human source"; done
for p in "${missing_play[@]}"; do echo "PLAY     $p — run android-rebuild assist"; done

if [ $(( ${#missing_attended[@]} + ${#missing_play[@]} )) -gt 0 ]; then
  echo "✗ ${#missing_attended[@]} attended and ${#missing_play[@]} Play app(s) missing; device does not match manifest" >&2
  exit 1
fi

if [ "$plan_lines" -eq 0 ]; then
  echo "✓ device matches manifest"
  # A no-op switch still confirms convergence — record it as a generation.
  [ "$record" -eq 1 ] && record_generation 0
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
  if ! adb_shell pm grant --user "$user" "$p" "$m"; then
    # A managed app installed earlier in this apply may have turned $m into an
    # already-granted install-time permission (planning read the device before
    # the install). Accept the failure only when the managed user's runtime
    # block or the package install-permission block reports granted — never
    # another user's state.
    post_dump=$(adb_shell dumpsys package "$p" | tr -d '\r')
    post_user=$(permission_user_block "$user" <<<"$post_dump") || post_user=
    post_install=$(install_permission_block <<<"$post_dump")
    grep -Fq "  $m: granted=true" <<<"$post_user"$'\n'"$post_install" \
      || { echo "pm grant failed and $m is not granted for $p (user $user)" >&2; exit 1; }
  fi
done
for t in "${todo_revoke[@]}"; do
  IFS=$US read -r p m <<<"$t"
  if ! adb_shell pm revoke --user "$user" "$p" "$m"; then
    # Reached only for packages absent at plan time (installed this apply):
    # an install-time permission cannot be revoked and the declared state is
    # unreachable. Fail with the classification instead of a bare pm error.
    post_dump=$(adb_shell dumpsys package "$p" | tr -d '\r')
    post_install=$(install_permission_block <<<"$post_dump")
    if grep -Fq "  $m: granted=" <<<"$post_install"; then
      echo "cannot revoke install-time permission $m for $p: not runtime-changeable" >&2
    else
      echo "pm revoke failed for $p $m (user $user)" >&2
    fi
    exit 1
  fi
done
for t in "${todo_permflag[@]}"; do
  IFS=$US read -r p m cur_csv want_csv <<<"$t"
  set_flags=()
  clear_flags=()
  for flag in "${writable_permission_flags[@]}"; do
    if [[ ",$want_csv," == *",$flag,"* ]]; then
      set_flags+=("$flag")
    else
      clear_flags+=("$flag")
    fi
  done
  [ "${#set_flags[@]}" -eq 0 ] || adb_shell pm set-permission-flags --user "$user" "$p" "$m" "${set_flags[@]}"
  [ "${#clear_flags[@]}" -eq 0 ] || adb_shell pm clear-permission-flags --user "$user" "$p" "$m" "${clear_flags[@]}"
done
for t in "${todo_appop[@]}"; do
  IFS=$US read -r p o _ w <<<"$t"
  adb_shell appops set --user "$user" "$p" "$o" "$w"
done
[ "${#todo_appop[@]}" -eq 0 ] || adb_shell appops write-settings >/dev/null
for p in "${todo_suspend[@]}"; do
  adb_shell pm suspend --user "$user" "$p" >/dev/null
done
for p in "${todo_unsuspend[@]}"; do
  adb_shell pm unsuspend --user "$user" "$p" >/dev/null
done
for t in "${todo_locale[@]}"; do
  IFS=$US read -r p _ w <<<"$t"
  adb_shell cmd locale set-app-locales "$p" --user "$user" --locales "$w"
done
for c in "${todo_ime_enable[@]}"; do
  adb_shell ime enable --user "$user" "$c" >/dev/null
done
for t in "${todo_ime_default[@]}"; do
  IFS=$US read -r _ w <<<"$t"
  adb_shell ime set --user "$user" "$w" >/dev/null
done
for c in "${todo_ime_disable[@]}"; do
  adb_shell ime disable --user "$user" "$c" >/dev/null
done
for t in "${todo_data_saver[@]}"; do
  IFS=$US read -r _ w <<<"$t"
  [ "$w" = enabled ] && enabled=true || enabled=false
  adb_shell cmd netpolicy set restrict-background "$enabled"
done
for t in "${todo_link_allowed[@]}"; do
  IFS=$US read -r p _ w <<<"$t"
  adb_shell pm set-app-links-allowed --user "$user" --package "$p" "$w"
done
for t in "${todo_link_selected[@]}"; do
  IFS=$US read -r p d <<<"$t"
  adb_shell pm set-app-links-user-selection --user "$user" --package "$p" true "$d"
done
for t in "${todo_link_unselected[@]}"; do
  IFS=$US read -r p d <<<"$t"
  adb_shell pm set-app-links-user-selection --user "$user" --package "$p" false "$d"
done
for pkg in "${todo_idle[@]}"; do
  adb_shell cmd deviceidle whitelist "+$pkg" >/dev/null
done
for pkg in "${todo_unidle[@]}"; do
  adb_shell cmd deviceidle whitelist "-$pkg" >/dev/null
done
for pkg in "${todo_remove[@]}"; do
  echo "uninstalling $pkg..."
  adb uninstall --user "$user" "$pkg" >/dev/null
done
echo "✓ applied $plan_lines changes"
[ "$record" -eq 1 ] && record_generation "$plan_lines"
exit 0
