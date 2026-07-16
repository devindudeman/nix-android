# Core option surface. Every option here must map to a verified primitive in
# docs/PRIMITIVES.md — no options for unproven capabilities.
{ lib, ... }:
{
  options = {
    device = {
      name = lib.mkOption {
        type = lib.types.str;
        description = "Device nickname; used in manifest and derivation names.";
      };
      user = lib.mkOption {
        type = lib.types.int;
        default = 0;
        description = "Android user profile to manage. Public v1 supports the owner profile (user 0) only.";
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
                type = strMatching "https?://[^[:space:]]+";
                description = "Base repo URL (serves signed entry.jar and index-v2.json).";
                example = "https://app.futo.org/fdroid/repo";
              };
              fingerprint = lib.mkOption {
                type = strMatching "[0-9a-fA-F]{64}";
                description = "SHA-256 fingerprint of the repository certificate that signs entry.jar, as 64 hexadecimal characters without separators.";
                example = "39d47869d29cbfce4691d9f7e6946a7b6d7e6ff4883497e6e675744ecdfa6d6d";
              };
              packages = lib.mkOption {
                type = listOf str;
                default = [ ];
                description = "Package ids to install from this repo.";
              };
            };
          });
        default = { };
        description = "Third-party F-Droid repos (FUTO, IzzyOnDroid, Gadgetbridge nightly, …), authenticated by the certificate fingerprint of their signed index-v2 entry point. A package may be declared from exactly one source.";
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
        description = "Self-built / locally sourced APKs, keyed by Android package id. No lock entry — the APK file IS the pin. (Pulling APKs off a device is out of scope; see docs/LIMITS.md.)";
      };

      attended = lib.mkOption {
        type = with lib.types; listOf str;
        default = [ ];
        description = "Declared-but-human-installed packages without a more specific source. Converge asserts presence and prints a TODO list for the missing.";
      };

      play = lib.mkOption {
        type = with lib.types; listOf str;
        default = [ ];
        description = "Google Play packages asserted present but installed with explicit user consent. Missing entries can be opened one at a time with `android-rebuild assist`; Play remains responsible for delivery, licensing, and updates.";
      };

      cleanup = lib.mkOption {
        type = lib.types.enum [
          "none"
          "uninstall"
        ];
        default = "none";
        description = "What converge does with installed-but-undeclared owner-user apps. \"none\" = additive (default); \"uninstall\" removes undeclared third-party apps after all other actions succeed.";
      };
    };

    # Phase-2 surface. Managed-key semantics throughout: converge only touches
    # what you declare — it never reverts device state you left undeclared.
    android = {
      settings = lib.genAttrs [ "global" "secure" "system" ] (
        ns:
        lib.mkOption {
          type = with lib.types; attrsOf (either str int);
          default = { };
          description = "Expert escape hatch for `settings put ${ns}` key/values (compared via `settings get`). Keys are Android-version-specific and must be independently verified for write access, read-back, and persistence; OS-owned keys can reject or revert writes.";
        }
      );

      darkMode = lib.mkOption {
        type = with lib.types; nullOr bool;
        default = null;
        description = "Dark mode via `cmd uimode night`. null = unmanaged.";
      };

      privateDns = lib.mkOption {
        type = with lib.types; nullOr str;
        default = null;
        description = "Private DNS: \"off\", \"opportunistic\", or a DoT hostname. Sugar over settings.global.private_dns_mode/_specifier. null = unmanaged.";
        example = "dns.example.com";
      };

      defaultApps = lib.genAttrs [ "browser" "sms" "dialer" "home" ] (
        role:
        lib.mkOption {
          type = with lib.types; nullOr str;
          default = null;
          description = "Package holding the ${role} role (`cmd role`). null = unmanaged.";
        }
      );

      packages = {
        disabled = lib.mkOption {
          type = with lib.types; listOf str;
          default = [ ];
          description = "Packages kept disabled for the managed user (`pm disable-user`). Ensure-disabled only: removing an entry does not re-enable (imperative escape: `pm enable`).";
        };

        suspended = lib.mkOption {
          type = with lib.types; listOf str;
          default = [ ];
          description = "Packages suspended by the adb shell authority for the managed user (`pm suspend`). Other suspension authorities remain independent.";
        };

        unsuspended = lib.mkOption {
          type = with lib.types; listOf str;
          default = [ ];
          description = "Packages from which nix-android removes adb-shell suspension (`pm unsuspend`). This cannot override suspension imposed by another package or administrator.";
        };
      };

      locales = lib.mkOption {
        type = with lib.types; attrsOf (listOf str);
        default = { };
        description = "Exact canonical BCP 47 per-app locale preference list (`cmd locale`). An empty list resets that app to the system language.";
      };

      inputMethod = {
        enabled = lib.mkOption {
          type = with lib.types; listOf str;
          default = [ ];
          description = "Input-method service components to ensure enabled (`ime enable`).";
        };
        disabled = lib.mkOption {
          type = with lib.types; listOf str;
          default = [ ];
          description = "Input-method service components to ensure disabled (`ime disable`).";
        };
        default = lib.mkOption {
          type = with lib.types; nullOr str;
          default = null;
          description = "Selected input-method service component (`ime set`). null = unmanaged; a selected component must also appear in enabled.";
        };
      };

      dataSaver = {
        enabled = lib.mkOption {
          type = with lib.types; nullOr bool;
          default = null;
          description = "Global Android Data Saver state (`cmd netpolicy set restrict-background`). null = unmanaged.";
        };
      };

      appLinks = lib.mkOption {
        type =
          with lib.types;
          attrsOf (submodule {
            options = {
              allowed = lib.mkOption {
                type = nullOr bool;
                default = null;
                description = "Whether this app may handle its verified links. null = unmanaged.";
              };
              selected = lib.mkOption {
                type = listOf str;
                default = [ ];
                description = "Declared web domains to select for this app for owner user 0.";
              };
              unselected = lib.mkOption {
                type = listOf str;
                default = [ ];
                description = "Declared web domains from which to clear this app's user selection.";
              };
            };
          });
        default = { };
        description = "User-owned app-link handling and domain selections. Domain-verifier results and shell force-approval states are never managed.";
      };

      permissions = lib.mkOption {
        type =
          with lib.types;
          attrsOf (submodule {
            options = {
              grant = lib.mkOption {
                type = listOf str;
                default = [ ];
                description = "Runtime permissions to ensure granted (pm grant). On GrapheneOS this includes android.permission.INTERNET (Network) and android.permission.OTHER_SENSORS (Sensors).";
              };
              revoke = lib.mkOption {
                type = listOf str;
                default = [ ];
                description = "Runtime permissions to ensure revoked (pm revoke).";
              };
              flags = lib.mkOption {
                type = attrsOf (
                  # Mirrors writable_permission_flags in engine/read-state.sh
                  # and scripts/render-import.py; change all three together.
                  # review-required failed bench read-back (PermissionController
                  # rewrites it from targetSdk) and is not offered.
                  listOf (enum [
                    "revoked-compat"
                    "revoke-when-requested"
                    "user-fixed"
                    "user-set"
                  ])
                );
                default = { };
                description = "Exact writable PackageManager flags for each runtime permission. The listed flags are set and other writable flags are cleared; Android-owned flags remain untouched.";
              };
            };
          });
        default = { };
        description = "Per-package runtime-permission grant bits and writable policy flags, keyed by package id.";
      };

      appOps = lib.mkOption {
        type =
          with lib.types;
          attrsOf (
            attrsOf (enum [
              "allow"
              "ignore"
              "deny"
              "default"
              "foreground"
            ])
          );
        default = { };
        description = "Explicit per-package AppOps overrides (`appops set`), keyed by package id and uppercase operation name. `default` clears the package override; UID-wide modes are intentionally outside this option.";
      };

      batteryOptimization.exempt = lib.mkOption {
        type = with lib.types; listOf str;
        default = [ ];
        description = "Packages exempted from battery optimization (`cmd deviceidle whitelist +pkg`). Ensure-present only. Android stores this as a global package/appId allowlist, so the effect is not confined to owner user 0 when the same package exists in another profile.";
      };
    };
  };
}
