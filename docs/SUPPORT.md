# Supported Android targets

nix-android supports two device families:

1. Google Pixel devices running Google's stock Android build;
2. Google Pixel devices running an official GrapheneOS build.

Public configuration manages owner user 0 over authorized adb shell uid 2000.
The bootloader may remain locked, verified boot remains enabled, and Nix runs on
the controller rather than the phone. The AOSP emulator is the mutation test
bench and format reference; it is not a third consumer support family.

## Evidence matrix

| Target | Executed evidence | Role |
| --- | --- | --- |
| Stock Pixel | Pixel 9 Pro, Android 16 / SDK 36: read-only snapshot v2, generated-module evaluation, exact no-op plan, and user-approved Play assistance | supported consumer target |
| GrapheneOS Pixel | Pixel 6, Android 17 / SDK 37, build `2026071101`: read-only snapshot v2, GrapheneOS permission-definition discovery, generated-module evaluation, exact no-op plan, and earlier explicitly approved additive/reversible acceptance tests | supported privacy target |
| AOSP emulator | Android 15 / SDK 35 x86_64: mutation, idempotence, graceful-reboot persistence, cleanup, bootstrap, and import round trip | mandatory mutation bench |

These rows are concrete compatibility evidence, not a promise that every past
or future release has identical command output. Synthetic fixtures preserve the
observed stock/Graphene command shapes without publishing device inventories.
When an OS update changes a read format, import must fail visibly or classify
the row as ambiguous; it must never silently emit a weaker declaration.

## Scope

- Owner user 0 is supported. Work profiles and Private Space can contribute
  read-only evidence but are not managed targets.
- Current official stock Android and GrapheneOS releases are the intended
  compatibility window. Older builds may work but are best-effort unless an
  executed fixture or hardware check covers them.
- Other AOSP-derived phones and OEM builds are best-effort. Contributions are
  welcome, but successful adb authorization alone is not a support claim.
- Controller outputs are x86_64 Linux and Apple Silicon macOS, as documented in
  [LIMITS.md](./LIMITS.md).

## What support means

For every public option, the target family must provide a verified read,
write, read-back, idempotence, and graceful-reboot persistence path on the AOSP
bench, plus read compatibility on the relevant real-phone family. Unsupported
or OS-owned state stays snapshot evidence with an explicit coverage status.

Support does not include root, enterprise device-owner enrollment, app-private
data restoration, silent consumer Play installation, Keystore/eSIM export, or
atomic rollback. Those are authority boundaries, not missing compatibility
shims.
