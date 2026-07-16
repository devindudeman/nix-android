{
  description = "My phone — declarative Android/GrapheneOS state via nix-android";

  inputs.nix-android.url = "github:devindudeman/nix-android";

  outputs =
    { nix-android, ... }:
    {
      # One entry per device. `phone` is the name you pass after `#`, e.g.
      #   android-rebuild plan --flake .#phone --serial <SERIAL>
      androidConfigurations.phone = nix-android.lib.mkDevice {
        # The CONTROLLER's system (this computer), not the phone.
        # Apple Silicon: "aarch64-darwin". Then change both package attrs below.
        system = "x86_64-linux";
        modules = [ ./phone.nix ];
        lockFile = ./apps.lock.json;
      };

      # Run the CLI version pinned by THIS flake, not whatever is newest upstream:
      #   nix run .#android-rebuild -- plan --flake .#phone --serial <SERIAL>
      packages.x86_64-linux.android-rebuild = nix-android.packages.x86_64-linux.android-rebuild;
    };
}
