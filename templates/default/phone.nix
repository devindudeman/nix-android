# Your device configuration. Everything below is the complete option surface;
# the active block is deliberately tiny so `nix flake init` gives you a valid,
# empty config. Uncomment what you want, then run `update` to lock app sources
# and `plan` to preview. Two shortcuts to a fuller start:
#   - `android-rebuild import --serial <SERIAL>` reads a live device into a
#     draft config you paste here.
#   - `android-rebuild suggest-sources --flake .#phone` finds F-Droid/GitHub
#     sources for Play apps you list under apps.play/apps.attended.
#
# Managed-key semantics throughout: converge only touches what you declare and
# never reverts device state you left undeclared. App pins are FLOORS, not exact
# versions — converge installs/upgrades to >= the locked version and never
# downgrades, so on-device updaters (Droid-ify, Obtainium) coexist fine.
{
  device.name = "phone";
  device.abi = "arm64-v8a"; # real phones; the emulator bench is "x86_64"

  # --- Apps ------------------------------------------------------------------
  # After editing app sources, run: android-rebuild update --flake .#phone
  apps = {
    # Main f-droid.org repo, pinned in apps.lock.json:
    # fdroid.packages = [
    #   "org.fdroid.fdroid"
    #   "com.termux"
    # ];

    # Third-party F-Droid repos, authenticated by their index fingerprint.
    # A package may be declared from exactly one source.
    # fdroid.repos.futo = {
    #   url = "https://app.futo.org/fdroid/repo";
    #   fingerprint = "39d47869d29cbfce4691d9f7e6946a7b6d7e6ff4883497e6e675744ecdfa6d6d";
    #   packages = [ "org.futo.voiceinput.shared" ];
    # };

    # GitHub/Gitea release APKs (Obtainium-style), keyed by package id. Exactly
    # one of github/gitea each. Assets may be a bare .apk or a .tar.gz with one.
    # release."dev.imranr.obtainium.fdroid".github = "ImranR98/Obtainium";
    # release."com.example.app".gitea = "git.example.com/owner/repo";

    # Self-built / locally sourced APKs (the file IS the pin; no lock entry).
    # Keep the APK OUTSIDE the repo — the store copy is fine, public git is not.
    # local."com.example.app".apk = /absolute/path/to/app.apk;

    # Google Play apps: asserted present, installed with your consent. Open the
    # next missing one with `android-rebuild assist --flake .#phone`.
    # play = [ "com.google.android.apps.maps" ];

    # Other human-installed apps with no more specific source (presence + TODO).
    # attended = [ "com.whatsapp" ];

    # What to do with installed-but-undeclared apps. Default "none" is additive
    # (leaves them alone). "uninstall" removes undeclared third-party apps —
    # review every removal in `plan` before ever setting this.
    # cleanup = "none";
  };

  # --- Android state ---------------------------------------------------------
  android = {
    # darkMode = true; # `cmd uimode night`; null = unmanaged
    # privateDns = "opportunistic"; # "off" | "opportunistic" | a DoT hostname

    # Default-app roles (`cmd role`); null = unmanaged.
    # defaultApps.browser = "org.mozilla.fennec_fdroid";
    # defaultApps.sms = "com.android.messaging";

    # Expert escape hatch: raw `settings put <ns> <key>`. Keys are
    # Android-version-specific — verify write/read-back/persistence yourself.
    # settings.global.stay_on_while_plugged_in = 3;
    # settings.secure = { };
    # settings.system = { };

    # Per-package runtime permissions and writable policy flags.
    # permissions."com.termux" = {
    #   grant = [ "android.permission.POST_NOTIFICATIONS" ];
    #   revoke = [ ];
    #   # Writable flags: revoked-compat | revoke-when-requested | user-fixed | user-set
    #   flags."android.permission.POST_NOTIFICATIONS" = [ "user-set" ];
    # };

    # Per-package AppOps overrides: allow | ignore | deny | default | foreground.
    # appOps."com.termux".VIBRATE = "deny";

    # Package state (ensure-only; removing an entry does not re-enable/unsuspend).
    # packages.disabled = [ "com.android.egg" ];
    # packages.suspended = [ ];
    # packages.unsuspended = [ ];

    # Per-app locale preference (canonical BCP 47); empty list = system default.
    # locales."org.fdroid.fdroid" = [ "en-US" ];

    # Input-method services. A `default` must also appear in `enabled`.
    # inputMethod = {
    #   enabled = [ "helium314.keyboard/.latin.LatinIME" ];
    #   default = "helium314.keyboard/.latin.LatinIME";
    # };

    # dataSaver.enabled = true; # global Data Saver; null = unmanaged

    # User-owned app-link handling and domain selection.
    # appLinks."org.fdroid.fdroid" = {
    #   allowed = true;
    #   selected = [ "f-droid.org" ];
    # };

    # Battery-optimization exemptions (ensure-present).
    # batteryOptimization.exempt = [ "com.termux" ];
  };
}
