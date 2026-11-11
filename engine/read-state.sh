# shellcheck shell=bash
# Shared device-output readers for the converge engine and the bench oracle.
# Sourced (not executed) by engine/converge.sh and scripts/bench-e2e.sh so the
# two sides cannot drift apart; parsers take command output on stdin and never
# run adb themselves.

# The only permission-policy flags adb shell may own. This array is the single
# shell-side source; converge.sh feeds it into its jq manifest validator, and
# modules/options.nix + scripts/render-import.py mirror it for Nix and import.
# review-required is deliberately absent: PermissionController rewrote it
# immediately after a shell write on the AOSP bench (it is derived from the
# app's targetSdk), so adb shell cannot own it.
writable_permission_flags=(revoke-when-requested revoked-compat user-fixed user-set)

# Print only the "User <N>:" blocks of a `dumpsys package <pkg>` dump.
# Fails when the block is missing so callers fail loudly instead of reading
# another profile's state. A block ends only at the next "    User N:" header
# or a line indented fewer than four spaces: AOSP Settings.dumpPackageLPr
# prints "    Suspend params:" at the header's own indent *inside* the user
# loop, ahead of "      runtime permissions:", plus a blank line after each
# suspender, so neither a four-space line nor a blank line may end the block.
# Every matching header is kept, not just the package entry's: a sharedUserId
# app's runtime permissions live in the later "Shared users:" section's
# "    User N: " block. Callers take the first match.
permission_user_block() {
  local wanted_user=$1
  gawk -v wanted_user="$wanted_user" '
    BEGIN { header = "    User " wanted_user ":" }
    /^    User [0-9]+:/ {
      active = index($0, header) == 1
      if (active) found = 1
    }
    /^ {0,3}[^ ]/ { active = 0 }
    active { print }
    END { if (!found) exit 1 }
  '
}

# Print only the "install permissions:" blocks (absent for apps that request
# no install-time permissions — empty output is not an error). Like the user
# block, this keeps the "Shared users:" copy that sharedUserId apps rely on.
install_permission_block() {
  gawk '
    /^    [^ ]/ { active = ($0 == "    install permissions:") }
    /^ {0,3}[^ ]/ { active = 0 }
    active { print }
  '
}

# Print only the first "  Package [...]" block of a `dumpsys package <pkg>`
# dump: the target's entry in the "Packages:" section. Excludes the resolver
# tables printed before it (app-controlled intent-filter strings) and the
# "Hidden system packages:" copy printed after it. Reads all input instead of
# exiting early, so a pipefail producer never dies of SIGPIPE.
package_block() {
  gawk '
    /^  Package \[/ { active = !seen; seen = 1 }
    /^ {0,3}[^ ]/ && !/^  Package \[/ { active = 0 }
    active { print }
  '
}

# True if a `dumpsys package <pkg>` dump shows an adb-shell suspension for the
# given user. The <N> in `suspendingPackage=<N>com.android.shell` is the
# SUSPENDER's user (`pm suspend` always passes USER_SYSTEM), not the suspended
# user, so the match is scoped to the target user's block of the package entry,
# where dumpPackageLPr prints that user's "Suspend params:". The anchored line
# shape also rejects resolver-table keys, which always end in ":".
has_shell_suspension_in_dump() {
  local user_block
  user_block=$(package_block | permission_user_block "$1") || return 1
  grep -Eq '^ +suspendingPackage=<0>com\.android\.shell( |$)' <<<"$user_block"
}

# Sorted CSV of writable flags present in one dumped `flags=[ ... ]` payload.
# LC_ALL=C matches jq's codepoint sort of the manifest side, so equal sets
# always compare equal regardless of the array order above.
writable_flags_csv() {
  local raw_flags=$1 flag platform_flag present=()
  for flag in "${writable_permission_flags[@]}"; do
    platform_flag=${flag^^}
    platform_flag=${platform_flag//-/_}
    if grep -Eq "(^|[|[:space:]])${platform_flag}([|[:space:]]|$)" <<<"$raw_flags"; then
      present+=("$flag")
    fi
  done
  [ "${#present[@]}" -eq 0 ] || printf '%s\n' "${present[@]}" | LC_ALL=C sort | paste -sd, -
}

# Package-level app-op mode from `appops get --user N <pkg> <op>` output.
# Prints the mode; fails when the output is empty or contains unrecognized
# lines, so both the engine and the bench abort on a format they cannot read.
appop_mode_from_output() {
  local op=$1 appop_output mode unknown
  appop_output=$(cat)
  mode=$(sed -n "s/^${op}: \(allow\|ignore\|deny\|default\|foreground\).*/\1/p" <<<"$appop_output" | head -n1)
  if [ -z "$mode" ]; then
    unknown=$(sed -E \
      -e '/^No operations\.$/d' \
      -e '/^Default mode: (allow|ignore|deny|default|foreground)$/d' \
      -e "/^Uid mode: ${op}: (allow|ignore|deny|default|foreground)$/d" \
      -e '/^$/d' <<<"$appop_output")
    if [ -z "$unknown" ] && [ -n "$appop_output" ]; then
      mode=default
    fi
  fi
  [ -n "$mode" ] || return 1
  printf '%s\n' "$mode"
}

# User-selected app-link domains from `pm get-app-links --user N <pkg>` output.
app_link_selected_domains() {
  awk '
    /^        Enabled:$/ { enabled=1; next }
    /^        Disabled:$/ { enabled=0; next }
    enabled && /^          [^[:space:]]/ { sub(/^          /, ""); print }
  '
}

# Installer package from the package entry of a `dumpsys package <pkg>` dump.
# Prints nothing when unset/null (sideloads, adb installs). Provenance
# heuristic: a Play-ecosystem installer means a Play-signed APK, which a
# differently-signed repo build can never upgrade in place.
installer_package_from_dump() {
  package_block | sed -n 's/^ *installerPackageName=\(.*\)$/\1/p' | sed '/^null$/d' | head -n1
}

# Other user ids for which the package is installed, from the package entry of
# a `dumpsys package <pkg>` dump. $1 = the managed user to exclude.
# Owner-profile Play can wedge installing a package another profile already has
# (LIMITS.md).
other_users_with_install() {
  local exclude=$1
  package_block | sed -n 's/^    User \([0-9][0-9]*\):.*installed=true.*/\1/p' | grep -vx "$exclude" || true
}

# Normalized APK signer digests from `apksigner verify --print-certs` output:
# one lowercase sha256 per line, sorted, deduplicated. Accepts both signer
# spellings ("Signer #N ..." and the v3.1 per-SDK "Signer (minSdkVersion=..)
# ...") and rejects the Play "Source Stamp Signer" line — that digest is
# Play's delivery stamp, not an app signing certificate. SHA-1/MD5 lines are
# excluded by the {64} length anchor.
apk_signer_digests() {
  grep '^Signer ' \
    | sed -n 's/.*certificate SHA-256 digest:[[:space:]]*\([0-9A-Fa-f]\{64\}\).*/\1/p' \
    | tr 'A-F' 'a-f' | sort -u
}
