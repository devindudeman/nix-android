# nix-android

**nix-darwin, but for your phone.** Declare Android apps and reachable device
state in Nix, inspect a read-only plan, then converge over adb.

```console
android-rebuild plan   --flake .#pixel --serial DEVICE_SERIAL
android-rebuild switch --flake .#pixel --serial DEVICE_SERIAL
android-rebuild assist --watch --flake .#pixel --serial DEVICE_SERIAL
android-rebuild bootstrap --flake .#pixel --serial DEVICE_SERIAL # wiped-device rebuild
```

nix-android works at adb-shell privilege on a stock, locked-bootloader device.
It requires neither root nor replacing the OS, weakening verified boot, or
installing Nix on the phone. GrapheneOS is the first-class target; an AOSP emulator is the
mutation test bench.

> **Status: alpha-ready.** The app and settings converge loop works end to end
> on the AOSP bench, has completed an additive install plus a reversible setting
> round trip on a locked GrapheneOS device, and passes the release packages and
> device-free checks on a physical Apple Silicon Mac. The pinned `macos-15` job
> repeats that gate after publication. See [docs/PLAN.md](docs/PLAN.md), and do
> not aim an unreviewed `switch` or `bootstrap` at a daily phone.

## What is declarative today?

- F-Droid and third-party F-Droid repository apps
- GitHub/Gitea release APKs and local APK files
- Google Play apps as user-confirmed presence assertions with Play-specific assistance
- other attended apps as generic presence assertions
- raw Android settings keys, dark mode, and Private DNS
- default browser, SMS, dialer, and home roles
- runtime permission grants and revocations
- package disablement and battery-optimization exemptions
- optional cleanup of undeclared user-installed apps
- resumable wiped-device bootstrap across reproducible and consent-bound apps

The default is additive: undeclared apps are left alone. Every device command
requires an explicit adb serial, the declared ABI must match the target, and
`plan` never writes to the device (it may evaluate, fetch, and build locally).
See [docs/LIMITS.md](docs/LIMITS.md) for the exact boundary between reconciled,
ensure-only, attended, and unreachable state.

## A taste

```nix
{
  device = {
    name = "pixel";
    abi = "arm64-v8a";
    user = 0;
  };

  apps.fdroid.packages = [
    "org.fdroid.fdroid"
    "com.termux"
  ];
  apps.play = [ "com.spotify.music" ];
  apps.cleanup = "none";

  android = {
    darkMode = true;
    privateDns = "opportunistic";
    permissions."com.termux".grant = [
      "android.permission.POST_NOTIFICATIONS"
    ];
    batteryOptimization.exempt = [ "com.termux" ];
  };
}
```

F-Droid locks are resolved through a certificate-authenticated `entry.jar`,
the signed `entry.json` index hash, and the per-APK hash. GitHub/Gitea assets
are package-ID checked when locked. Every resulting artifact is fetched by
hash into the Nix store. The engine needs no network once the complete converge
closure—including controller tools and APKs—is present locally. Missing paths
require a fetch from nixpkgs, the recorded app source, or a configured binary
cache.

## Start here

- [docs/USING.md](docs/USING.md) — bootstrap, complete option surface, CLI,
  safety, and semantics
- [docs/LIMITS.md](docs/LIMITS.md) — what adb-shell cannot or does not manage
- [docs/SUPPORT.md](docs/SUPPORT.md) — supported stock-Pixel/GrapheneOS target contract
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

## Development

```console
direnv --version # install direnv first if this fails
direnv allow
just check
just emu # x86_64 Linux with systemd only
nix run .#android-rebuild -- plan --flake .#bench --serial emulator-5554
```

Licensed under the [MIT License](LICENSE).
