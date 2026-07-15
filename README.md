# nix-android

**nix-darwin, but for your phone.** Declare your Android device's state —
installed apps, sources, settings, permissions — in a version-controlled Nix
file, and converge any device toward it over adb:

```
android-rebuild switch --flake .#pixel
```

No root. No unlocked bootloader. No custom OS image. nix-android speaks to a
**stock, locked, security-model-intact** device (GrapheneOS is the first-class
target) at adb-shell privilege, and is loudly honest about what lives beyond
that line. Not an OS builder — that's [robotnix](https://github.com/nix-community/robotnix);
not a Nix userland on the phone — that's [nix-on-droid](https://github.com/nix-community/nix-on-droid).
This is the missing third thing: **converge a running device toward a config file.**

> **Status: pre-release, under active development.** The core loop (module
> system → manifest with store-fetched, hash-verified APKs → plan/apply
> converge engine, idempotent) is working end-to-end against an emulator.
> See `docs/PLAN.md` for the roadmap and `docs/PRIMITIVES.md` for the
> verified adb capability matrix everything is built on.

## Taste

```nix
{
  device.name = "pixel";
  apps.fdroid.packages = [ "org.fdroid.fdroid" "com.termux" "app.comaps" ];
  apps.attended = [ "com.spotify.music" ]; # Play-catalog: asserted, human-installed
  apps.cleanup = "none";                   # or "uninstall" for NixOS-style purity
}
```

APKs resolve through F-Droid's signed index into `apps.lock.json` and are
fetched by sha256 into the Nix store — your phone's app payload is a real Nix
closure. Pins are floors: converge installs and upgrades, never downgrades,
never fights on-device updaters.

## Docs

- **[docs/USING.md](docs/USING.md)** — user guide: quick start, the full
  option surface, `import` from an existing phone, semantics and boundaries.
- **[docs/DEVELOPING.md](docs/DEVELOPING.md)** — contributor guide:
  architecture, ground rules, the dev loop, how to add options and sources.
- **[docs/PLAN.md](docs/PLAN.md)** — roadmap · **[docs/PRIMITIVES.md](docs/PRIMITIVES.md)** — verified adb capability matrix.

## Development

```bash
direnv allow      # devenv shell: adb, jq, aapt2, pre-commit hooks
just              # task list
nix run .#emulator   # headless AOSP bench (KVM)
nix run .#bench -- --serial emulator-5554          # plan
nix run .#bench -- --serial emulator-5554 --apply  # converge
```
