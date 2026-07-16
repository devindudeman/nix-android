# The emulator test bench — application and Android-state end-to-end target.
{
  device.name = "bench";
  device.abi = "x86_64";
  apps = {
    fdroid.packages = [
      "org.fdroid.fdroid"
      "com.termux"
      "helium314.keyboard"
    ];
    release = {
      "dev.imranr.obtainium.fdroid".github = "ImranR98/Obtainium";
      # Archive-wrapped release: the .tar.gz asset contains plezy.apk.
      "com.edde746.plezy".github = "edde746/plezy";
    };
  };

  # Phase-2 surface — every category exercised on the bench.
  android = {
    settings.global.stay_on_while_plugged_in = 3;
    settings.global.nix_android_quote_test = ''spaces ; touch /data/local/tmp/nix_android_injected $(id) ' " \ backslash'';
    darkMode = true;
    privateDns = "opportunistic";
    packages.disabled = [ "com.android.egg" ];
    permissions = {
      "org.fdroid.fdroid" = {
        # INTERNET is install-time on AOSP (runtime on GrapheneOS): the fresh
        # bootstrap exercises the failed-pm-grant apply guard and the steady
        # state must read as satisfied, not replan forever.
        grant = [
          "android.permission.INTERNET"
          "android.permission.POST_NOTIFICATIONS"
        ];
        flags."android.permission.POST_NOTIFICATIONS" = [
          "user-fixed"
          "user-set"
        ];
      };
      "dev.imranr.obtainium.fdroid".revoke = [ "android.permission.POST_NOTIFICATIONS" ];
      # Every writable flag value needs executed evidence; the two
      # policy-machinery flags are exercised on an undeclared-grant permission.
      # review-required was rejected here: the bench observed
      # PermissionController rewriting it immediately after the shell write.
      "com.termux".flags."android.permission.POST_NOTIFICATIONS" = [
        "revoke-when-requested"
        "revoked-compat"
      ];
    };
    appOps."org.fdroid.fdroid".RUN_IN_BACKGROUND = "ignore";
    appOps."com.termux".VIBRATE = "deny";
    locales."org.fdroid.fdroid" = [
      "en-US"
      "fr-FR"
    ];
    inputMethod = {
      enabled = [ "helium314.keyboard/.latin.LatinIME" ];
      default = "helium314.keyboard/.latin.LatinIME";
    };
    dataSaver = {
      enabled = true;
    };
    packages.suspended = [ "dev.imranr.obtainium.fdroid" ];
    appLinks."org.fdroid.fdroid" = {
      allowed = false;
      selected = [ "f-droid.org" ];
    };
    batteryOptimization.exempt = [ "com.termux" ];
    # Read-path + idempotence coverage (AOSP image has only one SMS app, so a
    # role *change* isn't testable here; the write was Pixel-verified).
    defaultApps.sms = "com.android.messaging";
  };
}
