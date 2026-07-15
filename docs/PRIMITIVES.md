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

| Boundary | Evidence |
|----------|----------|
| Secondary profiles unreachable | `pm` against user 10 (Work profile) → `SecurityException: Shell does not have permission to access user 10`. Converge scope = owner (user 0) only; Work profile belongs to its MDM; Private space (user 11) presumed same — verify |
| GrapheneOS per-app exploit protection (memtag etc.) | Not present in any `settings` namespace — storage location unknown, likely out of shell reach. Dig later; provisional LIMITS entry |

## Next session

> **Safety protocol applies (PLAN §Phase 0): the Pixel 6 is daily-use hardware.**
> Emulator-first for anything below marked (emu); Pixel only gets no-op /
> new-state-reversible probes, with explicit go-ahead per mutation class.

- [ ] Set up AOSP emulator on duo (KVM) — the free-fire lane
- [ ] (emu) `pm grant/revoke` round-trip; then Pixel: grant-what's-already-granted no-op only
- [ ] (emu) `ime set-default` round-trip
- [ ] (emu→pixel, with go-ahead) silent `adb install` + uninstall of a tiny NEW F-Droid APK — never touches existing apps
- [ ] (emu) `appops set`, `cmd netpolicy`, `pm suspend/hide`, `cmd package set-app-links`
- [ ] (emu) reboot-persistence pass for everything above
- [ ] Atlas probe script: walk `cmd -l` help texts → classification skeleton (read-only, Pixel OK)
- [ ] Private space (user 11) accessibility check (read-only)

Deprioritized: Wi-Fi module (verified working, stays a feature, not on Devin's
personal critical path).
