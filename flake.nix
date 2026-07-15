{
  description = "nix-android — nix-darwin for GrapheneOS/Android: declarative device state over adb, no root";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";
    devenv.url = "github:cachix/devenv";
    nix2container.url = "github:nlewo/nix2container";
    nix2container.inputs.nixpkgs.follows = "nixpkgs";
    mk-shell-bin.url = "github:rrbutani/nix-mk-shell-bin";
  };

  nixConfig = {
    extra-substituters = [ "https://devenv.cachix.org" ];
    extra-trusted-public-keys = [
      "devenv.cachix.org-1:w1cLUi8dv3hnoSPGAuibQv+f9TZLr6cv/Hm9XgU50cw="
    ];
  };

  outputs =
    inputs@{ flake-parts, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      imports = [ inputs.devenv.flakeModule ];
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "aarch64-darwin"
      ];

      flake = {
        lib = import ./lib { inherit (inputs) nixpkgs; };

        androidConfigurations.bench = inputs.self.lib.mkDevice {
          system = "x86_64-linux";
          modules = [ ./devices/bench.nix ];
          lockFile = ./apps.lock.json;
        };
      };

      perSystem =
        { system, ... }:
        let
          pkgs = import inputs.nixpkgs {
            inherit system;
            config = {
              allowUnfree = true;
              android_sdk.accept_license = true;
            };
          };
        in
        {
          packages = {
            # `nix run .#bench -- [--apply]` — converge the emulator bench device.
            bench = inputs.self.androidConfigurations.bench.converge;
          }
          // pkgs.lib.optionalAttrs (system == "x86_64-linux") {
            # Test bench: headless AOSP emulator (the "free-fire lane" —
            # mutation-class testing runs here, never on real hardware first).
            emulator = pkgs.androidenv.emulateApp {
              name = "nix-android-emu";
              platformVersion = "35";
              abiVersion = "x86_64";
              systemImageType = "default"; # pure AOSP, closest to GrapheneOS's base
              androidEmulatorFlags = "-no-window -no-audio -no-boot-anim";
            };
          };

          checks = {
            # The manifest must evaluate and build from the committed lock.
            bench-manifest = inputs.self.androidConfigurations.bench.manifest;
          };

          devenv.shells.default = {
            packages = with pkgs; [
              android-tools
              jq
              aapt
            ];
            git-hooks.hooks = {
              nixfmt-rfc-style.enable = true;
              statix.enable = true;
              deadnix.enable = true;
              shellcheck.enable = true;
            };
            enterShell = ''echo "▸ nix-android dev shell — bench: nix run .#emulator, converge: nix run .#bench"'';
          };
        };
    };
}
