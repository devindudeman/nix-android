# ADB-to-Nix capability map

nix-android does not make Android more manageable than adb makes it. Its job is
to turn persistent, readable adb-shell state into typed Nix, a reviewable diff,
and an idempotent apply. The ceiling is the `shell` user (uid 2000) on a locked
device: if that user cannot read, write, read back, and persist a value without
bypassing Android security, nix-android cannot honestly reconcile it.

This is the compact public map. [PRIMITIVES.md](./PRIMITIVES.md) is the executed
evidence ledger, [IMPORT.md](./IMPORT.md) describes observation and rendering,
and [LIMITS.md](./LIMITS.md) defines the resulting semantics.

## Status vocabulary

- **reconciled** — plan reads current state and `switch` drives it to the exact
  declared value;
- **ensure-only** — an entry is added or asserted, but deleting it from Nix does
  not apply the inverse operation;
- **attended** — Nix asserts presence while Android or the user owns consent and
  delivery;
- **candidate** — an adb primitive has passed an initial round trip, but no
  public option exists until version, scope, and reboot behavior are proven;
- **observed-only** — import can preserve evidence but cannot safely generate an
  active declaration;
- **unreachable** — adb shell cannot recover or restore the state.

`import` is intentionally asymmetric: it may observe more than it emits. Its
generated comments are part of the result, not a promise that every observed
fact is declarable.

## Publicly managed state

| Android state | ADB read | ADB write or action | Nix semantics | Import behavior |
| --- | --- | --- | --- | --- |
| Managed APK | `pm list packages --show-versioncode --user 0` | `adb install -r --user 0`; explicit cleanup uses `adb uninstall --user 0` | reconciled presence and version floor; optional destructive cleanup | package identity/version/source evidence is retained; non-Play sources remain attended until curated into a hash-addressed source |
| Play app | package presence plus recorded installer evidence | opens the official listing in `com.android.vending`; user confirms installation | attended presence | recorded Play installer becomes `apps.play`; attribution is evidence, not enforced provenance |
| Other attended app | package presence | external human-controlled installer | attended presence | every other owner-user third-party package becomes `apps.attended` |
| Obtainium release provenance | explicit user-supplied schema-v2 export plus ADB installer observation | normal hash-locked GitHub/Gitea resolver after curation/update | reconciled managed release when both facts agree | canonical credential-free GitHub/Forgejo sources become `apps.release`; unsupported/conflicting entries stay attended |
| Raw settings key | `settings get --user 0 NAMESPACE KEY` | `settings put --user 0 NAMESPACE KEY VALUE` | reconciled only for explicitly declared expert keys | not bulk-imported; settings tables contain derived, sensitive, and component-owned values |
| Dark mode | `cmd uimode night` | `cmd uimode night yes\|no` | reconciled boolean for the foreground owner | emits `true` or `false`; automatic/custom modes remain observed-only because the public type cannot represent them |
| Private DNS | two `settings get --user 0 global` keys | the same verified global settings path | reconciled `off`, `opportunistic`, or strict hostname | emits a typed value only when mode/specifier form a valid public value; ignores a stale specifier when mode is off/opportunistic |
| Browser, SMS, dialer, home | `cmd role get-role-holders --user 0 ROLE` | `cmd role add-role-holder --user 0 ROLE PACKAGE` | reconciled single holder | emits only an unambiguous single holder; multiple holders are reported and omitted |
| Runtime permission grant bit | package protobuf, `pm list permissions -d -g -f`, and PermissionInfo restriction flags | `pm grant/revoke --user 0 PACKAGE PERMISSION` | reconciled explicit grants/revocations | for third-party packages, emits currently granted runtime permissions except hard/soft restricted grants whose installer/platform allowlisting is not portable; never invents revocations |
| Writable permission-policy flags | per-package `dumpsys package` runtime-permission rows | `pm set-permission-flags/clear-permission-flags --user 0` | reconciled exact state for PackageManager's five writable flags | emits an exact list, including empty, for each observed third-party runtime-permission row; Android-owned flags remain snapshot evidence |
| Package app-op override | package sections from `dumpsys appops`; plan uses `appops get --user 0 PACKAGE OP` | `appops set --user 0 PACKAGE OP MODE` | reconciled explicit package override; `default` clears it | emits non-default package overrides; UID-wide permission-derived modes remain evidence |
| Disabled package | `pm list packages -d --user 0` | `pm disable-user --user 0 PACKAGE` | ensure-disabled | emits disabled third-party packages; retains but omits system-package disablement as non-portable |
| Package suspension | package protobuf suspending-package metadata | `pm suspend/unsuspend --user 0` | reconciles only the adb-shell suspension authority | emits third-party packages suspended by `com.android.shell`; other/unknown suspenders remain evidence |
| Per-app locale | `cmd locale get-app-locales` | `cmd locale set-app-locales` | exact ordered canonical BCP 47 locale list for declared packages | emits non-empty portable locale lists; empty system-default lists are retained in the snapshot |
| Input method | `ime list -s --user 0` plus `settings get secure default_input_method` | `ime enable/disable/set --user 0` | explicit enable/disable intent and selected enabled default | emits enabled components and the selected default when internally consistent |
| Global Data Saver | `cmd netpolicy get restrict-background` | `cmd netpolicy set restrict-background` | reconciled boolean | emits enabled or disabled; per-app UID policy remains observed-only after reboot failure |
| User app links | `pm get-app-links --user 0` | `pm set-app-links-allowed` and `set-app-links-user-selection` | reconciled handling toggle and explicit selected/unselected domains | emits non-default denied handling and positive selections; verifier state, invalid manifest `autoVerify` domains, and indistinguishable default/deselected domains remain evidence |
| Battery-optimization exemption | `cmd deviceidle whitelist` plus owner-user package inventory | `cmd deviceidle whitelist +PACKAGE` | ensure-present and device-global by package/appId | emits only rows whose source is `user` and whose package is installed for managed user 0; system and other-profile rows remain snapshot evidence |

The runtime-permission row is deliberately narrower than the AOSP package
protobuf. That protobuf reports a broad granted-permission set, including
normal and application-defined permissions. Rendering all of it as `pm grant`
would be false. The importer therefore uses PackageManager's dangerous/runtime
permission definitions as the allowlist, removes hard/soft restricted grants
whose installer/platform allowlisting cannot be recreated, and reports every
omitted category.
GrapheneOS documents its additional
[Network and Sensors permission toggles](https://grapheneos.org/features#network-permission-toggle);
the importer discovers their underlying definitions from the device rather
than hard-coding GrapheneOS package policy.

## Verified candidates, not public configuration

These commands have executed read/write round trips on the AOSP bench or a
GrapheneOS device, but remain out of the public module until their complete
scope and graceful-reboot behavior are covered:

| State | Read/write surface | Missing proof or design |
| --- | --- | --- |
| Wi-Fi networks | `cmd wifi add-network/list-networks/forget-network` | secret handling, OS variance, and portable identity |
| Per-app background-data UID policy | `cmd netpolicy ... restrict-background-blacklist/whitelist` | user-installed UID rows were written to the policy file but removed during the AOSP graceful-reboot bench |

These belong in Nix only after the same evidence chain as every existing option:
read, real change, read-back, idempotent second apply, graceful reboot, and
post-reboot no-op.

## Observed but not safely declarable

| Surface | Why it is not active Nix state |
| --- | --- |
| Complete settings dumps | combine desired values with defaults, caches, derived state, identifiers, and secrets; only reviewed keys belong in `android.settings` |
| Package installer/update-owner fields | useful source hints, but do not prove repository, URL, signer, or future delivery |
| App Manager signing certificate export | user-supplied signer hashes are stronger inventory evidence, but plan does not yet enforce installed signing identity |
| Split APK inventory | readable from the package protobuf, but nix-android does not yet reconstruct or reinstall bundle splits |
| Stopped/launched state | ephemeral process/user history, not desired persistent configuration |
| System-disabled packages | often build/OEM-specific and unsafe to copy to a different image |
| System DeviceIdle allowlist | owned by the OS, not evidence of user intent |
| Quick Settings layout | tested writes were reverted by SystemUI, so the apparent settings key fails read-back/idempotence |
| Private Space and work-profile inventories | partly readable, but public v1 deliberately manages owner user 0 only; tested work-profile writes were blocked by policy |

## Unreachable through this boundary

ADB shell does not provide a general, faithful restore path for app-private
data, login sessions, Android Keystore keys, eSIM state, backup-opted-out data,
Play entitlement, or silent consumer-Play installation. It also cannot expose
GrapheneOS controls that the OS does not publish to shell. Root, enterprise
device-owner enrollment, custom recovery, and building a replacement OS are
different authority models, not hidden nix-android features.

Finally, the ADB command surface is larger than configuration management:
logs, bug reports, force-stop, activity launches, tracing, and transient test
hooks are useful operations but not persistent desired state. Atlas records the
available `cmd` and settings surface for research; this map covers the
persistent, user-meaningful subset and explicitly accounts for omissions.
