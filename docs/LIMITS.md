# Supported targets, limits, and semantics

nix-android manages only state that adb shell (uid 2000) can read, write, and
verify without weakening Android's security model. A purpose-built option is
omitted when there is no reliable read-back or persistence primitive. Raw
`android.settings` remains an expert escape hatch for independently verified
keys.

## Supported targets

nix-android supports two device families:

1. Google Pixel devices running Google's stock Android build;
2. Google Pixel devices running an official GrapheneOS build.

Public configuration manages owner user 0 over authorized adb shell uid 2000.
The bootloader may remain locked, verified boot remains enabled, and Nix runs on
the controller rather than the phone. The AOSP emulator is the mutation test
bench and format reference; it is not a third consumer support family.

| Target | Executed evidence | Role |
| --- | --- | --- |
| Stock Pixel | Pixel 9 Pro, Android 16 / SDK 36: read-only snapshot v2, generated-module evaluation, exact no-op plan, and user-approved Play assistance | supported consumer target |
| GrapheneOS Pixel | Pixel 6, Android 17 / SDK 37, build `2026071101`: read-only snapshot v2, GrapheneOS permission-definition discovery, generated-module evaluation, exact no-op plan, and earlier explicitly approved additive/reversible acceptance tests | supported privacy target |
| AOSP emulator | Android 15 / SDK 35 x86_64: mutation, idempotence, graceful-reboot persistence, cleanup, bootstrap, and import round trip | mandatory mutation bench |

These rows are concrete compatibility evidence, not a promise that every past
or future release has identical command output. Synthetic fixtures preserve the
observed stock/Graphene command shapes without publishing device inventories.
When an OS update changes a read format, import must fail visibly or classify
the row as ambiguous; it must never silently emit a weaker declaration.

- Owner user 0 is supported. Work profiles and Private Space can contribute
  read-only evidence but are not managed targets.
- Current official stock Android and GrapheneOS releases are the intended
  compatibility window. Older builds may work but are best-effort unless an
  executed fixture or hardware check covers them.
- Other AOSP-derived phones and OEM builds are best-effort. Contributions are
  welcome, but successful adb authorization alone is not a support claim.
- Controller platforms are listed under [Host platforms](#host-platforms).

For every public option, the target family must provide a verified read,
write, read-back, idempotence, and graceful-reboot persistence path on the AOSP
bench, plus read compatibility on the relevant real-phone family. Unsupported
or OS-owned state stays snapshot evidence with an explicit coverage status.
Missing root, enterprise enrollment, and the items under
[Outside the boundary](#outside-the-boundary) are authority boundaries, not
missing compatibility shims.

## Reconciled state

`switch` reconciles every item below. `bootstrap` reconciles managed APKs in
its cleanup-free first phase, then rechecks them while reconciling the remaining
state from the complete manifest in its final phase:

- managed APK presence and upgrades to the locked version floor
- raw declared settings keys, dark mode, Private DNS, and default app roles
- explicit runtime permission grants/revocations and writable policy flags
- package-level app-op modes
- per-app locale lists, input-method enablement/selection, and global Data Saver
- adb-shell package suspension/unsuspension and user-owned app-link choices

Pins are floors, not exact versions. A newer installed app is accepted; Android
user builds do not permit ordinary downgrades.

Permission and app-op declarations are reasserted after a managed install or
upgrade, because a package transition can change that state. Permission-flag
declarations own only the four shell-writable flags that passed bench
read-back (`review-required` is advertised by `pm help` but rewritten by
PermissionController); system-fixed, restriction-exemption, and other
Android-owned flags are never cleared. App-op declarations are package-level and do not rewrite UID-wide
modes, which often derive from runtime permission state.

Grant and revoke declarations manage runtime permissions. Whether a permission
is runtime depends on the OS: GrapheneOS makes `INTERNET` and `OTHER_SENSORS`
runtime, stock Android does not. A declared grant of an install-time
permission Android already granted is satisfied; a grant of an ungranted
install-time permission or a revoke of any install-time permission fails
during plan, because `pm grant`/`pm revoke` cannot change install-time state.
That plan-time classification only covers packages installed when plan reads
the device. A package first installed by the same apply is classified after
its install: an impossible grant is accepted only when the install granted
the permission for the managed user, and an impossible revoke stops the
sequential apply at that step with a clear message.

Grant and permission-flag declarations for a permission the installed package
does not request fail during plan, before any write. Whether a permission is
requested is read from `dumpsys package` (present in the owner user's runtime
block or the install-permissions block), not from the APK manifest, so a
requested permission whose definition is missing on this OS also reads as not
requested. For a package installed or upgraded by the same apply this is known
only after the install: an unrequested revoke is treated as satisfied, an
unrequested grant stops the apply at that step, and an unrequested flag
declaration is applied as a silent no-op and caught by the next plan.

`android.darkMode` is the user-scope exception: Android's `cmd uimode night`
interface has no `--user` argument. The v1 engine requires the declared user to
be owner user 0 but does not verify which Android user is foreground. Only
manage dark mode while the owner is active.

## Ensure-only state

`android.packages.disabled` and
`android.batteryOptimization.exempt` ensure their entries are present.
`android.batteryOptimization.unexempt` is the ensure-absent counterpart: it
removes a listed package from the allowlist and reasserts the removal if
something re-adds it. Removing an entry from any of these lists does not invert
the previous action. Re-enable a package or change a battery exemption
imperatively when desired. A disabled entry that is not installed for the owner
user is skipped with a note rather than failing the plan, so a shared config may
name system packages one model does not ship; a typo in a package name is
therefore also only a note.

Battery exemption is the one v1 option whose underlying Android primitive is
not owner-profile-scoped: DeviceIdle stores a global package/appId allowlist. If
the same package exists in a work or private profile, the exemption can affect
that profile too.

`android.packages.suspended` and `unsuspended` reconcile only the
`com.android.shell` suspending authority. Android can simultaneously retain a
different suspender, so `unsuspended` does not promise the package is globally
unsuspended. App-link state likewise excludes verifier/force-approval state;
only owner-user handling and selection are managed.

`apps.cleanup = "none"` is additive. `"report"` is also additive: plan and
switch print a note per undeclared third-party app without counting it as drift
or ever uninstalling it. `"uninstall"` removes undeclared
third-party apps for owner user 0 and is intentionally destructive; always
review its plan. System packages are not cleanup candidates. Cleanup starts only
after every preceding install, setting, role, permission, disablement, and
exemption command returns success; the required follow-up `plan` verifies actual
convergence.

## Failure and rollback semantics

`switch` applies its reviewed plan sequentially; it is not an atomic Android
transaction. If an adb action fails, earlier actions remain applied and later
actions are skipped. A new `plan` reports the remaining drift. nix-android does
not snapshot app data or provide a general rollback, and version floors do not
downgrade a newer APK.

`bootstrap` is also sequential and resumable, not transactional. Its first
phase applies only managed APK installs/upgrades with cleanup disabled and all
Android state neutralized. Its Play phase requires user-confirmed installation.
Only its final phase applies the complete manifest. A failure leaves completed
work in place; rerunning recomputes each phase from device state.

## Play-assisted and attended state

Google's supported consumer integration opens an app's official Play listing;
it does not provide nix-android a headless APK-fetch/install API.
`apps.play` retains the declared source label while asserting package presence;
`android-rebuild assist` can open the first missing app's official Play listing;
`assist --watch` advances only after Android reports that package installed,
but the user owns account sign-in and installation consent. `apps.attended`
provides the same presence assertion for other human-controlled sources without
claiming Play provenance. Missing entries in either list abort plan and switch
before any mutation. See Google's
[Play linking guide](https://developer.android.com/distribute/marketing-tools/linking-to-google-play).

Convergence matches only the Android package ID. It does not prove the current
installer/update owner, Play entitlement, signing identity, enabled state, or
version. Import initially assigns `apps.play` only when the snapshot records
`com.android.vending` as installer, but that attribution remains evidence rather
than enforced provenance. `assist` likewise targets the installed package with
that package ID; it does not authenticate the Play Store package's signer.

Android Enterprise can force-install Play apps only after enterprise binding
and device/work-profile enrollment. nix-android does not silently turn a
personal device into an enterprise-managed device; that separate mechanism is
documented in the
[Android Management policy reference](https://developers.google.com/android/management/reference/rest/v1/enterprises.policies).
GrapheneOS
[sandboxed Play](https://grapheneos.org/usage#sandboxed-google-play) can
automatically update apps after their user-approved initial installation when
Play remains the last installer.

Cross-profile interference is real and outside nix-android's control: Android
keeps one APK copy per device shared across profiles, and a declared Play app
already installed in another profile (for example a work profile) can wedge
the owner-profile Play install indefinitely when the on-device copy is stale —
a current copy typically completes instantly without a download. The remedy is
user-side (update the app inside the owning profile first). `assist` waits on
package presence either way, and `--watch` follows declaration order, so one
wedged install blocks the consents behind it; interrupt and re-run after
resolving — already-installed apps are skipped.

## Outside the boundary

- root, bootloader unlocking, and enterprise device-owner enrollment
- app data, Keystore keys, eSIMs, and backup-opted-out application state
- silent consumer-Play fetching or initial-install confirmation
- work-profile mutation; public v1 supports owner user 0 only
- app downgrades or a true rollback of Android's mutable state
- split APK/app-bundle installation and device-to-device APK extraction
- GrapheneOS per-app exploit-protection toggles: write-only via
  `pm edit-gos-package-state` with no read-back, so not managed; other
  GrapheneOS controls are mapped in [GRAPHENEOS.md](./GRAPHENEOS.md)
- exact Quick Settings layouts: SystemUI reverted tested writes
- Wi-Fi declarations and per-app Data Saver UID policy; the latter passes
  read-back but loses user-installed rows across the mandatory AOSP reboot gate

Private Space inventory has been readable in testing, but it is deliberately
outside the v1 engine until multi-user behavior is proven across supported
Android versions.

`android.privateDns` writes Android's system Private DNS keys. nix-android does
not merge that intent with VPN or DNS-client configuration; leave it unmanaged
when another tool owns name resolution unless the combined behavior has been
reviewed.

## APK signatures

nix-android authenticates F-Droid repository metadata and pins artifact hashes.
For every pending upgrade, `plan` compares the installed APK's signer digests
with the manifest APK's and prints a definitive `WILL fail` note when they are
disjoint, falling back to an installer-provenance heuristic when `apksigner` is
unavailable or the pull fails (see [USING.md](./USING.md#plan-and-apply)).
Android's package manager refuses an incompatible replacement during apply; switching signing identities therefore requires a human-controlled
uninstall/reinstall and may lose app data.

## Host platforms

The flake exports controller packages for `x86_64-linux` and
`aarch64-darwin`. Linux is locally exercised; the Apple Silicon release
packages and all device-free Darwin checks pass on a physical ARM Mac. The
dedicated `macos-15` CI job repeats that gate after publication. ARM Linux is
not exported because the pinned Android `aapt2` package is unavailable there.
