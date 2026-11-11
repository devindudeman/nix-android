# Troubleshooting

## adb cannot see or use the phone

Check `nix shell nixpkgs#android-tools -c adb devices`:

- **Empty list (no devices).** Use a data cable rather than a charge-only one,
  unlock the phone, and confirm Developer options → USB debugging is on. For
  wireless debugging, re-run `adb connect HOST:PORT`; the port changes whenever
  wireless debugging is toggled.
- **`unauthorized`.** The RSA prompt was not accepted. Unlock the phone and
  accept "Allow USB debugging?". If no prompt appears, use Developer options →
  Revoke USB debugging authorizations, then replug.
- **`offline`.** The connection is half-open. Replug, or run
  `adb reconnect offline`. If it keeps happening, check for a second adb
  version restarting the server (see [QUICKSTART.md](./QUICKSTART.md)).
- **`no permissions`** (Linux). Your user lacks access to the USB device; your
  distribution's Android udev rules fix it.

## `'X' not in apps.lock.json — run android-rebuild update`

A declared F-Droid or release app has no lock entry yet, or its source changed
(`lock source is stale`, `repository fingerprint is stale`). Lock it and track
the result:

```console
nix run .#android-rebuild -- update --flake .#phone
git add apps.lock.json
```

Recovered `apps.release` entries from `import` need the same step.

## `INSTALL_FAILED_UPDATE_INCOMPATIBLE`

The installed copy is signed by a different key than the declared source, and
Android refuses cross-signer upgrades. `plan` warns ahead of time with
`note: PKG upgrade WILL fail` (or `will likely fail` when it can only infer the
signer from the installer). Either uninstall the app on the phone so `switch`
reinstalls it from the declared source (this loses the app's data), or move the
package to the lane it actually came from, such as `apps.play` or
`apps.attended`. See [USING.md](./USING.md#choosing-a-lane).

## Hash mismatch on a `release.<pkg>.url` source

`url` sources are mutable "latest" links: the vendor replaces the file in place,
so a lock written before that change fails the Nix fetch with
`hash mismatch in fixed-output derivation`. Run `update` to re-lock the new
file and `git add apps.lock.json`. Prefer `updateJson` when the vendor offers
one; it points at versioned files that do not change under the lock.

## A Play install sits at "Pending" forever

If the app is already installed in another profile (for example a work profile)
with a stale version, the owner-profile Play install can wedge. Update the app
inside the profile that owns it, then re-run `assist`; installed packages are
skipped. `assist --watch` follows declaration order, so one wedged app blocks
the ones after it. See [LIMITS.md](./LIMITS.md#play-assisted-and-attended-state).

## Warning noise on every command

`android-rebuild` evaluates your flake with `--impure` (pure evaluation would,
for example, refuse `apps.local` APK paths outside the flake). That makes Nix
consult `NIX_PATH`, so a missing channel directory prints
`warning: Nix search path entry '...' does not exist, ignoring`. Uncommitted
edits print `warning: Git tree '...' is dirty`. Both are harmless. Remember that
new files must be `git add`ed before Nix can see them.

Running `nix run github:devindudeman/nix-android` also prints
`ignoring untrusted flake configuration setting 'extra-substituters'`. That
cache only serves nix-android's development shell; the CLI does not need it.

## Slow APK fetches

`build`, `plan`, and `switch` fetch every locked APK into the Nix store, and
Nix runs at most `max-jobs` fetches at once (default 1). Set `max-jobs = auto`
in `nix.conf` to fetch in parallel. A daemon may ignore the client-side setting
unless your user is trusted. Once fetched, APKs stay in the store until garbage
collection. `update` downloads release assets one at a time; parallel
downloads and mirrors are being worked on in a separate PR.
