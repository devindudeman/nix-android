# nix-android option reference

<!-- Generated from modules/options.nix — do not edit by hand.
     Regenerate with `just options-doc`. -->

Device-state options map to adb primitives with executed read/write/read-back
evidence in [PRIMITIVES.md](./PRIMITIVES.md); source and device-identity options
are controller-side. Managed-key semantics throughout: converge only touches
what you declare and never reverts undeclared device state. App version pins
are floors — converge installs/upgrades to at least the locked version and never
downgrades.

## android\.packages\.disabled



Packages kept disabled for the managed user (` pm disable-user `)\. Ensure-disabled only: removing an entry does not re-enable (imperative escape: ` pm enable `)\.



*Type:*
list of string



*Default:*

```nix
[ ]
```



## android\.packages\.suspended



Packages suspended by the adb shell authority for the managed user (` pm suspend `)\. Other suspension authorities remain independent\.



*Type:*
list of string



*Default:*

```nix
[ ]
```



## android\.packages\.unsuspended



Packages from which nix-android removes adb-shell suspension (` pm unsuspend `)\. This cannot override suspension imposed by another package or administrator\.



*Type:*
list of string



*Default:*

```nix
[ ]
```



## android\.appLinks

User-owned app-link handling and domain selections\. Domain-verifier results and shell force-approval states are never managed\.



*Type:*
attribute set of (submodule)



*Default:*

```nix
{ }
```



*Example:*

```nix
{
  "org.fdroid.fdroid" = {
    allowed = true;
    selected = [
      "f-droid.org"
    ];
  };
}
```



## android\.appLinks\.\<name>\.allowed



Whether this app may handle its verified links\. null = unmanaged\.



*Type:*
null or boolean



*Default:*

```nix
null
```



## android\.appLinks\.\<name>\.selected



Declared web domains to select for this app for owner user 0\.



*Type:*
list of string



*Default:*

```nix
[ ]
```



## android\.appLinks\.\<name>\.unselected



Declared web domains from which to clear this app’s user selection\.



*Type:*
list of string



*Default:*

```nix
[ ]
```



## android\.appOps



Explicit per-package AppOps overrides (` appops set `), keyed by package id and uppercase operation name\. ` default ` clears the package override; UID-wide modes are intentionally outside this option\.



*Type:*
attribute set of attribute set of (one of “allow”, “ignore”, “deny”, “default”, “foreground”)



*Default:*

```nix
{ }
```



*Example:*

```nix
{
  "com.termux" = {
    RUN_IN_BACKGROUND = "allow";
    VIBRATE = "deny";
  };
}
```



## android\.batteryOptimization\.exempt



Packages exempted from battery optimization (` cmd deviceidle whitelist +pkg `)\. Ensure-present only\. Android stores this as a global package/appId allowlist, so the effect is not confined to owner user 0 when the same package exists in another profile\.



*Type:*
list of string



*Default:*

```nix
[ ]
```



## android\.batteryOptimization\.unexempt



Packages removed from the battery-optimization allowlist (` cmd deviceidle whitelist -pkg `)\. Ensure-absent only: converge removes a listed package from the whitelist when present and reasserts removal if something re-adds it\. A package cannot be both exempt and unexempt\. The same global-allowlist caveat as ` exempt ` applies\.



*Type:*
list of string



*Default:*

```nix
[ ]
```



## android\.darkMode



Dark mode via ` cmd uimode night `\. null = unmanaged\.



*Type:*
null or boolean



*Default:*

```nix
null
```



## android\.dataSaver\.enabled



Global Android Data Saver state (` cmd netpolicy set restrict-background `)\. null = unmanaged\.



*Type:*
null or boolean



*Default:*

```nix
null
```



## android\.defaultApps\.browser



Package holding the browser role (` cmd role `)\. null = unmanaged\.



*Type:*
null or string



*Default:*

```nix
null
```



*Example:*

```nix
"org.mozilla.fennec_fdroid"
```



## android\.defaultApps\.dialer



Package holding the dialer role (` cmd role `)\. null = unmanaged\.



*Type:*
null or string



*Default:*

```nix
null
```



*Example:*

```nix
"com.android.dialer"
```



## android\.defaultApps\.home



Package holding the home role (` cmd role `)\. null = unmanaged\.



*Type:*
null or string



*Default:*

```nix
null
```



*Example:*

```nix
"app.lawnchair"
```



## android\.defaultApps\.sms



Package holding the sms role (` cmd role `)\. null = unmanaged\.



*Type:*
null or string



*Default:*

```nix
null
```



*Example:*

```nix
"com.android.messaging"
```



## android\.inputMethod\.enabled



Input-method service components to ensure enabled (` ime enable `)\.



*Type:*
list of string



*Default:*

```nix
[ ]
```



## android\.inputMethod\.default



Selected input-method service component (` ime set `)\. null = unmanaged; a selected component must also appear in enabled\.



*Type:*
null or string



*Default:*

```nix
null
```



## android\.inputMethod\.disabled



Input-method service components to ensure disabled (` ime disable `)\.



*Type:*
list of string



*Default:*

```nix
[ ]
```



## android\.locales



Exact canonical BCP 47 per-app locale preference list (` cmd locale `)\. An empty list resets that app to the system language\.



*Type:*
attribute set of list of string



*Default:*

```nix
{ }
```



*Example:*

```nix
{
  "com.termux" = [ ];
  "org.fdroid.fdroid" = [
    "en-US"
  ];
}
```



## android\.permissions



Per-package runtime-permission grant bits and writable policy flags, keyed by package id\.



*Type:*
attribute set of (submodule)



*Default:*

```nix
{ }
```



*Example:*

```nix
{
  "com.termux" = {
    flags = {
      "android.permission.POST_NOTIFICATIONS" = [
        "user-set"
      ];
    };
    grant = [
      "android.permission.POST_NOTIFICATIONS"
    ];
  };
}
```



## android\.permissions\.\<name>\.flags



Exact writable PackageManager flags for each runtime permission\. The listed flags are set and other writable flags are cleared; Android-owned flags remain untouched\.



*Type:*
attribute set of list of (one of “revoked-compat”, “revoke-when-requested”, “user-fixed”, “user-set”)



*Default:*

```nix
{ }
```



## android\.permissions\.\<name>\.grant



Runtime permissions to ensure granted (pm grant)\. On GrapheneOS this includes android\.permission\.INTERNET (Network) and android\.permission\.OTHER_SENSORS (Sensors)\.



*Type:*
list of string



*Default:*

```nix
[ ]
```



## android\.permissions\.\<name>\.revoke



Runtime permissions to ensure revoked (pm revoke)\.



*Type:*
list of string



*Default:*

```nix
[ ]
```



## android\.privateDns



Private DNS: “off”, “opportunistic”, or a DoT hostname\. Sugar over settings\.global\.private_dns_mode/_specifier\. null = unmanaged\.



*Type:*
null or string



*Default:*

```nix
null
```



*Example:*

```nix
"dns.example.com"
```



## android\.settings\.global



Expert escape hatch for ` settings put global ` key/values (compared via ` settings get `)\. Keys are Android-version-specific and must be independently verified for write access, read-back, and persistence; OS-owned keys can reject or revert writes\.



*Type:*
attribute set of (string or signed integer)



*Default:*

```nix
{ }
```



*Example:*

```nix
{
  stay_on_while_plugged_in = 3;
}
```



## android\.settings\.secure



Expert escape hatch for ` settings put secure ` key/values (compared via ` settings get `)\. Keys are Android-version-specific and must be independently verified for write access, read-back, and persistence; OS-owned keys can reject or revert writes\.



*Type:*
attribute set of (string or signed integer)



*Default:*

```nix
{ }
```



*Example:*

```nix
{
  lock_screen_show_notifications = 0;
}
```



## android\.settings\.system



Expert escape hatch for ` settings put system ` key/values (compared via ` settings get `)\. Keys are Android-version-specific and must be independently verified for write access, read-back, and persistence; OS-owned keys can reject or revert writes\.



*Type:*
attribute set of (string or signed integer)



*Default:*

```nix
{ }
```



*Example:*

```nix
{
  screen_off_timeout = 300000;
}
```



## apps\.attended



Declared-but-human-installed packages without a more specific source\. Converge asserts presence and prints a TODO list for the missing\.



*Type:*
list of string



*Default:*

```nix
[ ]
```



*Example:*

```nix
[
  "com.example.private-beta"
]
```



## apps\.cleanup



What converge does with installed-but-undeclared owner-user apps\. “none” = additive (default)\. “report” = additive, but plan/switch print a note per undeclared third-party app — reverse-drift detection without ever uninstalling (notes are informational: they do not count as plan changes or block the in-sync verdict)\. “uninstall” removes undeclared third-party apps after all other actions succeed\.



*Type:*
one of “none”, “report”, “uninstall”



*Default:*

```nix
"none"
```



## apps\.fdroid\.packages



Package ids from the main f-droid\.org repo, pinned via apps\.lock\.json (pins are floors: converge upgrades to >= locked versionCode, never downgrades, never fights on-device updaters)\.



*Type:*
list of string



*Default:*

```nix
[ ]
```



*Example:*

```nix
[
  "org.fdroid.fdroid"
  "com.termux"
]
```



## apps\.fdroid\.repos



Third-party F-Droid repos (FUTO, IzzyOnDroid, Gadgetbridge nightly, …), authenticated by the certificate fingerprint of their signed index-v2 entry point\. A package may be declared from exactly one source\.



*Type:*
attribute set of (submodule)



*Default:*

```nix
{ }
```



## apps\.fdroid\.repos\.\<name>\.packages



Package ids to install from this repo\.



*Type:*
list of string



*Default:*

```nix
[ ]
```



## apps\.fdroid\.repos\.\<name>\.fingerprint



SHA-256 fingerprint of the repository certificate that signs entry\.jar, as 64 hexadecimal characters without separators\.



*Type:*
string matching the pattern \[0-9a-fA-F]{64}



*Example:*

```nix
"39d47869d29cbfce4691d9f7e6946a7b6d7e6ff4883497e6e675744ecdfa6d6d"
```



## apps\.fdroid\.repos\.\<name>\.url



Base repo URL (serves signed entry\.jar and index-v2\.json)\.



*Type:*
string matching the pattern https://\[^\[:space:]]+



*Example:*

```nix
"https://app.futo.org/fdroid/repo"
```



## apps\.local



Self-built / locally sourced APKs, keyed by Android package id\. No lock entry — the APK file IS the pin\. (Pulling APKs off a device is out of scope; see docs/LIMITS\.md\.)



*Type:*
attribute set of (submodule)



*Default:*

```nix
{ }
```



## apps\.local\.\<name>\.apk



Absolute path to a locally-built/self-signed APK (kept OUTSIDE the repo — a public git history is forever)\. The build copies the file into the Nix store: if the APK embeds secrets (API keys, tokens), the store path is world-readable on the build host and anything that replicates new store paths (a binary-cache push hook/timer, nix copy) will exfiltrate it — exclude these paths from any cache push\. versionCode and package id are read from the APK at build time via aapt2; a package-id mismatch fails the build\.



*Type:*
absolute path



## apps\.play



Google Play packages asserted present but installed with explicit user consent\. Missing entries can be opened one at a time with ` android-rebuild assist `; Play remains responsible for delivery, licensing, and updates\.



*Type:*
list of string



*Default:*

```nix
[ ]
```



*Example:*

```nix
[
  "com.spotify.music"
]
```



## apps\.release



Apps installed from release APKs (Obtainium-style), keyed by Android package id, pinned via apps\.lock\.json\. Exactly one of github/gitea/url/updateJson/html per app\. GitHub/Gitea assets may be bare \.apk or a \.tar\.gz containing one\.



*Type:*
attribute set of (submodule)



*Default:*

```nix
{ }
```



## apps\.release\.\<name>\.gitea



host/owner/repo on a Gitea instance whose releases ship this package’s APK (anonymous read)\. Signer continuity is enforced across refreshes for this source\.



*Type:*
null or string matching the pattern \[A-Za-z0-9\.-]+(:\[0-9]+)?/\[A-Za-z0-9\.*-]+/\[A-Za-z0-9\.*-]+



*Default:*

```nix
null
```



*Example:*

```nix
"git.example.com/owner/repo"
```



## apps\.release\.\<name>\.github



owner/repo whose GitHub releases ship this package’s APK\. Signer continuity is enforced across refreshes for this source\.



*Type:*
null or string matching the pattern \[A-Za-z0-9\.*-]+/\[A-Za-z0-9\.*-]+



*Default:*

```nix
null
```



*Example:*

```nix
"ImranR98/Obtainium"
```



## apps\.release\.\<name>\.html



Discovery-only HTML scrape for vendors that publish versioned APK links on a page but no stable URL or manifest (e\.g\. Steam)\. The page only NOMINATES a URL: the download still passes the full aapt2 package-id check, signer recording, and cross-refresh signer-continuity enforcement, so a changed or hostile page can only fail the update — never install the wrong app\. Page redesigns break discovery loudly at lock time; fix the regex and re-run update\.



*Type:*
null or (submodule)



*Default:*

```nix
null
```



## apps\.release\.\<name>\.html\.linkFilter



Extended regex the APK link must match\. ` update ` requires EXACTLY ONE page link to match — zero or several fail loudly (tighten the regex rather than trusting a sort heuristic)\.



*Type:*
string matching the pattern \[^\[:cntrl:]]+



*Example:*

```nix
"steam-android/steam-[0-9.]+\\.apk$"
```



## apps\.release\.\<name>\.html\.url



HTTPS page whose links include the vendor’s APK download\.



*Type:*
string matching the pattern https://\[^\[:space:]]+



*Example:*

```nix
"https://store.steampowered.com/mobile"
```



## apps\.release\.\<name>\.signerSha256



Optional config-level signer pin: signing-certificate SHA-256 digests (as ` apksigner verify --print-certs ` prints them) you trust for this app\. When set, the build fails unless at least one of the APK’s signers is listed, so editing apps\.lock\.json alone cannot change the app’s identity\. Independently of this pin, every managed APK’s signers must be a subset of the lock’s recorded ` signerSha256 `\.



*Type:*
null or (list of string matching the pattern \[0-9A-Fa-f]{64})



*Default:*

```nix
null
```



*Example:*

```nix
[
  "b353601f6a1d5fd6603ae2f50be80cf301367b86b6ab8b1f66243da96cd57362"
]
```



## apps\.release\.\<name>\.updateJson



HTTPS URL of a vendor update-manifest JSON with a ` url ` field pointing at the APK (the schema Signal publishes at updates\.signal\.org/android/latest\.json; an optional ` sha256sum ` field is cross-checked)\. Preferred over ` url ` when offered — the manifest points at versioned, immutable APK URLs, so a stale lock still fetches\. Signer continuity is enforced across refreshes for this source\.



*Type:*
null or string matching the pattern https://\[^\[:space:]]+



*Default:*

```nix
null
```



*Example:*

```nix
"https://updates.signal.org/android/latest.json"
```



## apps\.release\.\<name>\.url



HTTPS URL of the vendor’s direct-download APK (a stable ‘latest’ link)\. Locked like a release: ` update ` downloads it, validates the package id with aapt2, and records sha256 + signer\. Because the URL’s content changes in place on vendor updates, a stale lock can fail the store fetch with a hash mismatch until the next ` update ` (the copy fetched at lock time keeps working from the local store or a binary cache)\. Signer continuity is enforced across refreshes for this source\.



*Type:*
null or string matching the pattern https://\[^\[:space:]]+



*Default:*

```nix
null
```



*Example:*

```nix
"https://zoom.us/client/latest/zoom.apk"
```



## apps\.updaters\.fdroid



On-device updater recorded as installer of record for F-Droid (` apps.fdroid.packages ` and ` apps.fdroid.repos `) apps (` adb install -i `)\. Android lets an updater apply unattended updates only to apps it installed, so this hands later updates to it\. Must be installed for the owner user at install time or Android silently records no installer; converge installs a declared updater before the apps that name it\. null = no installer recorded (plain adb install)\.



*Type:*
null or string matching the pattern \[A-Za-z0-9_]+(\[\.]\[A-Za-z0-9_]+)+



*Default:*

```nix
null
```



*Example:*

```nix
"com.looker.droidify"
```



## apps\.updaters\.release



On-device updater recorded as installer of record for release (` apps.release `) apps (` adb install -i `)\. Android lets an updater apply unattended updates only to apps it installed, so this hands later updates to it\. Must be installed for the owner user at install time or Android silently records no installer; converge installs a declared updater before the apps that name it\. null = no installer recorded (plain adb install)\.



*Type:*
null or string matching the pattern \[A-Za-z0-9_]+(\[\.]\[A-Za-z0-9_]+)+



*Default:*

```nix
null
```



*Example:*

```nix
"com.looker.droidify"
```



## apps\.updaters\.reown



Re-own installed apps whose installer of record differs from the configured updater by reinstalling the same locked APK with ` -i ` (app data kept; the app is restarted)\. Only when the installed versionCode equals the lock and the updater is installed or being installed\. false = such apps are reported as notes only\.



*Type:*
boolean



*Default:*

```nix
false
```



## device\.abi



Device ABI — selects which APK builds the lock resolves (arm64-v8a = real phones, x86_64 = the emulator bench)\.



*Type:*
one of “arm64-v8a”, “armeabi-v7a”, “x86_64”



*Default:*

```nix
"arm64-v8a"
```



## device\.name



Device nickname; used in manifest and derivation names\.



*Type:*
string



## device\.user



Android user profile to manage\. Public v1 supports the owner profile (user 0) only\.



*Type:*
signed integer



*Default:*

```nix
0
```
