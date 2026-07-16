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

    permissions."com.termux" = {
      grant = [ "android.permission.POST_NOTIFICATIONS" ];
      revoke = [ ];
    };

    batteryOptimization.exempt = [ "com.termux" ];
  };
}
```

The evaluator rejects duplicate app sources, stale lock sources or repository
fingerprints, lock/device ABI mismatches, conflicting permission intent, and
raw Private DNS keys combined with `android.privateDns`. Raw setting values may
not be empty or the literal `null`, because Android's CLI uses `null` for an
absent key.

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
   settings, roles, permissions, disablement, or battery exemptions.
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
  > imported-pixel.nix)
```

Import is read-only. It decodes AOSP's structured package dump into a versioned
snapshot containing package versions, split and per-user state, install-source
evidence, and granted runtime-permission observations. The generated Nix is
more conservative: packages attributed to `com.android.vending` become
`apps.play` presence assertions and all other managed-user third-party apps
become `apps.attended`. Likely main-F-Droid and Obtainium entries also appear
as commented curation candidates. Installer attribution cannot prove a
repository, release URL, or signing trust anchor.

The snapshot and generated inventory are personal data. Keep both out of a
public repository and copy only declarations you deliberately choose to
publish. See [IMPORT.md](./IMPORT.md) for the schema, evidence boundaries, and
planned adapters.

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
