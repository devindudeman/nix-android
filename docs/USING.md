# Using nix-android

## Requirements

- a controller running x86_64 Linux or Apple Silicon macOS
- Nix with flakes enabled
- Android platform tools access to a device whose USB-debugging prompt has
  been accepted
- the adb serial from `adb devices`; device commands never select implicitly

The controller platform is a required `mkDevice` argument because it determines
which adb, jq, aapt2, and shell packages Nix builds. Use `"x86_64-linux"` or
`"aarch64-darwin"`.

## Create a device configuration

Create a configuration flake:

```console
mkdir my-phone && cd my-phone
git init
cat > flake.nix <<'EOF'
{
  inputs.nix-android.url = "github:devindudeman/nix-android";

  outputs = { nix-android, ... }: {
    androidConfigurations.pixel = nix-android.lib.mkDevice {
      system = "x86_64-linux"; # or "aarch64-darwin" on Apple Silicon
      modules = [ ./pixel.nix ];
      lockFile = ./apps.lock.json;
    };

    # Run the CLI version pinned by this flake, not whatever happens to be
    # newest upstream.
    packages.x86_64-linux.android-rebuild =
      nix-android.packages.x86_64-linux.android-rebuild;
  };
}
EOF
```

Create `pixel.nix` and seed the lock with the device ABI. Declaring one app
makes the first lock update meaningful. Files
must be in Git before Nix's flake source can see them.

```console
cat > pixel.nix <<'EOF'
{
  device.name = "pixel";
  device.abi = "arm64-v8a";
  apps.fdroid.packages = [ "org.fdroid.fdroid" ];
}
EOF
printf '%s\n' '{"abi":"arm64-v8a","lockedAt":0,"packages":{}}' > apps.lock.json
git add flake.nix pixel.nix apps.lock.json
nix flake lock
git add flake.lock
```

`flake.lock` now pins nix-android and its inputs. On Apple Silicon, change the
controller system and both package-system attributes from `x86_64-linux` to
`aarch64-darwin`.

Resolve the declared app sources, then inspect the manifest without a device:

```console
nix run .#android-rebuild -- \
  update --flake .#pixel
nix run .#android-rebuild -- \
  build --flake .#pixel
git add apps.lock.json
```

`build` prints the manifest's Nix store path; open that printed file to inspect
the JSON.

`update` accepts `--lock PATH` when the lock is not `./apps.lock.json`; the
path is resolved from the directory where `android-rebuild` runs. `build`,
`plan`, `switch`, `assist`, and `bootstrap` always read the lock pinned by
`mkDevice.lockFile` and reject `--lock`.

## Add nix-android to an existing flake

The same outputs can live beside NixOS, Home Manager, or nix-darwin outputs.
Add the input (following the parent flake's nixpkgs is optional but avoids a
second nixpkgs pin):

```nix
inputs.nix-android = {
  url = "github:devindudeman/nix-android";
  inputs.nixpkgs.follows = "nixpkgs";
};
```

Then add a top-level configuration and expose the pinned CLI for the controller
system:

```nix
androidConfigurations.pixel = inputs.nix-android.lib.mkDevice {
  system = "x86_64-linux";
  modules = [ ./devices/android/pixel.nix ];
  lockFile = ./devices/android/pixel-apps.lock.json;
};

packages.x86_64-linux.android-rebuild =
  inputs.nix-android.packages.x86_64-linux.android-rebuild;
```

With flake-parts, put `androidConfigurations.pixel` under `flake` and the
package alias under `perSystem.packages.android-rebuild`. The resulting command
is still `nix run .#android-rebuild -- plan --flake .#pixel --serial SERIAL`.
When the lock file is nested, pass its path to `update`:

```console
nix run .#android-rebuild -- update --flake .#pixel \
  --lock devices/android/pixel-apps.lock.json
```

`mkDevice.system` describes the controller, not the phone. To control one phone
from both Linux and macOS, reuse the same module and app lock in two outputs:

```nix
androidConfigurations = {
  pixel-linux = inputs.nix-android.lib.mkDevice {
    system = "x86_64-linux";
    modules = [ ./devices/android/pixel.nix ];
    lockFile = ./devices/android/pixel-apps.lock.json;
  };
  pixel-darwin = inputs.nix-android.lib.mkDevice {
    system = "aarch64-darwin";
    modules = [ ./devices/android/pixel.nix ];
    lockFile = ./devices/android/pixel-apps.lock.json;
  };
};

packages = {
  x86_64-linux.android-rebuild =
    inputs.nix-android.packages.x86_64-linux.android-rebuild;
  aarch64-darwin.android-rebuild =
    inputs.nix-android.packages.aarch64-darwin.android-rebuild;
};
```

Select the output matching the machine running adb. Both configurations target
the same declared phone ABI and resolve the same APK lock:

```console
# On Linux
nix run .#android-rebuild -- plan --flake .#pixel-linux --serial SERIAL

# On Apple Silicon macOS
nix run .#android-rebuild -- plan --flake .#pixel-darwin --serial SERIAL
```

Hash-locked F-Droid and release sources share safely. If the module declares an
`apps.local` APK by path, that path must be available when evaluating from each
controller; prefer a path inside a private shared flake or separate
host-specific modules.

## Complete option surface

```nix
{
  device = {
    name = "pixel";       # nickname; safe characters only
    abi = "arm64-v8a";   # armeabi-v7a or x86_64 are also accepted
    user = 0;             # public v1 is owner-only
  };

  apps = {
    # Main f-droid.org repository.
    fdroid.packages = [
      "org.fdroid.fdroid"
      "com.termux"
    ];

    # A third-party F-Droid repository requires its published repository
    # certificate SHA-256 fingerprint as an explicit trust anchor.
    fdroid.repos.futo = {
      url = "https://app.futo.org/fdroid/repo";
      fingerprint = "39d47869d29cbfce4691d9f7e6946a7b6d7e6ff4883497e6e675744ecdfa6d6d";
      packages = [ "org.futo.inputmethod.latin" ];
    };

    # Latest GitHub/Gitea release at lock-update time. Exactly one source is
    # allowed. A release archive must contain exactly one regular APK.
    release."dev.imranr.obtainium.fdroid".github = "ImranR98/Obtainium";
    release."com.example.app".gitea = "git.example.com/owner/repo";

    # The file itself is the pin. Keep personal/self-signed APKs outside the
    # public repo; package ID and versionCode are read with aapt2 at build time.
    local."com.example.mine".apk = /absolute/path/to/mine.apk;

    # Play packages are presence assertions. `assist --watch` opens their
    # official Play listings in order; Android still requires user consent.
    play = [ "com.spotify.music" ];

    # Packages installed by any other human-operated source are also
    # presence assertions.
    attended = [ "com.example.other-store-app" ];

    # Safe default. "uninstall" removes undeclared third-party owner apps.
    cleanup = "none";
  };

  android = {
    # Expert escape hatch. Only declare keys independently verified for the
    # Android version; values are compared as strings.
    settings.global.stay_on_while_plugged_in = 3;
    settings.secure.example_key = "value with spaces";
    settings.system.example_key = 1;

    darkMode = true;              # null = unmanaged; see user-scope note below
    privateDns = "opportunistic"; # "off", "opportunistic", or a DoT host

    defaultApps = {
      browser = "org.mozilla.fennec_fdroid";
      sms = null;
      dialer = null;
      home = null;
    };

    packages.disabled = [ "com.example.unwanted" ];
    packages.suspended = [ "com.example.pause-me" ];
    packages.unsuspended = [ ];

    locales."org.mozilla.fennec_fdroid" = [ "en-US" ];
    inputMethod = {
      enabled = [ "org.futo.inputmethod.latin/.LatinIME" ];
      disabled = [ ];
      default = "org.futo.inputmethod.latin/.LatinIME";
    };
    dataSaver.enabled = true;
    appLinks."org.mozilla.fennec_fdroid" = {
      allowed = true;
      selected = [ ];
      unselected = [ "example.com" ];
    };

    permissions."com.termux" = {
      grant = [ "android.permission.POST_NOTIFICATIONS" ];
      revoke = [ ];
      # Exact state for the writable subset only. Android-owned flags shown by
      # dumpsys remain untouched.
      flags."android.permission.POST_NOTIFICATIONS" = [ "user-set" ];
    };

    appOps."com.termux".RUN_IN_BACKGROUND = "allow";

    batteryOptimization.exempt = [ "com.termux" ];
  };
}
```

Permission flags support `revoked-compat`, `revoke-when-requested`,
`user-fixed`, and `user-set`. A declared flag list is exact for that writable
subset: switch sets listed flags and clears other writable flags, without
touching Android-owned flags such as `SYSTEM_FIXED` or restriction exemptions.
`review-required` also appears in `pm help`, but the AOSP bench observed
PermissionController rewriting it from the app's target SDK immediately after
a shell write, so nix-android does not offer it. App-op values are `allow`, `ignore`, `deny`, `default`, or
`foreground`; declarations are package-level and do not rewrite UID-wide modes.

Permission grants and revocations manage runtime permissions only. A declared
grant of an install-time permission that Android already granted (for
example `android.permission.INTERNET` on stock Android, where it is not the
runtime permission GrapheneOS makes it) is recognized as satisfied; a grant of
an ungranted install-time permission, or any revoke of an install-time
permission, fails during plan because `pm grant`/`pm revoke` cannot change it.
Plan-time classification requires the package to be installed when plan reads
the device: for a managed app first installed during the same apply, an
impossible install-time grant is accepted only if the install itself granted
it, and an impossible install-time revoke fails during apply with that
classification.

`android.locales` owns the exact locale list for each named package; `[]`
returns that app to the system language. Input methods use Android component
names (`package/.Service`): every selected default must also be listed in
`enabled`, and an entry cannot be both enabled and disabled. A fully-qualified
spelling (`package/package.Service`) is normalized to Android's short
component form at build time, because `ime list -s` reports only the short
form and an unnormalized spelling could never converge. Because
`android.inputMethod` owns the same Android state as the raw
`default_input_method`/`enabled_input_methods` secure keys, declaring both is
rejected at evaluation. `dataSaver.enabled`
manages only the global Data Saver switch. Per-app UID allow/deny lists are
captured by import but are not declarable because they were removed across a
graceful reboot for user-installed apps on the mandatory AOSP bench.

Package suspension is scoped to the adb-shell suspending authority. The
`suspended` list adds that authority and `unsuspended` removes it; neither
claims to override Digital Wellbeing, parental controls, or an administrator.
App-link declarations own only the per-user handling toggle and explicit user
domain selection. Android's verifier results, domain signatures, and shell
force-approval states remain OS-owned evidence. A domain may be selected for
only one declared package.

The evaluator rejects duplicate app sources, stale lock sources or repository
fingerprints, lock/device ABI mismatches, conflicting permission intent, raw
Private DNS keys combined with `android.privateDns`, and raw input-method keys
combined with `android.inputMethod`. Raw setting values may not be empty or
the literal `null`, because Android's CLI uses `null` for an absent key.

`android.privateDns` manages Android's system Private DNS setting; it does not
coordinate with VPN or DNS-client policy. Leave it `null` when software such as
a VPN client owns name resolution, or review the networking effect before
switching it.

Android's `cmd uimode night` interface has no user selector. Although public v1
otherwise targets owner user 0, `android.darkMode` must only be switched while
the owner is the foreground user; nix-android does not currently preflight the
active Android user.

## Plan and apply

```console
adb devices

nix run .#android-rebuild -- \
  plan --flake .#pixel --serial SERIAL

nix run .#android-rebuild -- \
  switch --flake .#pixel --serial SERIAL
```

`ANDROID_SERIAL` may replace `--serial`, but an explicit serial is easier to
audit. Before any plan or mutation, the engine validates the complete manifest
and compares `device.abi` with `ro.product.cpu.abi` on the selected target.

`plan` is device-read-only, although Nix may fetch or build missing store paths
on the controller. `switch` computes the same plan and applies it. Review every
line before switching a real device, then run `plan` again; a converged device
prints `✓ device matches manifest`. Missing Play or other attended apps abort
before any device writes.

`bootstrap` is also a mutating command. It exists for a wiped or newly prepared
device and applies a reviewed declaration in resumable phases; it is not a
replacement for reviewing `plan` first.

`switch` is sequential, not transactional. If a later adb action fails, earlier
actions remain applied; re-run `plan` to see the remainder. Managed permission
intent is reasserted after an app install or upgrade. Destructive cleanup, when
explicitly set to `"uninstall"`, runs last so a preceding failure cannot start
removals.

Do not hard-reboot immediately after a switch. Android package restrictions,
app-ops, and device-idle state use write-behind storage. Use a normal power-menu
reboot. In an emulator-only persistence test, after allowing state to settle,
use `adb -s emulator-5554 shell svc power reboot userrequested`.

## Install declared Play apps

When `plan` reports a missing `apps.play` package, open its exact official Play
listing with:

```console
nix run .#android-rebuild -- \
  assist --flake .#pixel --serial SERIAL

# Keep the command running and advance after each on-device installation.
nix run .#android-rebuild -- \
  assist --watch --flake .#pixel --serial SERIAL
```

Like `plan` and `switch`, `assist` checks the selected device ABI against the
manifest before acting.

Without `--watch`, each invocation opens only the first missing package in the
installed Play Store and reports how many follow it. With `--watch`, the helper
polls owner-user package presence, detects the completed on-device install, and
opens the next declaration. It never advances merely because the listing was
opened. The same listing remains first until its package is installed.
nix-android does not sign in, supply Google
credentials, click the install button, accept permissions, or bypass licensing;
the person holding the unlocked phone completes the normal Play flow. Watch mode
times out after 30 minutes per package by default and is safely resumable by
rerunning the command. Run `plan` again afterward.

The declaration is a package-ID presence assertion, not a provenance check.
Convergence does not verify Play entitlement, installer/update owner, signing
identity, enabled state, or version for `apps.play` entries. The assistant also
routes to the installed package named `com.android.vending`; adb shell exposes
no verified general primitive here for authenticating that package's signer.

On GrapheneOS, the initial app installation still requires explicit consent.
Sandboxed Google Play can perform unattended updates afterward when Play was
the last installer. See GrapheneOS's
[sandboxed Google Play documentation](https://grapheneos.org/usage#sandboxed-google-play)
and Android's official
[Google Play linking documentation](https://developer.android.com/distribute/marketing-tools/linking-to-google-play).

## Rebuild a wiped phone

First prepare the OS, enable USB debugging, authorize the controller, and
review the complete plan. On GrapheneOS, install and configure sandboxed Google
Play yourself if the declaration contains `apps.play`; nix-android does not
bootstrap Google services or an account.

```console
nix run .#android-rebuild -- \
  plan --flake .#pixel --serial SERIAL

nix run .#android-rebuild -- \
  bootstrap --flake .#pixel --serial SERIAL
```

`bootstrap` validates the full manifest without contacting adb, then proceeds
in three resumable phases:

1. Install or upgrade hash-addressed managed APKs. This derived phase forces
   `apps.cleanup = "none"`, removes attended assertions, and applies no Android
   state.
2. Run the Play queue in watch mode. Each missing official listing opens in
   declaration order, but installation remains an explicit on-device action.
3. Apply the complete manifest through the normal convergence engine, including
   Android state and any explicitly enabled cleanup.

If Play Store is unavailable, a Play install times out, an adb action fails, or
a generic `apps.attended` entry is still absent, bootstrap stops. Earlier
completed phases remain applied; rerunning the same command rechecks them and
continues from the remaining drift. A missing generic attended entry must be
installed through its declared human source before phase three can proceed.
Cleanup still runs last and never runs in phase one.

This reconstructs declared reachable state, not app data, account sessions,
Keystore material, eSIMs, or OS setup. Finish with a fresh `plan` and require
`✓ device matches manifest`.

## Import an existing phone

```console
(umask 077
nix run .#android-rebuild -- \
  import --serial SERIAL > imported-pixel.nix)

# Optional: also preserve the normalized evidence outside the public checkout.
(umask 077
nix run .#android-rebuild -- \
  import --serial SERIAL \
  --snapshot-out ~/Documents/phone-migration/pixel.snapshot.json \
  --report-out ~/Documents/phone-migration/pixel.coverage.json \
  --obtainium-export ~/Documents/phone-migration/obtainium-export.json \
  --app-manager-export ~/Documents/phone-migration/app-manager-list.json \
  > imported-pixel.nix)
```

Import is read-only. It decodes AOSP's structured package dump into a versioned
snapshot containing package versions, split and per-user state, install-source
evidence, granted-permission observations, writable permission flags,
package-level app-op evidence, and narrow Android state reads. The
generated Nix is more conservative: packages attributed to
`com.android.vending` become
`apps.play` presence assertions and all other managed-user third-party apps
become `apps.attended`. Likely main-F-Droid and Obtainium entries also appear
as commented curation candidates. It also renders representable dark mode and
Private DNS, unambiguous default roles, disabled third-party packages,
user-added battery exemptions, currently granted runtime permissions, writable
permission flags, and non-default package app-op overrides.
It also emits adb-shell package suspension, non-default per-app locales,
enabled/selected input methods, global Data Saver, and non-default user-owned
app-link state. Per-app Data Saver UID rows and Android-owned app-link
verification remain coverage evidence rather than active declarations.
An optional Obtainium schema-v2 export restores supported GitHub and Codeberg
or self-hosted Forgejo release declarations when the current installer also
records Obtainium. Obtainium calls the Forgejo adapter `Codeberg` in exported
source identifiers. Unsupported or conflicting sources stay attended. The
adapter discards complete `settings`, `additionalSettings`, timestamps,
credentials, unsupported host/source details, and arbitrary export fields.
Recovered `apps.release` declarations are lock-backed: run
`android-rebuild update` once before the first `build`/`plan` of the generated
configuration, or evaluation fails with `not in apps.lock.json`. Attended-only
imports need no update step.
An optional App Manager JSON app-list export contributes signing-certificate
SHA-256 evidence and a second installer observation. Signers are emitted as
comments and coverage facts because plan does not yet enforce installed signer
identity.
Permission rendering intersects the package protobuf's broad grant set with
PackageManager's dangerous/runtime definitions, omits hard/soft restricted
grants whose installer/platform allowlisting is not portable, and never infers
revocations. Unparsed permission-restriction metadata omits the grants of the
permission it names; only a row that cannot be attributed to one permission
falls back to omitting all automatic grants. Policy-flag rows are rendered
only when the declaration also reproduces the observed granted state, so a
generated configuration never asserts `user-fixed` on a permission it leaves
denied.
Automatic dark mode, system-owned state, ambiguous rows, and unsupported facts
are retained or reported instead of guessed. Installer attribution cannot
prove a repository, release URL, or signing trust anchor.

The snapshot and generated inventory are personal data. Keep both out of a
public repository and copy only declarations you deliberately choose to
publish. See [IMPORT.md](./IMPORT.md) for the schema, evidence boundaries, and
export adapters.

## Move apps off the Play install-consent path

An import records apps as `apps.play` (presence assertions Play delivers with
per-app consent) or `apps.attended`. Reproducing such a phone means confirming
each Play install by hand, which dominates the setup cost. `suggest-sources`
reports which of those entries are published on a hash-lockable F-Droid source
so they can move to `apps.fdroid` and install unattended:

```console
nix run .#android-rebuild -- suggest-sources --flake .#pixel
```

It is read-only and needs no device. For each `apps.play` and `apps.attended`
entry it checks the main f-droid.org archive and IzzyOnDroid — reusing the same
signed `entry.jar` and index-v2 verification `update` performs, including the
signing-lineage and full lock-field completeness the resolver requires, so a
suggestion is never something `update` would then reject. It prints the
migration: the packages to remove from `apps.play`/`apps.attended` and the
`apps.fdroid` block to add. Availability is a suggestion, not a guarantee of the
same app or signer: move an entry only after you recognize it, then run `update`
(which re-verifies and pins each APK) before converging. Packages not found stay
`apps.play`/`apps.attended`.

GitHub and Gitea releases have no signed package-id-to-repo index, so a repo is
never trusted from its name alone — the model is broad, fallible discovery
followed by package-id verification and a human signer check.

**Verify** a repo you already know with `--release-hint`. It resolves that
release and matches the APK's package id (the same check `update` enforces,
trying each release flavor until one matches):

```console
nix run .#android-rebuild -- suggest-sources --flake .#pixel \
  --release-hint org.example.app=owner/repo \
  --release-hint com.example.other=git.example.com/owner/repo
```

`owner/repo` is GitHub; `host/owner/repo` is Gitea. The resolver requires the
release APK to carry a valid signature and records every signing-certificate
SHA-256 digest; a confirmed hint is rendered as an `apps.release` entry with
those digests shown alongside as **advisory evidence**. This establishes
**package-id compatibility, not source identity**: a different signer's APK with
the same package id installs on a clean phone, and the signer also governs
signature-level permissions and shared-uid identity (nix-android does not yet
enforce signer continuity — see [LIMITS.md](./LIMITS.md)). Confirm the shown
signer is one you trust before relying on it. An unverifiable hint warns (with the underlying reason) and stays
`apps.play`/`apps.attended`. An explicit hint takes precedence even when the
package is also on F-Droid (your explicit intent wins; the F-Droid availability
is noted).

**Discover** candidate repos you do not know with `--discover`, which looks up
each unresolved candidate in the crowdsourced [Obtainium
catalog](https://github.com/ImranR98/apps.obtainium.imranr.dev) (keyed by
package id) and proposes GitHub/Codeberg repos to verify:

```console
nix run .#android-rebuild -- suggest-sources --flake .#pixel --discover
```

Discovery is opt-in because it sends your candidate package ids to a third-party
host over the network. Its output is deliberately **not** promoted into the
migration: the catalog is untrusted and a package-id match alone does not prove
signer continuity (which nix-android does not yet enforce, see
[LIMITS.md](./LIMITS.md)). Each proposal is printed with the `--release-hint`
command to confirm it — recognize the app and ideally check its signer, then
verify, then add.
For the field-by-field ADB read/write/import classification, see
[CAPABILITIES.md](./CAPABILITIES.md).

The optional coverage JSON uses schema version 1 and contains no adb serial. It
is deterministic for a given snapshot and has this top-level shape:

```json
{
  "schemaVersion": 1,
  "snapshotSchemaVersion": 2,
  "device": {
    "model": "Pixel 6",
    "product": "oriole",
    "abi": "arm64-v8a",
    "sdk": 37,
    "securityPatch": "2026-07-05",
    "managedUser": 0
  },
  "summary": {
    "declarable": 0,
    "observed-only": 0,
    "ambiguous": 0,
    "unreachable": 0
  },
  "facts": [
    {
      "surface": "android.example",
      "status": "declarable",
      "itemCount": 1,
      "reason": "example explanation"
    }
  ]
}
```

`status` is one of `declarable`, `observed-only`, `ambiguous`, or
`unreachable`; `itemCount` is an integer or `null` when no finite observed
count exists. New fields or meanings require a coverage `schemaVersion` bump;
`snapshotSchemaVersion` records the input schema interpreted by the renderer.
The report is an audit and regression artifact, not additional desired state.
Treat it as private because its device metadata and counts can still identify
a personal setup.

## Lock and signature behavior

For F-Droid repositories, update verifies the `entry.jar` signature, requires
the trusted certificate fingerprint, verifies that `entry.json` is signed,
checks the index-v2 hash, and records each APK hash. A failed update writes no
partial lock. GitHub/Gitea assets are hash-pinned and their Android package ID
is checked before the lock is written. Release resolution uses anonymous public
APIs and is therefore subject to the host's unauthenticated rate limits.

F-Droid selection follows `metadata.preferredSigner` before versionCode and
records the chosen signing lineage. A repository exposing multiple lineages
without a preferred signer fails closed.

The evaluator binds every configured app's lock entry back to its configured
source. Changing a repository URL, fingerprint, or release owner without
refreshing the lock fails the manifest build. Unreferenced extra lock entries
are ignored.

Android itself rejects an update signed by an incompatible key. nix-android
does not yet predict that mismatch during `plan`; see [LIMITS.md](./LIMITS.md).
