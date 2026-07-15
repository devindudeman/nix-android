# droidnix (working name)

nix-darwin, but for GrapheneOS: converge a stock, locked-bootloader Android
device toward a version-controlled Nix file over adb at uid 2000 — no root,
security model untouched.

- **Read `docs/PLAN.md` first** — phases, architecture (manifest + engine),
  design decisions. `docs/PRIMITIVES.md` is the verified adb capability matrix;
  every module option must cite a verified primitive.
- **⚠️ Safety protocol (non-negotiable):** Devin's Pixel 6 (GrapheneOS, daily
  use) gets read-only probes and no-op/trivially-reversible round-trips ONLY.
  All mutation-class testing runs on the emulator first
  (`nix run .#emulator`), and touches real hardware only after emulator proof
  plus Devin's explicit go-ahead. Never uninstall/suspend/revoke on his real
  apps. Raw device captures (app inventory, settings dumps) are personal data:
  they live in `~/Documents/phone-migration/`, never in this repo.
- Public release is a goal (Phase 5): write code and docs as if strangers will
  read them. Working name droidnix; final name is an open question.
- Style: mirror nix-config conventions (nixfmt RFC-166, statix, deadnix,
  builder-with-slots, module groups). AGENTS.md symlinks here.
