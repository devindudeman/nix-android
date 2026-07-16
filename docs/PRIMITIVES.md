# Verified adb primitives

Every option in `modules/options.nix` is backed by an executed read/write test.
Raw captures contain personal device state and live only under
`~/Documents/phone-migration/`; this document records the distilled evidence.

## GrapheneOS read-only surface

Device: Pixel 6 (`oriole`), GrapheneOS build `2026071101`, SDK 37, security
patch `2026-07-05`, adb shell uid 2000.

The 2026-07-15 Atlas rerun listed 333 `cmd` services and 401 current settings
keys. After fixing adb's stdin-drain behavior, the capture contains exactly 333
service headers for 333 listed services. A help section does not imply a
writable or persistent interface.

## Verified read/write primitives

| Primitive | Device evidence | Public option |
| --- | --- | --- |
| `adb install -r --user 0`, `adb uninstall --user 0` | AOSP 35 install/reinstall/removal round trips; additive F-Droid install and version read-back on locked GrapheneOS | managed apps and explicit cleanup |
| `pm list packages --show-versioncode --user 0` | AOSP bench and GrapheneOS owner-user package presence; unlike `-3`, includes preinstalled/system packages | `apps.play`, `apps.attended`, and managed-app diffing |
| `settings get/put --user 0 global/secure/system` | Private DNS and representative keys read/write; all three namespaces exercised on AOSP bench | `android.settings.*`, `android.privateDns` |
| `cmd uimode night` | real-device off/on convergence with no-op read-back; bench idempotence and reboot persistence | `android.darkMode` |
| `cmd role get-role-holders/add-role-holder --user 0` | real-device reversible role check; bench read/idempotence | `android.defaultApps.*` |
| `pm grant/revoke --user 0` | AOSP POST_NOTIFICATIONS round trip reflected in dumpsys; declared grants are read from both the `User 0` runtime block and the package `install permissions:` block, so an already-granted install-time permission (Pixel 9 stock `INTERNET`, read-only 2026-07-16) reads as satisfied and an ungranted install-time grant/revoke aborts before mutation | `android.permissions.*` |
| `pm set-permission-flags/clear-permission-flags --user 0` | AOSP `USER_SET`/`USER_FIXED`/`REVOKED_COMPAT`/`REVOKE_WHEN_REQUESTED` set/clear/read-back plus graceful-reboot persistence; `review-required` is advertised by `pm help` but was rewritten by PermissionController on bench read-back, so only these four are owned | `android.permissions.*.flags` |
| `appops get/set --user 0` | AOSP package-level `RUN_IN_BACKGROUND` allow/ignore/foreground/default and `VIBRATE` deny round trip and graceful-reboot persistence; UID modes remain separate evidence | `android.appOps.*` |
| `pm disable-user --user 0` plus `pm list -d` | AOSP change/read-back/idempotence | `android.packages.disabled` |
| `pm suspend/unsuspend --user 0` plus package-protobuf suspender metadata | AOSP `com.android.shell` suspend/unsuspend round trip, idempotence, and graceful-reboot persistence; read-back matches the `<user>`-qualified `suspendingPackage` line in the package's `Suspend params:` section (emulator-verified 2026-07-16) | `android.packages.suspended`, `unsuspended` |
| `cmd locale set-app-locales/get-app-locales` | AOSP non-empty/clear round trip, idempotence, and graceful-reboot persistence | `android.locales.*` |
| `ime list/enable/disable/set --user 0` | AOSP enable/disable/set round trip, idempotence, and graceful-reboot persistence; declared components are canonicalized to Android's short `ime list -s` form; GrapheneOS enumeration read shape | `android.inputMethod.*` |
| `cmd netpolicy get/set restrict-background` | AOSP global Data Saver change/read-back, idempotence, and graceful-reboot persistence | `android.dataSaver.enabled` |
| `pm get-app-links/set-app-links-allowed/set-app-links-user-selection --user 0` | AOSP owner-user handling denial and positive domain selection round trip, idempotence, and graceful-reboot persistence | `android.appLinks.*` |
| `cmd deviceidle whitelist +/-package` | real-device reversible check; AOSP change/read-back/idempotence | `android.batteryOptimization.exempt` |

Raw `android.settings` is intentionally an expert surface. This table proves
the command path, not every Android-version-specific key. A key is suitable
only after a real change reads back and survives a graceful reboot.

GrapheneOS Network and Sensors controls map to runtime
`android.permission.INTERNET` and `android.permission.OTHER_SENSORS` in package
state. The public engine uses the same verified `pm grant/revoke` mechanism,
but no destructive permission test was performed on the daily phone.

## User-confirmed Play assistance

The Pixel's read-only `am help` output on 2026-07-16 verified that
`start-activity` accepts an explicit `--user`, action, data URI, and target
package. An offline fake-adb fixture verifies that `android-rebuild assist`
opens exactly one
`https://play.google.com/store/apps/details?id=<package>` URI in
`com.android.vending`, refuses unsafe package IDs before adb, and performs no
launch when all declarations are present or the selected device ABI differs.
The fixture also proves `assist --watch` opens multiple declarations in order
only after `pm list packages --user 0` reports each preceding package present.
On 2026-07-16, the authorized two-app acceptance run on a stock Android 16
Pixel 9 Pro opened Wikipedia (`org.wikipedia`) and then Mullvad VPN
(`net.mullvad.mullvadvpn`). The owner confirmed each installation in Play;
watch mode advanced only after package presence appeared. The final plan was a
no-op, and `pm list packages -i --user 0` attributed both installs to
`com.android.vending`. No settings, roles, permissions, cleanup, or unrelated
app declarations were present in the private test manifest.

This is assistance, not silent installation: Android/Play owns authentication,
licensing, delivery, and the install confirmation. The supported public
consumer integration is the official listing link. Fully managed Android
devices have separate enterprise `FORCE_INSTALLED` policy machinery, which is
outside nix-android's stock locked-device boundary. See the official
[Play linking guide](https://developer.android.com/distribute/marketing-tools/linking-to-google-play)
and [Android Management policy reference](https://developers.google.com/android/management/reference/rest/v1/enterprises.policies).

## Other verified candidates without modules

| Primitive | Result |
| --- | --- |
| `cmd wifi add-network/list-networks/forget-network` | dummy WPA2 network added, observed, and removed on GrapheneOS |
| `cmd netpolicy add/remove restrict-background-blacklist/whitelist` | immediate AOSP round trip and policy-file write; user-installed UID rows were removed during graceful reboot, so snapshot evidence only |

These are candidates, not undocumented options. They still need the full
version/persistence design and an engine idempotence test.

## Rejected and bounded primitives

| Boundary | Evidence |
| --- | --- |
| Quick Settings layout | `settings put secure sysui_qs_tiles` accepted a write, then SystemUI restored its own value. It fails read-back/idempotence and has no option. |
| Work profile | package inventory is visible through dumpsys, but shell mutations against the managed user returned `SecurityException` because `DISALLOW_DEBUGGING_FEATURES` applies. |
| Private Space | package enumeration worked on the tested GrapheneOS build, unlike the work profile. It remains outside public v1 pending broader multi-user proof. |
| GrapheneOS exploit protection | no writable state was found in the settings or `cmd` surface. |
| App data and protected identity state | no adb-shell primitive bypasses Android backup opt-out, Keystore, or eSIM boundaries. |

## Persistence finding

On the AOSP bench, an abrupt `adb reboot` immediately after writes preserved
settings and installed apps but lost recently changed device-idle, app-op,
locale, and package-restriction state. After allowing state to settle and using
`svc power reboot userrequested`, the same state persisted. These services use
write-behind files under `/data/system`.

Per-app NetworkPolicy UID rows are a separate negative result. Root inspection
of the emulator-only debug image confirmed the blacklist row was written to
`/data/system/netpolicy.xml`; after graceful reboot Android rewrote the file
without user-installed UID rows. This reproduced with F-Droid and Plezy while
global Data Saver persisted. Consequently import preserves those UID rows as
observed-only evidence and no per-app Data Saver option exists.

Rules derived from the test:

1. never hard-reboot immediately after converge;
2. use graceful user-requested reboot for persistence tests;
3. require a post-reboot no-op plan before calling a primitive persistent.

## Stock Android read-side

A separate stock Android 16 Pixel accepted the same explicit-serial import and
plan read paths for owner-user package inventory. This is one read-side data
point, not a blanket compatibility claim for every OEM Android build.

On 2026-07-16, snapshot-v2 capture on that stock Pixel 9 Pro (SDK 36) also
completed the narrow read-only surface for `cmd uimode night`, both Private DNS
settings, four role-holder queries, all disabled owner-user packages,
`cmd deviceidle whitelist`, and `pm list permissions -d -g -f`. The structured
package dump contained 612 per-user permission records; missing proto2 scalar
IDs decoded semantically as owner user 0. PackageManager listed 268
dangerous/runtime permission definitions. Intersecting those definitions with
the broad package grant set produced valid active grant declarations while
omitting normal, app-defined, and hard/soft restricted grants. The final
capture also classified stock-only denied-permission rows without a flags
suffix, platform AppOps identities, and invalid manifest `autoVerify` domains
without an unparsed row. Automatic dark mode and seven disabled system packages
were retained as evidence and explicitly omitted rather than misrepresented.
The generated Nix evaluated successfully and its complete read-only plan
against the same phone was a no-op. No device mutation was performed.

The same capture confirmed an upstream diagnostic limitation: AOSP declares
`UserInfoProto.first_install_time_ms` as signed `int32`, and the stock Pixel's
present-day values were overflowed. Snapshot v2 preserves that field as
`firstInstallTimeMsWire` rather than inventing a timestamp.

The matching read-only comparison ran against the Pixel 6 GrapheneOS build
`2026071101` on 2026-07-16. Snapshot v2 parsed 272 dangerous/runtime
definitions without an unparsed row and confirmed `android.permission.INTERNET`,
`android.permission.OTHER_SENSORS`, and
`android.permission.ACCESS_LOCAL_NETWORK` in GrapheneOS's set but not the stock
Pixel's. Its first generated plan also exposed a scope bug: a `source=user`
DeviceIdle row referred to Google Play services installed only in another
profile. DeviceIdle is global, so source alone does not prove owner-user intent.
The importer now intersects user-added DeviceIdle rows with the independent
`pm list packages --user 0` inventory; the out-of-scope row remains snapshot
evidence and an explicit omission. The recaptured generated module evaluated
through `lib.mkDevice` and planned as an exact no-op against the same GrapheneOS
phone in 10.7 seconds. The comparison also observed a system package present in
the owner-user `pm` inventory but absent from the package protobuf, so only
third-party declarations—not the full independent inventory—are required to
appear in that diagnostic format. No device mutation was performed.

## Engine bugs caught by hardware-shaped tests

- adb consumed a process-substitution loop's stdin, so only its first item ran;
  all engine adb calls now read from `/dev/null`.
- tab-separated `read` collapsed empty setting fields; internal tuples now use
  ASCII Unit Separator.
- adb joins `shell` arguments before the remote shell parses them; the engine
  now builds one single-quoted remote command.
- malformed JSON in a process substitution could bypass `set -e`; a complete
  manifest schema check now runs before the first adb read.

The mandatory release bar remains plan → apply → direct verification → no-op
plan → graceful reboot → no-op plan on the AOSP bench.
