# PRIMITIVES — verified adb capability matrix

> Phase 0 ground-truthing. Every row below was **actually executed**, not
> recalled. Raw captures (inventory, `cmd -l`, settings dumps — personal data,
> kept out of this public-mirrored repo) live in `~/Documents/phone-migration/`.

**Session 1 — 2026-07-15.** Device: Pixel 6 (oriole), **GrapheneOS build
2026071101** (Android 17 / SDK 37, patch 2026-07-05), uid 2000 over USB adb.
Surface size: 333 `cmd` services, 401 settings keys, 35 user apps.

## Verified WORKING at shell (read + write + reversible round-trip)

| Primitive | Read | Write | Notes |
|-----------|------|-------|-------|
| `cmd role get/add-role-holder` | ✓ | ✓ | Default browser/SMS/home/dialer — declarative default apps confirmed |
| `settings put global/secure` | ✓ | ✓ | incl. `private_dns_mode`/`private_dns_specifier`, `sysui_qs_tiles` (full QS layout incl. `custom(...)` third-party tiles) |
| `cmd uimode night` | ✓ | ✓ | Dark mode |
| `cmd deviceidle whitelist +/-pkg` | ✓ | ✓ | Battery-optimization exemptions; add/remove round-trip clean |
| `cmd wifi add-network / list-networks / forget-network` | ✓ | ✓ | **Declarative Wi-Fi confirmed on GrapheneOS** — dummy wpa2 network added, listed, forgotten cleanly. sops-PSK design is GO |
| `ime list` | ✓ | untested | Keyboards enumerable; `set-default` next session |
| `appops get` | ✓ | untested | Per-app op modes readable |
| `pm list packages -3 --show-versioncode -i --user 0` | ✓ | — | Inventory incl. installer attribution |
| GrapheneOS **Network** permission | ✓ | expected | = runtime `android.permission.INTERNET` (granted flags visible in dumpsys) → `pm grant/revoke` territory |
| GrapheneOS **Sensors** permission | ✓ | expected | = runtime `android.permission.OTHER_SENSORS`, same mechanism |

## Verified LIMITS

## Atlas raw capture (2026-07-15, GrapheneOS 2026071101)

`scripts/atlas-probe.sh` → `~/Documents/phone-migration/probes/`. **335 `cmd`
services; 134 have no shell interface, ~200 do.** No graphene-named services —
supports the exploit-protection-out-of-reach hypothesis. New find from the walk:
`cmd locale` has clean get/set symmetry for **device locale AND per-app locales**
(`set-app-locales`, `set-device-locale`) — strong module candidate; write test
on emulator.

| Boundary | Evidence |
|----------|----------|
| Secondary profiles unreachable | `pm` against user 10 (Work profile) → `SecurityException: Shell does not have permission to access user 10`. Converge scope = owner (user 0) only; Work profile belongs to its MDM; Private space (user 11) presumed same — verify |
| GrapheneOS per-app exploit protection (memtag etc.) | Not present in any `settings` namespace — storage location unknown, likely out of shell reach. Dig later; provisional LIMITS entry |

## Session 2 — 2026-07-15 (emulator bench, AOSP API 35 x86_64 userdebug)

Bench: `nix run .#emulator` (headless, KVM on duo). All probes ran with explicit
`-s emulator-5554`; adb refuses untargeted commands with two devices attached —
extra guardrail. Test payload: F-Droid.apk (12 MB).

All verified on the bench, full write round-trips:

| Primitive | Result |
|-----------|--------|
| Silent `adb install` / `uninstall` / reinstall | ✓ zero prompts, versionCode readable |
| `pm grant/revoke` (POST_NOTIFICATIONS) | ✓ reflected in dumpsys immediately |
| `appops set/get` round-trip | ✓ |
| `ime set` | ✓ "Input method … selected" |
| `cmd netpolicy add/remove restrict-background-blacklist <uid>` | ✓ |
| `pm suspend/unsuspend` | ✓ suspended=true visible in pm dump |
| `cmd locale set-app-locales` set/get/clear | ✓ per-app locale fully scriptable |
| `cmd package get-app-links` | ✓ read incl. **signer cert hash** — feeds the engine's signature-mismatch detection |

**⚠ Persistence nuance (the session's big find):** after an abrupt `adb reboot`,
only `settings put` survived — deviceidle whitelist, per-app locale,
`pm disable-user`, and appops all reverted (while installed apps survived, so
/data was intact). With a ~90 s settle + graceful `svc power reboot
userrequested`, **everything persisted**. Interpretation: those subsystems
write-behind their /data/system XMLs and flush on clean shutdown; the settings
provider commits synchronously. Engine rules: (1) never hard-reboot right after
converge; (2) persistence tests must use graceful reboots. Normal power-menu
reboots are graceful, so real-world risk is low. (Settle-vs-graceful not
bisected — recipe recorded as both.)

**LIMITS correction:** Private space (user 11) **is shell-enumerable** on the
Pixel (`pm list packages --user 11` works) — unlike the Work profile (user 10,
SecurityException). Scope: owner + Private space manageable; Work profile
belongs to its MDM.

## Next session

- [ ] Pixel no-op confirmations (with go-ahead): grant-what's-granted, ime-set-current
- [ ] (emu) `pm hide`, `cmd package set-app-links --package` write side
- [ ] (emu) `cmd role` write round-trip (role service on emulator), `settings put system`
- [ ] F-Droid index-v2 → versionCode/APK-URL/sha256 resolution (pure curl+jq, no device)
- [ ] Obtainium export round-trip (has an app list on the Pixel? read-only export)
- [ ] Atlas classification pass: cmd-help.txt → docs/ATLAS.md skeleton
- [ ] **Phase 1 start**: module system skeleton (`lib.evalModules` → manifest.json golden test)

Deprioritized: Wi-Fi module (verified working, stays a feature, not on Devin's
personal critical path).
