# Using nix-android

Declare your Android device's apps and (soon) settings in Nix; converge any
device toward that file over adb. No root, no unlocked bootloader — nix-android
talks to a stock, security-model-intact device at adb-shell privilege.

## Requirements

- Nix (flakes enabled) on a Linux/macOS machine
- A device with **USB debugging** enabled (Settings → About phone → tap Build
  number 7× → Developer options → USB debugging) and the host's key accepted
- Tested against: GrapheneOS (Android 17) on real hardware, AOSP 35 emulator.
  Any adb-reachable Android in that era should behave; see
  [PRIMITIVES.md](./PRIMITIVES.md) for exactly what's verified where.

## Quick start

```nix
# flake.nix (your config repo)
{
  inputs.nix-android.url = "github:OWNER/nix-android";

  outputs = { nix-android, ... }: {
    androidConfigurations.pixel = nix-android.lib.mkDevice {
      modules = [ ./pixel.nix ];
      lockFile = ./apps.lock.json;
    };
  };
}
```

```nix
# pixel.nix — the full option surface today
{
  device.name = "pixel";
  device.abi = "arm64-v8a";   # x86_64 for an emulator target
  device.user = 0;            # Android user profile (owner)

  # F-Droid apps, resolved through the signed index into the lock file.
  apps.fdroid.packages = [ "org.fdroid.fdroid" "com.termux" ];

  # GitHub/Gitea release APKs (Obtainium-style). Exactly one source per app.
  # Assets may be a bare .apk or a .tar.gz containing one.
  apps.release."dev.imranr.obtainium".github = "ImranR98/Obtainium";
  apps.release."com.example.app".gitea = "git.example.com/owner/repo";

  # Self-built APKs: the file is the pin. Keep it OUTSIDE the repo; package id
  # is verified against the declaration at build time.
  apps.local."com.example.mine".apk = /home/me/apks/mine.apk;

  # Play-catalog apps: not headlessly fetchable — converge asserts presence
  # and prints a to-install list for you.
  apps.attended = [ "com.spotify.music" ];

  # "none" = additive only (safe default). "uninstall" = NixOS-style purity:
  # undeclared user apps get removed.
  apps.cleanup = "none";
}
```

```bash
android-rebuild update --flake .#pixel   # resolve versions/hashes → apps.lock.json
android-rebuild plan   --flake .#pixel   # read-only diff vs the device
android-rebuild switch --flake .#pixel   # plan + apply
```

With two devices attached, add `--serial <adb-serial>` (see `adb devices`).

## Starting from an existing phone

```bash
android-rebuild import --serial XXXX > pixel.nix
```

Reads the device (read-only) and emits a starter config, classified by each
app's installer: F-Droid clients → `apps.fdroid.packages`, Play/Aurora →
`apps.attended`, Obtainium → `apps.release` stubs, everything else flagged
for curation. Curate before converging:

- **Not everything a F-Droid *client* installed is on f-droid.org** (e.g.
  IzzyOnDroid repo apps). `android-rebuild update` fails loudly per missing
  package — move those to `apps.release` or `apps.attended`.
- **Same app, different source = different signature.** Converge refuses a
  signature-mismatched install rather than eating app data. Switching an
  existing app's source means uninstall/reinstall — your explicit decision.

## Semantics that matter

- **Plan by default.** Nothing touches the device without `switch` (or
  `--apply` on the raw engine). Plans are cheap; run them constantly.
- **Pins are floors.** Converge installs and upgrades to ≥ the locked
  versionCode. It never downgrades (Android blocks that anyway) and never
  fights on-device updaters — if F-Droid client auto-updated past your pin,
  that's fine.
- **The APK payload is a Nix closure.** Every managed APK is fetched by
  sha256 into the store (F-Droid index chain-of-trust; release assets hashed
  at lock time; local files badging-verified). Offline converge works.
- **Generations**: each applied manifest is recorded (rollback = converge to
  a previous manifest; remember floors — rollback can't downgrade).

## What it can NOT do (by design — no root)

- Install Play-only apps headlessly (`apps.attended` is the honest boundary).
- Migrate app *data* (Seedvault and per-app exports are the escape hatch).
- Touch a work profile: mutations are blocked by Android
  (`DISALLOW_DEBUGGING_FEATURES`); inventory is readable. Private space is
  reachable.
- Downgrade apps, or anything above adb-shell privilege.
