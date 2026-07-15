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
nix run .#bench -- --serial emulator-5554           # plan
nix run .#bench -- --serial emulator-5554 --apply   # converge
```

### Running the emulator bench SAFELY (learned the hard way — a host crash)

`nix run .#emulator` naively is a trap on a laptop. Two hazards, both real:

1. **It hard-crashed the host once.** The emulator with host-GPU falls back to
   a Vulkan path (`VulkanAllocateHostMemory`) that balloons host RAM to 5–7 GB+
   and can hang the whole machine (no OOM-kill — pinned shmem is unreclaimable,
   so the box just dies). ALWAYS run it inside a memory-capped systemd scope so
   a runaway emulator is killed instead of the host:
   ```bash
   systemd-run --user --unit=nixandroid-emu -p MemoryMax=12G -p MemorySwapMax=0 \
     --setenv=ANDROID_SDK_ROOT="$sdk" \
     --setenv=ANDROID_AVD_HOME="$HOME/.cache/nix-android/avd" \
     --setenv=ANDROID_USER_HOME="$HOME/.cache/nix-android/androidhome" \
     "$sdk/emulator/emulator" -avd nixa \
       -no-window -no-audio -no-boot-anim -no-snapshot \
       -gpu swiftshader_indirect -memory 2048 -port 5554
   ```
   Create the persistent AVD `nixa` once with `avdmanager create avd -n nixa -k
   'system-images;android-35;default;x86_64'`. `$sdk` = the androidsdk store
   path (grep `ANDROID_HOME=` out of `result/bin/run-test-emulator`).
2. **Use `-gpu swiftshader_indirect`, not host GPU** — nixpkgs/upstream both
   warn host-GPU gives black-screen/Vulkan balloon headless. SwiftShader is the
   sanctioned headless renderer.
3. **Run the `emulator` binary in the FOREGROUND as the unit's main process** —
   the `run-test-emulator` wrapper backgrounds the emulator and exits, so under
   systemd the cgroup tears down and kills it right after boot. Invoke the
   binary directly so systemd supervises it.

`adb -s emulator-5554 emu kill` (or `systemctl --user stop nixandroid-emu`) to
tear down.

### Bash gotchas the engine hit (don't reintroduce)

- **`adb` calls drain `while read` stdin.** `adb shell` reads stdin; inside a
  `while read … done < <(…)` loop it eats the loop's input so only the first
  item iterates. The engine routes every adb call through an `adb()` wrapper
  that appends `</dev/null`.
- **That wrapper must use `command`.** `adb_base=(adb …); adb(){ command …; }`
  — without `command`, the function named `adb` calls itself forever.
- **`IFS=$'\t' read` collapses empty fields.** Tab is whitespace-class, so a
  tuple with an empty interior field (`a\t\tc`) loses it and shifts everything
  left. The engine uses US (`$'\037'`) as the tuple separator instead.
- **SystemUI-owned settings don't converge.** `sysui_qs_tiles` accepts a
  no-op write but SystemUI reverts any real change — so it fails the idempotence
  bar and is NOT a supported option. Test a *real* change + reboot, never a
  no-op, before declaring a primitive verified.

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
