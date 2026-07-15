# CLAUDE.md — working in the nix-android repo

nix-darwin, but for GrapheneOS/Android: converge a stock, locked-bootloader
device toward a version-controlled Nix file over adb at uid 2000 — no root,
security model untouched. Name is final (chosen 2026-07-15); CLI is
`android-rebuild`, outputs are `androidConfigurations.<device>`.

- **New here? Read `docs/DEVELOPING.md`** (architecture, ground rules, dev
  loop, how-to-add). `docs/PLAN.md` = roadmap; `docs/USING.md` = user-facing
  behavior; `docs/PRIMITIVES.md` = verified adb capability matrix — **every
  module option must cite a verified primitive**, no options for unproven
  capabilities.
- **⚠️ Safety protocol (non-negotiable):** Devin's Pixel 6 (GrapheneOS, daily
  use) gets read-only probes and no-op/trivially-reversible round-trips ONLY.
  All mutation-class testing runs on the emulator first
  (`nix run .#emulator`), and touches real hardware only after emulator proof
  plus Devin's explicit go-ahead. Never uninstall/suspend/revoke on his real
  apps. Raw device captures (app inventory, settings dumps) are personal data:
  they live in `~/Documents/phone-migration/`, never in this repo.

## Local development

`direnv allow` → devenv shell (adb, jq, aapt2; nixfmt/statix/deadnix/shellcheck
pre-commit). `just` lists tasks. Bench loop:
`nix run .#emulator` (headless AOSP, fresh userdata each launch) →
`nix run .#bench -- --serial emulator-5554 [--apply]`.

## Layout

`modules/options.nix` (option surface) · `lib/` (mkDevice: evalModules →
manifest.json, APKs as hash-verified store paths) · `engine/converge.sh`
(plan-by-default; `--apply`) · `scripts/update-lock.sh` (F-Droid index-v2 →
apps.lock.json) · `scripts/atlas-probe.sh` (read-only device capture) ·
`devices/` (device configs; bench = emulator).

## Don't

- Don't run `nix flake check` whole — devenv's task eval currently fails with
  a spurious "path .drv is not valid"; build individual checks instead
  (`nix build .#checks.x86_64-linux.bench-manifest --impure --accept-flake-config`).
- Don't drop `--serial` in engine/adb calls — two devices are often attached.
- Don't hard-reboot after mutations (write-behind state loss — PRIMITIVES.md).
- Public release is Phase 5: write code and docs as if strangers will read them.
