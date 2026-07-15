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
    in
    {
      packages.${system} = {
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

      devShells.${system}.default = pkgs.mkShell {
        packages = with pkgs; [
          android-tools
          jq
        ];
      };
    };
}
