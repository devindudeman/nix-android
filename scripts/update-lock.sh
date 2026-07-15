#!/usr/bin/env bash
# Resolve F-Droid packages to pinned {versionCode, versionName, url, sha256}
# and write the lock file Nix reads to fetch APKs into the store.
#
# Usage: update-lock.sh --lock apps.lock.json [--abi arm64-v8a] \
#          [pkg ...] [--fdroid pkg=repo-url ...] [--github pkg=owner/repo ...] \
#          [--gitea pkg=host/owner/repo ...]
#   Plain pkg args resolve against f-droid.org; --fdroid pins a package to a
#   third-party F-Droid repo (same index-v2 format, per-repo verified cache).
#   With no packages given, refreshes every package already in the lock.
#
# Chain of trust: entry.json carries index-v2.json's sha256; we verify it
# before extracting, and each APK's sha256 lands in the lock for Nix fetchurl.
# Stable-only: versions with a non-empty releaseChannels (e.g. Beta) are
# skipped. ABI: versions are eligible if they have no native code or include
# the requested ABI (arm64-v8a = real phones; x86_64 = the emulator bench).
#
# GitHub releases (--github): latest release's .apk asset (prefer universal,
# else ABI-suffixed); the APK is downloaded once and aapt2 reads versionCode/
# versionName out of it AND verifies the manifest package id matches the
# declared one — a wrong `pkg=owner/repo` mapping fails loudly here, not on
# the device.
set -euo pipefail

repo=https://f-droid.org/repo
lock=apps.lock.json
abi=arm64-v8a
pkgs=()
fspecs=()
ghspecs=()
gtspecs=()
while [ $# -gt 0 ]; do
  case $1 in
  --lock) lock=$2; shift 2 ;;
  --abi) abi=$2; shift 2 ;;
  --fdroid) fspecs+=("$2"); shift 2 ;;
  --github) ghspecs+=("$2"); shift 2 ;;
  --gitea) gtspecs+=("$2"); shift 2 ;;
  *) pkgs+=("$1"); shift ;;
  esac
done
if [ $(( ${#pkgs[@]} + ${#fspecs[@]} + ${#ghspecs[@]} + ${#gtspecs[@]} )) -eq 0 ] && [ -f "$lock" ]; then
  mapfile -t pkgs < <(jq -r '.packages | to_entries[] | select(.value.source == null) | .key' "$lock")
  mapfile -t fspecs < <(jq -r '.packages | to_entries[] | select(.value.source // "" | startswith("fdroid:")) | "\(.key)=\(.value.source | sub("^fdroid:"; ""))"' "$lock")
  mapfile -t ghspecs < <(jq -r '.packages | to_entries[] | select(.value.source // "" | startswith("github:")) | "\(.key)=\(.value.source | sub("^github:"; ""))"' "$lock")
  mapfile -t gtspecs < <(jq -r '.packages | to_entries[] | select(.value.source // "" | startswith("gitea:")) | "\(.key)=\(.value.source | sub("^gitea:"; ""))"' "$lock")
fi
[ $(( ${#pkgs[@]} + ${#fspecs[@]} + ${#ghspecs[@]} + ${#gtspecs[@]} )) -gt 0 ] || { echo "no packages to lock" >&2; exit 1; }

cache=${XDG_CACHE_HOME:-$HOME/.cache}/nix-android
mkdir -p "$cache"

# Fetch a repo's index-v2 with the entry.json sha256 chain, cached per repo.
fetch_index() { # $1=repo-url → echoes verified index path
  local r=$1 slug entry want index name
  slug=$(sha256sum <<<"$r" | cut -c1-16)
  index="$cache/index-$slug.json"
  entry=$(curl -fsS "$r/entry.json")
  want=$(jq -r '.index.sha256' <<<"$entry")
  name=$(jq -r '.index.name' <<<"$entry")
  if [ ! -f "$index" ] || [ "$(sha256sum "$index" | cut -d' ' -f1)" != "$want" ]; then
    echo "fetching $r$name…" >&2
    curl -fsS "$r$name" -o "$index"
    local got
    got=$(sha256sum "$index" | cut -d' ' -f1)
    [ "$got" = "$want" ] || { echo "index sha256 mismatch for $r: $got != $want" >&2; exit 1; }
  fi
  echo "$index"
}

resolve_fdroid() { # $1=pkg $2=repo-url $3=source-tag-or-empty
  local p=$1 r=$2 srctag=$3 index
  index=$(fetch_index "$r")
  jq --arg p "$p" --arg abi "$abi" --arg repo "$r" --arg src "$srctag" '
    .packages[$p] // error("package not in index \($repo): \($p)")
    | .versions | to_entries | map(.value)
    | map(select((.releaseChannels // []) | length == 0))
    | map(select((.manifest.nativecode // []) as $n | ($n | length == 0) or ($n | index($abi))))
    | sort_by(-.manifest.versionCode) | .[0]
    // error("no stable \($abi)-compatible version: \($p)")
    | {($p): ({
        versionCode: .manifest.versionCode,
        versionName: .manifest.versionName,
        url: ($repo + .file.name),
        sha256: .file.sha256,
      } + (if $src != "" then {source: $src} else {} end))}' "$index"
}

resolved=$({
  for p in "${pkgs[@]}"; do
    resolve_fdroid "$p" "$repo" ""
  done
  for spec in "${fspecs[@]}"; do
    p=${spec%%=*} rurl=${spec#*=}
    resolve_fdroid "$p" "$rurl" "fdroid:$rurl"
  done

  # Shared resolver for GitHub + Gitea releases (compatible asset JSON shape).
  # Assets may be bare .apk or a .tar.gz containing one (recorded as apkPath).
  resolve_release() { # $1=pkg $2=api-url $3=source-tag
    local p=$1 api=$2 srctag=$3 rel url tmp apkfile apkpath="" sha badging got_pkg
    rel=$(curl -fsS "$api")
    # Prefer a universal APK (no abi in the name) → abi-suffixed APK →
    # abi-matching .tar.gz → universal .tar.gz.
    url=$(jq -r --arg abi "$abi" '
      [.assets[] | select(.name | endswith(".apk"))] as $apks
      | [.assets[] | select(.name | endswith(".tar.gz"))] as $tars
      | ([$apks[] | select(.name | test("arm64|armeabi|x86") | not)]
         + [$apks[] | select(.name | contains($abi))]
         + [$tars[] | select(.name | contains($abi))]
         + [$tars[] | select(.name | test("arm64|armeabi|x86") | not)])
      | .[0].browser_download_url // error("no suitable .apk/.tar.gz asset")' <<<"$rel")
    tmp=$(mktemp -d)
    curl -fsSL "$url" -o "$tmp/asset"
    sha=$(sha256sum "$tmp/asset" | cut -d' ' -f1)
    if [[ $url == *.tar.gz ]]; then
      apkpath=$(tar -tzf "$tmp/asset" | grep '\.apk$' | head -1)
      [ -n "$apkpath" ] || { echo "no .apk inside $url" >&2; exit 1; }
      tar -xzf "$tmp/asset" -C "$tmp" "$apkpath"
      apkfile="$tmp/$apkpath"
    else
      apkfile="$tmp/asset"
    fi
    badging=$(aapt2 dump badging "$apkfile")
    rm -rf "$tmp"
    got_pkg=$(sed -n "s/^package: name='\([^']*\)'.*/\1/p" <<<"$badging")
    [ "$got_pkg" = "$p" ] || { echo "package mismatch for $srctag: declared $p, APK says $got_pkg" >&2; exit 1; }
    jq -n --arg p "$p" --arg src "$srctag" --arg url "$url" --arg sha "$sha" --arg apkpath "$apkpath" \
      --arg code "$(sed -n "s/.*versionCode='\([0-9]*\)'.*/\1/p" <<<"$badging")" \
      --arg name "$(sed -n "s/.*versionName='\([^']*\)'.*/\1/p" <<<"$badging")" \
      '{($p): ({versionCode: ($code | tonumber), versionName: $name, url: $url, sha256: $sha, source: $src}
               + (if $apkpath != "" then {apkPath: $apkpath} else {} end))}'
  }

  for spec in "${ghspecs[@]}"; do
    p=${spec%%=*} gh=${spec#*=}
    resolve_release "$p" "https://api.github.com/repos/$gh/releases/latest" "github:$gh"
  done
  for spec in "${gtspecs[@]}"; do
    p=${spec%%=*} gt=${spec#*=} # host/owner/repo
    host=${gt%%/*} orepo=${gt#*/}
    resolve_release "$p" "https://$host/api/v1/repos/$orepo/releases/latest" "gitea:$gt"
  done
} | jq -s 'add')

jq -n --argjson packages "$resolved" --arg abi "$abi" --arg ts "$(date +%s)" \
  '{abi: $abi, lockedAt: ($ts | tonumber), packages: $packages}' > "$lock"
echo "wrote $lock ($(jq -r '.packages | length' "$lock") packages, abi=$abi)"
