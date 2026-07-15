# Core option surface. Every option here must map to a verified primitive in
# docs/PRIMITIVES.md — no options for unproven capabilities.
{ lib, ... }:
{
  options = {
    device = {
      name = lib.mkOption {
        type = lib.types.str;
        description = "Device nickname; used in manifest and state paths.";
      };
      user = lib.mkOption {
        type = lib.types.int;
        default = 0;
        description = "Android user profile to manage (owner = 0).";
      };
    };

    apps = {
      fdroid.packages = lib.mkOption {
        type = with lib.types; listOf str;
        default = [ ];
        description = "F-Droid package ids, pinned via apps.lock.json (pins are floors: converge upgrades to >= locked versionCode, never downgrades, never fights on-device updaters).";
      };

      attended = lib.mkOption {
        type = with lib.types; listOf str;
        default = [ ];
        description = "Declared-but-human-installed (Play/Aurora — not headlessly fetchable). Converge asserts presence and prints a TODO list for the missing.";
      };

      cleanup = lib.mkOption {
        type = lib.types.enum [
          "none"
          "uninstall"
        ];
        default = "none";
        description = "What converge does with installed-but-undeclared user apps. \"none\" = additive (default), \"uninstall\" = NixOS-style purity.";
      };
    };
  };
}
