# Limits and semantics

nix-android manages only state that adb shell (uid 2000) can read, write, and
verify without weakening Android's security model. A purpose-built option is
omitted when there is no reliable read-back or persistence primitive. Raw
`android.settings` remains an expert escape hatch for independently verified
keys.

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
declarations own only the five flags PackageManager exposes for shell writes;
system-fixed, restriction-exemption, and other Android-owned flags are never
cleared. App-op declarations are package-level and do not rewrite UID-wide
modes, which often derive from runtime permission state.

`android.darkMode` is the user-scope exception: Android's `cmd uimode night`
interface has no `--user` argument. The v1 engine requires the declared user to
be owner user 0 but does not verify which Android user is foreground. Only
manage dark mode while the owner is active.

## Ensure-only state

`android.packages.disabled` and
`android.batteryOptimization.exempt` ensure their entries are present. Removing
an entry from Nix does not invert the previous action. Re-enable a package or
remove a battery exemption imperatively when desired.

Battery exemption is the one v1 option whose underlying Android primitive is
not owner-profile-scoped: DeviceIdle stores a global package/appId allowlist. If
the same package exists in a work or private profile, the exemption can affect
that profile too.

`android.packages.suspended` and `unsuspended` reconcile only the
`com.android.shell` suspending authority. Android can simultaneously retain a
different suspender, so `unsuspended` does not promise the package is globally
unsuspended. App-link state likewise excludes verifier/force-approval state;
only owner-user handling and selection are managed.

`apps.cleanup = "none"` is additive. `"uninstall"` removes undeclared
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

## Outside the boundary

- app data, Keystore keys, eSIMs, and backup-opted-out application state
- silent consumer-Play fetching or initial-install confirmation
- work-profile mutation; public v1 supports owner user 0 only
- app downgrades or a true rollback of Android's mutable state
- split APK/app-bundle installation and device-to-device APK extraction
- GrapheneOS exploit-protection toggles not exposed to adb shell
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
It does not currently compare installed and desired signer certificates during
planning. Android's package manager refuses an incompatible replacement during
apply; switching signing identities therefore requires a human-controlled
uninstall/reinstall and may lose app data.

## Host platforms

The flake exports controller packages for `x86_64-linux` and
`aarch64-darwin`. Linux is locally exercised; the Apple Silicon release
packages and all device-free Darwin checks pass on a physical ARM Mac. The
dedicated `macos-15` CI job repeats that gate after publication. ARM Linux is
not exported because the pinned Android `aapt2` package is unavailable there.
