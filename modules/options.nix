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
      abi = lib.mkOption {
        type = lib.types.enum [
          "arm64-v8a"
          "armeabi-v7a"
          "x86_64"
        ];
        default = "arm64-v8a";
        description = "Device ABI — selects which APK builds the lock resolves (arm64-v8a = real phones, x86_64 = the emulator bench).";
      };
    };

    apps = {
      fdroid.packages = lib.mkOption {
        type = with lib.types; listOf str;
        default = [ ];
        description = "F-Droid package ids, pinned via apps.lock.json (pins are floors: converge upgrades to >= locked versionCode, never downgrades, never fights on-device updaters).";
      };

      release = lib.mkOption {
        type =
          with lib.types;
          attrsOf (submodule {
            options.github = lib.mkOption {
              type = str;
              description = "owner/repo whose GitHub releases ship this package's APK.";
              example = "ImranR98/Obtainium";
            };
          });
        default = { };
        description = "Apps installed from GitHub release APKs (Obtainium-style), keyed by Android package id, pinned via apps.lock.json.";
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
