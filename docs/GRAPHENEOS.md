# GrapheneOS at adb-shell privilege

This is the single reference for what GrapheneOS adds on top of AOSP, what of
it adb shell (uid 2000) can reach, and how GrapheneOS changes day-to-day use
of nix-android. [LIMITS.md](./LIMITS.md), [PRIMITIVES.md](./PRIMITIVES.md), and
[USING.md](./USING.md) link here instead of repeating it.

Evidence comes from two places, kept separate on purpose:

- **Source:** GrapheneOS
  [platform_frameworks_base](https://github.com/GrapheneOS/platform_frameworks_base/tree/17)
  and
  [platform_system_sepolicy](https://github.com/GrapheneOS/platform_system_sepolicy/tree/17),
  branch `17`.
- **Device:** read-only probes of a GrapheneOS Pixel 9 Pro, build
  `CP3A.261005.005`, on 2026-11-11. No setting was written.

Nothing on this page has passed the mutation bench (see
[The bench gap](#the-bench-gap)). The repo rule still applies: no typed option
without read, write, real-change read-back, and graceful-reboot persistence.

## Settings keys reachable through `android.settings`

GrapheneOS's `SettingsProvider` marks its own keys
`@Protected(readWrite = SETTINGS)` and then exempts the shell package from that
check, with the source comment "ADB is used for testing". So `settings get` and
`settings put` at uid 2000 reach the keys below. Reads were verified on the
device. Writes follow from source and were **not** bench-verified.

Global namespace:

| Key | Meaning |
| --- | --- |
| `settings_reboot_after_timeout` | auto-reboot after this many ms locked; default 18 hours |
| `bluetooth_off_timeout`, `wifi_off_timeout`, `nfc_off_timeout` | radio auto-off timers; `0` = off |
| `network_location` | `0` off, `1` Apple, `2` GrapheneOS proxy, `3` Apple China |
| `geocoder` | `0` off, `1` OpenStreetMap, `2` GrapheneOS |
| `restrict_memory_dyn_code_exec`, `restrict_storage_dyn_code_exec`, `restrict_webview_dyn_code_exec` | default dynamic-code-loading restrictions |
| `force_app_memtag` | force MTE for apps |
| `allow_automatic_pkg_hardening_config` | automatic per-app hardening config |
| `allow_clipboard_read` | default clipboard read policy |
| `force_disable_supl` | disable SUPL |
| `psds_server`, `attest_remote_provisioner_server`, `widevine_provisioner_server`, `cert_transparency_downloader` | service endpoint selection |
| `battery_charge_limit` | charge limit |

Secure namespace: `lockscreen_scramble_pin_layout`,
`lockscreen_scramble_pin_layout_secondary`, `scramble_sim_pin_layout`,
`auto_grant_OTHER_SENSORS_perm`, `screenshot_timestamp_exif`,
`cross_profile_clipboard_access`, `disallow_delayed_locking_on_user_stop`.

```nix
android.settings.global.settings_reboot_after_timeout = "28800000"; # 8 hours
android.settings.secure.lockscreen_scramble_pin_layout = "1";
```

Label for these keys until a GrapheneOS bench exists: **source-verified,
device read-verified, not bench-verified.**

One wrinkle. A key the user never touched is unset and reads `null`, so
declaring the default value shows as drift until the first `switch` writes it.
After that the key is explicitly set: it pins the value and no longer follows a
later change to GrapheneOS's default. The engine rejects the literal string
`"null"` as a declared value, so there is no way to declare "unset".

A typed `grapheneos.*` option set over these keys is deferred (see
[PLAN.md](./PLAN.md)). The raw namespace works today.

## Per-app exploit protection: write-only, so not managed

The per-app toggles (hardened_malloc, extended virtual address space, MTE, exec
spawning, the three dynamic-code-loading restrictions, native debugging,
`ENABLE_EXPLOIT_PROTECTION_COMPAT_MODE`, `BLOCK_PLAY_INTEGRITY_API`, clipboard,
and Storage/Contact Scopes) do have a shell write verb, in
`PackageManagerShellCommand.java`:

```text
pm edit-gos-package-state <pkg> <userId> add-flag|clear-flag <FLAG>
  [set-storage-scopes <hex>] [set-contact-scopes <hex>]
```

`GosPackageStatePermissions` grants `SHELL_UID` full access. There is no read
path: the state is not in `dumpsys` and lives only in the root-only
`packages.xml` as `<GrapheneOS-package-state flags-1=…>`. Without a read-back,
plan cannot diff and switch cannot verify, so nix-android does not manage it.
Storage and Contact Scopes are opaque hex blobs and must never be declared even
if a read path appears. The verb's existence is verified from source only; it
was not run.

## Unreachable at uid 2000

| Control | Why |
| --- | --- |
| USB-C port mode (`persist.security.usb_mode`) | sepolicy grants `get_prop` only to `system_app` |
| Duress PIN/password | needs the owner credential; must never go near a config file |
| GrapheneOS App Store and System Updater (`app.seamlessupdate.client`) channels | app-private storage (inferred, not probed) |
| Sandboxed Google Play compatibility toggles | app-private storage (inferred, not probed) |
| Work profile | `pm list packages --user 11` returned `SecurityException` on the Pixel 9 Pro |
| Private Space | same `SecurityException` on the Pixel 9 Pro; the Pixel 6 build `2026071101` allowed enumeration ([PRIMITIVES.md](./PRIMITIVES.md)) |

Readable with `getprop` but not writable from shell (`system_prop` context):

| Property | Values |
| --- | --- |
| `persist.sys.connectivity_checks` | `0` GrapheneOS, `1` standard, `2` disabled |
| `persist.security.exec_spawn` | global exec spawning |
| `persist.native_debug` | global native debugging |
| `persist.keyguard.camera` | camera access from the lock screen |

Already covered without anything GrapheneOS-specific:

- The Network and Sensors toggles are the runtime permissions
  `android.permission.INTERNET` and `android.permission.OTHER_SENSORS`.
  `android.permissions.<pkg>.grant`/`revoke` manage them. GrapheneOS adds no
  app-ops of its own.
- Camera and microphone toggles are AOSP sensor privacy, with no readable
  per-sensor state at shell.

## The bench gap

The AOSP emulator is the engine-logic bench. It cannot prove GrapheneOS
behavior. A GrapheneOS emulator build (`sdk_phone64_x86_64`, per
[grapheneos.org/build](https://grapheneos.org/build)) is `userdebug`, and
`Build.IS_DEBUGGABLE` flips exactly the behavior under test: the USB-C port
mode defaults to all ports enabled, root can enter the protected settings, and
the gmscompat bypass is on. x86_64 also has no MTE.

Recommendation: a spare Pixel 8a or newer on official stable GrapheneOS as the
GrapheneOS mutation bench, with the AOSP emulator staying the engine-logic CI.
Until that exists, every GrapheneOS-only key stays labeled as above and none
becomes a typed option.

## adb on a locked GrapheneOS phone

GrapheneOS's USB-C port defaults to "Charging-only when locked". By source this
does not cut a data connection made before the phone locked. Two things do drop
adb until the next unlock:

- unplugging and replugging the cable while locked;
- the auto-reboot (`settings_reboot_after_timeout`) firing, which lands the
  phone in Before-First-Unlock.

Keep the phone unlocked and the cable seated for long runs: `assist --watch`,
`bootstrap`, a large `switch`. `switch` warns when `dumpsys window policy`
reports the keyguard showing at start; it does not refuse, because a session
opened before locking keeps working.

## GrapheneOS and installers

- `adb install` from shell skips Android's update-owner reminder
  (`PackageInstallerSession` checks `!isInstallerShell`).
- `InstallPackageHelper` clears the update owner when the installer changes.
  A managed upgrade of an app Play installed therefore silently takes it away
  from Play's automatic updates.
- Never record `app.grapheneos.apps` as the installer (`adb install -i`) of a
  third-party app it did not deliver.
- GrapheneOS blocks installs of Google Play services and the Play Store that
  aren't initiated by its first-party source, except from shell. Keep
  `com.android.vending` and `com.google.android.gms` in `apps.attended` and
  install them through the GrapheneOS App Store.

## OS build in generation receipts

GrapheneOS ships roughly weekly (31 build IDs between 2026-08-05 and
2026-11-08). Each generation receipt records `ro.build.fingerprint` and
`ro.build.version.incremental`, and `status` prints
`OS changed since last switch: <old> → <new>` when the fingerprint differs, so
drift after an OTA is read in that light. Receipts from before this field
existed show `unknown`.
