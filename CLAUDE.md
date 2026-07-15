# Working in nix-android

nix-android converges reachable Android/GrapheneOS device state toward a Nix
configuration over adb shell uid 2000. It does not require root, an unlocked
bootloader, a custom OS, or Nix on the phone. The public API is
`lib.mkDevice`, `androidConfigurations.<device>`, and `android-rebuild`.

Read these before changing behavior:

- `docs/DEVELOPING.md` — architecture, checks, and contribution workflow
- `docs/PRIMITIVES.md` — executed adb capability evidence
- `docs/USING.md` — public behavior and complete option surface
- `docs/LIMITS.md` — exact reconciliation and no-root boundaries
- `docs/PLAN.md` — first-release gate and deferred roadmap

Every new module option must cite an executed read/write/read-back/graceful-
reboot primitive. Do not expose a setting merely because `settings put`
returned success.

## Real-phone safety protocol

Devin's Pixel 6 is a production daily-use GrapheneOS phone.

- Without explicit approval for a specific mutation, use read-only probes only.
- Run all mutation-class tests on the AOSP emulator first.
- Never uninstall, suspend, revoke, change roles, or alter settings on the
  Pixel as an inferred test step.
- Every target-specific adb invocation names its serial; unscoped `adb devices`
  is discovery only, and two devices are commonly attached.
- Never hard-reboot after writes. Allow write-behind state to settle and use a
  graceful user-requested reboot in emulator persistence tests.
- Raw inventories, settings dumps, and Atlas captures belong under
  `~/Documents/phone-migration/`, never in Git.

## Local workflow

```console
direnv allow
just fmt
just check
just emu
nix run .#android-rebuild -- plan --flake .#bench --serial emulator-5554
```

For mutation-class development, apply only on the emulator:

```console
nix run .#android-rebuild -- switch --flake .#bench --serial emulator-5554
```

A real-phone `switch` is allowed only after the same mutation class passes the
emulator and the owner explicitly approves the exact reviewed plan. Keep
`apps.cleanup = "none"` unless each proposed removal receives separate approval.

Do not run whole-tree `nix flake check`; devenv task evaluation currently fails
with a spurious `path .drv is not valid`. `just check` is the canonical focused
gate.

## Code map

`modules/options.nix` defines the option surface. `lib/default.nix` evaluates
modules, validates source/lock relationships, fetches APKs, and writes the
versioned manifest. `engine/converge.sh` validates, plans, and applies the
manifest. `scripts/update-lock.sh` authenticates signed F-Droid entry metadata
and resolves release assets. `scripts/atlas-probe.sh` is read-only.

Public v1 manages owner user 0 only. `mkDevice.system` is required and supported
controller outputs are `x86_64-linux` and `aarch64-darwin`. Packaged scripts
must use Nix's absolute Bash path, not ambient macOS Bash.

Keep changes small, update nearby public/developer docs in the same pass, and
leave one runnable check for non-trivial logic. Do not push until the release
gate in `docs/PLAN.md` is actually satisfied and Devin asks to publish.
