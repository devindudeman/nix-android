#!/usr/bin/env bash
# Resolve F-Droid packages to pinned {versionCode, versionName, url, sha256}
# and write the lock file Nix reads to fetch APKs into the store.
#
# Usage: update-lock.sh --lock apps.lock.json [--abi arm64-v8a] pkg [pkg...]
#   With no packages given, refreshes every package already in the lock.
#
# Chain of trust: entry.json carries index-v2.json's sha256; we verify it
# before extracting, and each APK's sha256 lands in the lock for Nix fetchurl.
# Stable-only: versions with a non-empty releaseChannels (e.g. Beta) are
# skipped. ABI: versions are eligible if they have no native code or include
# the requested ABI (arm64-v8a = real phones; x86_64 = the emulator bench).
set -euo pipefail

repo=https://f-droid.org/repo
lock=apps.lock.json
abi=arm64-v8a
pkgs=()
while [ $# -gt 0 ]; do
  case $1 in
  --lock) lock=$2; shift 2 ;;
  --abi) abi=$2; shift 2 ;;
  *) pkgs+=("$1"); shift ;;
  esac
done
if [ ${#pkgs[@]} -eq 0 ] && [ -f "$lock" ]; then
  mapfile -t pkgs < <(jq -r '.packages | keys[]' "$lock")
fi
[ ${#pkgs[@]} -gt 0 ] || { echo "no packages to lock" >&2; exit 1; }

cache=${XDG_CACHE_HOME:-$HOME/.cache}/nix-android
mkdir -p "$cache"

entry=$(curl -fsS "$repo/entry.json")
want=$(jq -r '.index.sha256' <<<"$entry")
index="$cache/index-v2.json"
if [ ! -f "$index" ] || [ "$(sha256sum "$index" | cut -d' ' -f1)" != "$want" ]; then
  echo "fetching index-v2.json…" >&2
  curl -fsS "$repo/index-v2.json" -o "$index"
  got=$(sha256sum "$index" | cut -d' ' -f1)
  [ "$got" = "$want" ] || { echo "index sha256 mismatch: $got != $want" >&2; exit 1; }
fi

resolved=$(for p in "${pkgs[@]}"; do
  jq --arg p "$p" --arg abi "$abi" --arg repo "$repo" '
    .packages[$p] // error("package not in index: \($p)")
    | .versions | to_entries | map(.value)
    | map(select((.releaseChannels // []) | length == 0))
    | map(select((.manifest.nativecode // []) as $n | ($n | length == 0) or ($n | index($abi))))
    | sort_by(-.manifest.versionCode) | .[0]
    // error("no stable \($abi)-compatible version: \($p)")
    | {($p): {
        versionCode: .manifest.versionCode,
        versionName: .manifest.versionName,
        url: ($repo + .file.name),
        sha256: .file.sha256,
      }}' "$index"
done | jq -s 'add')

jq -n --argjson packages "$resolved" --arg abi "$abi" \
  --arg ts "$(jq -r '.timestamp' <<<"$entry")" \
  '{abi: $abi, indexTimestamp: ($ts | tonumber), packages: $packages}' > "$lock"
echo "wrote $lock ($(jq -r '.packages | length' "$lock") packages, abi=$abi)"
