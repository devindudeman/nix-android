# The emulator test bench — Phase 1's end-to-end target.
{
  device.name = "bench";
  apps.fdroid.packages = [
    "org.fdroid.fdroid"
    "com.termux"
  ];
}
