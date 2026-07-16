# Device Owner lane — design doc (not yet built)

This documents a **proposed, opt-in** Device Owner (DO) lane for nix-android and
the decisions behind it. Nothing here is implemented. It exists so the lane is
scoped honestly before any code, and so its real (narrow) value and its
standing costs are on the table.

Status: **design + emulator prototype (prototype kept off `main`).** The design
below is on `main`; a working minimal-DPC prototype that proved the three risks
on the AOSP emulator lives on the separate branch `dpc-prototype` (see
[§7](#7-phased-plan)). No DPC, option, lane, or provisioning is on `main` or in
the engine.

Design status: **design only.** No DPC is built on `main`, no device-owner provisioning ships,
and none is planned until the emulator prototype in
[§7](#7-phased-plan) proves the three risks and the owner approves the exact
reviewed plan. The real-phone safety protocol in the repo `CLAUDE.md` applies in
full: emulator first, never the Pixel as an inferred step.

## 1. The premise, challenged first

The motivation was "silent-install the apps that still need a manual Play tap."
Grounding that against how Android actually works changes the conclusion:

- **`adb shell` (uid 2000) already installs APKs silently.** That is exactly
  what `adb install` / `pm install` does — the `shell` domain holds
  `INSTALL_PACKAGES`. A tethered controller does not need Device Owner to
  install an APK without a prompt. nix-android's `bootstrap` already does this
  for every managed APK.
- **DO does not conjure Play-only APKs.** Silent DO install only works on an
  APK you already possess and push. Spotify, banking apps, and other
  Play-delivered binaries are not APKs nix-android has; DO cannot fetch them.
  The apps DO could silently install are precisely the ones the tether already
  installs silently. DO does not move the Play-only set.

So the honest value of a DO lane is **not** "install the 150 Play apps." It is
two narrow things `adb shell` genuinely cannot do:

1. **Untethered, reboot-persistent convergence** — an on-device agent that
   applies declared state without the laptop attached and survives reboot (adb's
   authority dies on reboot; a DO app does not).
2. **A small set of DO-gated policy verbs** — operations behind Device Owner
   that uid 2000 cannot perform:
   - `setUninstallBlocked(pkg, true)` — pin an app against user uninstall.
   - `setPermissionGrantState(...)` — a grant *policy* that also applies to
     future installs, stronger than one-shot `pm grant`.
   - `setApplicationHidden(...)` — a hide stronger than `pm disable-user`.
   - silent uninstall as policy, `setKeepUninstalledPackages`, delegated install
     scopes.

If that list is not worth the costs in [§6](#6-costs-and-boundaries), the lane
should not be built. This doc assumes it is worth prototyping *to learn*, not
that it is worth shipping.

## 2. What is genuinely gated behind Device Owner

| Capability | uid 2000 (today) | Device Owner | Worth the lane? |
| --- | --- | --- | --- |
| Silent install of a pushed APK (tethered) | yes (`pm install`) | yes | no — already have it |
| Silent install untethered / after reboot | no (adb authority dies) | yes (on-device agent) | maybe |
| Block user uninstall of an app | no | `setUninstallBlocked` | yes |
| Permission-grant *policy* for future installs | no (only one-shot `pm grant`) | `setPermissionGrantState` | yes |
| Hide an app beyond `pm disable-user` | partial | `setApplicationHidden` | maybe |
| Fetch a Play-only APK | no | no | n/a — DO does not help |

The rightmost column is the whole argument: the lane earns its cost only for the
"yes/maybe" rows, and only if untethered convergence or hard uninstall-pinning
is something the owner actually wants.

## 3. Architecture: a minimal, self-built DPC

Recommendation: **a purpose-built ~100-line Java DPC**, not an adopted
third-party app (Dhizuku/OwnDroid/TestDPC). Rationale:

- It is an ordinary APK whose "DO-ness" is pure manifest content, so it builds
  as a **fixed-output Nix derivation** from the toolchain the flake already
  pulls: `androidenv` build-tools (`aapt2`, `d8`, `apksigner`), `jdk_headless`,
  and `platforms/android-35/android.jar`. **No Gradle, no Android Studio.** A
  Java-only DPC keeps the toolchain to `javac` + `d8` (Kotlin would add
  `kotlinc`).
- It is signed with a key nix-android controls, is dependency-free, and — the
  safety-critical part — we can guarantee it ships a reachable **self-clear**
  command (see [§5](#5-provisioning-and-the-exit-path)). An unremovable DO is
  the worst failure mode; owning the code removes that risk.
- Dhizuku's cleverness (delegating DO to other apps to bypass the one-DO limit)
  solves a problem nix-android does not have, at the cost of a third-party
  trust/UX surface that fights the "declarative, minimal, no-Google,
  laptop-driven" identity. It stays a study reference, not a dependency.

Minimum viable DPC components (all mandatory, nothing more):

- a `DeviceAdminReceiver` subclass (can be effectively empty);
- `res/xml/device_admin.xml` with an **empty** `<uses-policies>` — silent
  install via `PackageInstaller` declares no policy; only the DO-gated verbs we
  actually call would add entries;
- a manifest `<receiver>` guarded by `android.permission.BIND_DEVICE_ADMIN`,
  with the `android.app.device_admin` meta-data and the
  `android.app.action.DEVICE_ADMIN_ENABLED` intent filter;
- an **exported, permission-guarded** command receiver (see [§4](#4-controller--dpc-command-channel)).

No `INSTALL_PACKAGES` (privileged, ungrantable) and no `REQUEST_INSTALL_PACKAGES`
(that is the non-DO sideload-prompt path) are declared. Being DO is what
suppresses the prompt.

Silent install itself is a standard `PackageInstaller` session
(`createSession` → `openWrite` the bytes → `commit`); the DO status, not any
extra permission, makes `commit` prompt-free.

## 4. Controller → DPC command channel

The laptop pushes bytes and must tell the on-device DPC to act. The naive design
is a **trap**:

- **Do not** `adb push` an APK to `/data/local/tmp` and have the DPC read it.
  Files there are SELinux-labeled `shell_data_file`; the DPC's app domain is not
  allowed to read them on a production build (DAC world-readable bits do not
  help — MAC denies it). This silently works on some debug builds and fails on
  real devices. It is the single most likely way to design this wrong.

The clean split:

- **Bytes go through `shell`, not the DPC.** `adb push … && adb shell pm install`
  — SELinux-clean, already silent, no DPC involved. The DPC is not the install
  path for tethered bytes.
- **DO-gated policy verbs go through an intent.** `adb shell am broadcast -a
  <action> --es cmd blockUninstall --es pkg com.foo -n <dpc>/<Receiver>` to an
  `exported` receiver guarded by a signature-level permission the DPC defines.
  The DPC then calls the `DevicePolicyManager` API. No file crosses a domain
  boundary, so no SELinux problem.
- **Untethered install** (the reboot-persistent case, if pursued) has the DPC
  pull bytes from a location it owns — its own data dir or a `content://`
  provider — never `/data/local/tmp`.

Prototype must confirm an `am broadcast` from uid 2000 actually reaches the
guarded receiver and the DO call succeeds.

## 5. Provisioning and the exit path

Provisioning is **`bootstrap`-phase only**, never `switch`:

- `adb shell dpm set-device-owner <pkg>/<receiver>` succeeds only on a
  device that is **unprovisioned** (`Settings.Secure.USER_SETUP_COMPLETE` unset
  or within the window), has **no accounts**, and **one user** (no work profile,
  no secondary user). Any account present is the #1 failure. Since Android 7 the
  DPC generally needs `android:testOnly="true"` for adb-driven provisioning —
  which also debug-flags the app and bars it from Play (irrelevant here, but a
  fact to record). This is why the lane lives in the wiped-device `bootstrap`
  path, not steady-state `switch`.
- **The exit path is the sharp edge.** `dpm` cannot unset a DO. Absent a
  self-clear, **factory reset is the only way out.** The DPC therefore **must**
  expose `clearDeviceOwnerApp(pkg)` over its command channel, and the prototype
  must prove the round trip: provision → do work → clear → gone, no reset. This
  is a hard release gate: no DO lane ships until the clean teardown is proven.

## 6. Costs and boundaries

Standing costs on a personal daily driver, all permanent while DO is set:

- a visible "device is managed by your organization" disclosure;
- the account-wipe prerequisite to enter, and factory-reset-to-exit unless the
  DPC self-clears;
- work-profile / org enrollment is locked out (one management context only);
- a `testOnly` debug-flagged admin app in the trusted computing base.

Attestation: becoming DO does **not by itself** change the Play Integrity
verdict — integrity is keyed on bootloader/ROM/Play-certification, not
management state. On GrapheneOS the Pixel already fails stock Play Integrity
because GrapheneOS is not Play-certified; the DO lane does not materially change
that. Banking-app behavior is a GrapheneOS-vs-Play-Integrity question that
exists with or without DO. Confirm specific apps separately; do not attribute
their behavior to the lane.

Permanent boundaries (consistent with [LIMITS.md](./LIMITS.md)): the DO lane
would still not fetch Play-only APKs, not bypass Android's permission model
beyond the documented DO-gated verbs, and not promise app-data migration.

## 7. Phased plan

Nothing touches a real phone until the risks pass on the AOSP emulator and the
owner approves the exact plan.

**The prototype and its results are deliberately not on `main`.** A minimal
~100-line Java DPC, a code-less payload, a Gradle-free flake build, and an
emulator-only harness live on the branch **`dpc-prototype`** — kept off `main`
because it is throwaway (a `testOnly` debug app, an unguarded command receiver,
and a checked-in throwaway signing key), not something to carry in the shipped
tree or its history. What that branch proved, on the AOSP emulator
(android-35 x86_64):

1. **DO silent install works on AOSP.** `PackageInstaller.commit()` under Device
   Owner returned `STATUS_SUCCESS` with no `PENDING_USER_ACTION` — a prompt-free
   install of the bundled payload. **Still unverified on GrapheneOS** — the one
   claim no first-party GrapheneOS source confirmed; verify on a **spare**
   GrapheneOS device, never inferred on the Pixel.
2. **The command channel is SELinux-clean.** `am broadcast` from uid 2000
   reached the exported receiver and the DO verbs (`isDeviceOwnerApp`,
   `setUninstallBlocked`, `clearDeviceOwnerApp`) succeeded. The DPC never read
   `/data/local/tmp`; the payload rode in the DPC's own assets.
3. **The exit path needs no factory reset.** `clearDeviceOwnerApp` yielded
   `isDeviceOwnerApp() == false` and `dpm list-owners` dropped the package;
   re-provisioning after a self-clear + reinstall succeeded on the emulator.

Remaining steps, none of which are `main` changes yet:

4. **GrapheneOS validation on a spare device**, then re-decide shipping.
5. **Only then**, design the option surface (which DO-gated verbs become
   declarative) and the `bootstrap` integration, as a separate reviewed change.
6. **Real GrapheneOS** validation stays gold-standard and owner-gated; the Pixel
   6 daily driver is not a DO test bed.

## 8. Decision the owner still has to make

The prototype is worth building **to learn** whether GrapheneOS honors DO silent
install and whether the clean teardown works — those are genuinely unknown and
cheap to answer on an emulator. Whether the lane then **ships** depends on
whether untethered/reboot-persistent convergence and hard uninstall-pinning are
capabilities the owner actually wants, given the managed-device banner, the
account-wipe, and the factory-reset-to-exit. This doc's recommendation is:
**build the emulator prototype, answer the three risks, and re-decide shipping
with real data** — not to commit to the lane sight-unseen.
