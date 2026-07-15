#!/usr/bin/env bash
# android-rebuild — the nix-android CLI, deliberately shaped like darwin-rebuild.
#
#   android-rebuild build  --flake .#pixel            eval + fetch closure, no device
#   android-rebuild plan   --flake .#pixel --serial S     diff manifest vs device
#   android-rebuild switch --flake .#pixel --serial S     plan + apply
#   android-rebuild update --flake .#pixel [--lock PATH]  refresh apps.lock.json
#   android-rebuild import --serial S                 connected device → starter device.nix (stdout)
#
# Runs from the config repo (the flake). NIX_ANDROID_SRC points at the
# nix-android checkout for helper scripts; the packaged CLI bakes it in.
set -euo pipefail

src=${NIX_ANDROID_SRC:?NIX_ANDROID_SRC not set (use the packaged android-rebuild)}
nix_android_bash=${NIX_ANDROID_BASH:?NIX_ANDROID_BASH not set (use the packaged android-rebuild)}
nixargs=(--impure --accept-flake-config)

usage() {
  cat <<'EOF'
Usage:
  android-rebuild build  --flake REF#DEVICE
  android-rebuild plan   --flake REF#DEVICE --serial SERIAL
  android-rebuild switch --flake REF#DEVICE --serial SERIAL
  android-rebuild update --flake REF#DEVICE [--lock apps.lock.json]
  android-rebuild import --serial SERIAL

The --serial argument (or ANDROID_SERIAL) is mandatory for every device command.
EOF
}

cmd=${1:-}
case $cmd in
help | -h | --help) usage; exit 0 ;;
"") usage >&2; exit 2 ;;
esac
shift
flakeref="."
serial=${ANDROID_SERIAL:-}
lock=apps.lock.json
flake_set=0
while [ $# -gt 0 ]; do
  case $1 in
  --flake)
    [ $# -ge 2 ] || { echo "--flake requires a value" >&2; exit 2; }
    flakeref=$2; flake_set=1; shift 2
    ;;
  --serial)
    [ $# -ge 2 ] || { echo "--serial requires a value" >&2; exit 2; }
    serial=$2; shift 2
    ;;
  --lock)
    [ $# -ge 2 ] || { echo "--lock requires a value" >&2; exit 2; }
    lock=$2; shift 2
    ;;
  -h | --help) usage; exit 0 ;;
  *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

case $cmd in
import)
  [ "$flake_set" -eq 0 ] || { echo "import does not take --flake" >&2; exit 2; }
  [ -n "$serial" ] || { echo "import requires --serial SERIAL (or ANDROID_SERIAL)" >&2; exit 2; }
  exec "$nix_android_bash" "$src/scripts/import.sh" --serial "$serial"
  ;;
build | plan | switch | update) ;;
*) echo "unknown command: $cmd" >&2; usage >&2; exit 2 ;;
esac

if [ "$cmd" = plan ] || [ "$cmd" = switch ]; then
  [ -n "$serial" ] || { echo "$cmd requires --serial SERIAL (or ANDROID_SERIAL)" >&2; exit 2; }
fi

flake=${flakeref%%#*}
flake=${flake:-.}
dev=${flakeref#*#}
if [ "$dev" = "$flakeref" ] || [ -z "$dev" ]; then
  dev=$(nix eval "${nixargs[@]}" "$flake#androidConfigurations" --apply builtins.attrNames --json | jq -r 'if length == 1 then .[0] else error("multiple devices — pass --flake .#<name>: \(join(", "))") end')
fi
attr="$flake#androidConfigurations.$dev"

engine_args=(--serial "$serial")

case $cmd in
build)
  out=$(nix build "${nixargs[@]}" "$attr.manifest" --no-link --print-out-paths)
  echo "manifest: $out"
  ;;
plan | switch)
  conv=$(nix build "${nixargs[@]}" "$attr.converge" --no-link --print-out-paths)
  apply=()
  [ "$cmd" = switch ] && apply=(--apply)
  exec "$conv"/bin/* "${engine_args[@]}" "${apply[@]}"
  ;;
update)
  config=$(nix eval "${nixargs[@]}" "$attr.config" \
    --apply 'c: { inherit (c.device) abi; inherit (c.apps) fdroid release; }' --json)
  abi=$(jq -er '.abi' <<<"$config")
  mapfile -t fdroid < <(jq -r '.fdroid.packages[]' <<<"$config")
  mapfile -t fspecs < <(jq -r '.fdroid.repos |
    to_entries[] | .value as $r | $r.packages[] | "--fdroid\n\(.)\n\($r.url)\n\($r.fingerprint)"' <<<"$config")
  mapfile -t relspecs < <(jq -r '.release |
    to_entries[] | if .value.github != null
      then "--github\n\(.key)=\(.value.github)"
      else "--gitea\n\(.key)=\(.value.gitea)" end' <<<"$config")
  resolver=$(nix build "${nixargs[@]}" "$src#update-lock" --no-link --print-out-paths)
  exec "$resolver/bin/nix-android-update-lock" --lock "$lock" --abi "$abi" "${fdroid[@]}" "${fspecs[@]}" "${relspecs[@]}"
  ;;
esac
