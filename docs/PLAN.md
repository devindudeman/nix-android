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
- exact writable permission-policy flags and package-level app-op modes
- per-app locales, input-method enablement/selection, and global Data Saver
- adb-shell package suspension and user-owned app-link handling/selection
- ensure-disabled packages
- ensure-present battery-optimization exemptions

### Tooling and safety

- read-only, versioned package/Android-state snapshot, conservative source
  classification, runtime-grant/flag filtering, package app-op import, and
  explicit omission report
- credential-free Obtainium release-source and App Manager signer adapters
- read-only Atlas capture with one explicit serial and no stdin-drain truncation
- resumable wiped-device bootstrap and user-confirmed Play installation queue
- x86_64 AOSP emulator bench
- formatter, shellcheck, statix, deadnix, manifest, parser, signed-lock,
  archive-safety, evaluator, and repeatable emulator checks
- x86_64 Linux and Apple Silicon macOS controller outputs

## After 0.1

Prioritized by the only measure that matters: minutes of a real new-phone
setup eliminated. A read-only import of a 186-app stock Pixel 9 evaluated and
planned as an exact no-op, which confirms the reconciliation surface is broad
enough; the remaining setup cost is dominated by one thing — the per-app Play
install-consent marathon (159 taps on that phone). Work is ranked against
that, not against surface breadth.

### Done

- **De-Play curation (F-Droid/IzzyOnDroid).** `android-rebuild
  suggest-sources` reports which `apps.play`/`apps.attended` entries are
  published on the main archive or IzzyOnDroid and lockable by the real
  resolver (shared eligibility, including signing-lineage and full lock-field
  completeness). It prints the migration the user applies by hand — the list
  to remove from `apps.play`/`apps.attended` and the `apps.fdroid` block to
  add — then `update` pins them. Against a 186-app import it surfaced 30.
- **Release-source discovery and verification.** The model is broad, fallible
  discovery then package-id verification and a human signer check. `--discover`
  looks up each unresolved candidate in the crowdsourced Obtainium catalog
  (both `configs[]` and `config` schemas, keyed by package id) and proposes
  GitHub/Codeberg repos — opt-in, because it queries a third-party host with
  the candidate package ids. A raw catalog proposal is never promoted on the
  catalog's word; `--discover --verify` promotes one only after the real
  resolver confirms the apk package id and surfaces its signer for review.
  `--release-hint PKG=owner/repo` (GitHub) or `PKG=host/owner/repo`
  (Gitea) confirms a repo through the real resolver, matching the apk package
  id (iterating release flavors until one matches) and surfacing the resolved
  signer for the user to confirm. Package-id match is compatibility, not source
  identity; signer continuity is not yet enforced.
- **Generations and drift (`status`/`generations`).** After every successful
  `switch`, the controller attempts to stage a generation — a copy of the
  applied manifest plus a JSONL log line under
  `$XDG_STATE_HOME/nix-android/<device.name>/`, the home-manager profile model
  minus the bootloader. A storage failure warns but does not turn an
  already-converged device into a failed switch. `status` re-plans the
  last-applied generation
  against the device to report drift since the last switch (distinct from
  `plan`, which diffs the current config); `generations` lists the ledger. This
  is a controller-side receipt, not a NixOS bootable snapshot: it cannot restore
  app data, downgrade an app, or invert ensure-only state, and does not yet
  offer a rollback verb. The receipt logic is unit-tested device-free
  (`test-generations.sh`).
- **Flake `templates` + self-documenting scaffold.** `nix flake init -t
  github:devindudeman/nix-android` writes a starter config repo: a consumer
  `flake.nix` pinning the CLI, a `phone.nix` that documents the main option
  groups inline (minimal active block so it evaluates as-is), a starter lock,
  `.gitignore`, and a quickstart README. The `template` check builds the
  scaffold's manifest through `mkDevice`, so a renamed or removed option fails
  CI here instead of in a fresh user's repo. Device auto-population is left to
  the existing `import` command rather than duplicated.
- **Generated option reference.** `docs/OPTIONS.md` is rendered from the typed
  module options via `nixosOptionsDoc` (`just options-doc`; the `options-doc`
  check fails if the committed file drifts). Executed adb evidence remains in
  the separately maintained `docs/PRIMITIVES.md` matrix.
- **`plan` reports induced effects.** A fresh install starts from default
  permission state and an upgrade can reset specific grants, flags, or app-ops,
  so the engine reasserts declared intent afterward (precautionary). `plan` now
  annotates those lines
  `(after install)`/`(after upgrade)`, so a reassertion of already-correct state
  reads as a sequenced consequence rather than unexplained drift. Asserted on
  the emulator gate (bench-e2e fresh-device plan).

### Next

- **Optional Device Owner lane (emulator prototype).** Designed in
  [DEVICE-OWNER.md](./DEVICE-OWNER.md). The honest scope is narrow: `adb shell`
  already installs APKs silently over a tether and Device Owner cannot fetch
  Play-only APKs, so DO's genuine value is only untethered/reboot-persistent
  convergence and a few DO-gated policy verbs (`setUninstallBlocked`,
  `setPermissionGrantState`, `setApplicationHidden`). Recommended base is a
  purpose-built ~100-line Java DPC built as a Gradle-free fixed-output Nix
  derivation (not Dhizuku). An emulator prototype (kept off `main` on the
  `dpc-prototype` branch) already answered two of the three risks on AOSP — an
  SELinux-clean command channel and a factory-reset-free exit via
  `clearDeviceOwnerApp` both work, and DO silent install is prompt-free on AOSP.
  The open risk is whether GrapheneOS honors DO silent install (a spare-device
  test, never the Pixel), which gates the shipping decision. Strictly opt-in and
  bootstrap-scoped.
- **Special app access.** Notification-listener and accessibility-service
  enablement (`cmd notification allow_listener`; the secure component lists
  gated by the `ACCESS_RESTRICTED_SETTINGS` app-op). Fiddly minutes on every
  fresh phone; primitives already read-verified on hardware.

### Deferred

- HTML rendering of the option reference (nixos-render-docs) if a hosted docs
  site is ever published
- broader resolver regression fixtures for release-asset selection and the
  no-`preferredSigner` multiple-lineage rejection path
- exact plan-time signer verification (pull the installed APK, compare
  `apksigner` digest against the lock's signer) — the shipped plan `note:` is
  an installer-provenance heuristic; exactness costs apksigner+jdk in the
  engine closure
- `assist --watch` skip/reorder for a wedged Play install (today it is
  head-of-line blocking in declaration order)
- a rollback verb over recorded generations, documenting that it cannot restore
  app data, downgrade packages, or invert ensure-only state, and that missing
  APK store paths would need a re-fetch
- split APK/device-extracted app migration
- optional cross-snapshot comparison tooling beyond the implemented coverage report
- optional device product/serial identity guards without forcing identifiers
  into public configuration
- multi-user work after per-version owner/Private-Space/work-profile testing
- verified Wi-Fi secret handling and per-app Data Saver policy once a
  persistent owner-user primitive passes the emulator reboot gate
- on-device Termux/rish execution
- shell completion and selected Nix flag passthrough

### Not planned

- Declaring low-value ambient settings for their own sake (radio auto-off,
  screen timeouts, and similar). A dedicated `grapheneos.*` namespace and a
  from-source GrapheneOS emulator bench were considered and dropped: they cost
  a heavy build/maintenance treadmill to declare state worth seconds of manual
  tapping. GrapheneOS-specific keys remain available through the
  `android.settings` expert escape hatch, and real-device read-only comparison
  stays the way GrapheneOS behavior is checked.

No `stateVersion`, module hierarchy, daemon, website, or alternate engine
language is planned until a demonstrated compatibility or maintenance problem
requires it.

## Permanent boundaries

nix-android will not unlock bootloaders, replace GrapheneOS, bypass Android's
permission model, promise app-data migration, fetch Play-only apps silently, or
pretend mutable Android state has NixOS-style atomic rollback. See
[LIMITS.md](./LIMITS.md).
