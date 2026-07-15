#!/usr/bin/env bash
# android-rebuild — the nix-android CLI, deliberately shaped like darwin-rebuild.
#
#   android-rebuild build  --flake .#pixel            eval + fetch closure, no device
#   android-rebuild plan   --flake .#pixel [--serial S]   diff manifest vs device
#   android-rebuild switch --flake .#pixel [--serial S]   plan + apply
#   android-rebuild update --flake .#pixel            refresh apps.lock.json
#   android-rebuild import [--serial S]               connected device → starter device.nix (stdout)
#
# Runs from the config repo (the flake). NIX_ANDROID_SRC points at the
# nix-android checkout for helper scripts; the packaged CLI bakes it in.
set -euo pipefail

src=${NIX_ANDROID_SRC:?NIX_ANDROID_SRC not set (use the packaged android-rebuild)}
nixargs=(--impure --accept-flake-config)

cmd=${1:?usage: android-rebuild build|plan|switch|update|import [--flake ref#device] [--serial S]}
shift
flakeref="."
serial=${ANDROID_SERIAL:-}
while [ $# -gt 0 ]; do
  case $1 in
  --flake) flakeref=$2; shift 2 ;;
  --serial) serial=$2; shift 2 ;;
  *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done
flake=${flakeref%%#*}
flake=${flake:-.}
dev=${flakeref#*#}
if [ "$dev" = "$flakeref" ] || [ -z "$dev" ]; then
  dev=$(nix eval "${nixargs[@]}" "$flake#androidConfigurations" --apply builtins.attrNames --json | jq -r 'if length == 1 then .[0] else error("multiple devices — pass --flake .#<name>: \(join(", "))") end')
fi
attr="$flake#androidConfigurations.$dev"

engine_args=()
[ -n "$serial" ] && engine_args+=(--serial "$serial")

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
  abi=$(nix eval "${nixargs[@]}" "$attr.config.device.abi" --raw 2>/dev/null || echo arm64-v8a)
  mapfile -t fdroid < <(nix eval "${nixargs[@]}" "$attr.config.apps.fdroid.packages" --json | jq -r '.[]')
  mapfile -t fspecs < <(nix eval "${nixargs[@]}" "$attr.config.apps.fdroid.repos" --json | jq -r '
    to_entries[] | .value.url as $u | .value.packages[] | "--fdroid\n\(.)=\($u)"')
  mapfile -t relspecs < <(nix eval "${nixargs[@]}" "$attr.config.apps.release" --json | jq -r '
    to_entries[] | if .value.github != null
      then "--github\n\(.key)=\(.value.github)"
      else "--gitea\n\(.key)=\(.value.gitea)" end')
  exec bash "$src/scripts/update-lock.sh" --abi "$abi" "${fdroid[@]}" "${fspecs[@]}" "${relspecs[@]}"
  ;;
import)
  exec bash "$src/scripts/import.sh" "${engine_args[@]}"
  ;;
*)
  echo "unknown command: $cmd" >&2
  exit 2
  ;;
esac
