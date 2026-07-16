# My phone (nix-android)

Declarative Android/GrapheneOS device state over adb. Generated from
`nix flake init -t github:devindudeman/nix-android`.

## First run

```console
git init && git add -A          # Nix only sees git-tracked files
nix flake lock                  # pin nix-android + its inputs
git add flake.lock

# Edit phone.nix — set device.abi, uncomment the apps you want — then:
nix run .#android-rebuild -- update --flake .#phone     # lock app sources
git add apps.lock.json

adb devices                     # find your device serial
nix run .#android-rebuild -- plan   --flake .#phone --serial <SERIAL>
nix run .#android-rebuild -- switch --flake .#phone --serial <SERIAL>
```

`plan` is read-only; review every line before `switch`. After a switch,
`status` reports drift and `generations` lists what you've converged.

Apple Silicon: change `system` and the package attributes in `flake.nix` from
`x86_64-linux` to `aarch64-darwin`.

## Two faster starts

- **From a live device:** `android-rebuild import --serial <SERIAL>` reads the
  owner profile into a draft config you paste into `phone.nix`.
- **De-Google:** list Play apps under `apps.play`, then
  `android-rebuild suggest-sources --flake .#phone` finds F-Droid/GitHub
  sources for them.

`phone.nix` documents the full option surface inline. Full docs:
<https://github.com/devindudeman/nix-android/blob/main/docs/USING.md>.
