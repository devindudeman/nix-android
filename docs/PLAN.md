# declarative-android — nix-darwin, but for GrapheneOS

> **Status: DRAFT / planning (2026-07-15).** New standalone project (will get its
> own repo — this doc lives in `drafts/` only until the repo exists, then moves
> there and this copy becomes a pointer). Research basis: deep-research run
> 2026-07-15, 19 sources, 25 claims adversarially verified, 0 refuted. Key
> verified facts are cited inline; open questions from that run are folded into
> Phase 0.

## The pitch

A NixOS-style module system that converges a **stock, locked-bootloader
GrapheneOS device** toward a version-controlled Nix file — apps, app sources,
settings, permissions, debloat — over plain `adb` (uid 2000, no root, security
model untouched). `darwin-rebuild switch` for your phone:

```
android-rebuild switch --flake .#pixel
```

"Good enough within the environment" is the design creed, exactly as nix-darwin
treats macOS: converge everything reachable at shell privilege, be loudly honest
about what isn't, never fight the OS. Moving to a new device = flash GrapheneOS,
enable adb, run converge.

**Nobody has built this.** The research found only a 35-minute-old abandoned
prototype ([phenax/nix-android-apps](https://github.com/phenax/nix-android-apps),
2022, adb-install-only) and building blocks. The niche — NixOS users × GrapheneOS
users — is small but real, passionate, and completely unserved. Public release is
a goal from day one.

## What the research established (verified, 2026-07-15)

- **Every needed primitive works at adb-shell privilege:** `adb install` /
  `pm install` are silent (no confirmation tap — that's only for on-device
  installer intents), `pm grant/revoke` + `appops set` cover permissions,
  `settings put system|secure|global` covers settings (shell holds
  WRITE_SECURE_SETTINGS), `pm disable-user` covers debloat.
- **The same script can run PC-free on-device** via Shizuku's `rish` shell in
  Termux (uid 2000; must re-pair wireless debugging after each reboot).
- **The two "purer" architectures are dead ends for a daily driver today:**
  robotnix (Nix-built self-signed images) is alpha + forks you off the official
  OTA channel; device-owner MDM (true silent reconciliation) is blocked on
  GrapheneOS SetupWizard2 **PR #40** (open, wanted upstream, needs rework).
  Re-check PR #40 each phase — if merged, it becomes an optional backend.
- **Hard non-root ceiling (document, don't fight):** app *data* of backup-opted-out
  apps (Signal, Briar), FLAG_STOPPED apps excluded from backups, downgrades
  blocked on user builds, eSIMs and Keystore keys non-exportable, Play-only apps
  not fetchable.

## Architecture: manifest + engine

The one load-bearing design decision. Nix evaluates modules into a **plain JSON
manifest** (the declared state — pure data, no logic); a single **converge
engine** reads the manifest, queries the device, computes a plan, applies it.

```
phone.nix ──eval──► manifest.json ──engine──► adb ──► device
   (Nix module system)      (data)      (one script)
```

Why split: the engine is reusable verbatim by the on-device Termux/rish variant
(Phase 4) and testable against an emulator without any Nix on the test box. The
Nix layer stays thin — options, types, assertions, APK fetching. No abstractions
beyond this. (ponytail: engine starts as one POSIX-ish shell script + jq; a Go/Rust
rewrite is the named upgrade path if bash parsing pain exceeds ~500 lines.)

### The Nix UX (target — v1 surface, nothing speculative)

```nix
# flake.nix (user's phone repo)
androidConfigurations.pixel = nix-android.lib.mkDevice {
  modules = [ ./pixel.nix ];
};
```

```nix
# pixel.nix
{
  device.name = "pixel";           # matched against adb serial at converge time
  device.user = 0;                 # GrapheneOS user profile (multi-profile later)

  # Apps, by source. F-Droid + direct-APK are fetched INTO THE NIX STORE by
  # hash (index-v2 / GitHub releases API + lock file) — reproducible payloads,
  # offline-capable converge. This is the genuinely nix-y part.
  apps.fdroid.packages = [ "org.fdroid.fdroid" "com.termux" "app.comaps" ];
  apps.release."com.imranr.obtainium" = { github = "ImranR98/Obtainium"; };

  # Play/Aurora apps can't be fetched headlessly: declared as *attended* —
  # converge asserts presence and prints a human TODO list. Honest boundary.
  apps.attended = [ "com.spotify.music" ];

  # NixOS-purity dial, homebrew-cleanup style: "none" (additive) or
  # "uninstall" (undeclared user apps removed). Default none; flip when brave.
  apps.cleanup = "none";

  android.settings.global.stay_on_while_plugged_in = 0;
  android.permissions."com.termux".grant = [ "android.permission.POST_NOTIFICATIONS" ];
  android.packages.disabled = [ ];   # debloat via pm disable-user

  # ---- Atlas-dependent options (each lands only after Phase 0 verifies its
  #      primitive at uid 2000 — see "The ADB surface" below) ----
  android.defaultApps.browser = "org.mozilla.fenix";        # cmd role
  android.darkMode = true;                                   # cmd uimode night
  android.privateDns = "dns.example.com";                    # settings put global private_dns_*
  android.quickSettings.tiles = [ "internet" "bt" "flashlight" ];  # sysui_qs_tiles
  android.wifi.networks."HomeNet".pskFile = config.sops.secrets.wifi-home.path;  # cmd wifi
  android.batteryOptimization.exempt = [ "com.termux" ];     # cmd deviceidle whitelist
}
```

### The CLI (mirrors darwin-rebuild deliberately)

| Command | Does |
|---------|------|
| `android-rebuild build` | eval → manifest, fetch APK closure, **print the plan** (diff vs device) — apply nothing |
| `android-rebuild switch` | build + apply + record generation |
| `android-rebuild import` | **`nixos-generate-config` for phones**: read a connected device (pm list -3 -i, settings, grants) and emit a starter `pixel.nix` — this is the migration-day killer feature and reuses the app-inventory adb work already done |
| `android-rebuild update` | refresh the lock file (latest versionCodes/hashes from F-Droid index-v2 + GitHub releases) |
| `android-rebuild rollback` | converge to previous generation's manifest |

Generations = applied manifests archived in `~/.local/state/nix-android/<device>/`.
Rollback re-converges to an old manifest — honest about being convergence, not a
store symlink flip (the device is mutable; we don't pretend otherwise).

### Converge semantics (the corners that bite)

- **Pins are floors, not exact:** F-Droid client / App Store on-device will
  self-update apps. Converge upgrades to ≥ locked versionCode, never downgrades
  (blocked on user builds anyway), never fights auto-updaters.
- **Signature mismatch** (app switching source, e.g. Play→F-Droid build): detect
  installed signer, refuse, require explicit `--reinstall <pkg>` (= data loss,
  human decision).
- **Split APKs / app bundles:** `adb install-multiple`; F-Droid is single-APK,
  GitHub releases usually universal — spike confirms coverage.
- **Idempotence is the test:** `switch` twice in a row → second run is a no-op
  with an empty plan. This assert is the project's one non-negotiable check.

## The ADB surface — take ALL of it

adb-shell is far bigger than `pm` + `settings`. Modern Android exposes **every
system service** through `cmd` (`adb shell cmd -l` lists ~150 of them, each with
its own subcommand help), plus `dumpsys` for reads, `content` for provider-level
state, `wm`/`ime`/`svc` for display/keyboard/radios. The project's ambition is to
claim *everything* in that surface that is (a) writable at uid 2000 and
(b) persistent — transient state (airplane mode now, brightness now) is not
config and stays out.

**The Atlas** is Phase 0's centerpiece and a standing deliverable: a generated
`ATLAS.md` capability matrix built by a probe script that walks `cmd -l`, captures
each service's help text, and hand-classifies candidates into: *verified-writable
/ needs-verification / read-only / transient / privileged-beyond-shell*. Every
module option must cite its Atlas row. Regenerate per Android major and per
GrapheneOS release — the Atlas doubles as the version-support matrix.

High-value candidates to probe first (all **unverified until Phase 0 runs them**
— this list is the hunting map, not a promise):

| Category | Primitive | Would give us |
|----------|-----------|---------------|
| Default apps | `cmd role add-role-holder` (browser/SMS/dialer/launcher via RoleManager); `cmd package set-home-activity` | Declarative default apps — huge daily-life win |
| Wi-Fi | `cmd wifi add-network` / `add-suggestion` / `list-networks` | Declarative Wi-Fi profiles, PSKs from **sops-nix** — flagship feature for fleet-brained users |
| Network policy | `cmd netpolicy` (per-app background data), `settings put global private_dns_mode/specifier` | Data-saver rules + declarative DoT/private DNS |
| UI | `cmd uimode night`, `wm density/size`, `settings put secure sysui_qs_tiles`, animation scales | Dark mode, display density, exact QS tile layout |
| Input | `ime list/enable/set-default`, `settings put secure enabled_accessibility_services` | Keyboard + accessibility services as config |
| Power | `cmd deviceidle whitelist` | Battery-optimization exemptions (Syncthing, Termux daemons) |
| Notifications | `cmd notification allow_listener`, channel state via dumpsys | Notification-listener grants (declared, not tapped) |
| Package extras | `pm suspend/unsuspend`, `pm hide`, `pm install-existing`, `cmd package set-app-links` | Focus-mode suspension, resurrect preinstalled apps, URL-handler defaults |
| Locale/time | `cmd locale` (?), `settings put system system_locales`, `cmd time_detector` | Language + time config |

Method for each: run it, reboot, confirm persistence, note the exact
read-back command (the engine needs *read* + *write* + *compare* per option —
no read-back, no option). Expect a healthy fraction to fail at uid 2000 or on
GrapheneOS specifically; the Atlas records the tombstones too, so the README's
LIMITS section is generated evidence, not vibes.

## Borrowed from nix-config (design it like home)

This project should feel like the author's own fleet repo, both because those
patterns are proven and because it *is* going to be consumed from it:

- **Builder-with-slots** (`flake.nix:355` `mkWorkstation` pattern): `mkDevice`
  takes `modules` + ordered slots, and module *groups* compose like
  `homeModules.common/theming/desktop` — e.g. `droidModules.base` (F-Droid,
  Termux, sane settings) + `droidModules.degoogled` + per-device module. A
  future second phone = compose groups + tiny device file, exactly like adding
  a laptop today.
- **sops-nix for secrets**: Wi-Fi PSKs and any API-keyed app config declared via
  the same age-key + `sops.secrets` flow the fleet already uses; the manifest
  carries *paths*, the engine reads them at converge time — secrets never land
  in the manifest JSON or the store.
- **justfile task runner** mirroring the repo's (`just switch`, `just plan`,
  `just import`, `just atlas`).
- **Same hygiene**: treefmt + nixfmt (RFC-166), statix, deadnix pre-commit;
  CLAUDE.md canonical + AGENTS.md symlink (project-setup skill).
- **GitOps, comin-flavored** (Phase 4): the phone config lives in a git repo;
  a udev rule + systemd service on the laptops runs `android-rebuild switch`
  automatically when *your* phone (by serial) is plugged in — comin's
  pull-on-change model with the USB cable as the trigger. Same safety shape
  too: plan-before-apply, generation recorded, converge is idempotent.
- **Eventually a skill**: a `nix-android` skill in `home/skills/` once the CLI
  stabilizes, so every agent can operate the phone config.

## Phases

### Phase 0 — Ground-truth the primitives (IN PROGRESS — session 1 done 2026-07-15)

Devin's daily Pixel 6 turned out to already run GrapheneOS, so Graphene-specific
validation started immediately (see `PRIMITIVES.md`). Deliverable: capability
matrix — every claimed primitive actually run, output format noted.

> **⚠️ Safety protocol — the Pixel 6 is a daily-use device Devin needs working.**
> On it: read-only probes and no-op/trivially-reversible round-trips ONLY (write
> current value back; add-then-remove of *new* state). Anything with breakage
> potential — uninstalls of existing apps, permission revokes on apps in use,
> `pm suspend`, role changes to different values, reboot-persistence passes —
> runs on an AOSP emulator (KVM on duo) first, and touches the Pixel only after
> emulator proof + explicit go-ahead. The converge engine inherits this posture:
> plan-before-apply always, destructive actions gated behind explicit flags.

Devices: Pixel 6 (GrapheneOS, careful lane) + AOSP emulator (free-fire lane).
Config portability target: this phone's config should later converge onto
another Pixel — the multi-device story is real from day one.

Generic (this week, current phone + AOSP emulator):
- [ ] **Build the Atlas probe script** (`cmd -l` walk → help capture → classification skeleton) and run it — this frames everything below
- [ ] `pm list packages -3 --show-versioncode -i` / `dumpsys package` parse shapes
- [ ] silent `adb install` / `install-multiple`, uninstall, disable-user round-trip
- [ ] `pm grant/revoke` + `appops set` — which permission classes each covers
- [ ] `settings list/put` across the three namespaces; which secure keys reject shell
- [ ] The Atlas hunting map, priority order: `cmd role`, `cmd wifi add-network`, `sysui_qs_tiles`, `private_dns_*`, `cmd uimode`, `cmd deviceidle`, `ime`, `cmd netpolicy` — each with reboot-persistence + read-back check
- [ ] F-Droid index-v2: resolve package → versionCode → APK URL + sha256 (curl + jq only)
- [ ] Obtainium JSON export round-trip (research's biggest unverified gap)

GrapheneOS-specific (migration day, on the Pixel):
- [ ] Network/Sensors permission toggles from shell — appops? settings? unreachable?
- [ ] Per-app exploit-protection settings — shell-writable or document-as-manual?
- [ ] Multi-profile (`--user N`) behavior for all of the above
- [ ] nix-on-droid under hardened seccomp (issue #130 / PROOT_NO_SECCOMP=1) — nice-to-have

### Phase 1 — MVP: apps only (IN PROGRESS — core loop DONE on bench 2026-07-15)

**Working end-to-end on the emulator bench:** module system
(`modules/options.nix`, `lib.mkDevice`) → manifest.json with store-fetched,
hash-verified APKs (F-Droid index-v2 chain of trust: entry.json sha256 →
index → per-APK sha256 in `apps.lock.json` via `scripts/update-lock.sh`,
stable-channel filtering, ABI selection) → converge engine
(`engine/converge.sh`: plan-by-default, `--apply` to execute; install /
upgrade-to-floor / attended-assert / cleanup-uninstall). Verified: plan → apply
(2 installs) → idempotent no-op, AND the removal path (undeclared + `cleanup =
"uninstall"` → remove → re-converge match). `nix run .#bench -- --serial …`.

Remaining for Phase 1 proper:
- [ ] `android-rebuild` CLI wrapper (build|switch|update|import subcommands)
- [ ] `import`: read a connected device → starter device.nix
- [ ] GitHub-release app source (`apps.release.*`)
- [ ] Device-sourced apps (Phase 2+, for migration day): `pm path` + `adb pull`
      extracts installed APKs (incl. splits) from the old device,
      `install-multiple` onto the new — signature preserved, so Aurora/Play
      keep updating them after. Makes attended (Play-catalog) apps portable
      device-to-device without accounts. Personal-use migration only; app data
      still doesn't travel. Devin's real attended count: 6 apps.
- [ ] devenv + pre-commit hygiene pass (flake-parts wiring per project-setup)
- [ ] **Real-phone exit criterion: duo converges the Pixel's app set from a
      git-tracked flake, twice, second run no-op — with Devin's go-ahead,
      plan reviewed together first, cleanup="none".**

### Phase 2 — settings, permissions, debloat

`android.settings.*`, `android.permissions.*`, `packages.disabled`, informed by
the Phase 0 matrix. `import` learns to capture these too. Exit: migration-day
dry run — `import` from old phone, `switch` onto a factory-reset emulator, get
a usable clone of the app+settings layer.

### Phase 3 — the migration (eat the dogfood at the moment it matters)

Pixel + GrapheneOS day: `import` from the old phone → prune/curate `pixel.nix`
→ `switch` onto the fresh Pixel → Seedvault/per-app restores for data (manual,
documented as such). The blog post writes itself from this day's notes.

### Phase 4 — portability + polish

Generations/rollback, multi-device (`androidConfigurations.<name>`), the
on-device Termux+rish engine variant, attended-apps UX, `apps.cleanup =
"uninstall"` mode, the udev plug-in-to-converge trigger on the laptop fleet
(comin-flavored GitOps, see above), defensive parsing pinned to the Atlas's
Android-version support matrix.

### Phase 5 — go public

Docs (README with the nix-darwin analogy front and center, honest LIMITS.md from
the research's "cannot be declarative" list), flake template, name finalized,
GitHub repo (public per project-setup remote rules), announce on GrapheneOS
forum + NixOS discourse — tone: respects the security model, no root, no
unlocked bootloader, ever. Re-check Headwind PR #40; if merged, design (don't
necessarily build) the device-owner backend.

## Open questions (decide before their phase, not before starting)

1. **Name: DECIDED 2026-07-15 — `nix-android`**, the literal nix-darwin sibling;
   CLI `android-rebuild`, `androidConfigurations.<device>` outputs. Devin chose
   it over the coined candidates (droidnix, adroit, phonix) for maximum
   discoverability. The README must be up-front that scope = uid-2000 converge
   on a stock OS (not an OS build — that's robotnix) to earn the canonical name.
2. **Engine language.** Start bash+jq (ponytail rung 6); named ceiling = parsing
   `dumpsys` in bash. Upgrade path: single static Go binary. Decide when it hurts.
3. **Emulator CI.** Module-eval + manifest golden tests in `nix flake check` from
   Phase 1; headless AVD smoke test is wanted but may be local-only (KVM on duo)
   rather than CI. Decide in Phase 2.
4. **Play-gap stance.** Attended-apps list vs. scripting Aurora Store — start
   attended (zero magic), revisit only if the list exceeds ~5 apps in practice.

## Risks

| Risk | Mitigation |
|------|------------|
| `pm`/`settings` output formats churn across Android majors | Support matrix in PRIMITIVES.md; parse defensively; emulator regression per major |
| Wireless-debugging re-pair friction (on-device variant) | USB-from-laptop is the primary lane; on-device is Phase 4 sugar |
| F-Droid index-v2 schema drift | It's stable, versioned JSON; lock-file layer isolates the blast radius |
| Auto-updaters racing converge | Pins-are-floors semantics (above) makes races harmless |
| Scope creep toward app *data* | Out of scope, forever, without root — LIMITS.md says so in bold |

## Prior-art pointers (for the eventual README credits)

robotnix (image-build-time Nix, alpha) · nix-on-droid (Nix userland, not Android
state) · phenax/nix-android-apps (the 35-minute prototype proving adb-install
feasibility) · Shizuku/rish (on-device uid-2000) · Headwind MDM + GrapheneOS
SetupWizard2 PR #40 (the future device-owner lane) · Seedvault (the data
escape-hatch we point at, not wrap).
