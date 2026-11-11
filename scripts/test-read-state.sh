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

# A suspended package: AOSP Settings.dumpPackageLPr prints "    Suspend params:"
# at the User header's own indent, plus a blank line per suspender, BEFORE the
# runtime permissions. Neither may end the block.
suspended_perm_dump=$(cat <<'EOF'
Packages:
  Package [com.example.suspended] (1a2b3c):
    installerPackageName=null
    install permissions:
      android.permission.INTERNET: granted=true
    User 0: ceDataInode=344234 installed=true hidden=false suspended=true enabled=0
      installReason=0
      uninstallReason=0
    Suspend params:
      suspendingPackage=<0>com.android.shell dialogInfo=null quarantined=false

      gids=[3003]
      runtime permissions:
        android.permission.CAMERA: granted=true, flags=[ USER_SET|USER_FIXED]
    User 10: ceDataInode=0 installed=true hidden=false suspended=false enabled=0
      runtime permissions:
        android.permission.CAMERA: granted=false, flags=[ USER_SET]
EOF
)
scoped=$(permission_user_block 0 <<<"$suspended_perm_dump")
grep -Fq 'android.permission.CAMERA: granted=true, flags=[ USER_SET|USER_FIXED]' <<<"$scoped" \
  || fail "Suspend params line hid the suspended package's runtime permissions"
grep -Fq 'granted=false' <<<"$scoped" \
  && fail "suspended user block crossed into user 10"
grep -Fq 'INTERNET' <<<"$(install_permission_block <<<"$suspended_perm_dump")" \
  || fail "install block missed INTERNET in a suspended package"

# sharedUserId apps: dumpPackageLPr omits their permissions from the package
# entry; AOSP dumpSharedUsersLPr prints them under "Shared users:" with the
# same four-space headers. Both extractors must keep reading that copy.
shared_uid_dump=$(cat <<'EOF'
Packages:
  Package [com.example.shared] (abc123):
    sharedUser=SharedUserSetting{def456 com.example.uid/10234}
    User 0: ceDataInode=1 installed=true hidden=false suspended=false enabled=0
      installReason=0

Shared users:
  SharedUser [com.example.uid] (def456):
    appId=10234
    Packages
      PackageSetting{789 com.example.shared/10234}
    install permissions:
      android.permission.INTERNET: granted=true
    User 0:
      gids=[3003]
      runtime permissions:
        android.permission.CAMERA: granted=true, flags=[ USER_SET]
EOF
)
grep -Fq 'android.permission.CAMERA: granted=true' <<<"$(permission_user_block 0 <<<"$shared_uid_dump")" \
  || fail "user block lost a sharedUserId app's runtime permissions"
grep -Fq 'android.permission.INTERNET: granted=true' <<<"$(install_permission_block <<<"$shared_uid_dump")" \
  || fail "install block lost a sharedUserId app's install permissions"

# --- install_permission_block: package-level section only --------------------
installed=$(install_permission_block <<<"$multi_user_dump")
grep -Fq 'android.permission.INTERNET: granted=true' <<<"$installed" \
  || fail "install block missed INTERNET"
grep -Fq 'CAMERA' <<<"$installed" \
  && fail "install block leaked runtime state"
[ -z "$(install_permission_block <<<'    User 0: installed=true')" ] \
  || fail "install block invented content for a dump without the section"

# --- has_shell_suspension_in_dump: scoped to the target user's block ---------
# `<0>` names the suspender's user (pm suspend passes USER_SYSTEM), so both
# profiles' shell suspensions print `<0>com.android.shell`; only the block
# that holds the line says which user is suspended.
has_shell_suspension_in_dump 0 <<<"$suspended_perm_dump" \
  || fail "shell suspension for user 0 not detected"
has_shell_suspension_in_dump 10 <<<"$suspended_perm_dump" \
  && fail "user 10 falsely matched user 0's suspension"
work_only_dump=$(cat <<'EOF'
Packages:
  Package [com.example.suspended] (1a2b3c):
    User 0: ceDataInode=344234 installed=true hidden=false suspended=false enabled=0
      runtime permissions:
    User 10: ceDataInode=21299 installed=true hidden=false suspended=true enabled=0
    Suspend params:
      suspendingPackage=<0>com.android.shell dialogInfo=null quarantined=false

EOF
)
has_shell_suspension_in_dump 0 <<<"$work_only_dump" \
  && fail "work-profile-only suspension read as an owner-profile suspension"
has_shell_suspension_in_dump 10 <<<"$work_only_dump" \
  || fail "work-profile shell suspension not detected for user 10"
other_suspender=${suspended_perm_dump/com.android.shell/com.example.wellbeing}
has_shell_suspension_in_dump 0 <<<"$other_suspender" \
  && fail "another authority falsely matched the shell suspender"
prefix_suspender=${suspended_perm_dump/com.android.shell /com.android.shellx }
has_shell_suspension_in_dump 0 <<<"$prefix_suspender" \
  && fail "a package-name prefix falsely matched the shell suspender"
# An app controls its intent-filter strings, and the resolver tables print
# before "Packages:". A forged action must not read as a shell suspension.
forged_dump=$(cat <<'EOF'
Activity Resolver Table:
  Non-Data Actions:
      suspendingPackage=<0>com.android.shell dialogInfo=null:
        5c1e2f0 com.example.forger/.Main filter 8d9a1b2
      x suspendingPackage=<0>com.android.shell:
        5c1e2f0 com.example.forger/.Main filter 8d9a1b2

Packages:
  Package [com.example.forger] (4d5e6f):
    User 0: ceDataInode=11 installed=true hidden=false suspended=false enabled=0
      runtime permissions:
EOF
)
has_shell_suspension_in_dump 0 <<<"$forged_dump" \
  && fail "resolver-table intent-filter string forged a shell suspension"

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
# Fixture from a GrapheneOS Pixel 6 (SDK 37) capture on 2026-07-17: an app
# installed in the work profile (user 10) but not owner user 0, delivered by
# Aurora Store. Indentation follows AOSP dumpPackageLPr (prefix "  "). The
# resolver and hidden-system lines are synthetic: an app-controlled action
# string and the updated-system-app copy must not leak into either parser.
provenance_dump=$(cat <<'EOF'
Activity Resolver Table:
  Non-Data Actions:
      installerPackageName=com.android.vending:
        5c1e2f0 com.example.forger/.Main filter 8d9a1b2
      User 11: installed=true:
        5c1e2f0 com.example.forger/.Main filter 8d9a1b2

Packages:
  Package [com.example.crossprofile] (1234abc):
    installerPackageName=com.aurora.store
    versionName=21.26.364
    User 0: ceDataInode=0 deDataInode=0 installed=false hidden=false stopped=true
    User 10: ceDataInode=21299 deDataInode=22627 installed=true hidden=false stopped=false
    User 11: ceDataInode=0 deDataInode=0 installed=false hidden=false stopped=false

Hidden system packages:
  Package [com.example.crossprofile] (5678def):
    installerPackageName=com.android.vending
    User 12: ceDataInode=0 deDataInode=0 installed=true hidden=false stopped=false
EOF
)
[ "$(installer_package_from_dump <<<"$provenance_dump")" = com.aurora.store ] \
  || fail "installer package misread"
[ "$(other_users_with_install 0 <<<"$provenance_dump")" = 10 ] \
  || fail "other-profile install users misread"
[ -z "$(other_users_with_install 10 <<<"$provenance_dump")" ] \
  || fail "excluded user leaked into other-profile install list"
adb_install_dump=$(cat <<'EOF'
Packages:
  Package [com.example.adb] (9abc):
    installerPackageName=null
    User 0: ceDataInode=11 deDataInode=12 installed=true hidden=false stopped=false
EOF
)
[ -z "$(installer_package_from_dump <<<"$adb_install_dump")" ] \
  || fail "null installer should read as empty"


# --- apk_signer_digests: signer lines only, stamp excluded, normalized ------
whatsapp_installed=$(cat <<'DUMP'
Signer (minSdkVersion=33, maxSdkVersion=2147483647) certificate SHA-256 digest: FB920D381BEE1B2093F27DC8F13D994DA629DC91887D0529B35C9A2DC4F4A6C2
Signer (minSdkVersion=33, maxSdkVersion=2147483647) certificate SHA-1 digest: 1111111111111111111111111111111111111111
Signer (minSdkVersion=24, maxSdkVersion=32) certificate SHA-256 digest: 3987d043d10aefaf5a8710b3671418fe57e0e19b653c9df82558feb5ffce5d44
Source Stamp Signer certificate SHA-256 digest: 3257d599a49d2c961a471ca9843f59d341a405884583fc087df4237b733bbd6d
DUMP
)
got=$(apk_signer_digests <<<"$whatsapp_installed")
[ "$got" = "3987d043d10aefaf5a8710b3671418fe57e0e19b653c9df82558feb5ffce5d44
fb920d381bee1b2093f27dc8f13d994da629dc91887d0529b35c9a2dc4f4a6c2" ] \
  || fail "apk_signer_digests: per-SDK signers not normalized/deduped or stamp leaked"

signal_lineage=$(cat <<'DUMP'
Signer #1 certificate SHA-256 digest: 29f34e5f27f211b424bc5bf9d67162c0eafba2da35af35c16416fc446276ba26
Signer #1 certificate MD5 digest: 22222222222222222222222222222222
Signer #2 certificate SHA-256 digest: 4be4f6cd5be844083e900279dc822af65a547fecc26aba7ff1f5203a45518cd8
DUMP
)
got=$(apk_signer_digests <<<"$signal_lineage")
[ "$(wc -l <<<"$got")" -eq 2 ] || fail "apk_signer_digests: lineage digests miscounted"
apk_signer_digests </dev/null | grep -q . && fail "apk_signer_digests: empty input produced output"

echo "✓ read-state parser fixtures passed"
