# droidnix task runner — `just` lists recipes

# build + launch the headless AOSP emulator (the mutation-test bench)
emu:
    nix run .#emulator

# read-only Atlas capture from a connected device (personal data → keep out of repo)
atlas out serial="":
    bash scripts/atlas-probe.sh {{ out }} {{ serial }}

# format the tree
fmt:
    nix fmt 2>/dev/null || nixfmt flake.nix
