{
  description = "droidnix — nix-darwin for GrapheneOS/Android: declarative device state over adb (working name)";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { self, nixpkgs }:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs {
        inherit system;
        config = {
          allowUnfree = true;
          android_sdk.accept_license = true;
        };
      };
      dlib = import ./lib { inherit nixpkgs; };
    in
    {
      lib = dlib;

      droidConfigurations.bench = dlib.mkDevice {
        inherit system;
        modules = [ ./devices/bench.nix ];
        lockFile = ./apps.lock.json;
      };

      packages.${system} = {
        # `nix run .#bench -- [--apply]` — converge the emulator bench device.
        bench = self.droidConfigurations.bench.converge;

        # Phase-0 test bench: headless AOSP emulator (the "free-fire lane" —
        # mutation-class probes run here, never on real hardware first).
        emulator = pkgs.androidenv.emulateApp {
          name = "droidnix-emu";
          platformVersion = "35";
          abiVersion = "x86_64";
          systemImageType = "default"; # pure AOSP, closest to GrapheneOS's base
          androidEmulatorFlags = "-no-window -no-audio -no-boot-anim";
        };
      };

      checks.${system} = {
        # The manifest must evaluate and build from the committed lock.
        bench-manifest = self.droidConfigurations.bench.manifest;
      };

      devShells.${system}.default = pkgs.mkShell {
        packages = with pkgs; [
          android-tools
          jq
        ];
      };
    };
}
