# nix-android task runner — `just` lists recipes

# launch the headless AOSP emulator in a memory-capped systemd scope
emu:
    systemd-run --user --scope --unit=nixandroid-emu -p MemoryMax=12G -p MemorySwapMax=0 nix run .#emulator --accept-flake-config

# required pre-real-phone emulator gate: repeat apply/reboot/no-op on fresh userdata
bench-e2e runs="2":
    systemd-run --user --scope --unit=nixandroid-bench-e2e -p MemoryMax=12G -p MemorySwapMax=0 bash scripts/bench-e2e.sh {{ runs }}

# read-only Atlas capture from a connected device (personal data → keep out of repo)
atlas out serial:
    bash scripts/atlas-probe.sh {{ out }} {{ serial }}

# format the tree
fmt:
    nix fmt

# public release checks (whole-flake check is blocked by devenv task evaluation)
check:
    set -e; system=$(nix eval --impure --raw --expr builtins.currentSystem); \
      nix build ".#checks.$system.formatting" ".#checks.$system.shellcheck" ".#checks.$system.engine-parsers" ".#checks.$system.generations" ".#checks.$system.template" ".#checks.$system.suggest-sources" ".#checks.$system.statix" \
        ".#checks.$system.deadnix" ".#checks.$system.cli-safety" ".#checks.$system.manifest-safety" \
        ".#checks.$system.import-snapshot" ".#checks.$system.assist-safety" \
        ".#checks.$system.bootstrap-safety" \
        ".#checks.$system.update-lock-safety" ".#checks.$system.validation" \
        --accept-flake-config --no-link; \
      if [ "$system" = x86_64-linux ]; then nix build .#checks.x86_64-linux.bench-manifest --accept-flake-config --no-link; fi; \
      if [ "$system" = aarch64-darwin ]; then nix build .#checks.aarch64-darwin.{darwin-manifest,darwin-converge} --accept-flake-config --no-link; fi
