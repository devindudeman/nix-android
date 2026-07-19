# mkDevice: modules → { manifest, converge, config }.
# Manifest is pure data (JSON); APKs are fetched into the store by the hashes
# in the lock file, so a device's app payload is a real Nix closure.
{ nixpkgs }:
{
  mkDevice =
    {
      system,
      modules,
      lockFile,
    }:
    let
      pkgs = import nixpkgs { inherit system; };
      inherit (nixpkgs) lib;
      eval = lib.evalModules { modules = [ ../modules/options.nix ] ++ modules; };
      cfg = eval.config;
      lock = builtins.fromJSON (builtins.readFile lockFile);
      officialFdroidFingerprint = "43238d512c1e5eb2d6569f4a3afbf5523418b82e0a3ed1552770abb9a9c9ccab";

      releaseNames = builtins.attrNames cfg.apps.release;
      managedLockedNames =
        cfg.apps.fdroid.packages
        ++ lib.concatMap (r: r.packages) (builtins.attrValues cfg.apps.fdroid.repos)
        ++ releaseNames;
      declaredApps =
        managedLockedNames ++ builtins.attrNames cfg.apps.local ++ cfg.apps.attended ++ cfg.apps.play;
      inputMethodComponents =
        cfg.android.inputMethod.enabled
        ++ cfg.android.inputMethod.disabled
        ++ lib.optional (cfg.android.inputMethod.default != null) cfg.android.inputMethod.default;
      # Android reports IME ids as ComponentName.flattenToShortString(); a
      # fully-qualified spelling of the same component would never match the
      # device and could never converge, so normalize at manifest build time.
      canonicalComponent =
        component:
        let
          parts = lib.splitString "/" component;
          pkg = builtins.head parts;
          cls = lib.last parts;
        in
        if lib.hasPrefix (pkg + ".") cls then "${pkg}/${lib.removePrefix pkg cls}" else component;
      inputMethodFinal = {
        enabled = map canonicalComponent cfg.android.inputMethod.enabled;
        disabled = map canonicalComponent cfg.android.inputMethod.disabled;
        default =
          if cfg.android.inputMethod.default == null then
            null
          else
            canonicalComponent cfg.android.inputMethod.default;
      };
      inputMethodPackages = map (
        component: lib.head (lib.splitString "/" component)
      ) inputMethodComponents;
      referencedPackages =
        declaredApps
        ++ cfg.android.packages.disabled
        ++ cfg.android.packages.suspended
        ++ cfg.android.packages.unsuspended
        ++ cfg.android.batteryOptimization.exempt
        ++ cfg.android.batteryOptimization.unexempt
        ++ builtins.attrNames cfg.android.permissions
        ++ builtins.attrNames cfg.android.appOps
        ++ builtins.attrNames cfg.android.locales
        ++ builtins.attrNames cfg.android.appLinks
        ++ inputMethodPackages
        ++ builtins.attrValues (lib.filterAttrs (_: v: v != null) cfg.android.defaultApps);
      invalidPackageNames = builtins.filter (
        p: builtins.match "[A-Za-z0-9_]+([.][A-Za-z0-9_]+)+" p == null
      ) referencedPackages;
      invalidPermissionNames = builtins.filter (p: builtins.match "[A-Za-z0-9_.]+" p == null) (
        lib.concatMap (v: v.grant ++ v.revoke ++ builtins.attrNames v.flags) (
          builtins.attrValues cfg.android.permissions
        )
      );
      invalidAppOpNames = lib.concatLists (
        lib.mapAttrsToList (
          p: operations:
          map (operation: "${p}:${operation}") (
            builtins.filter (operation: builtins.match "[A-Z][A-Z0-9_]*" operation == null) (
              builtins.attrNames operations
            )
          )
        ) cfg.android.appOps
      );
      invalidInputMethodComponents = builtins.filter (
        component:
        builtins.match "[A-Za-z0-9_]+([.][A-Za-z0-9_]+)+/[.]?[A-Za-z0-9_$]+([.][A-Za-z0-9_$]+)*" component
        == null
      ) inputMethodComponents;
      invalidLocales = lib.concatLists (
        lib.mapAttrsToList (
          package: locales:
          map (locale: "${package}:${locale}") (
            builtins.filter (
              locale:
              builtins.stringLength locale > 100
              ||
                builtins.match "[a-z]{2,8}(-[A-Z][a-z]{3})?(-([A-Z]{2}|[0-9]{3}))?(-([a-z0-9]{5,8}|[0-9][a-z0-9]{3}))*(-[0-9a-wy-z](-[a-z0-9]{2,8})+)*(-x(-[a-z0-9]{1,8})+)?" locale
                == null
            ) locales
          )
        ) cfg.android.locales
      );
      validDomain =
        domain:
        let
          hostname = lib.removePrefix "*." domain;
          labels = lib.splitString "." hostname;
        in
        builtins.stringLength domain <= 253
        && builtins.length labels >= 2
        && lib.all (label: builtins.match "[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?" label != null) labels;
      invalidAppLinkDomains = lib.concatLists (
        lib.mapAttrsToList (
          package: state:
          map (domain: "${package}:${domain}") (
            builtins.filter (domain: !validDomain domain) (state.selected ++ state.unselected)
          )
        ) cfg.android.appLinks
      );
      duplicateApps = lib.unique (
        builtins.filter (p: lib.count (q: q == p) declaredApps > 1) declaredApps
      );
      permissionConflicts = lib.concatLists (
        lib.mapAttrsToList (
          p: v: map (permission: "${p}:${permission}") (lib.intersectLists v.grant v.revoke)
        ) cfg.android.permissions
      );
      duplicatePermissions = lib.concatLists (
        lib.mapAttrsToList (
          p: v: map (permission: "${p}:${permission}") (duplicates (v.grant ++ v.revoke))
        ) cfg.android.permissions
      );
      duplicatePermissionFlags = lib.concatLists (
        lib.mapAttrsToList (
          p: permissionState:
          lib.concatLists (
            lib.mapAttrsToList (
              permission: flags: map (flag: "${p}:${permission}:${flag}") (duplicates flags)
            ) permissionState.flags
          )
        ) cfg.android.permissions
      );
      duplicates =
        values:
        lib.unique (builtins.filter (value: lib.count (candidate: candidate == value) values > 1) values);
      duplicateNewState =
        map (value: "disabled:${value}") (duplicates cfg.android.packages.disabled)
        ++ map (value: "suspended:${value}") (duplicates cfg.android.packages.suspended)
        ++ map (value: "unsuspended:${value}") (duplicates cfg.android.packages.unsuspended)
        ++ map (value: "deviceidle-exempt:${value}") (duplicates cfg.android.batteryOptimization.exempt)
        ++ map (value: "deviceidle-unexempt:${value}") (duplicates cfg.android.batteryOptimization.unexempt)
        ++ map (value: "ime-enabled:${value}") (duplicates inputMethodFinal.enabled)
        ++ map (value: "ime-disabled:${value}") (duplicates inputMethodFinal.disabled)
        ++ lib.concatLists (
          lib.mapAttrsToList (
            package: locales: map (locale: "locale:${package}:${locale}") (duplicates locales)
          ) cfg.android.locales
        )
        ++ lib.concatLists (
          lib.mapAttrsToList (
            package: state:
            map (domain: "app-link:${package}:${domain}") (duplicates (state.selected ++ state.unselected))
          ) cfg.android.appLinks
        );
      suspensionConflicts = lib.intersectLists cfg.android.packages.suspended cfg.android.packages.unsuspended;
      deviceidleConflicts = lib.intersectLists cfg.android.batteryOptimization.exempt cfg.android.batteryOptimization.unexempt;
      inputMethodConflicts = lib.intersectLists inputMethodFinal.enabled inputMethodFinal.disabled;
      inputMethodDefaultDisabled =
        inputMethodFinal.default != null
        && !builtins.elem inputMethodFinal.default inputMethodFinal.enabled;
      # `ime set/enable/disable` and the raw secure keys are one Android
      # surface; two declared authorities would rewrite each other every
      # switch (same shape as the privateDns guard below).
      inputMethodRawConflict =
        inputMethodComponents != [ ]
        && (
          cfg.android.settings.secure ? default_input_method
          || cfg.android.settings.secure ? enabled_input_methods
        );
      appLinkConflicts = lib.concatLists (
        lib.mapAttrsToList (
          package: state:
          map (domain: "${package}:${domain}") (lib.intersectLists state.selected state.unselected)
        ) cfg.android.appLinks
      );
      selectedAppLinkDomains = lib.concatMap (state: state.selected) (
        builtins.attrValues cfg.android.appLinks
      );
      duplicateSelectedAppLinkDomains = lib.unique (
        builtins.filter (
          domain: lib.count (candidate: candidate == domain) selectedAppLinkDomains > 1
        ) selectedAppLinkDomains
      );
      invalidReleaseSources = builtins.attrNames (
        lib.filterAttrs (
          _: v:
          builtins.length (
            builtins.filter (s: s != null) [
              v.github
              v.gitea
              v.url
              v.updateJson
              v.html
            ]
          ) != 1
        ) cfg.apps.release
      );
      privateDnsRawConflict =
        cfg.android.privateDns != null
        && (
          cfg.android.settings.global ? private_dns_mode
          || cfg.android.settings.global ? private_dns_specifier
        );
      privateDnsLabels =
        if cfg.android.privateDns == null then [ ] else lib.splitString "." cfg.android.privateDns;
      validPrivateDns =
        cfg.android.privateDns == null
        || builtins.elem cfg.android.privateDns [
          "off"
          "opportunistic"
        ]
        || (
          builtins.stringLength cfg.android.privateDns <= 253
          && privateDnsLabels != [ ]
          && lib.all (
            label: builtins.match "[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?" label != null
          ) privateDnsLabels
        );
      settingEntries =
        lib.concatMap
          (
            ns:
            lib.mapAttrsToList (key: value: {
              inherit ns key;
              value = toString value;
            }) cfg.android.settings.${ns}
          )
          [
            "global"
            "secure"
            "system"
          ];
      invalidSettings = builtins.filter (
        s:
        builtins.match "[A-Za-z0-9_.-]+" s.key == null
        || s.value == ""
        || s.value == "null"
        || lib.any (c: lib.hasInfix c s.value) [
          "\n"
          "\r"
          (builtins.fromJSON ''"\u001f"'')
        ]
      ) settingEntries;
      expectedLocked = lib.listToAttrs (
        map (p: {
          name = p;
          value = {
            source = null;
            repoFingerprint = officialFdroidFingerprint;
          };
        }) cfg.apps.fdroid.packages
        ++ lib.concatLists (
          lib.mapAttrsToList (
            _: repo:
            map (p: {
              name = p;
              value = {
                source = "fdroid:${repo.url}";
                repoFingerprint = lib.toLower repo.fingerprint;
              };
            }) repo.packages
          ) cfg.apps.fdroid.repos
        )
        ++ lib.mapAttrsToList (p: release: {
          name = p;
          value = {
            source =
              if release.github != null then
                "github:${release.github}"
              else if release.gitea != null then
                "gitea:${release.gitea}"
              else if release.url != null then
                "url:${release.url}"
              else if release.updateJson != null then
                "urljson:${release.updateJson}"
              else
                "html:${release.html.url}";
            repoFingerprint = null;
            linkFilter = if release.html != null then release.html.linkFilter else null;
          };
        }) cfg.apps.release
      );
      # Lock-independent checks. `android-rebuild update` reads `config`, and
      # updating is the documented fix for a stale lock — so the lock/abi
      # comparison lives in `validated` below, not here.
      validatedConfig =
        if builtins.match "[A-Za-z0-9._-]+" cfg.device.name == null then
          throw "nix-android: device.name must contain only letters, numbers, dot, underscore, or hyphen"
        else if cfg.device.user != 0 then
          throw "nix-android: public v1 supports device.user = 0 only"
        else if invalidPackageNames != [ ] then
          throw "nix-android: invalid Android package names: ${lib.concatStringsSep ", " (lib.unique invalidPackageNames)}"
        else if invalidPermissionNames != [ ] then
          throw "nix-android: invalid Android permission names: ${lib.concatStringsSep ", " (lib.unique invalidPermissionNames)}"
        else if invalidAppOpNames != [ ] then
          throw "nix-android: invalid Android app-op names: ${lib.concatStringsSep ", " invalidAppOpNames}"
        else if invalidInputMethodComponents != [ ] then
          throw "nix-android: invalid input-method components: ${lib.concatStringsSep ", " (lib.unique invalidInputMethodComponents)}"
        else if invalidLocales != [ ] then
          throw "nix-android: invalid portable app locale tags: ${lib.concatStringsSep ", " invalidLocales}"
        else if invalidAppLinkDomains != [ ] then
          throw "nix-android: invalid app-link domains: ${lib.concatStringsSep ", " invalidAppLinkDomains}"
        else if duplicateApps != [ ] then
          throw "nix-android: each app must have exactly one source; duplicate declarations: ${lib.concatStringsSep ", " duplicateApps}"
        else if permissionConflicts != [ ] then
          throw "nix-android: permissions cannot be both granted and revoked: ${lib.concatStringsSep ", " permissionConflicts}"
        else if duplicatePermissions != [ ] then
          throw "nix-android: permission entries must be unique: ${lib.concatStringsSep ", " duplicatePermissions}"
        else if duplicatePermissionFlags != [ ] then
          throw "nix-android: permission flags must be unique: ${lib.concatStringsSep ", " duplicatePermissionFlags}"
        else if duplicateNewState != [ ] then
          throw "nix-android: Android state list entries must be unique: ${lib.concatStringsSep ", " duplicateNewState}"
        else if suspensionConflicts != [ ] then
          throw "nix-android: packages cannot be both suspended and unsuspended: ${lib.concatStringsSep ", " suspensionConflicts}"
        else if deviceidleConflicts != [ ] then
          throw "nix-android: packages cannot be both battery-optimization exempt and unexempt: ${lib.concatStringsSep ", " deviceidleConflicts}"
        else if inputMethodConflicts != [ ] then
          throw "nix-android: input methods cannot be both enabled and disabled: ${lib.concatStringsSep ", " inputMethodConflicts}"
        else if inputMethodDefaultDisabled then
          throw "nix-android: android.inputMethod.default must also appear in android.inputMethod.enabled"
        else if appLinkConflicts != [ ] then
          throw "nix-android: app-link domains cannot be both selected and unselected: ${lib.concatStringsSep ", " appLinkConflicts}"
        else if duplicateSelectedAppLinkDomains != [ ] then
          throw "nix-android: a domain can be selected for only one app: ${lib.concatStringsSep ", " duplicateSelectedAppLinkDomains}"
        else if invalidReleaseSources != [ ] then
          throw "nix-android: release apps must set exactly one of github/gitea/url/updateJson/html: ${lib.concatStringsSep ", " invalidReleaseSources}"
        else if inputMethodRawConflict then
          throw "nix-android: android.inputMethod conflicts with raw default_input_method/enabled_input_methods settings"
        else if privateDnsRawConflict then
          throw "nix-android: android.privateDns conflicts with raw private_dns_mode/private_dns_specifier settings"
        else if !validPrivateDns then
          throw "nix-android: android.privateDns must be off, opportunistic, or a valid DNS hostname"
        else if invalidSettings != [ ] then
          throw "nix-android: raw settings require safe keys and nonempty values other than literal 'null'"
        else
          true;
      validated =
        if (lock.abi or null) != cfg.device.abi then
          throw "nix-android: ${baseNameOf lockFile} targets '${lock.abi or "unknown"}', but device.abi is '${cfg.device.abi}' — run android-rebuild update"
        else
          validatedConfig;

      fetchApk =
        p:
        let
          l0 = lib.attrByPath [ "packages" p ] null lock;
          expected = expectedLocked.${p};
          actualSource = if l0 == null then null else l0.source or null;
          actualFingerprint =
            if l0 == null || !(l0 ? repoFingerprint) then null else lib.toLower l0.repoFingerprint;
          l =
            if l0 == null then
              throw "nix-android: '${p}' not in ${baseNameOf lockFile} — run android-rebuild update"
            else if actualSource != expected.source then
              throw "nix-android: '${p}' lock source is stale — run android-rebuild update"
            else if expected.repoFingerprint != null && actualFingerprint != expected.repoFingerprint then
              throw "nix-android: '${p}' repository fingerprint is stale — run android-rebuild update"
            else if (expected.linkFilter or null) != null && (l0.linkFilter or null) != expected.linkFilter then
              throw "nix-android: '${p}' link filter is stale — run android-rebuild update"
            else
              l0;
          src = pkgs.fetchurl {
            inherit (l) url sha256;
          };
          safeApkPath =
            l ? apkPath
            && l.apkPath != ""
            && !(lib.hasPrefix "/" l.apkPath)
            && !(lib.hasPrefix "-" l.apkPath)
            && !(builtins.elem ".." (lib.splitString "/" l.apkPath));
        in
        {
          package = p;
          inherit (l) versionCode;
          # Archive-wrapped releases (e.g. plezy ships foo.tar.gz containing
          # plezy.apk): the lock records the inner path; extract in the store.
          apk =
            if !(l ? apkPath) then
              src
            else if !safeApkPath then
              throw "nix-android: unsafe archive member for '${p}' in ${baseNameOf lockFile}"
            else
              pkgs.runCommand "${p}.apk" { nativeBuildInputs = [ pkgs.gnutar ]; } ''
                tar -xzOf ${lib.escapeShellArg (toString src)} -- ${lib.escapeShellArg l.apkPath} > "$out"
              '';
        };

      # Sugar options desugar to plain settings keys — zero engine surface.
      sugarSettings = {
        global =
          if cfg.android.privateDns == null then
            { }
          else if
            builtins.elem cfg.android.privateDns [
              "off"
              "opportunistic"
            ]
          then
            { private_dns_mode = cfg.android.privateDns; }
          else
            {
              private_dns_mode = "hostname";
              private_dns_specifier = cfg.android.privateDns;
            };
        secure = { };
        system = { };
      };
      settingsFinal = lib.genAttrs [ "global" "secure" "system" ] (
        ns: lib.mapAttrs (_: toString) (cfg.android.settings.${ns} // sugarSettings.${ns})
      );

      baseManifest =
        assert validated;
        pkgs.writeText "nix-android-${cfg.device.name}-manifest-base.json" (
          builtins.toJSON {
            manifestVersion = 4;
            device = {
              inherit (cfg.device) name user abi;
            };
            android = {
              settings = settingsFinal;
              roles = lib.filterAttrs (_: v: v != null) cfg.android.defaultApps;
              inputMethod = inputMethodFinal;
              inherit (cfg.android)
                appLinks
                appOps
                darkMode
                dataSaver
                locales
                permissions
                ;
              disabled = cfg.android.packages.disabled;
              suspended = cfg.android.packages.suspended;
              unsuspended = cfg.android.packages.unsuspended;
              deviceidleExempt = cfg.android.batteryOptimization.exempt;
              deviceidleUnexempt = cfg.android.batteryOptimization.unexempt;
            };
            apps = {
              # One unified list regardless of source — the engine doesn't care
              # where an APK came from, only that it's a hash-verified store path.
              managed = map fetchApk managedLockedNames;
              inherit (cfg.apps) attended play cleanup;
            };
          }
        );

      # Local APKs carry no lock entry: versionCode + package id are read from
      # the file at build time, and a package-id mismatch fails the build.
      localSnippets = lib.concatStrings (
        lib.mapAttrsToList (p: v: ''
          badging=$(aapt2 dump badging ${v.apk})
          pkgid=$(sed -n "s/^package: name='\([^']*\)'.*/\1/p" <<<"$badging")
          [ "$pkgid" = "${p}" ] || { echo "apps.local: declared ${p} but APK is $pkgid" >&2; exit 1; }
          code=$(sed -n "s/.*versionCode='\([0-9]*\)'.*/\1/p" <<<"$badging")
          jq --arg p "${p}" --arg apk "${v.apk}" --argjson code "$code" \
            '.apps.managed += [{package: $p, versionCode: $code, apk: $apk}]' \
            m.json > m2.json && mv m2.json m.json
        '') cfg.apps.local
      );

      manifest =
        if cfg.apps.local == { } then
          baseManifest
        else
          pkgs.runCommand "nix-android-${cfg.device.name}-manifest.json"
            {
              nativeBuildInputs = [
                pkgs.aapt
                pkgs.jq
              ];
            }
            ''
              cp ${baseManifest} m.json
              ${localSnippets}
              cp m.json $out
            '';

      converge = pkgs.writeShellApplication {
        name = "nix-android-converge-${cfg.device.name}";
        runtimeInputs = [
          pkgs.android-tools
          # For the exact plan-time signer preflight on pending upgrades; the
          # engine degrades to the installer-provenance heuristic without it
          # (standalone Termux/rish later).
          pkgs.apksigner
          pkgs.coreutils
          pkgs.gawk
          pkgs.gnugrep
          pkgs.gnused
          pkgs.jq
        ];
        text = ''
          exec ${pkgs.bash}/bin/bash ${../engine}/converge.sh ${manifest} "$@"
        '';
      };
    in
    {
      inherit manifest converge;
      config = builtins.seq validatedConfig cfg;
    };
}
