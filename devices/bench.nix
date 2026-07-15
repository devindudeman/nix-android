# The emulator test bench — Phase 1's end-to-end target.
{
  device.name = "bench";
  device.abi = "x86_64";
  apps.fdroid.packages = [
    "org.fdroid.fdroid"
    "com.termux"
  ];
  apps.release."dev.imranr.obtainium.fdroid".github = "ImranR98/Obtainium";
  # Archive-wrapped release: the .tar.gz asset contains plezy.apk.
  apps.release."com.edde746.plezy".github = "edde746/plezy";

  # Phase-2 surface — every category exercised on the bench.
  android = {
    settings.global.stay_on_while_plugged_in = 3;
    darkMode = true;
    privateDns = "opportunistic";
    quickSettings.tiles = [
      "internet"
      "bt"
      "flashlight"
      "dark"
    ];
    packages.disabled = [ "com.android.egg" ];
    permissions."org.fdroid.fdroid".grant = [ "android.permission.POST_NOTIFICATIONS" ];
    batteryOptimization.exempt = [ "com.termux" ];
    # Read-path + idempotence coverage (AOSP image has only one SMS app, so a
    # role *change* isn't testable here; the write was Pixel-verified).
    defaultApps.sms = "com.android.messaging";
  };
}
