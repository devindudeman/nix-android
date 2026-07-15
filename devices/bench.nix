# The emulator test bench — Phase 1's end-to-end target.
{
  device.name = "bench";
  device.abi = "x86_64";
  apps.fdroid.packages = [
    "org.fdroid.fdroid"
    "com.termux"
  ];
  apps.release."dev.imranr.obtainium.fdroid".github = "ImranR98/Obtainium";
}
