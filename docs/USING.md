# Using nix-android

## Requirements

- a controller running x86_64 Linux or Apple Silicon macOS
- Nix with flakes enabled
- Android platform tools access to a device whose USB-debugging prompt has
  been accepted
- the adb serial from `adb devices`; device commands never select implicitly

[QUICKSTART.md](./QUICKSTART.md) covers enabling USB or wireless debugging;
[TROUBLESHOOTING.md](./TROUBLESHOOTING.md) covers common failures.

The controller platform is a required `mkDevice` argument because it determines
which adb, jq, aapt2, and shell packages Nix builds. Use `"x86_64-linux"` or
`"aarch64-darwin"`.

## Selecting an ADB client

`NIX_ANDROID_ADB` selects a single executable for device operations in the
converge engine, importer, Play assistant and Atlas probe, and for
`android-rebuild`'s own device preflight (`adb devices`) and `status`. It overrides the
packaged tool's ADB even when Nix prepends its runtime inputs to PATH. Use an
absolute executable or wrapper path; arguments belong in the wrapper rather
than the variable. An unavailable override fails without falling back to another
client. Explicit serial selection and manifest validation still apply, and the
override is inherited by bootstrap's engine/assistant subprocesses.

For example, a WSL controller can select a local wrapper that invokes the
Windows ADB client already authorized by the phone:

```console
NIX_ANDROID_ADB=/absolute/path/to/windows-adb-wrapper \
  nix run .#android-rebuild -- plan --flake .#phone --serial SERIAL
```

The wrapper and Windows server's trust/device inventory are controller-local
inputs. Their implementation must preserve argv and any caller's device guards.
Windows clients also need Windows paths for install/pull operations; a shell-only
bridge is insufficient evidence that APK transfers work. This variable selects
a controller transport, not Android API compatibility or an emulator endpoint.

The engine only queries package inventories, disabled-package state, input
methods and DeviceIdle when the manifest declares state that needs them.
A raw-settings-only declaration therefore requires the target ABI and scoped
`settings get/put` interfaces rather than unrelated modern Android services.
Other declarations retain their own API prerequisites; this does not establish
full provisioning support for older OEM phones.

## Create a device configuration

The fastest start is the template, which scaffolds a working flake plus a
`phone.nix` documenting the main option groups inline (the full reference is
the generated [OPTIONS.md](./OPTIONS.md)):

```console
mkdir my-phone && cd my-phone
nix flake init -t github:devindudeman/nix-android
git init && git add -A   # Nix only sees git-tracked files
nix flake lock && git add flake.lock
```

Then edit `phone.nix` (uncomment the apps you want; `device.abi` already
defaults to `arm64-v8a`) and skip to *Resolve the declared app sources* below.
Two faster ways to populate it: `nix run .#android-rebuild -- import --serial
SERIAL` reads a live device into a draft config, and `nix run .#android-rebuild
-- suggest-sources` finds F-Droid/GitHub sources for Play apps.

The rest of this section explains what the template writes, if you would rather
assemble it by hand.

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
    # newest upstream, on every supported controller system.
    packages = builtins.mapAttrs (_: p: { inherit (p) android-rebuild; })
      nix-android.packages;
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
controller `system` from `x86_64-linux` to `aarch64-darwin`.

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

`android-rebuild` evaluates the target flake with `--impure`, so a single
output may also pick the controller with
`system = builtins.currentSystem or "x86_64-linux";` and `apps.local` may
point outside the flake. It does not pass `--accept-flake-config`: a
`nixConfig` in the flake you name (extra substituters, keys) is not trusted
silently. Nix prompts on a terminal and otherwise ignores it with a warning;
put caches you rely on in `nix.conf`, or answer the prompt once.

Hash-locked F-Droid and release sources share safely. If the module declares an
`apps.local` APK by path, that path must be available when evaluating from each
controller; prefer a path inside a private shared flake or separate
host-specific modules.

## Options

Every option, with its type, default, and description, is in the generated
[OPTIONS.md](./OPTIONS.md) (rendered from the typed module options via `just
options-doc`). The canonical annotated example is the template's
[phone.nix](../templates/default/phone.nix): it documents every option group
inline, and the `template` check builds its active block against the real
option surface. The README has a short
[filled-in example](../README.md#set-up-a-config). Executed device evidence is
indexed separately in [PRIMITIVES.md](./PRIMITIVES.md). The notes below cover
semantics the option descriptions only summarize.

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

Every grant and flag declaration must name a permission the package requests.
When the package is installed and unchanged by the plan and its dump lists the
permission in neither the user's runtime block nor the install-permissions
block, plan fails with `<package> does not request <permission>` before any
write (`pm grant` would throw and `pm set-permission-flags` would silently do
nothing). A revoke of a permission the package does not request is already
satisfied. For a managed app installed or upgraded by the same apply, the check
runs after its install: a revoke the new APK does not request is noted and
skipped, and an unrequested grant stops the apply with the same reason.

`packages.disabled` does not require its entries to exist, so one shared config
can disable a system package that only some models ship: an entry not installed
for the owner user is skipped with a note. Every other package reference
(roles, permissions, suspension, battery exemption, app-ops, locales, app
links, input methods) must be installed or declared as an app.

`android.locales` owns the exact locale list for each named package; `[]`
returns that app to the system language. Input methods use Android component
names (`package/.Service`): every selected default must also be listed in
`enabled`, and an entry cannot be both enabled and disabled. A fully-qualified
spelling (`package/package.Service`) is normalized to Android's short
component form at build time, because `ime list -s` reports only the short
form and an unnormalized spelling could never converge. Because
`android.inputMethod` owns the same Android state as the raw
`default_input_method`/`enabled_input_methods` secure keys, declaring both is
rejected at evaluation. `doNotDisturb.mode` manages only the global Do Not Disturb
mode (`off`, `priority`, `alarms`, or `total` for total silence); it is set with
`cmd notification set_dnd` because Android silently ignores a shell write to the
`zen_mode` setting, so `android.settings.global.zen_mode` cannot do it. A device without
`set_dnd` fails the plan with a clear message (Android 6 has no `cmd` at all; the oldest Android that
has `set_dnd` has not been established, and the AOSP Android 15 bench is the only version proven). Automatic schedules and the priority exceptions are left alone. `dataSaver.enabled`
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

Before building anything, device commands look the serial up in `adb devices`
(discovery only) and stop with a one-line hint when it is missing,
`unauthorized`, or `offline`. A flake with several `androidConfigurations`
needs `--flake REF#NAME`; an unknown name prints the available ones, for
example `android-rebuild: no device 'nope'; available: bench, darwin-smoke`.

`plan` is device-read-only, although Nix may fetch or build missing store paths
on the controller. `switch` computes the same plan and applies it. Review every
line before switching a real device, then run `plan` again; a converged device
prints `✓ device matches manifest`. Missing Play or other attended apps abort
before any device writes.

Exit codes are a stable contract, so scripts can tell "needs a switch" from
"broken":

| Code | Meaning |
| --- | --- |
| 0 | In sync (`plan`, `status`), or `switch`/`bootstrap` applied successfully |
| 1 | Error: adb or device failure, unreachable serial, nothing recorded for `status`/`generations` |
| 2 | Usage error or refused preflight (bad flags, unknown device name, invalid manifest, ABI mismatch) |
| 3 | `plan` or `status` found pending changes (`-- plan only (N changes)`) |
| 4 | Blocked on attended or Play apps only a person can install (`plan`, `switch`, `status`, `assist --watch` timeout) |

`switch` returns 0 after applying changes; it never returns 3. Before this
contract, pending changes and an in-sync device both exited 0, and a missing
Play app exited 1 like an adb failure.

Advisory `note:` lines (signer preflight, `apps.cleanup = "report"`) go to
stderr after the last plan line and before the verdict, including when the
run is blocked on Play apps. stdout carries only plan lines and the verdict.

A fresh install starts a package from default permission state, and an upgrade
can reset specific grants, flags, or app-ops depending on the version
transition. So the engine reasserts your declared intent after an install or
upgrade — precautionary, not a claim that Android blanket-resets everything.
`plan` marks those induced lines `(after install)` or `(after upgrade)` — for
example `grant org.fdroid.fdroid android.permission.POST_NOTIFICATIONS (after
install)` — so a reassertion of already-correct state reads as a sequenced
consequence, not unexplained drift.

`bootstrap` is also a mutating command. It exists for a wiped or newly prepared
device and applies a reviewed declaration in resumable phases; it is not a
replacement for reviewing `plan` first.

`switch` is sequential, not transactional. If a later adb action fails, earlier
actions remain applied; re-run `plan` to see the remainder.

An upgrade can fail with `INSTALL_FAILED_UPDATE_INCOMPATIBLE` when the
installed copy is signed by a different key than the declared source's build —
Android refuses cross-signer upgrades. For every pending upgrade `plan` runs an
exact signer preflight: it pulls the installed APK, compares its `apksigner`
digest set against the manifest APK's, and stays silent on an overlap (the
in-place upgrade is verified acceptable) or emits a definitive `note: … WILL
fail` on disjoint sets. When `apksigner` is unavailable (a standalone engine)
or the pull fails, it falls back to the older provenance heuristic: a `note:
… will likely fail` when the installed copy's installer is Play-ecosystem
(Play Store, Aurora) but the declared source is F-Droid/GitHub. The fix in
either case is uninstalling the app so switch reinstalls it from the declared
source, or reclassifying its lane. Managed permission
intent is reasserted after an app install or upgrade. Destructive cleanup, when
explicitly set to `"uninstall"`, runs last so a preceding failure cannot start
removals.

### Installer of record and on-device updaters

A plain `adb install` records no installer (`installerPackageName=null`,
initiated by `com.android.shell`). Android lets an app store update a package
without a confirmation prompt only when that store is the package's installer
of record, so a store such as Droid-ify or Obtainium cannot silently update
apps nix-android installed, and an engine upgrade resets an app the store
already owned. Set `apps.updaters.fdroid` (F-Droid and third-party F-Droid
repos) and `apps.updaters.release` (`apps.release`) to the updater's package
ID and every install, upgrade, and bootstrap phase passes `-i <updater>`.
`apps.local` apps never record one.

The updater must be installed for the owner user at install time; otherwise
Android silently records null. When the updater is itself a declared app,
switch installs it first, reads the installer back afterward, and re-owns any
app that still lacks it (including an updater that is its own installer) with
one same-version reinstall. An updater missing from the device produces a
`note: updater … is not installed` and changes nothing.

`plan` also notes installed apps whose installer of record differs from the
configured updater. The only adb path that changes the installer of an
existing app is reinstalling the same versionCode with `-i` (`pm
set-installer` is refused to the shell), so it is opt-in:
`apps.updaters.reown = true` turns those notes into `reown` plan lines. A
reown keeps app data but restarts the app, and its permission/AppOps intent is
reasserted afterward. It only applies when the installed versionCode equals
the lock; an app that is ahead of the lock stays a note until `update` catches
the lock up. nix-android never passes `--update-ownership`, so it does not pin
updates to one store.

On GrapheneOS, the USB-C port defaults to charging-only while locked. A
session opened before locking keeps working, but a cable replug while locked or
the auto-reboot drops adb until the next unlock. Keep the phone unlocked for
long runs (`assist --watch`, `bootstrap`, a large `switch`); `switch` warns
when the keyguard is showing. See [GRAPHENEOS.md](./GRAPHENEOS.md).

Do not hard-reboot immediately after a switch. Android package restrictions,
app-ops, and device-idle state use write-behind storage. Use a normal power-menu
reboot. In an emulator-only persistence test, after allowing state to settle,
use `adb -s emulator-5554 shell svc power reboot userrequested`.

### Fetch performance

Every managed APK is its own fixed-output `fetchurl` derivation, so a lock
refresh that moves many apps means many downloads. `build`, `plan`, `switch`,
`assist`, and `bootstrap` pass `--max-jobs 8` to `nix build`, so those fetches
run concurrently even on a controller whose `nix.conf` says `max-jobs = 1`.
Override it with `NIX_ANDROID_MAX_JOBS` (a positive integer or `auto`):

```console
NIX_ANDROID_MAX_JOBS=16 nix run .#android-rebuild -- plan --flake .#pixel --serial SERIAL
```

`max-jobs` is one of the client options the Nix daemon applies for every
client, trusted or not, so no `trusted-users` entry is needed.

Before building, those commands print `fetching N APKs (M MB) ...` on stderr
when managed APKs are missing from the local store (nothing when all are
present). The count comes from a sub-second evaluation of the device's
`fetchPlan` output; it is skipped silently if that evaluation fails or takes
longer than five seconds. Sizes come from the lock: F-Droid entries record
the signed index's file size, release entries do not, so the figure reads
`M+ MB` when some sizes are unknown and is omitted when none are known.

F-Droid entries also carry up to four HTTPS mirrors, taken at `update` time
from the repository's signed index (`repo.mirrors`; `http://` and `.onion`
mirrors are dropped). The APK is fetched with `fetchurl { urls = [ primary ] ++
mirrors; }` under the same locked sha256, so a mirror that serves different
bytes fails the hash check exactly as a tampered primary would. Mirrors are
tried in order only when the previous URL fails (an HTTP error, connection
failure, or hash mismatch); a primary that is merely slow is not abandoned.
Locks written before mirrors existed simply have no `mirrors` field and fetch
from the primary only; run `update` to add them. Release-lane entries never
have mirrors.

## Generations and drift

After every successful `switch` (including a no-op switch on an
already-converged device), the controller attempts to record a *generation*: a
copy of the applied manifest plus a log line under
`${XDG_STATE_HOME:-~/.local/state}/nix-android/<device.name>/`. Receipt writes
are staged atomically; if controller storage is unavailable, `switch` warns but
remains successful because the device has already converged. This is like a
home-manager profile generation, but it is **not** a NixOS bootable snapshot. It
cannot restore app data, downgrade an app, or undo an ensure-only entry the
device later dropped.

```console
# Has the device drifted from what you last switched?
nix run .#android-rebuild -- \
  status --flake .#pixel --serial SERIAL

# List recorded convergences (generation, time, change count, serial).
nix run .#android-rebuild -- \
  generations --flake .#pixel
```

`status` re-plans the *last-applied* generation against the device, so it
reports divergence since the last switch — distinct from `plan`, which shows
what the *current* config would change. It reads reachable state only; a clean
result prints `✓ device matches manifest` and exits 0; drift exits 3. If
nothing has been recorded yet, `status` and `generations` say so on stderr and
exit 1. Each receipt also records the OS
build (`ro.build.fingerprint`, `ro.build.version.incremental`); when the device
has since taken an OTA, `status` prints `OS changed since last switch: <old> →
<new>` first, and `generations` lists each receipt's build (`unknown` for
receipts recorded before this field). If the last generation's saved
manifest is missing (deleted or never fully written), `status` says so rather
than guessing. `generations` and the other device-free verbs (`build`,
`update`, `suggest-sources`) reject `--serial`.

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

Watch mode follows declaration order, so a wedged install blocks the consents
behind it. A common wedge: the declared app is already installed in another
profile with a stale version, which can hang the owner-profile Play install
indefinitely (a current copy typically completes instantly) — update the app
inside the owning profile first, then re-run `assist`; installed packages are
skipped. See [LIMITS.md](./LIMITS.md).

The declaration is a package-ID presence assertion, not a provenance check.
Convergence does not verify Play entitlement, installer/update owner, signing
identity, enabled state, or version for `apps.play` entries. The assistant also
routes to the installed package named `com.android.vending`; adb shell exposes
no verified general primitive here for authenticating that package's signer.

On GrapheneOS, the initial app installation still requires explicit consent.
Sandboxed Google Play can perform unattended updates afterward when Play was
the last installer. Keep `com.android.vending` and `com.google.android.gms` in
`apps.attended`; GrapheneOS only accepts their installation from its own App
Store or from shell ([GRAPHENEOS.md](./GRAPHENEOS.md#grapheneos-and-installers)). See GrapheneOS's
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
comments and coverage facts, not enforced; to enforce a release app's signer,
copy the digest you trust into `apps.release.<pkg>.signerSha256`.
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

## Choosing a lane

`apps.play` should be the last resort, not the default. The recommended
preference order, most- to least-declarative:

1. **`apps.fdroid`** (main f-droid.org) — signed index, hash-locked,
   unattended.
2. **`apps.fdroid.repos.<name>`** — a third-party F-Droid repo you already
   trust (IzzyOnDroid, a vendor's own repo), same lock guarantees under your
   pinned fingerprint.
3. **`apps.release`** — GitHub/Gitea releases (`github`/`gitea`) or the
   vendor's own direct APK channel (`url`/`updateJson`/`html`), hash- and
   signer-recorded at lock time. Many major vendors publish the same build
   they ship to Play, under the *same signing key*, on their own site — a
   vendor update-manifest JSON (`updateJson`, Signal's `latest.json` schema)
   beats a bare `url` when offered, because the manifest points at versioned
   immutable APKs, while a mutable "latest" URL can hash-mismatch at fetch
   time once the vendor replaces the file (the copy fetched at lock time
   keeps working from the local store or a binary cache; `update` is the
   remedy). Vendors that only link a versioned APK from a web page (Steam)
   use `html`: a discovery-only scrape where exactly one page link must match
   your `linkFilter` regex — the page merely *nominates* the URL, and the
   download still passes every package-id and signature check, so a changed
   or hostile page can only fail the update, never install the wrong app.
   For every release lane, GitHub/Gitea included (a release is only an upload
   by whoever holds the repository's credentials), the only trust anchors are
   TLS and the recorded signer, so `update` refuses a signer change unless
   explicitly allowed (`update --allow-signer-rotation PKG`), and the build
   refuses an APK whose signers are not in the lock. The first lock is
   trust-on-first-use; pin the signer in config with
   `apps.release.<pkg>.signerSha256` once you have confirmed it. Verify the
   vendor channel before declaring it:

   ```console
   apksigner verify --print-certs installed.apk   # pulled via adb
   apksigner verify --print-certs vendor.apk      # from the vendor's site
   ```

   Identical signer digests mean the vendor channel can upgrade the installed
   copy in place. Different digests mean the installed copy can only be
   upgraded by its current channel — switching requires an uninstall.
4. **`apps.local`** — the APK file is the pin (self-built, custom-signed).
5. **`apps.attended` + a human-driven vendor download** — for vendors whose
   direct URLs are bot-guarded or expiring-signed (a lock refresh cannot
   absorb that breakage, e.g. WhatsApp's expiring signed CDN links), declare
   the app attended and let an on-device updater (e.g. Obtainium) or a human
   deliver it.
6. **`apps.play`** — only for apps with no other distribution at all.

Picking a source for a new app — stop at the first rung that holds:

1. `suggest-sources` finds it on f-droid.org or a repo you already pin →
   `apps.fdroid`.
2. The vendor has GitHub/Gitea releases shipping an APK → `github`/`gitea`
   (confirm the signer you trust once, from the lock's recorded digests).
3. The vendor publishes an update-manifest JSON → `updateJson`.
4. The vendor publishes a stable direct APK URL → `url`.
5. The vendor's page links a versioned APK → `html` with a `linkFilter`
   tight enough to match exactly one link.
6. The APK is self-built, or the vendor URL is expiring/bot-guarded →
   `apps.local`, or `apps.attended` + an on-device updater.
7. Nothing above exists → `apps.play`.

Set `apps.cleanup = "report"` once your declaration covers the device: every
plan then notes installed-but-undeclared apps (without ever uninstalling or
dirtying the in-sync verdict), so drift finds you instead of accumulating
until the next manual import.

Whenever a lane change would take over an app that is already installed,
compare signers first (the apksigner recipe above): the same digest means the
new channel upgrades in place; a different digest means uninstall/reinstall.
Locked versions are floors, so an on-device updater running ahead of the lock
is never a conflict.

Every step down the list costs reproducibility: lanes 1–4 reinstall unattended
on a wiped phone; lane 5 needs a human with the vendor URL; lane 6 needs Play
consent per app. The trust model behind lanes 1–3 (record the APK hash and
signer at lock time; Android itself enforces signer continuity on every
upgrade) is the same one F-Droid's `AllowedAPKSigningKeys` and Accrescent use —
the lock-time signer record, checked again against every APK at build time,
closes Android's trust-on-first-use gap, the OS covers the rest. Floors-not-pins matches Android's own managed-device model
(`minimumVersionCode`), where on-device stores may run ahead but never behind.

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
suggestion is never something `update` would then reject. Add `--repo URL
FINGERPRINT LABEL` to also check a third-party F-Droid repo you use (e.g. FUTO's
`https://app.futo.org/fdroid/repo`); the LABEL renders as an
`apps.fdroid.repos.<name>` block. It prints the migration: the packages to
remove from `apps.play`/`apps.attended` and the `apps.fdroid` block to add. Availability is a suggestion, not a guarantee of the
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
signature-level permissions and shared-uid identity. nix-android enforces
signer continuity only from the first lock onward (see
[LIMITS.md](./LIMITS.md)), so confirm the shown signer is one you trust before
relying on it, and consider pinning it with `signerSha256`. An unverifiable hint warns (with the underlying reason) and stays
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
host over the network. By default its output is **not** promoted into the
migration: the catalog is untrusted and a package-id match alone does not prove
source identity (signer continuity is enforced only after the first lock, see
[LIMITS.md](./LIMITS.md)). Add `--verify` to resolve each proposal and promote
the package-id matches to verified `apps.release` entries (with signers), in one
command:

```console
nix run .#android-rebuild -- suggest-sources --flake .#pixel --discover --verify
```

Still confirm the shown signer is one you trust. A candidate that is not in the
Obtainium catalog (or fails to resolve) is not proposed; if you already know its
repo, name it with `--release-hint <pkg>=<owner/repo>`, or recover your own
Obtainium sources by passing your Obtainium export to `import --obtainium-export
<file>`, which renders a supported release straight to `apps.release` when the
package's current installer corroborates Obtainium delivery.
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
checks the index-v2 hash, and records each APK hash plus up to four HTTPS
mirror URLs from the same signed index (see Fetch performance). A failed update writes no
partial lock. `update` rewrites the lock to exactly the declared F-Droid and
release set, so a removed declaration drops out; removing the last one leaves
an empty `packages` set rather than re-resolving the old entries.

A signature cannot tell a fresh index from a replayed old one, so `update`
also records each repository's signed `entry.json` timestamp in the lock's
top-level `repoTimestamps` map (repository URL to milliseconds) and refuses an
index older than the recorded one, or older than the last verified
`entry.jar` in the local cache. That stops a mirror or network attacker from
pinning older, validly signed app versions. A lock without the field accepts
and records the current timestamp; floors are kept even when a repository is
dropped from the config. If a repository genuinely reset its index, re-run
`android-rebuild update ... --allow-index-rollback` once. GitHub/Gitea assets are hash-pinned and their Android package ID
is checked before the lock is written. Release resolution uses anonymous public
APIs and is therefore subject to the host's unauthenticated rate limits.

Source strings are typed before anything is fetched: F-Droid repository,
release `url`, `updateJson`, and `html.url` values must be `https://` URLs
without whitespace, `github` must be `owner/repo`, `gitea` must be
`host[:port]/owner/repo`, and `linkFilter` may not contain control characters.
`update` hands these values to the resolver as NUL-delimited arguments, so a
config value can never turn into a resolver flag such as
`--allow-signer-rotation`.

Every network fetch the resolver and `suggest-sources --discover` make is
HTTPS-only (`curl --proto =https`, so no plain-HTTP downgrade or cross-scheme
redirect), requires TLS 1.2 or newer, and is time- and size-capped. The
F-Droid index is requested with `--compressed`.

Refreshes short-circuit versioned release sources: when a github/gitea/
updateJson/html source resolves to the same URL already locked (same ABI,
complete entry), the previous entry is reused without re-downloading the APK,
so a no-change refresh costs only the metadata fetches. Mutable `url` sources
always re-download — the same URL serves new content after a vendor update.

F-Droid selection follows `metadata.preferredSigner` before versionCode and
records the chosen signing lineage. A repository exposing multiple lineages
without a preferred signer fails closed.

The evaluator binds every configured app's lock entry back to its configured
source. Changing a repository URL, fingerprint, or release owner without
refreshing the lock fails the manifest build. Unreferenced extra lock entries
are ignored.

Each managed APK is also bound to its lock entry at build time: its package
id and versionCode must equal the lock's, every `apksigner` signer digest must
appear in the lock's `signerSha256`, and an F-Droid entry's URL must sit under
its configured repository. A mismatch fails the build naming the package, so a
lock edit that swaps in a differently-signed APK never reaches a device (fresh
installs included). Set `apps.release.<pkg>.signerSha256` to pin a release
app's signer in your configuration, so editing the lock alone cannot change its
identity. Android itself rejects an update signed by an incompatible key, and `plan`
predicts that for each pending upgrade (see *Plan and apply* above and
[LIMITS.md](./LIMITS.md#apk-signatures)).
