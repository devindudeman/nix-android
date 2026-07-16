{
  description = "nix-android — nix-darwin for GrapheneOS/Android: declarative device state over adb, no root";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";
    devenv.url = "github:cachix/devenv";
    nix2container.url = "github:nlewo/nix2container";
    nix2container.inputs.nixpkgs.follows = "nixpkgs";
    mk-shell-bin.url = "github:rrbutani/nix-mk-shell-bin";
  };

  nixConfig = {
    extra-substituters = [ "https://devenv.cachix.org" ];
    extra-trusted-public-keys = [
      "devenv.cachix.org-1:w1cLUi8dv3hnoSPGAuibQv+f9TZLr6cv/Hm9XgU50cw="
    ];
  };

  outputs =
    inputs@{ flake-parts, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      imports = [ inputs.devenv.flakeModule ];
      systems = [
        "x86_64-linux"
        "aarch64-darwin"
      ];

      flake = {
        lib = import ./lib { inherit (inputs) nixpkgs; };

        # `nix flake init -t github:devindudeman/nix-android` — a starter config
        # repo whose phone.nix documents the full option surface inline.
        templates.default = {
          path = ./templates/default;
          description = "Declarative Android/GrapheneOS device config via nix-android";
          welcomeText = ''
            # nix-android device config

            Next steps:
            - `git init && git add -A` (Nix only sees git-tracked files)
            - edit `phone.nix` (device.abi + the apps you want)
            - `nix run .#android-rebuild -- update --flake .#phone`
            - `nix run .#android-rebuild -- plan --flake .#phone --serial <SERIAL>`

            `phone.nix` documents every option inline. See README.md.
          '';
        };

        androidConfigurations.bench = inputs.self.lib.mkDevice {
          system = "x86_64-linux";
          modules = [ ./devices/bench.nix ];
          lockFile = ./apps.lock.json;
        };
        androidConfigurations.darwin-smoke = inputs.self.lib.mkDevice {
          system = "aarch64-darwin";
          modules = [
            {
              device.name = "darwin-smoke";
              device.abi = "arm64-v8a";
            }
          ];
          lockFile = builtins.toFile "nix-android-darwin-smoke-lock.json" (
            builtins.toJSON {
              abi = "arm64-v8a";
              lockedAt = 0;
              packages = { };
            }
          );
        };
      };

      perSystem =
        { system, ... }:
        let
          pkgs = import inputs.nixpkgs {
            inherit system;
            config = {
              allowUnfree = true;
              android_sdk.accept_license = true;
            };
          };
          androidSdk =
            (pkgs.androidenv.composeAndroidPackages {
              includeEmulator = true;
              includeSystemImages = true;
              platformVersions = [ "35" ];
              systemImageTypes = [ "default" ]; # pure AOSP, closest to GrapheneOS's base
              abiVersions = [ "x86_64" ];
            }).androidsdk;
          androidSdkRoot = "${androidSdk}/libexec/android-sdk";
          importPython = pkgs.python3.withPackages (python: [ python.protobuf ]);
        in
        {
          packages = rec {
            update-lock = pkgs.writeShellApplication {
              name = "nix-android-update-lock";
              runtimeInputs = with pkgs; [
                aapt
                apksigner
                curl
                coreutils
                gnugrep
                gnutar
                gnused
                jdk_headless
                jq
                unzip
              ];
              text = ''exec ${pkgs.bash}/bin/bash ${inputs.self}/scripts/update-lock.sh "$@"'';
            };

            # The CLI, deliberately shaped like darwin-rebuild:
            # android-rebuild build|plan|switch|assist|bootstrap|update|import
            android-rebuild = pkgs.writeShellApplication {
              name = "android-rebuild";
              runtimeInputs = with pkgs; [
                android-tools
                coreutils
                curl
                gawk
                gnugrep
                gnused
                importPython
                jq
              ];
              text = ''
                export NIX_ANDROID_SRC=${inputs.self}
                export NIX_ANDROID_BASH=${pkgs.bash}/bin/bash
                exec "$NIX_ANDROID_BASH" ${inputs.self}/scripts/android-rebuild.sh "$@"
              '';
            };
            default = android-rebuild;
          }
          // pkgs.lib.optionalAttrs (system == "x86_64-linux") {
            # `nix run .#bench -- --serial emulator-5554 [--apply]` — converge
            # the emulator bench device.
            bench = inputs.self.androidConfigurations.bench.converge;

            # Test bench: headless AOSP emulator (the "free-fire lane" —
            # mutation-class testing runs here, never on real hardware first).
            emulator = pkgs.writeShellApplication {
              name = "nix-android-emulator";
              runtimeInputs = with pkgs; [
                android-tools
                coreutils
                gnugrep
                iproute2
                util-linux
              ];
              text = ''
                exec 9>/tmp/nix-android-emulator-5554.lock
                flock -n 9 || { echo "another nix-android emulator owns port 5554" >&2; exit 1; }
                devices=$(adb devices)
                if grep -q '^emulator-5554[[:space:]]' <<<"$devices"; then
                  echo "emulator-5554 is already attached" >&2
                  exit 1
                fi
                if [ -n "$(ss -Hln 'sport = :5554 or sport = :5555')" ]; then
                  echo "emulator console/adb ports 5554-5555 are already in use" >&2
                  exit 1
                fi

                run_root=$(mktemp -d "''${TMPDIR:-/tmp}/nix-android-emulator.XXXXXX")
                emulator_pid=
                cleanup() {
                  set +e
                  if [ -n "$emulator_pid" ] && kill -0 "$emulator_pid" 2>/dev/null; then
                    adb -s emulator-5554 emu kill >/dev/null 2>&1
                    for _ in $(seq 1 20); do
                      kill -0 "$emulator_pid" 2>/dev/null || break
                      sleep 0.25
                    done
                    kill "$emulator_pid" 2>/dev/null
                    wait "$emulator_pid" 2>/dev/null
                  fi
                  rm -rf -- "$run_root"
                }
                trap cleanup EXIT
                trap 'exit 130' HUP INT TERM
                if [ -n "''${NIX_ANDROID_RUN_ROOT_FILE:-}" ]; then
                  printf '%s\n' "$run_root" > "$NIX_ANDROID_RUN_ROOT_FILE"
                fi

                export ANDROID_HOME=${androidSdkRoot}
                export ANDROID_SDK_ROOT=$ANDROID_HOME
                export ANDROID_USER_HOME=$run_root/user
                export ANDROID_AVD_HOME=$ANDROID_USER_HOME/avd
                mkdir -p "$ANDROID_AVD_HOME"
                printf '\n' | ${androidSdk}/bin/avdmanager create avd --force \
                  --name nix-android --package 'system-images;android-35;default;x86_64' \
                  --path "$ANDROID_AVD_HOME/nix-android.avd" >/dev/null

                "$ANDROID_HOME/emulator/emulator" -avd nix-android -port 5554 \
                  -no-window -no-audio -no-boot-anim -no-snapshot -wipe-data \
                  -gpu swiftshader_indirect -memory 2048 &
                emulator_pid=$!

                deadline=$((SECONDS + 300))
                until [ "$(adb -s emulator-5554 shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = 1 ] \
                  && pm=$(adb -s emulator-5554 shell pm path android 2>/dev/null) \
                  && grep -q '^package:' <<<"$pm" \
                  && netpolicy=$(adb -s emulator-5554 shell cmd netpolicy get restrict-background 2>/dev/null) \
                  && grep -q '^Restrict background status:' <<<"$netpolicy"; do
                  kill -0 "$emulator_pid" 2>/dev/null || { wait "$emulator_pid"; exit $?; }
                  [ "$SECONDS" -lt "$deadline" ] || { echo "emulator boot timed out after five minutes" >&2; exit 1; }
                  sleep 2
                done
                adb -s emulator-5554 shell cmd package wait-for-handler --timeout 60000 >/dev/null
                echo "nix-android bench ready at emulator-5554; Ctrl-C to stop" >&2
                wait "$emulator_pid"
              '';
            };
          };

          checks = {
            formatting = pkgs.runCommand "nix-android-formatting" { nativeBuildInputs = [ pkgs.nixfmt ]; } ''
              find ${inputs.self} -name '*.nix' -print0 | xargs -0 nixfmt --check
              touch $out
            '';
            shellcheck =
              pkgs.runCommand "nix-android-shellcheck" { nativeBuildInputs = [ pkgs.shellcheck ]; }
                ''
                  shellcheck -x ${inputs.self}/engine/*.sh ${inputs.self}/scripts/*.sh
                  touch $out
                '';
            engine-parsers =
              pkgs.runCommand "nix-android-engine-parsers"
                {
                  nativeBuildInputs = [
                    pkgs.bash
                    pkgs.coreutils
                    pkgs.gawk
                    pkgs.gnugrep
                    pkgs.gnused
                  ];
                }
                ''
                  bash ${inputs.self}/scripts/test-read-state.sh
                  touch $out
                '';
            generations =
              pkgs.runCommand "nix-android-generations"
                {
                  nativeBuildInputs = [
                    pkgs.bash
                    pkgs.coreutils
                    pkgs.diffutils
                    pkgs.jq
                  ];
                }
                ''
                  bash ${inputs.self}/scripts/test-generations.sh
                  touch $out
                '';
            # The `nix flake init` scaffold must stay valid against the real
            # option surface: build the template device's manifest so a renamed
            # or removed option fails here instead of in a fresh user's repo.
            template = pkgs.runCommand "nix-android-template" { } ''
              cp ${
                (inputs.self.lib.mkDevice {
                  inherit system;
                  modules = [ ./templates/default/phone.nix ];
                  lockFile = ./templates/default/apps.lock.json;
                }).manifest
              } "$out"
            '';
            suggest-sources =
              pkgs.runCommand "nix-android-suggest-sources"
                {
                  nativeBuildInputs = [
                    pkgs.bash
                    pkgs.coreutils
                    pkgs.curl
                    pkgs.gnugrep
                    pkgs.gnused
                    pkgs.jq
                  ];
                }
                ''
                  bash ${inputs.self}/scripts/test-suggest-sources.sh \
                    ${inputs.self}/scripts/suggest-sources.sh
                  touch $out
                '';
            statix = pkgs.runCommand "nix-android-statix" { nativeBuildInputs = [ pkgs.statix ]; } ''
              statix check ${inputs.self}
              touch $out
            '';
            deadnix = pkgs.runCommand "nix-android-deadnix" { nativeBuildInputs = [ pkgs.deadnix ]; } ''
              deadnix --fail ${inputs.self}
              touch $out
            '';
            cli-safety = pkgs.runCommand "nix-android-cli-safety" { } ''
              cli=${inputs.self.packages.${system}.android-rebuild}/bin/android-rebuild
              "$cli" --help >/dev/null
              env -i PATH=/nope "$cli" --help >/dev/null
              grep -Fq ${pkgs.coreutils}/bin "$cli"
              grep -Fq ${pkgs.gawk}/bin "$cli"
              grep -Fq ${pkgs.gnugrep}/bin "$cli"
              grep -Fq ${pkgs.gnused}/bin "$cli"
              converge=${
                if system == "x86_64-linux" then
                  "${inputs.self.androidConfigurations.bench.converge}/bin/nix-android-converge-bench"
                else
                  "${inputs.self.androidConfigurations.darwin-smoke.converge}/bin/nix-android-converge-darwin-smoke"
              }
              grep -Fq ${pkgs.coreutils}/bin "$converge"
              grep -Fq ${pkgs.gawk}/bin "$converge"
              grep -Fq ${pkgs.gnugrep}/bin "$converge"
              grep -Fq ${pkgs.gnused}/bin "$converge"
              ! "$cli" plan --flake ${inputs.self}#bench >/dev/null 2>&1
              ! "$cli" switch --flake ${inputs.self}#bench >/dev/null 2>&1
              ! "$cli" assist --flake ${inputs.self}#bench >/dev/null 2>&1
              ! "$cli" bootstrap --flake ${inputs.self}#bench >/dev/null 2>&1
              ! "$cli" import >/dev/null 2>&1
              ! "$cli" unknown >/dev/null 2>&1
              ! "$cli" build --flake >/dev/null 2>&1
              ! "$cli" build --flake x#bench --lock nope.json >/dev/null 2>lock-err
              grep -q 'only valid with update' lock-err
              ! "$cli" build --flake x#bench --snapshot-out nope.json >/dev/null 2>snapshot-err
              grep -q 'only valid with import' snapshot-err
              ! "$cli" build --flake x#bench --report-out nope.json >/dev/null 2>report-err
              grep -q 'only valid with import' report-err
              ! "$cli" build --flake x#bench --obtainium-export nope.json >/dev/null 2>obtainium-err
              grep -q 'only valid with import' obtainium-err
              ! "$cli" build --flake x#bench --app-manager-export nope.json >/dev/null 2>app-manager-err
              grep -q 'only valid with import' app-manager-err
              ! "$cli" build --flake x#bench --watch >/dev/null 2>watch-err
              grep -q 'only valid with assist' watch-err
              touch $out
            '';
            import-snapshot =
              pkgs.runCommand "nix-android-import-snapshot" { nativeBuildInputs = [ importPython ]; }
                ''
                  python3 ${inputs.self}/scripts/test-package-snapshot.py
                  python3 ${inputs.self}/scripts/test-provenance-adapters.py
                  touch $out
                '';
            assist-safety =
              pkgs.runCommand "nix-android-assist-safety"
                {
                  nativeBuildInputs = [ pkgs.jq ];
                }
                ''
                  ${pkgs.bash}/bin/bash ${inputs.self}/scripts/test-assist-play.sh \
                    ${inputs.self}/scripts/assist-play.sh ${pkgs.bash}/bin/bash
                  touch $out
                '';
            bootstrap-safety =
              pkgs.runCommand "nix-android-bootstrap-safety"
                {
                  nativeBuildInputs = [ pkgs.jq ];
                }
                ''
                  ${pkgs.bash}/bin/bash ${inputs.self}/scripts/test-bootstrap.sh \
                    ${inputs.self}/scripts/bootstrap.sh ${pkgs.bash}/bin/bash
                  touch $out
                '';
            manifest-safety =
              pkgs.runCommand "nix-android-manifest-safety" { nativeBuildInputs = [ pkgs.jq ]; }
                ''
                  echo '{"apps":{"cleanup":"uninstall"}}' > malformed.json
                  ! ${pkgs.bash}/bin/bash ${inputs.self}/engine/converge.sh malformed.json --serial never-contact-this >/dev/null 2>error
                  grep -q 'invalid or unsupported manifest' error

                  jq -n '{
                    manifestVersion: 3,
                    device: {name: "test", user: 0, abi: "x86_64"},
                    apps: {cleanup: "none", attended: [], play: [], managed: []},
                    android: {
                      darkMode: null, disabled: [], deviceidleExempt: [], roles: {},
                      settings: {global: {}, secure: {}, system: {}},
                      permissions: {}, appOps: {}, suspended: [], unsuspended: [],
                      locales: {}, inputMethod: {enabled: [], disabled: [], default: null},
                      dataSaver: {enabled: null}, appLinks: {}
                    }
                  }' > valid.json
                  mkdir fakebin
                  printf '%s\n' '#!${pkgs.runtimeShell}' 'touch "$PWD/contacted"' 'exit 99' > fakebin/adb
                  chmod +x fakebin/adb
                  reject() {
                    jq "$2" valid.json > "$1.json"
                    ! PATH="$PWD/fakebin:$PATH" ${pkgs.bash}/bin/bash ${inputs.self}/engine/converge.sh \
                      "$1.json" --serial never-contact-this >/dev/null 2>error
                    grep -q 'invalid or unsupported manifest' error
                    test ! -e contacted
                  }
                  reject duplicate '.apps.managed = [
                    {package:"org.example.app",versionCode:1,apk:"/one.apk"},
                    {package:"org.example.app",versionCode:1,apk:"/two.apk"}]'
                  reject duplicate-play '.apps.attended = ["org.example.app"] |
                    .apps.play = ["org.example.app"]'
                  reject legacy-manifest '.manifestVersion = 1'
                  reject unknown-root '.future = {}'
                  reject unknown-app-source '.apps.privateSource = ["org.example.app"]'
                  reject unknown-android-state '.android.future = {}'
                  reject unknown-managed-field '.apps.managed = [
                    {package:"org.example.app",versionCode:1,apk:"/one.apk",future:true}]'
                  reject unknown-permission-field '.android.permissions."org.example.app" = {
                    grant:[], revoke:[], flags:{}, future:[]}'
                  reject missing-setting-namespace 'del(.android.settings.system)'
                  reject permission-conflict '.android.permissions."org.example.app" = {
                    grant:["android.permission.CAMERA"], revoke:["android.permission.CAMERA"], flags:{}}'
                  reject suspension-conflict '.android.suspended = ["org.example.app"] |
                    .android.unsuspended = ["org.example.app"]'
                  reject duplicate-disabled '.android.disabled = ["org.example.app", "org.example.app"]'
                  reject duplicate-deviceidle '.android.deviceidleExempt = ["org.example.app", "org.example.app"]'
                  reject invalid-locale '.android.locales."org.example.app" = ["en_US"]'
                  reject invalid-ime '.android.inputMethod.default = "org.example.ime/.Service"'
                  reject app-link-conflict '.android.appLinks."org.example.app" = {
                    allowed:null, selected:["example.com"], unselected:["example.com"]}'
                  reject app-link-owner-conflict '.android.appLinks = {
                    "org.example.one": {allowed:null, selected:["example.com"], unselected:[]},
                    "org.example.two": {allowed:null, selected:["example.com"], unselected:[]}}'
                  reject control-identifier '.apps.attended = ["org.example.app\n"]'
                  reject empty-setting '.android.settings.global.example = ""'
                  reject null-setting '.android.settings.global.example = "null"'
                  PATH="$PWD/fakebin:$PATH" ${pkgs.bash}/bin/bash ${inputs.self}/engine/converge.sh \
                    valid.json --validate-only
                  test ! -e contacted
                  ! PATH="$PWD/fakebin:$PATH" ${pkgs.bash}/bin/bash ${inputs.self}/engine/converge.sh \
                    valid.json --serial expected-contact >/dev/null 2>&1
                  test -e contacted
                  touch $out
                '';
            update-lock-safety =
              let
                locked = (builtins.fromJSON (builtins.readFile ./apps.lock.json)).packages."org.fdroid.fdroid";
                fixtureApk = pkgs.fetchurl {
                  inherit (locked) url sha256;
                };
              in
              pkgs.runCommand "nix-android-update-lock-safety"
                {
                  nativeBuildInputs = with pkgs; [
                    aapt
                    apksigner
                    coreutils
                    curl
                    gnugrep
                    gnutar
                    gnused
                    jdk_headless
                    jq
                    unzip
                  ];
                }
                ''
                  ${pkgs.bash}/bin/bash ${inputs.self}/scripts/test-update-lock.sh \
                    ${inputs.self.packages.${system}.update-lock}/bin/nix-android-update-lock \
                    ${fixtureApk} \
                    ${inputs.self}/scripts/update-lock.sh
                  touch $out
                '';
            validation =
              let
                rejectsWithLock =
                  lockFile: module:
                  !(builtins.tryEval
                    (inputs.self.lib.mkDevice {
                      inherit system;
                      modules = [ module ];
                      inherit lockFile;
                    }).manifest.outPath
                  ).success;
                rejects = rejectsWithLock ./apps.lock.json;
                lock = builtins.fromJSON (builtins.readFile ./apps.lock.json);
                alterLock =
                  package: attrs:
                  builtins.toFile "nix-android-invalid-lock.json" (
                    builtins.toJSON (
                      lock
                      // {
                        packages = lock.packages // {
                          "${package}" = lock.packages.${package} // attrs;
                        };
                      }
                    )
                  );
              in
              assert rejects {
                device = {
                  name = "wrong-user";
                  user = 1;
                  abi = "x86_64";
                };
              };
              assert rejects {
                device.name = "wrong-abi";
                device.abi = "arm64-v8a";
              };
              assert rejects {
                device.name = "duplicate-app";
                device.abi = "x86_64";
                apps.fdroid.packages = [ "org.fdroid.fdroid" ];
                apps.attended = [ "org.fdroid.fdroid" ];
              };
              assert rejects {
                device.name = "duplicate-play-app";
                device.abi = "x86_64";
                apps.play = [ "org.example.app" ];
                apps.attended = [ "org.example.app" ];
              };
              assert rejects {
                device.name = "permission-conflict";
                device.abi = "x86_64";
                android.permissions."org.example.app" = {
                  grant = [ "android.permission.POST_NOTIFICATIONS" ];
                  revoke = [ "android.permission.POST_NOTIFICATIONS" ];
                };
              };
              assert rejects {
                device.name = "duplicate-permission";
                device.abi = "x86_64";
                android.permissions."org.example.app".grant = [
                  "android.permission.CAMERA"
                  "android.permission.CAMERA"
                ];
              };
              assert rejects {
                device.name = "suspension-conflict";
                device.abi = "x86_64";
                android.packages.suspended = [ "org.example.app" ];
                android.packages.unsuspended = [ "org.example.app" ];
              };
              assert rejects {
                device.name = "duplicate-disabled";
                device.abi = "x86_64";
                android.packages.disabled = [
                  "org.example.app"
                  "org.example.app"
                ];
              };
              assert rejects {
                device.name = "duplicate-deviceidle";
                device.abi = "x86_64";
                android.batteryOptimization.exempt = [
                  "org.example.app"
                  "org.example.app"
                ];
              };
              assert rejects {
                device.name = "invalid-locale";
                device.abi = "x86_64";
                android.locales."org.example.app" = [ "en_US" ];
              };
              assert rejects {
                device.name = "noncanonical-locale";
                device.abi = "x86_64";
                android.locales."org.example.app" = [ "EN-us" ];
              };
              assert rejects {
                device.name = "truncated-locale";
                device.abi = "x86_64";
                android.locales."org.example.app" = [ "en-a" ];
              };
              assert rejects {
                device.name = "invalid-ime-default";
                device.abi = "x86_64";
                android.inputMethod.default = "org.example.ime/.Service";
              };
              assert rejects {
                device.name = "duplicate-app-link-owner";
                device.abi = "x86_64";
                android.appLinks = {
                  "org.example.one".selected = [ "example.com" ];
                  "org.example.two".selected = [ "example.com" ];
                };
              };
              assert rejects {
                device.name = "noncanonical-app-link";
                device.abi = "x86_64";
                android.appLinks."org.example.app".selected = [ "Example.COM" ];
              };
              assert rejects {
                device.name = "release-source-conflict";
                device.abi = "x86_64";
                apps.release."org.example.app" = {
                  github = "example/app";
                  gitea = "git.example.com/example/app";
                };
              };
              assert rejects {
                device.name = "private-dns-conflict";
                device.abi = "x86_64";
                android.privateDns = "dns.example.com";
                android.settings.global.private_dns_mode = "hostname";
              };
              assert rejects {
                device.name = "input-method-raw-conflict";
                device.abi = "x86_64";
                android = {
                  inputMethod.enabled = [ "org.example.ime/.Service" ];
                  inputMethod.default = "org.example.ime/.Service";
                  settings.secure.default_input_method = "org.example.ime/.Service";
                };
              };
              # Canonicalization must detect that the expanded and short
              # spellings are one component.
              assert rejects {
                device.name = "cross-spelling-ime-conflict";
                device.abi = "x86_64";
                android.inputMethod = {
                  enabled = [ "org.example.ime/.Service" ];
                  disabled = [ "org.example.ime/org.example.ime.Service" ];
                };
              };
              assert rejects {
                device.name = "stale-release-source";
                device.abi = "x86_64";
                apps.release."dev.imranr.obtainium.fdroid".gitea = "git.example.com/example/app";
              };
              assert rejectsWithLock
                (alterLock "org.fdroid.fdroid" {
                  repoFingerprint = "0000000000000000000000000000000000000000000000000000000000000000";
                })
                {
                  device.name = "stale-repository-fingerprint";
                  device.abi = "x86_64";
                  apps.fdroid.packages = [ "org.fdroid.fdroid" ];
                };
              assert rejectsWithLock (alterLock "com.edde746.plezy" { apkPath = "../../escape.apk"; }) {
                device.name = "unsafe-archive-member";
                device.abi = "x86_64";
                apps.release."com.edde746.plezy".github = "edde746/plezy";
              };
              assert rejects {
                device.name = "invalid-package";
                device.abi = "x86_64";
                apps.attended = [ "not a package; touch /tmp/nope" ];
              };
              assert rejects {
                device.name = "invalid-private-dns";
                device.abi = "x86_64";
                android.privateDns = "bad host name";
              };
              assert rejects {
                device.name = "ambiguous-empty-setting";
                device.abi = "x86_64";
                android.settings.global.example = "";
              };
              assert rejects {
                device.name = "ambiguous-null-setting";
                device.abi = "x86_64";
                android.settings.global.example = "null";
              };
              # `.config` is gated by the lock-independent checks (android-rebuild
              # update reads it) …
              assert
                !(builtins.tryEval
                  (inputs.self.lib.mkDevice {
                    inherit system;
                    modules = [
                      {
                        device.name = "config-gate";
                        device.abi = "x86_64";
                        apps.attended = [ "not a package" ];
                      }
                    ];
                    lockFile = ./apps.lock.json;
                  }).config.device.name
                ).success;
              # … but not by the lock/abi comparison, so `update` still works
              # against a stale lock.
              assert
                (builtins.tryEval
                  (inputs.self.lib.mkDevice {
                    inherit system;
                    modules = [
                      {
                        device.name = "stale-lock-config";
                        device.abi = "arm64-v8a";
                      }
                    ];
                    lockFile = ./apps.lock.json;
                  }).config.device.abi
                ).success;
              pkgs.runCommand "nix-android-validation" { } "touch $out";
          }
          // pkgs.lib.optionalAttrs (system == "x86_64-linux") {
            # The bench manifest is a Linux-host derivation by design.
            bench-manifest = inputs.self.androidConfigurations.bench.manifest;
          }
          // pkgs.lib.optionalAttrs (system == "aarch64-darwin") {
            darwin-manifest = inputs.self.androidConfigurations.darwin-smoke.manifest;
            darwin-converge = inputs.self.androidConfigurations.darwin-smoke.converge;
          };

          formatter = pkgs.nixfmt-tree;

          devenv.shells.default = {
            devenv.root =
              let
                pwd = builtins.getEnv "PWD";
              in
              if pwd != "" then pwd else toString inputs.self;
            packages = with pkgs; [
              android-tools
              jq
              aapt
              just
              importPython
            ];
            git-hooks.hooks = {
              # `nixfmt` = pkgs.nixfmt (the RFC-style formatter); the old
              # `nixfmt-rfc-style` alias now warns on eval.
              nixfmt.enable = true;
              statix.enable = true;
              deadnix.enable = true;
              shellcheck = {
                enable = true;
                # -x follows the shared engine/read-state.sh source; without it
                # the hook only passes when that file happens to be staged too.
                args = [ "-x" ];
              };
            };
            enterShell = ''echo "▸ nix-android dev shell — bench: just emu, converge: android-rebuild plan --flake .#bench --serial emulator-5554"'';
          };
        };
    };
}
