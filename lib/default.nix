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
      eval = nixpkgs.lib.evalModules { modules = [ ../modules/options.nix ] ++ modules; };
      cfg = eval.config;
      lock = builtins.fromJSON (builtins.readFile lockFile);

      fetchApk =
        p:
        let
          l =
            lock.packages.${p}
              or (throw "nix-android: '${p}' not in ${baseNameOf lockFile} — run scripts/update-lock.sh ${p}");
        in
        {
          package = p;
          inherit (l) versionCode;
          apk = pkgs.fetchurl {
            url = l.url;
            inherit (l) sha256;
          };
        };

      manifest = pkgs.writeText "nix-android-${cfg.device.name}-manifest.json" (
        builtins.toJSON {
          device = {
            inherit (cfg.device) name user;
          };
          apps = {
            # One unified list regardless of source — the engine doesn't care
            # where an APK came from, only that it's a hash-verified store path.
            managed = map fetchApk (
              cfg.apps.fdroid.packages ++ builtins.attrNames cfg.apps.release
            );
            inherit (cfg.apps) attended cleanup;
          };
        }
      );

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
