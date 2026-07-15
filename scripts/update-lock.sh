#!/usr/bin/env bash
# Resolve F-Droid packages to pinned {versionCode, versionName, url, sha256}
# and write the lock file Nix reads to fetch APKs into the store.
#
# Usage: update-lock.sh --lock apps.lock.json [--abi arm64-v8a] [--replace] \
#          [pkg ...] [--fdroid pkg repo-url fingerprint ...] [--github pkg=owner/repo ...] \
#          [--gitea pkg=host/owner/repo ...]
#   Plain pkg args resolve against f-droid.org; --fdroid pins a package to a
#   third-party F-Droid repo and authenticates its signed entry.jar using the
#   repository certificate's SHA-256 fingerprint (64 hex characters).
#   With no packages given, refreshes every package already in the lock,
#   keeping the lock's recorded ABI unless --abi overrides it.
#   Resolved entries MERGE into an existing same-ABI lock; --replace rewrites
#   the lock to exactly the given set (android-rebuild update passes it, since
#   the config is the authoritative full set).
#
# Chain of trust: the repository certificate signs entry.jar; entry.json inside
# carries index-v2.json's sha256; each APK's sha256 then lands in the lock for
# Nix fetchurl. Every link is verified before its data is trusted.
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
shopt -s inherit_errexit

repo=https://f-droid.org/repo
# F-Droid's published repository-signing certificate (SHA-256, no separators).
repo_fingerprint=43238d512c1e5eb2d6569f4a3afbf5523418b82e0a3ed1552770abb9a9c9ccab
lock=apps.lock.json
abi=arm64-v8a
abi_set=0
replace=0
US=$'\037'
pkgs=()
fspecs=()
ghspecs=()
gtspecs=()
test_asset=()

inspect_release_asset() { # $1=package $2=downloaded asset $3=display name
  local p=$1 asset=$2 display=$3
  local apkfile=$asset apkpath="" tmp badging got_pkg sha listing
  local -a apkpaths
  sha=$(sha256sum "$asset" | cut -d' ' -f1)
  if [[ $display == *.tar.gz ]]; then
    mapfile -t apkpaths < <(tar -tzf "$asset" | grep '\.apk$' || true)
    [ "${#apkpaths[@]}" -eq 1 ] || { echo "expected exactly one .apk inside $display, found ${#apkpaths[@]}" >&2; return 1; }
    apkpath=${apkpaths[0]}
    if [[ $apkpath == /* || $apkpath == -* ]] || [[ /$apkpath/ == */../* ]]; then
      echo "unsafe .apk archive member: $apkpath" >&2
      return 1
    fi
    listing=$(tar -tzvf "$asset" -- "$apkpath")
    [ "${listing:0:1}" = - ] || { echo ".apk archive member is not a regular file: $apkpath" >&2; return 1; }
    tmp=$(mktemp -d)
    apkfile="$tmp/app.apk"
    tar -xzOf "$asset" -- "$apkpath" > "$apkfile"
  fi
  badging=$(aapt2 dump badging "$apkfile") || { [ -z "${tmp:-}" ] || rm -rf "$tmp"; return 1; }
  [ -z "${tmp:-}" ] || rm -rf "$tmp"
  got_pkg=$(sed -n "s/^package: name='\([^']*\)'.*/\1/p" <<<"$badging")
  [ "$got_pkg" = "$p" ] || { echo "package mismatch: declared $p, APK says $got_pkg" >&2; return 1; }
  jq -n --arg sha "$sha" --arg apkpath "$apkpath" \
    --arg code "$(sed -n "s/.*versionCode='\([0-9]*\)'.*/\1/p" <<<"$badging")" \
    --arg name "$(sed -n "s/.*versionName='\([^']*\)'.*/\1/p" <<<"$badging")" \
    '{sha256: $sha, apkPath: $apkpath, versionCode: ($code | tonumber), versionName: $name}'
}

while [ $# -gt 0 ]; do
  case $1 in
  --lock)
    [ $# -ge 2 ] || { echo "--lock requires a value" >&2; exit 2; }
    lock=$2; shift 2
    ;;
  --abi)
    [ $# -ge 2 ] || { echo "--abi requires a value" >&2; exit 2; }
    abi=$2; abi_set=1; shift 2
    ;;
  --replace)
    replace=1; shift
    ;;
  --fdroid)
    [ $# -ge 4 ] || { echo "--fdroid requires: PACKAGE REPO_URL FINGERPRINT" >&2; exit 2; }
    fspecs+=("${2}${US}${3}${US}${4}")
    shift 4
    ;;
  --github)
    [ $# -ge 2 ] || { echo "--github requires PACKAGE=OWNER/REPO" >&2; exit 2; }
    ghspecs+=("$2"); shift 2
    ;;
  --gitea)
    [ $# -ge 2 ] || { echo "--gitea requires PACKAGE=HOST/OWNER/REPO" >&2; exit 2; }
    gtspecs+=("$2"); shift 2
    ;;
  --inspect-release-asset)
    [ $# -ge 3 ] || { echo "--inspect-release-asset requires PACKAGE ASSET" >&2; exit 2; }
    test_asset=("$2" "$3"); shift 3
    ;;
  *) pkgs+=("$1"); shift ;;
  esac
done
if [ "${#test_asset[@]}" -gt 0 ]; then
  inspect_release_asset "${test_asset[0]}" "${test_asset[1]}" "${test_asset[1]}"
  exit
fi
if [ $(( ${#pkgs[@]} + ${#fspecs[@]} + ${#ghspecs[@]} + ${#gtspecs[@]} )) -eq 0 ] && [ -f "$lock" ]; then
  if ! jq -e '
    (.abi | IN("arm64-v8a", "armeabi-v7a", "x86_64"))
    and (.packages | type == "object" and all(to_entries[];
      (.key | type == "string")
      and (.value | type == "object")
      and (.value.source == null
        or (.value.source | type == "string" and test("^(fdroid:|github:|gitea:).+")))
      and (if (.value.source // "" | startswith("fdroid:"))
        then (.value.repoFingerprint | type == "string" and test("^[0-9A-Fa-f]{64}$"))
        else true end)))
  ' "$lock" >/dev/null; then
    echo "cannot refresh malformed lock: $lock" >&2
    exit 1
  fi
  refresh=$(jq -c '
    {
      plain: [.packages | to_entries[] | select(.value.source == null) | .key],
      fdroid: [.packages | to_entries[] | select(.value.source // "" | startswith("fdroid:"))
        | [.key, (.value.source | sub("^fdroid:"; "")), .value.repoFingerprint]],
      github: [.packages | to_entries[] | select(.value.source // "" | startswith("github:"))
        | "\(.key)=\(.value.source | sub("^github:"; ""))"],
      gitea: [.packages | to_entries[] | select(.value.source // "" | startswith("gitea:"))
        | "\(.key)=\(.value.source | sub("^gitea:"; ""))"]
    }
  ' "$lock")
  mapfile -t pkgs < <(jq -r '.plain[]' <<<"$refresh")
  while IFS=$'\t' read -r p r fp; do
    fspecs+=("${p}${US}${r}${US}${fp}")
  done < <(jq -r '.fdroid[] | @tsv' <<<"$refresh")
  mapfile -t ghspecs < <(jq -r '.github[]' <<<"$refresh")
  mapfile -t gtspecs < <(jq -r '.gitea[]' <<<"$refresh")
  [ "$abi_set" -eq 1 ] || abi=$(jq -r '.abi' "$lock")
fi
[ $(( ${#pkgs[@]} + ${#fspecs[@]} + ${#ghspecs[@]} + ${#gtspecs[@]} )) -gt 0 ] || { echo "no packages to lock" >&2; exit 1; }

# Entries resolved for one ABI must never silently coexist with (or silently
# drop) entries locked for another.
existing='{}'
if [ "$replace" -eq 0 ] && [ -f "$lock" ]; then
  prev_abi=$(jq -r '.abi // empty' "$lock")
  if [ "$prev_abi" != "$abi" ]; then
    echo "cannot merge into $lock: it targets abi '${prev_abi:-unknown}', not '$abi' — pass --replace to rewrite it" >&2
    exit 1
  fi
  existing=$(jq '.packages // {}' "$lock")
fi

cache=${XDG_CACHE_HOME:-$HOME/.cache}/nix-android
mkdir -p "$cache"

# Fetch a repo's index-v2 through its signed entry.jar, cached per repo.
fetch_index() { # $1=repo-url $2=expected-cert-sha256 → verified index path
  local r=$1 expected=${2,,} slug entry_jar entry verify got want index index_tmp name tmp
  [[ $expected =~ ^[0-9a-f]{64}$ ]] || { echo "invalid repository fingerprint for $r" >&2; return 1; }
  slug=$(printf '%s' "$r" | sha256sum | cut -c1-16)
  entry_jar="$cache/entry-$slug.jar"
  index="$cache/index-$slug.json"
  tmp="$entry_jar.tmp.$$"
  if ! curl -fsS "$r/entry.jar" -o "$tmp"; then
    rm -f "$tmp"
    echo "failed to fetch signed entry.jar from $r" >&2
    return 1
  fi
  if ! verify=$(jarsigner -verify -verbose "$tmp" 2>&1); then
    rm -f "$tmp"
    echo "invalid entry.jar signature for $r" >&2
    return 1
  fi
  if ! grep -Eq '^sm[[:space:]].* entry\.json$' <<<"$verify"; then
    rm -f "$tmp"
    echo "entry.json is not covered by the entry.jar signature for $r" >&2
    return 1
  fi
  if [ "$(unzip -Z1 "$tmp" | grep -cx 'entry.json')" -ne 1 ]; then
    rm -f "$tmp"
    echo "entry.jar must contain exactly one entry.json for $r" >&2
    return 1
  fi
  got=$(keytool -printcert -jarfile "$tmp" 2>/dev/null | sed -n 's/^[[:space:]]*SHA256: //p' | tr -d ':[:space:]' | tr '[:upper:]' '[:lower:]' | sort -u)
  if [ "$got" != "$expected" ]; then
    rm -f "$tmp"
    echo "repository fingerprint mismatch for $r: $got != $expected" >&2
    return 1
  fi
  mv "$tmp" "$entry_jar"
  entry=$(unzip -p "$entry_jar" entry.json)
  want=$(jq -r '.index.sha256' <<<"$entry")
  name=$(jq -r '.index.name' <<<"$entry")
  if [ ! -f "$index" ] || [ "$(sha256sum "$index" | cut -d' ' -f1)" != "$want" ]; then
    echo "fetching $r$name..." >&2
    index_tmp="$index.tmp.$$"
    if ! curl -fsS "$r$name" -o "$index_tmp"; then
      rm -f "$index_tmp"
      echo "failed to fetch $r$name" >&2
      return 1
    fi
    got=$(sha256sum "$index_tmp" | cut -d' ' -f1)
    if [ "$got" != "$want" ]; then
      rm -f "$index_tmp"
      echo "index sha256 mismatch for $r: $got != $want" >&2
      return 1
    fi
    mv "$index_tmp" "$index"
  fi
  echo "$index"
}

resolve_fdroid() { # $1=pkg $2=repo-url $3=fingerprint $4=source-tag-or-empty
  local p=$1 r=$2 fp=${3,,} srctag=$4 index
  index=$(fetch_index "$r" "$fp")
  jq --arg p "$p" --arg abi "$abi" --arg repo "$r" --arg fp "$fp" --arg src "$srctag" '
    .packages[$p] // error("package not in index \($repo): \($p)")
    | (.metadata.preferredSigner // null) as $preferred
    | .versions | to_entries | map(.value)
    | map(select((.releaseChannels // []) | length == 0))
    | map(select((.manifest.nativecode // []) as $n | ($n | length == 0) or ($n | index($abi))))
    | if $preferred == null then .
      | ([.[].manifest.signer.sha256[]] | unique) as $signers
      | if ($signers | length) == 1 then .
        else error("multiple signing lineages without metadata.preferredSigner: \($p)") end
      else map(select((.manifest.signer.sha256 // []) | index($preferred)))
      end
    | sort_by(-.manifest.versionCode) | .[0]
    // error("no stable \($abi)-compatible version from the preferred signing lineage: \($p)")
    | {($p): ({
        versionCode: .manifest.versionCode,
        versionName: .manifest.versionName,
        url: ($repo + .file.name),
        sha256: .file.sha256,
        repoFingerprint: $fp,
        signerSha256: (.manifest.signer.sha256 // error("version has no signer metadata: \($p)")),
        preferredSigner: $preferred,
      } + (if $src != "" then {source: $src} else {} end))}' "$index"
}

resolved=$({
  for p in "${pkgs[@]}"; do
    resolve_fdroid "$p" "$repo" "$repo_fingerprint" ""
  done
  for spec in "${fspecs[@]}"; do
    IFS=$US read -r p rurl fp <<<"$spec"
    resolve_fdroid "$p" "$rurl" "$fp" "fdroid:$rurl"
  done

  # Shared resolver for GitHub + Gitea releases (compatible asset JSON shape).
  # Assets may be bare .apk or a .tar.gz containing one (recorded as apkPath).
  resolve_release() { # $1=pkg $2=api-url $3=source-tag
    local p=$1 api=$2 srctag=$3 rel asset asset_name url tmp inspected apkpath sha
    rel=$(curl --proto '=https' --tlsv1.2 -fsS "$api")
    # Prefer a universal APK (no abi in the name) → abi-suffixed APK →
    # abi-matching .tar.gz → universal .tar.gz.
    asset=$(jq -c --arg abi "$abi" '
      def architecture: "arm64|aarch64|armeabi|armv7|x86|x64|amd64";
      def wanted:
        if $abi == "arm64-v8a" then "arm64|aarch64"
        elif $abi == "armeabi-v7a" then "armeabi|armv7"
        else "x86_64|x64|amd64" end;
      [.assets[] | select(.name | endswith(".apk"))] as $apks
      | [.assets[] | select(.name | endswith(".tar.gz"))] as $tars
      | ([$apks[] | select(.name | test(architecture; "i") | not)]
         + [$apks[] | select(.name | test(wanted; "i"))]
         + [$tars[] | select(.name | test(wanted; "i"))]
         + [$tars[] | select(.name | test(architecture; "i") | not)])
      | .[0] // error("no suitable .apk/.tar.gz asset")
      | {name, url: .browser_download_url}' <<<"$rel")
    asset_name=$(jq -r .name <<<"$asset")
    url=$(jq -r .url <<<"$asset")
    [[ $url == https://* ]] || { echo "release asset URL is not HTTPS: $url" >&2; exit 1; }
    tmp=$(mktemp -d)
    curl --proto '=https' --tlsv1.2 -fsSL "$url" -o "$tmp/asset"
    inspected=$(inspect_release_asset "$p" "$tmp/asset" "$asset_name")
    rm -rf "$tmp"
    sha=$(jq -r .sha256 <<<"$inspected")
    apkpath=$(jq -r .apkPath <<<"$inspected")
    jq -n --arg p "$p" --arg src "$srctag" --arg url "$url" --arg sha "$sha" --arg apkpath "$apkpath" \
      --arg code "$(jq -r .versionCode <<<"$inspected")" \
      --arg name "$(jq -r .versionName <<<"$inspected")" \
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

expected=$(( ${#pkgs[@]} + ${#fspecs[@]} + ${#ghspecs[@]} + ${#gtspecs[@]} ))
actual=$(jq -r 'length' <<<"$resolved")
[ "$actual" -eq "$expected" ] || { echo "resolved $actual unique packages, expected $expected — duplicate or missing declaration" >&2; exit 1; }

lock_tmp="$lock.tmp.$$"
trap 'rm -f "$lock_tmp"' EXIT
jq -n --argjson existing "$existing" --argjson packages "$resolved" --arg abi "$abi" --arg ts "$(date +%s)" \
  '{abi: $abi, lockedAt: ($ts | tonumber), packages: ($existing + $packages)}' > "$lock_tmp"
mv "$lock_tmp" "$lock"
trap - EXIT
echo "wrote $lock ($(jq -r '.packages | length' "$lock") packages, abi=$abi)"
