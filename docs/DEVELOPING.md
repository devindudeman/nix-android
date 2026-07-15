# Developing nix-android

New here? This is the map. Read [PLAN.md](./PLAN.md) for the roadmap and
philosophy, [PRIMITIVES.md](./PRIMITIVES.md) for the verified capability
matrix, [USING.md](./USING.md) for the user-facing behavior you must not break.

## Architecture in one diagram

```
device.nix ──eval (Nix module system)──► manifest.json ──engine (bash)──► adb ──► device
              lib/mkDevice                 pure data       plan / apply
              modules/options.nix          + store APKs    engine/converge.sh
```

The **manifest/engine split is the one load-bearing decision**: the manifest
is plain JSON (APKs as store paths, everything else data), the engine is a
single bash script that reads it, diffs against device reality, prints a plan,
and applies on `--apply`. Why: the engine reruns unmodified from Termux/rish
on-device someday, and tests without Nix. Don't leak logic across the line.

## File map

| Path | What |
|------|------|
| `modules/options.nix` | The entire option surface. Every option MUST cite a verified primitive in PRIMITIVES.md |
| `lib/default.nix` | `mkDevice`: evalModules → manifest derivation; APK fetching (F-Droid/release by lock hash, archives extracted in-store, local APKs badging-verified at build) |
| `engine/converge.sh` | Plan-by-default converge. Explicit `--serial` always |
| `scripts/update-lock.sh` | Resolves declared apps → `apps.lock.json` (F-Droid index-v2 with sha256 chain; GitHub/Gitea latest-release; aapt2 versionCode + package-id verification) |
| `scripts/android-rebuild.sh` | The CLI: build/plan/switch/update/import |
| `scripts/import.sh` | Device → starter device.nix (read-only) |
| `scripts/atlas-probe.sh` | Read-only device capability capture |
| `devices/bench.nix` | The emulator bench config — the e2e test target |

## Ground rules

1. **No option without a verified primitive.** Before adding any module
   option: prove the read, the write, AND graceful-reboot persistence on the
   bench; record it in PRIMITIVES.md; only then write the option. No
   read-back command = no option (the engine must be able to diff it).
2. **Plan-by-default is sacred.** Any new engine capability prints its plan
   line and does nothing without `--apply`. Destructive actions additionally
   hide behind explicit config (`cleanup = "uninstall"`) or flags.
3. **Real hardware is production.** Mutation-class development happens on the
   emulator (`nix run .#emulator` — fresh userdata every launch). A real
   phone gets: read-only, no-op writes, or additive installs — and only with
   its owner's explicit go-ahead. See CLAUDE.md's safety protocol.
4. **Never fight the OS.** Pins are floors; on-device updaters win races;
   signature mismatches refuse rather than clobber; write-behind subsystems
   (deviceidle/appops/package-restrictions) mean no hard reboots after
   mutations (PRIMITIVES.md §persistence).
5. **Personal data stays out.** Device captures, inventories, private hosts
   (Gitea URLs etc.) never land in this repo — generic examples only. This
   repo is written for strangers.

## Dev loop

```bash
direnv allow                 # devenv shell: adb, jq, aapt2, pre-commit hooks
nix run .#emulator           # headless AOSP bench (KVM; fresh userdata)
nix run .#bench -- --serial emulator-5554           # plan
nix run .#bench -- --serial emulator-5554 --apply   # converge
```

The e2e bar for any apps-path change: **plan → apply → verify → re-plan is a
no-op** (idempotence), plus the removal path when relevant. The eval bar:
`nix build .#checks.x86_64-linux.bench-manifest --impure --accept-flake-config`
must build from the committed lock.

Known wart: whole-tree `nix flake check` currently fails inside devenv's task
eval ("path .drv is not valid") — build individual checks instead.

## How to add things

**A module option** (Phase 2 pattern): bench-verify the primitive (write,
read-back, graceful-reboot persistence) → PRIMITIVES.md row → option in
`modules/options.nix` → field in the manifest (lib) → engine: read device
state, diff, plan line, apply step → bench e2e including idempotence.

**An app source**: resolver in `update-lock.sh` (must end with a sha256 for
the downloaded artifact + aapt2 package-id/versionCode verification) → lock
entry shape → `fetchApk`/manifest handling in `lib/default.nix` (store path,
extraction if archived) → option in `modules/options.nix` → bench test with a
public example app. The engine should not need changes — sources all converge
into the uniform `apps.managed` list.

## Testing philosophy

Golden rule: if it didn't run against a device (emulator counts), it isn't
verified. The negative tests matter as much as the positive: wrong package id
declared for a local APK must fail the build; a beta-only F-Droid app must
fail the lock; a signature mismatch must refuse. When you find a new boundary
(like the work-profile block), root-cause it to source (AOSP/app code), then
record it in PRIMITIVES.md with evidence — LIMITS entries are generated
knowledge, not vibes.
