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
        description = "Package ids from the main f-droid.org repo, pinned via apps.lock.json (pins are floors: converge upgrades to >= locked versionCode, never downgrades, never fights on-device updaters).";
      };

      fdroid.repos = lib.mkOption {
        type =
          with lib.types;
          attrsOf (submodule {
            options = {
              url = lib.mkOption {
                type = str;
                description = "Base repo URL (serves entry.json / index-v2.json).";
                example = "https://app.futo.org/fdroid/repo";
              };
              packages = lib.mkOption {
                type = listOf str;
                default = [ ];
                description = "Package ids to install from this repo.";
              };
            };
          });
        default = { };
        description = "Third-party F-Droid repos (FUTO, IzzyOnDroid, Gadgetbridge nightly, …) — same index-v2 format as f-droid.org. Declaring the same package in two repos is undefined (last lock write wins); don't.";
      };

      release = lib.mkOption {
        type =
          with lib.types;
          attrsOf (submodule {
            options = {
              github = lib.mkOption {
                type = nullOr str;
                default = null;
                description = "owner/repo whose GitHub releases ship this package's APK.";
                example = "ImranR98/Obtainium";
              };
              gitea = lib.mkOption {
                type = nullOr str;
                default = null;
                description = "host/owner/repo on a Gitea instance whose releases ship this package's APK (anonymous read).";
                example = "git.example.com/owner/repo";
              };
            };
          });
        default = { };
        description = "Apps installed from GitHub/Gitea release APKs (Obtainium-style), keyed by Android package id, pinned via apps.lock.json. Exactly one of github/gitea per app. Release assets may be bare .apk or a .tar.gz containing one.";
      };

      local = lib.mkOption {
        type =
          with lib.types;
          attrsOf (submodule {
            options.apk = lib.mkOption {
              type = path;
              description = "Absolute path to a locally-built/self-signed APK (kept OUTSIDE the repo — the store copy is fine, a public git history is not). versionCode and package id are read from the APK at build time via aapt2; a package-id mismatch fails the build.";
            };
          });
        default = { };
        description = "Self-built / device-extracted APKs, keyed by Android package id. No lock entry — the APK file IS the pin.";
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
