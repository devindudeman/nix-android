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
      declaredApps = managedLockedNames ++ builtins.attrNames cfg.apps.local ++ cfg.apps.attended;
      referencedPackages =
        declaredApps
        ++ cfg.android.packages.disabled
        ++ cfg.android.batteryOptimization.exempt
        ++ builtins.attrNames cfg.android.permissions
        ++ builtins.attrValues (lib.filterAttrs (_: v: v != null) cfg.android.defaultApps);
      invalidPackageNames = builtins.filter (
        p: builtins.match "[A-Za-z0-9_]+([.][A-Za-z0-9_]+)+" p == null
      ) referencedPackages;
      invalidPermissionNames = builtins.filter (p: builtins.match "[A-Za-z0-9_.]+" p == null) (
        lib.concatMap (v: v.grant ++ v.revoke) (builtins.attrValues cfg.android.permissions)
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
          p: v:
          map (permission: "${p}:${permission}") (
            lib.unique (
              builtins.filter (
                permission: lib.count (candidate: candidate == permission) (v.grant ++ v.revoke) > 1
              ) (v.grant ++ v.revoke)
            )
          )
        ) cfg.android.permissions
      );
      invalidReleaseSources = builtins.attrNames (
        lib.filterAttrs (_: v: (v.github == null) == (v.gitea == null)) cfg.apps.release
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
            source = if release.github != null then "github:${release.github}" else "gitea:${release.gitea}";
            repoFingerprint = null;
          };
        }) cfg.apps.release
      );
      validated =
        if builtins.match "[A-Za-z0-9._-]+" cfg.device.name == null then
          throw "nix-android: device.name must contain only letters, numbers, dot, underscore, or hyphen"
        else if cfg.device.user != 0 then
          throw "nix-android: public v1 supports device.user = 0 only"
        else if invalidPackageNames != [ ] then
          throw "nix-android: invalid Android package names: ${lib.concatStringsSep ", " (lib.unique invalidPackageNames)}"
        else if invalidPermissionNames != [ ] then
          throw "nix-android: invalid Android permission names: ${lib.concatStringsSep ", " (lib.unique invalidPermissionNames)}"
        else if (lock.abi or null) != cfg.device.abi then
          throw "nix-android: ${baseNameOf lockFile} targets '${lock.abi or "unknown"}', but device.abi is '${cfg.device.abi}' — run android-rebuild update"
        else if duplicateApps != [ ] then
          throw "nix-android: each app must have exactly one source; duplicate declarations: ${lib.concatStringsSep ", " duplicateApps}"
        else if permissionConflicts != [ ] then
          throw "nix-android: permissions cannot be both granted and revoked: ${lib.concatStringsSep ", " permissionConflicts}"
        else if duplicatePermissions != [ ] then
          throw "nix-android: permission entries must be unique: ${lib.concatStringsSep ", " duplicatePermissions}"
        else if invalidReleaseSources != [ ] then
          throw "nix-android: release apps must set exactly one of github/gitea: ${lib.concatStringsSep ", " invalidReleaseSources}"
        else if privateDnsRawConflict then
          throw "nix-android: android.privateDns conflicts with raw private_dns_mode/private_dns_specifier settings"
        else if !validPrivateDns then
          throw "nix-android: android.privateDns must be off, opportunistic, or a valid DNS hostname"
        else if invalidSettings != [ ] then
          throw "nix-android: raw settings require safe keys and nonempty values other than literal 'null'"
        else
          true;

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
            manifestVersion = 1;
            device = {
              inherit (cfg.device) name user abi;
            };
            android = {
              settings = settingsFinal;
              roles = lib.filterAttrs (_: v: v != null) cfg.android.defaultApps;
              inherit (cfg.android) darkMode permissions;
              disabled = cfg.android.packages.disabled;
              deviceidleExempt = cfg.android.batteryOptimization.exempt;
            };
            apps = {
              # One unified list regardless of source — the engine doesn't care
              # where an APK came from, only that it's a hash-verified store path.
              managed = map fetchApk managedLockedNames;
              inherit (cfg.apps) attended cleanup;
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
          pkgs.jq
        ];
        text = ''
          exec ${pkgs.bash}/bin/bash ${../engine/converge.sh} ${manifest} "$@"
        '';
      };
    in
    {
      inherit manifest converge;
      config = cfg;
    };
}
