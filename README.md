# nix-android

**nix-darwin, but for your phone.** Declare Android apps and reachable device
state in Nix, inspect a read-only plan, then converge over adb.

No root, no bootloader unlock, no custom OS, and nothing installed on the
phone: everything runs on your computer at adb-shell privilege.

**Status: alpha; `plan` never writes; read it before every `switch`.**

## Requirements

- a Google Pixel on stock Android or GrapheneOS, with USB debugging enabled
  and this computer authorized ([docs/QUICKSTART.md](docs/QUICKSTART.md)
  walks through it)
- Nix with flakes enabled, on x86_64 Linux or Apple Silicon macOS

## Try it without committing to anything

`import` reads the phone and prints a draft config. It writes nothing to the
device and needs no config repo:

```console
nix run github:devindudeman/nix-android -- import --serial $(adb get-serialno)
```

## Set up a config

```console
mkdir my-phone && cd my-phone
nix flake init -t github:devindudeman/nix-android
git init && git add -A          # Nix only sees git-tracked files
```

The template's `phone.nix` documents the main option groups inline. A
filled-in `phone.nix`:

```nix
{
  device.name = "phone";
  apps = {
    fdroid.packages = [ "org.mozilla.fennec_fdroid" "com.termux" ];
    fdroid.repos.futo = {
      url = "https://app.futo.org/fdroid/repo";
      fingerprint = "39d47869d29cbfce4691d9f7e6946a7b6d7e6ff4883497e6e675744ecdfa6d6d";
      packages = [ "org.futo.inputmethod.latin" ];
    };
    release."dev.imranr.obtainium.fdroid".github = "ImranR98/Obtainium";
    release."org.thoughtcrime.securesms".updateJson = "https://updates.signal.org/android/latest.json";
    play = [ "com.spotify.music" ];
  };
  android.darkMode = true;
  android.privateDns = "opportunistic";
  android.defaultApps.browser = "org.mozilla.fennec_fdroid";
  android.permissions."com.termux".grant = [ "android.permission.POST_NOTIFICATIONS" ];
  android.batteryOptimization.exempt = [ "com.termux" ];
}
```

Then lock the app sources, preview, and apply:

```console
nix run .#android-rebuild -- update --flake .#phone && git add apps.lock.json
nix run .#android-rebuild -- plan   --flake .#phone --serial SERIAL
nix run .#android-rebuild -- switch --flake .#phone --serial SERIAL
```

`status` reports drift since the last switch, `assist --watch` walks you
through the Play installs, and `bootstrap` rebuilds a wiped phone. See
[docs/USING.md](docs/USING.md).

## What is declarative today?

- F-Droid and third-party F-Droid repository apps
- GitHub/Gitea release APKs, direct vendor-URL APKs (bare URL, a Signal-style
  update-manifest JSON, or a Steam-style HTML-discovered link), and local APK
  files
- Google Play apps as user-confirmed presence assertions with Play-specific assistance
- other attended apps as generic presence assertions
- credential-free Obtainium release-source and App Manager signer import adapters
- raw Android settings keys, dark mode, and Private DNS
- default browser, SMS, dialer, and home roles
- runtime permission grants/revocations, writable permission flags, and package app-ops
- per-app locales, input-method selection, global Data Saver, and user app-link choices
- package disablement/suspension and battery-optimization exemptions/removals
- optional cleanup of undeclared user-installed apps
- resumable wiped-device bootstrap across reproducible and consent-bound apps

The default is additive: undeclared apps are left alone. Every device command
requires an explicit adb serial, the declared ABI must match the target, and
`plan` never writes to the device (it may evaluate, fetch, and build locally).
See [docs/LIMITS.md](docs/LIMITS.md) for the exact boundary between reconciled,
ensure-only, attended, and unreachable state.

F-Droid locks are resolved through a certificate-authenticated `entry.jar`,
the signed `entry.json` index hash, and the per-APK hash. GitHub/Gitea assets
are package-ID checked when locked. Every resulting artifact is fetched by
hash into the Nix store. The engine needs no network once the complete converge
closure—including controller tools and APKs—is present locally. Missing paths
require a fetch from nixpkgs, the recorded app source, or a configured binary
cache.

## Start here

- [docs/QUICKSTART.md](docs/QUICKSTART.md) — USB/wireless debugging to a
  first reviewed `switch`
- [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md) — adb states, lock and
  signer errors, Play wedges, warning noise
- [docs/USING.md](docs/USING.md) — setup, CLI, bootstrap, safety, and option
  semantics
- [docs/OPTIONS.md](docs/OPTIONS.md) — every option, generated from the typed
  module definitions
- [docs/LIMITS.md](docs/LIMITS.md) — supported targets and what adb-shell
  cannot or does not manage
- [docs/CAPABILITIES.md](docs/CAPABILITIES.md) — auditable ADB read/write/import-to-Nix map
- [docs/DEVELOPING.md](docs/DEVELOPING.md) — architecture, checks, and emulator
  workflow
- [docs/PRIMITIVES.md](docs/PRIMITIVES.md) — device-tested adb capability matrix
- [docs/IMPORT.md](docs/IMPORT.md) — faithful import model, schema, and prior art
- [docs/PLAN.md](docs/PLAN.md) — release gate and post-0.1 roadmap

nix-android can be its own configuration flake or an input to an existing
flake. The latter adds `androidConfigurations.<device>` beside existing
`nixosConfigurations` and `darwinConfigurations`; see the existing-flake and
multi-controller examples in [docs/USING.md](docs/USING.md).

## What it will never do

- unlock a bootloader, root the phone, or replace GrapheneOS
- bypass Android's permission model or its install-consent prompts
- fetch Play-only apps silently
- migrate app data, Keystore keys, or eSIMs
- pretend mutable Android state has NixOS-style atomic rollback

See [docs/LIMITS.md](docs/LIMITS.md) for the exact boundary.

## Development

```console
direnv --version # install direnv first if this fails
direnv allow
just check
just emu # x86_64 Linux with systemd only
nix run .#android-rebuild -- plan --flake .#bench --serial emulator-5554
```

Licensed under the [MIT License](LICENSE).
