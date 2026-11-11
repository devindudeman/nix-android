# Quickstart

From a phone with default settings to a reviewed first `switch`. Everything
before `switch` is read-only on the phone.

## 1. Authorize this computer

On the phone, open Settings → About phone and tap **Build number** seven times.
Then turn on Settings → System → Developer options → **USB debugging**. Plug the
phone in, unlock it, and accept **Allow USB debugging?** (tick "Always allow
from this computer").

```console
nix shell nixpkgs#android-tools -c adb devices
```

The first column is the serial. `device` means ready. `unauthorized` means the
prompt has not been accepted: unlock the phone and look for it, or use
Developer options → Revoke USB debugging authorizations and replug. Other
states are in [TROUBLESHOOTING.md](./TROUBLESHOOTING.md).

Two different adb versions (this `nix shell`, the CLI's pinned one, Android
Studio, Homebrew) restart each other's server and drop in-flight commands.

**Wireless debugging** (Android 11+): Developer options → Wireless debugging →
Pair device with pairing code, then use the two addresses it shows:

```console
adb pair 192.168.1.50:41234      # pairing address, then enter the code
adb connect 192.168.1.50:37017   # address on the Wireless debugging screen
```

The serial is then `host:port`, here `192.168.1.50:37017`.

## 2. Create the config

```console
mkdir my-phone && cd my-phone
nix flake init -t github:devindudeman/nix-android
git init && git add -A           # Nix only sees git-tracked files
nix flake lock && git add flake.lock
```

On Apple Silicon, set `system = "aarch64-darwin"` in `flake.nix`. Edit
`phone.nix`, or start from your phone's current state with
`nix run .#android-rebuild -- import --serial SERIAL`.

## 3. Lock, plan, switch

```console
export ANDROID_SERIAL=SERIAL     # replaces --serial on every command
nix run .#android-rebuild -- update && git add apps.lock.json
nix run .#android-rebuild -- plan
nix run .#android-rebuild -- switch
nix run .#android-rebuild -- plan     # expect: ✓ device matches manifest
```

`--flake` defaults to `.`, and a flake with exactly one `androidConfigurations`
entry selects it automatically; with several, pass `--flake .#NAME`. Read every
`plan` line before `switch`. The rest of the CLI is in [USING.md](./USING.md).
