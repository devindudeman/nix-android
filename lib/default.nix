# mkDevice: modules → { manifest, converge, config }.
# Manifest is pure data (JSON); APKs are fetched into the store by the hashes
# in the lock file, so a device's app payload is a real Nix closure.
{ nixpkgs }:
{
  mkDevice =
    {
      system ? "x86_64-linux",
      modules,
      lockFile,
    }:
    let
      pkgs = import nixpkgs { inherit system; };
      inherit (nixpkgs) lib;
      eval = lib.evalModules { modules = [ ../modules/options.nix ] ++ modules; };
      cfg = eval.config;
      lock = builtins.fromJSON (builtins.readFile lockFile);

      fetchApk =
        p:
        let
          l =
            lock.packages.${p}
              or (throw "nix-android: '${p}' not in ${baseNameOf lockFile} — run android-rebuild update");
          src = pkgs.fetchurl {
            url = l.url;
            inherit (l) sha256;
          };
        in
        {
          package = p;
          inherit (l) versionCode;
          # Archive-wrapped releases (e.g. plezy ships foo.tar.gz containing
          # plezy.apk): the lock records the inner path; extract in the store.
          apk =
            if l ? apkPath then
              pkgs.runCommand "${p}.apk" { } "tar -xzOf ${src} ${l.apkPath} > $out"
            else
              src;
        };

      # Sanity: each release app names exactly one source.
      checkedRelease = lib.mapAttrs (
        p: v:
        if (v.github == null) == (v.gitea == null) then
          throw "nix-android: apps.release.${p} must set exactly one of github/gitea"
        else
          v
      ) cfg.apps.release;

      # Sugar options desugar to plain settings keys — zero engine surface.
      sugarSettings = {
        global =
          if cfg.android.privateDns == null then
            { }
          else if builtins.elem cfg.android.privateDns [ "off" "opportunistic" ] then
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
        ns: lib.mapAttrs (_: v: toString v) (cfg.android.settings.${ns} // sugarSettings.${ns})
      );

      baseManifest = pkgs.writeText "nix-android-${cfg.device.name}-manifest-base.json" (
        builtins.toJSON {
          device = {
            inherit (cfg.device) name user;
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
            managed = map fetchApk (
              lib.unique (
                cfg.apps.fdroid.packages
                ++ lib.concatMap (r: r.packages) (builtins.attrValues cfg.apps.fdroid.repos)
                ++ builtins.attrNames checkedRelease
              )
            );
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
          exec bash ${../engine/converge.sh} ${manifest} "$@"
        '';
      };
    in
    {
      inherit manifest converge;
      config = cfg;
    };
}
