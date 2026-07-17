#!/usr/bin/env bash
# Golden-fixture tests for engine/read-state.sh. The bench oracle shares these
# parsers with the engine, so a shared regression would make implementation and
# oracle agree incorrectly; these fixtures pin each parser against raw device
# output captured from the AOSP emulator, a stock Pixel 9 (SDK 36), and a
# GrapheneOS Pixel (SDK 37) on 2026-07-16.
set -euo pipefail

# shellcheck source-path=SCRIPTDIR/../engine
# shellcheck source=read-state.sh
source "$(dirname "${BASH_SOURCE[0]}")/../engine/read-state.sh"

fail() {
  echo "test-read-state: $1" >&2
  exit 1
}

# --- permission_user_block: exact user scoping, no cross-profile bleed -------
multi_user_dump=$(cat <<'EOF'
    install permissions:
      android.permission.INTERNET: granted=true
    User 10: installed=true
      runtime permissions:
        android.permission.CAMERA: granted=false, flags=[ USER_SET]
    User 0: installed=true
      runtime permissions:
        android.permission.CAMERA: granted=true, flags=[ USER_SET]
EOF
)
scoped=$(permission_user_block 0 <<<"$multi_user_dump")
grep -Fq 'android.permission.CAMERA: granted=true' <<<"$scoped" \
  || fail "user block missed user 0 state"
grep -Fq 'granted=false' <<<"$scoped" \
  && fail "user block crossed into another profile"
grep -Fq 'INTERNET' <<<"$scoped" \
  && fail "user block leaked the install-permissions section"
permission_user_block 3 <<<"$multi_user_dump" >/dev/null 2>&1 \
  && fail "user block reported a missing user as found"

# --- install_permission_block: package-level section only --------------------
installed=$(install_permission_block <<<"$multi_user_dump")
grep -Fq 'android.permission.INTERNET: granted=true' <<<"$installed" \
  || fail "install block missed INTERNET"
grep -Fq 'CAMERA' <<<"$installed" \
  && fail "install block leaked runtime state"
[ -z "$(install_permission_block <<<'    User 0: installed=true')" ] \
  || fail "install block invented content for a dump without the section"

# --- has_shell_suspension_in_dump: user-qualified suspender ------------------
suspend_dump=$(cat <<'EOF'
    User 0: ceDataInode=344234 installed=true hidden=false suspended=true enabled=0
    Suspend params:
      suspendingPackage=<0>com.android.shell dialogInfo=null quarantined=false
EOF
)
has_shell_suspension_in_dump 0 <<<"$suspend_dump" \
  || fail "shell suspension for user 0 not detected"
has_shell_suspension_in_dump 10 <<<"$suspend_dump" \
  && fail "user 10 falsely matched user 0 suspension"
other_suspender=${suspend_dump/com.android.shell/com.example.wellbeing}
has_shell_suspension_in_dump 0 <<<"$other_suspender" \
  && fail "another authority falsely matched the shell suspender"

# --- appop_mode_from_output: package mode, defaults, and hard failures -------
[ "$(appop_mode_from_output RUN_IN_BACKGROUND <<<'RUN_IN_BACKGROUND: ignore; time=+3m41s121ms ago')" = ignore ] \
  || fail "package-level app-op mode with trailing detail misread"
[ "$(appop_mode_from_output RUN_IN_BACKGROUND <<<'No operations.')" = default ] \
  || fail "'No operations.' did not read as default"
[ "$(appop_mode_from_output VIBRATE <<<'VIBRATE: deny')" = deny ] \
  || fail "deny mode misread"
appop_mode_from_output RUN_IN_BACKGROUND </dev/null >/dev/null 2>&1 \
  && fail "empty app-op output did not fail"
appop_mode_from_output RUN_IN_BACKGROUND <<<'unexpected format' >/dev/null 2>&1 \
  && fail "unrecognized app-op output did not fail"

# --- writable_flags_csv: writable subset only, codepoint-sorted --------------
[ "$(writable_flags_csv 'USER_SET|USER_FIXED|USER_SENSITIVE_WHEN_GRANTED')" = 'user-fixed,user-set' ] \
  || fail "writable flag extraction/order wrong"
[ "$(writable_flags_csv 'REVOKED_COMPAT|REVOKE_WHEN_REQUESTED')" = 'revoke-when-requested,revoked-compat' ] \
  || fail "policy flag extraction/order wrong"
[ -z "$(writable_flags_csv 'USER_SENSITIVE_WHEN_GRANTED|SYSTEM_FIXED')" ] \
  || fail "Android-owned flags leaked into the writable set"
[ -z "$(writable_flags_csv '')" ] || fail "empty flags produced output"
grep -Fq 'review-required' <<<"$(writable_flags_csv 'REVIEW_REQUIRED')" \
  && fail "review-required must stay outside the writable set"

# --- app_link_selected_domains: Enabled section only -------------------------
links_dump=$(cat <<'EOF'
      Verification link handling allowed: true
      Selection state:
        Enabled:
          f-droid.org
        Disabled:
          example.com
EOF
)
[ "$(app_link_selected_domains <<<"$links_dump")" = 'f-droid.org' ] \
  || fail "app-link selected domains misread"


# --- installer_package_from_dump / other_users_with_install ------------------
# Fixture captured from a GrapheneOS Pixel 6 (SDK 37) on 2026-07-17: an app
# installed in the work profile (user 10) but not owner user 0, delivered by
# Aurora Store.
provenance_dump=$(cat <<'EOF'
  Packages:
    Package [com.example.crossprofile] (1234abc):
      installerPackageName=com.aurora.store
      versionName=21.26.364
    User 0: ceDataInode=0 deDataInode=0 installed=false hidden=false stopped=true
    User 10: ceDataInode=21299 deDataInode=22627 installed=true hidden=false stopped=false
    User 11: ceDataInode=0 deDataInode=0 installed=false hidden=false stopped=false
EOF
)
[ "$(installer_package_from_dump <<<"$provenance_dump")" = com.aurora.store ] \
  || fail "installer package misread"
[ "$(other_users_with_install 0 <<<"$provenance_dump")" = 10 ] \
  || fail "other-profile install users misread"
[ -z "$(other_users_with_install 10 <<<"$provenance_dump")" ] \
  || fail "excluded user leaked into other-profile install list"
adb_install_dump=$(cat <<'EOF'
      installerPackageName=null
    User 0: ceDataInode=11 deDataInode=12 installed=true hidden=false stopped=false
EOF
)
[ -z "$(installer_package_from_dump <<<"$adb_install_dump")" ] \
  || fail "null installer should read as empty"

echo "✓ read-state parser fixtures passed"
