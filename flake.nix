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
        # repo whose phone.nix documents the main option groups inline.
        templates.default = {
          path = ./templates/default;
          description = "Declarative Android/GrapheneOS device config via nix-android";
          welcomeText = ''
            # nix-android device config

            Next steps:
            - `git init && git add -A` (Nix only sees git-tracked files)
            - edit `phone.nix` (the apps you want; Apple Silicon: set `system` in flake.nix)
            - `nix run .#android-rebuild -- update --flake .#phone`
            - `nix run .#android-rebuild -- plan --flake .#phone --serial <SERIAL>`

            `phone.nix` documents the main option groups inline; the full
            generated reference is upstream at docs/OPTIONS.md. See README.md.
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
          # apps.lock.json with one entry's fields overridden, for negative checks.
          benchLock = builtins.fromJSON (builtins.readFile ./apps.lock.json);
          alterLock =
            package: attrs:
            builtins.toFile "nix-android-invalid-lock.json" (
              builtins.toJSON (
                benchLock
                // {
                  packages = benchLock.packages // {
                    "${package}" = benchLock.packages.${package} // attrs;
                  };
                }
              )
            );
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

            # Option reference rendered from the typed module options. Executed
            # device evidence lives in docs/PRIMITIVES.md. Regenerate the
            # committed docs/OPTIONS.md with `just options-doc`.
            options-doc =
              let
                eval = pkgs.lib.evalModules { modules = [ ./modules/options.nix ]; };
                doc = pkgs.nixosOptionsDoc {
                  inherit (eval) options;
                  transformOptions =
                    opt:
                    # Drop the module system's own _module.* plumbing; strip the
                    # store-path declaration links (pure data, not a NixOS host).
                    if builtins.head opt.loc == "_module" then
                      opt // { visible = false; }
                    else
                      opt // { declarations = [ ]; };
                };
              in
              doc.optionsCommonMark;
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
            adb-client =
              let
                device = inputs.self.lib.mkDevice {
                  inherit system;
                  modules = [
                    {
                      device.name = "client-test";
                      device.abi = "x86_64";
                    }
                  ];
                  lockFile = builtins.toFile "client-test-lock.json" (
                    builtins.toJSON {
                      abi = "x86_64";
                      lockedAt = 0;
                      packages = { };
                    }
                  );
                };
              in
              pkgs.runCommand "nix-android-adb-client"
                {
                  nativeBuildInputs = [
                    pkgs.jq
                    pkgs.gawk
                    pkgs.gnugrep
                    pkgs.gnused
                  ];
                }
                ''
                  ${pkgs.bash}/bin/bash ${inputs.self}/scripts/test-adb-client.sh \
                    ${inputs.self} ${pkgs.bash}/bin/bash \
                    ${inputs.self.packages.${system}.android-rebuild}/bin/android-rebuild \
                    ${device.converge}/bin/nix-android-converge-client-test
                  touch $out
                '';
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
            # docs/OPTIONS.md must match what the typed options render to, so a
            # changed option cannot ship with a stale reference.
            options-doc = pkgs.runCommand "nix-android-options-doc" { nativeBuildInputs = [ pkgs.bash ]; } ''
              bash ${inputs.self}/scripts/render-options-doc.sh \
                ${inputs.self.packages.${system}.options-doc} > rendered.md
              if ! diff -u ${inputs.self}/docs/OPTIONS.md rendered.md; then
                echo "docs/OPTIONS.md is stale — run 'just options-doc'" >&2
                exit 1
              fi
              printf 'fixture\n' > unreadable.md
              chmod 000 unreadable.md
              if bash ${inputs.self}/scripts/render-options-doc.sh unreadable.md > unreadable.out 2>/dev/null; then
                echo "render-options-doc accepted an unreadable input" >&2
                exit 1
              fi
              test ! -s unreadable.out
              touch $out
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
              ! "$cli" status --flake ${inputs.self}#bench >/dev/null 2>&1
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
              # Device-closure builds pass --max-jobs (parallel APK fetches)
              # regardless of nix.conf; a stub nix records the invocation.
              mkdir stub
              cat > stub/nix <<EOF
              #!${pkgs.bash}/bin/bash
              echo "\$*" >> $PWD/nix.log
              case "\$*" in
              *fetchPlan*) echo '[{"path":"/nix/store/absent.apk","size":2500000},{"path":"/","size":7},{"path":"/nix/store/absent2.apk"}]' ;;
              *) echo /nix/store/fake-manifest ;;
              esac
              EOF
              chmod +x stub/nix
              PATH=$PWD/stub:$PATH "$cli" build --flake x#bench >/dev/null 2>progress-err
              grep -qx 'fetching 2 APKs (2+ MB) ...' progress-err
              grep -q -- 'build .* --max-jobs 8 x#androidConfigurations.bench.manifest' nix.log
              PATH=$PWD/stub:$PATH NIX_ANDROID_MAX_JOBS=3 "$cli" build --flake x#bench >/dev/null
              grep -q -- '--max-jobs 3 x#androidConfigurations.bench.manifest' nix.log
              ! PATH=$PWD/stub:$PATH NIX_ANDROID_MAX_JOBS=0 "$cli" build --flake x#bench >/dev/null 2>jobs-err
              grep -q 'NIX_ANDROID_MAX_JOBS' jobs-err
              # update's argv is NUL-delimited: a newline inside a config value
              # stays inside that one argument instead of becoming a flag. A
              # fake nix serves the config and a fake resolver records argv.
              mkdir -p fakebin fakeresolver/bin
              printf '%s\n' '#!${pkgs.runtimeShell}' \
                'case "$1" in' \
                '  eval) cat "$NIX_ANDROID_TEST_CONFIG" ;;' \
                '  build) echo "$NIX_ANDROID_TEST_RESOLVER" ;;' \
                '  *) exit 1 ;;' \
                'esac' > fakebin/nix
              printf '%s\n' '#!${pkgs.runtimeShell}' \
                'printf "%s\0" "$@" > "$NIX_ANDROID_TEST_ARGV"' \
                > fakeresolver/bin/nix-android-update-lock
              chmod +x fakebin/nix fakeresolver/bin/nix-android-update-lock
              printf '%s' '{"abi":"x86_64","fdroid":{"packages":["org.example.one"],"repos":{"x":{
                "url":"https://repo.example/fdroid\n--allow-signer-rotation","fingerprint":"ff",
                "packages":["org.example.two"]}}},"release":{"org.example.three":{"github":null,
                "gitea":null,"url":null,"updateJson":null,
                "html":{"url":"https://page.example/\n--allow-signer-rotation","linkFilter":"a\nb"}}}}' \
                > config.json
              NIX_ANDROID_TEST_CONFIG=$PWD/config.json \
                NIX_ANDROID_TEST_RESOLVER=$PWD/fakeresolver \
                NIX_ANDROID_TEST_ARGV=$PWD/argv \
                PATH="$PWD/fakebin:$PATH" "$cli" update --flake x#dev --lock lock.json
              mapfile -d "" -t argv < argv
              for a in "''${argv[@]}"; do
                [ "$a" != --allow-signer-rotation ] || { echo "newline smuggled a flag into update" >&2; exit 1; }
              done
              # --lock lock.json --abi x86_64 --replace, one plain pkg, 4 fdroid
              # words, 3 html words: 13 arguments.
              [ "''${#argv[@]}" -eq 13 ] || { echo "update argv has ''${#argv[@]} words, expected 13" >&2; exit 1; }
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
                    manifestVersion: 4,
                    device: {name: "test", user: 0, abi: "x86_64"},
                    apps: {cleanup: "none", attended: [], play: [], managed: []},
                    android: {
                      darkMode: null, disabled: [], deviceidleExempt: [], deviceidleUnexempt: [], roles: {},
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
                  reject duplicate-unexempt '.android.deviceidleUnexempt = ["org.example.app", "org.example.app"]'
                  reject deviceidle-conflict '.android.deviceidleExempt = ["org.example.app"] |
                    .android.deviceidleUnexempt = ["org.example.app"]'
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
                  rm contacted
                  jq '.apps.cleanup = "report"' valid.json > report.json
                  ! PATH="$PWD/fakebin:$PATH" ${pkgs.bash}/bin/bash ${inputs.self}/engine/converge.sh \
                    report.json --serial expected-contact >/dev/null 2>&1
                  test -e contacted
                  ${pkgs.bash}/bin/bash ${inputs.self}/scripts/test-converge-plan.sh \
                    ${inputs.self}/engine/converge.sh ${pkgs.bash}/bin/bash
                  touch $out
                '';
            update-lock-safety =
              let
                locked = (builtins.fromJSON (builtins.readFile ./apps.lock.json)).packages."org.fdroid.fdroid";
                fixtureApk = pkgs.fetchurl {
                  inherit (locked) url sha256;
                };
                # Build-time lock binding: a correctly hash-pinned APK whose
                # signer/versionCode disagree with its lock entry (or with the
                # config pin) must fail its own derivation.
                mismatched =
                  package: attrs: module:
                  pkgs.testers.testBuildFailure
                    (inputs.self.lib.mkDevice {
                      inherit system;
                      modules = [
                        {
                          device.name = "lock-binding";
                          device.abi = "x86_64";
                        }
                        module
                      ];
                      lockFile = alterLock package attrs;
                    }).apks.${package};
                wrongSigner = [ "2222222222222222222222222222222222222222222222222222222222222222" ];
                bindingFailures = {
                  "not a locked signerSha256" = mismatched "org.fdroid.fdroid" { signerSha256 = wrongSigner; } {
                    apps.fdroid.packages = [ "org.fdroid.fdroid" ];
                  };
                  "versionCode is 1023052, lock says 1" = mismatched "org.fdroid.fdroid" { versionCode = 1; } {
                    apps.fdroid.packages = [ "org.fdroid.fdroid" ];
                  };
                  # Archive-wrapped release: extraction and the check share one derivation.
                  "APK for com.edde746.plezy does not match" = mismatched "com.edde746.plezy" {
                    signerSha256 = wrongSigner;
                  } { apps.release."com.edde746.plezy".github = "edde746/plezy"; };
                  "signerSha256 pin" = mismatched "dev.imranr.obtainium.fdroid" { } {
                    apps.release."dev.imranr.obtainium.fdroid" = {
                      github = "ImranR98/Obtainium";
                      signerSha256 = wrongSigner;
                    };
                  };
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
                  ${pkgs.lib.concatStrings (
                    pkgs.lib.mapAttrsToList (expect: drv: ''
                      grep -Fq ${pkgs.lib.escapeShellArg expect} ${drv}/testBuildFailure.log \
                        || { echo "lock-binding failure lacks: "${pkgs.lib.escapeShellArg expect} >&2; cat ${drv}/testBuildFailure.log >&2; exit 1; }
                    '') bindingFailures
                  )}
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
                # What `android-rebuild update` reads: the typed apps config.
                rejectsConfig =
                  module:
                  !(builtins.tryEval (
                    let
                      inherit
                        (inputs.self.lib.mkDevice {
                          inherit system;
                          modules = [
                            {
                              device.name = "config-type";
                              device.abi = "x86_64";
                            }
                            module
                          ];
                          lockFile = ./apps.lock.json;
                        })
                        config
                        ;
                    in
                    builtins.deepSeq config.apps config.apps
                  )).success;
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
                device.name = "deviceidle-conflict";
                device.abi = "x86_64";
                android.batteryOptimization.exempt = [ "org.example.app" ];
                android.batteryOptimization.unexempt = [ "org.example.app" ];
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
              assert rejectsWithLock
                (alterLock "org.fdroid.fdroid" { url = "https://evil.example/repo/org.fdroid.fdroid_1023052.apk"; })
                {
                  device.name = "fdroid-url-outside-repo";
                  device.abi = "x86_64";
                  apps.fdroid.packages = [ "org.fdroid.fdroid" ];
                };
              assert rejectsWithLock (alterLock "dev.imranr.obtainium.fdroid" { signerSha256 = [ ]; }) {
                device.name = "release-without-signer";
                device.abi = "x86_64";
                apps.release."dev.imranr.obtainium.fdroid".github = "ImranR98/Obtainium";
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
              # Release/repo strings become update-lock argv: control characters
              # and non-HTTPS URLs are type errors before any fetch.
              assert rejectsConfig {
                apps.release."org.example.app".url = "https://example.com/a.apk\n--allow-signer-rotation";
              };
              assert rejectsConfig {
                apps.release."org.example.app".github = "owner/repo\n--allow-signer-rotation";
              };
              assert rejectsConfig {
                apps.release."org.example.app".gitea = "git.example.com/owner/repo\r";
              };
              assert rejectsConfig {
                apps.release."org.example.app".updateJson = "http://example.com/latest.json";
              };
              assert rejectsConfig {
                apps.release."org.example.app".html = {
                  url = "https://example.com/mobile";
                  linkFilter = "app\\.apk$\n--allow-signer-rotation";
                };
              };
              assert rejectsConfig {
                apps.fdroid.repos.example = {
                  url = "http://example.com/fdroid/repo";
                  fingerprint = "0000000000000000000000000000000000000000000000000000000000000000";
                };
              };
              # The positive control keeps the helper from passing vacuously.
              assert
                !(rejectsConfig {
                  apps.release."org.example.app".html = {
                    url = "https://example.com/mobile";
                    linkFilter = "app-[0-9.]+\\.apk$";
                  };
                });
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
