# Alpha release plan

nix-android's first public release is a 0.1 alpha. This file records its actual
release gate and deliberately deferred roadmap; it is not a speculative product
pitch.

## Definition of alpha-ready

The alpha is ready only when all of these are true:

- [x] Typed `lib.mkDevice` configuration produces a plain, versioned manifest.
- [x] Managed APKs are hash-addressed Nix store paths.
- [x] Main and third-party F-Droid metadata is authenticated from signed
      `entry.jar` through index and APK hashes.
- [x] GitHub/Gitea assets are package-ID checked, archive-safe, and atomically
      locked.
- [x] Lock entries are bound to the configured source, repository URL, and
      repository certificate fingerprint.
- [x] `android-rebuild` has documented build/update/plan/switch/assist/bootstrap/import behavior,
      mandatory serials for device commands, and device-free CLI checks.
- [x] The engine validates its complete manifest before adb, refuses target ABI
      mismatches, quotes remote-shell arguments, and aborts on missing
      Play/attended apps before mutation.
- [x] Owner-only v1 scope, ensure-only semantics, destructive cleanup, signature
      behavior, and no-root limits are explicit.
- [x] MIT license, public repository URL, focused Linux CI, and Apple Silicon CI
      definitions exist.
- [x] A fresh independent re-review finds no unresolved high/critical issue.
- [x] x86_64 Linux focused checks and release packages pass without `--impure`.
- [x] Apple Silicon Darwin packages and device-free checks build on a real Mac
      or the `macos-15` CI runner.
- [x] Two consecutive fresh AOSP benches pass plan → bootstrap → direct
      verification → no-op plan → graceful reboot → no-op plan → structured
      import coverage → clean teardown.
- [x] Negative bench tests prove ABI mismatch and missing Play/attended apps abort
      before writes, and a setting containing spaces survives remote quoting.
- [x] A clean-clone audit contains no personal capture, absolute generated
      symlink, private hostname, accidental unresolved placeholder in
      copy-paste guidance, stale claim, or untracked release artifact.

The physical Apple Silicon pass closes the pre-publication gate. The pinned
`macos-15` job repeats it after the first push; a CI failure is a release
blocker, not a warning to ignore.

Real-phone mutation is not a release criterion. Daily phones remain in the
read-only lane until a user separately reviews a concrete plan and authorizes
that exact write. As additional validation, a locked GrapheneOS device completed
an explicitly reviewed F-Droid install and reversible dark-mode round trip; both
ended in a no-op plan without cleanup, permission, role, or Private DNS changes.

## Implemented surface for 0.1

### Applications

- main and fingerprint-pinned third-party F-Droid repositories
- GitHub and anonymous Gitea latest-release assets at lock-update time
- single-APK `.tar.gz` release assets
- local APKs with build-time package-ID/versionCode inspection
- source-labeled Play and generic attended package presence assertions
- additive cleanup default and explicit undeclared-user-app uninstall mode
- version floors: install or upgrade, never downgrade a newer installed app

### Android state

- declared raw global/secure/system settings keys
- dark mode and Private DNS
- browser, SMS, dialer, and home roles
- explicit runtime permission grants/revocations
- ensure-disabled packages
- ensure-present battery-optimization exemptions

### Tooling and safety

- read-only, versioned package-protobuf snapshot and conservative Play/attended import
- read-only Atlas capture with one explicit serial and no stdin-drain truncation
- resumable wiped-device bootstrap and user-confirmed Play installation queue
- x86_64 AOSP emulator bench
- formatter, shellcheck, statix, deadnix, manifest, parser, signed-lock,
  archive-safety, evaluator, and repeatable emulator checks
- x86_64 Linux and Apple Silicon macOS controller outputs

## After 0.1

These are useful but are not allowed to delay a small, honest initial release:

- generated option reference and an exported flake `templates` consumer output
- broader resolver regression fixtures for release-asset selection and the
  no-`preferredSigner` multiple-lineage rejection path
- applied-state receipts and generations; any rollback must document that it
  cannot restore app data, downgrade packages, or invert ensure-only state
- split APK/device-extracted app migration
- targeted import of already-supported Android state and explicit curation report
- optional credential-free App Manager and Obtainium export adapters
- optional device product/serial identity guards without forcing identifiers
  into public configuration
- multi-user work after per-version owner/Private-Space/work-profile testing
- verified modules for Wi-Fi secrets, locale, input methods, app-ops, package
  suspension, app links, and network policy
- on-device Termux/rish execution
- shell completion and selected Nix flag passthrough

No `stateVersion`, module hierarchy, daemon, website, or alternate engine
language is planned until a demonstrated compatibility or maintenance problem
requires it.

## Permanent boundaries

nix-android will not unlock bootloaders, replace GrapheneOS, bypass Android's
permission model, promise app-data migration, fetch Play-only apps silently, or
pretend mutable Android state has NixOS-style atomic rollback. See
[LIMITS.md](./LIMITS.md).
