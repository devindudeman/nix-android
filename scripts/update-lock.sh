#!/usr/bin/env bash
# Resolve F-Droid packages to pinned {versionCode, versionName, url, sha256}
# and write the lock file Nix reads to fetch APKs into the store.
#
# Usage: update-lock.sh --lock apps.lock.json [--abi arm64-v8a] [--replace] \
#          [pkg ...] [--fdroid pkg repo-url fingerprint ...] [--github pkg=owner/repo ...] \
#          [--gitea pkg=host/owner/repo ...] [--url pkg=https://... ...] \
#          [--urljson pkg=https://... ...] [--html pkg=page-url link-regex ...] \
#          [--allow-signer-rotation pkg ...]
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
#
# Direct vendor URLs (--url): the URL is fetched as-is (HTTPS only), must
# resolve to a single APK (or a .tar.gz containing one), and gets the same
# aapt2 package-id and apksigner checks. --urljson fetches a small vendor
# update-manifest JSON first and follows its .url (the schema Signal publishes
# at updates.signal.org/android/latest.json); a sha256sum field, when present,
# is cross-checked against the downloaded APK. Both lanes have only TLS-to-
# vendor plus the recorded signer as trust anchors, so a refresh REFUSES a
# signer change unless the package is listed via --allow-signer-rotation —
# verify the vendor actually announced a key rotation before passing it.
#
# HTML discovery (--html): for vendors with versioned APK links on a page but
# no stable URL or manifest (e.g. Steam). The page only NOMINATES a link:
# exactly one page link must match the extended regex (zero or several fail
# loudly — tighten the regex, no sort heuristics), and the download then gets
# the identical package-id/signature/continuity treatment. A page redesign
# breaks the update loudly; it can never install the wrong app.
set -euo pipefail
shopt -s inherit_errexit

# shellcheck source-path=SCRIPTDIR
# shellcheck source=fdroid-eligibility.sh
source "$(dirname "${BASH_SOURCE[0]}")/fdroid-eligibility.sh"

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
uspecs=()
ujspecs=()
hspecs=()
allow_rotation=()
test_asset=()
fetch_index_spec=()

inspect_release_asset() { # $1=package $2=downloaded asset $3=display name
  local p=$1 asset=$2 display=$3
  local apkfile=$asset apkpath="" tmp badging got_pkg sha listing
  local -a apkpaths
  sha=$(sha256sum "$asset" | cut -d' ' -f1)
  if [[ $display == *.tar.gz ]]; then
    # Bound enumeration so a decompression bomb with millions of members cannot
    # stall the scan; a real single-apk archive lists far fewer entries.
    local entries member_size
    entries=$(tar -tzf "$asset" 2>/dev/null | head -n 10001 | wc -l)
    [ "$entries" -le 10000 ] || { echo "archive has too many members: $display" >&2; return 1; }
    mapfile -t apkpaths < <(tar -tzf "$asset" 2>/dev/null | grep '\.apk$' || true)
    [ "${#apkpaths[@]}" -eq 1 ] || { echo "expected exactly one .apk inside $display, found ${#apkpaths[@]}" >&2; return 1; }
    apkpath=${apkpaths[0]}
    if [[ $apkpath == /* || $apkpath == -* ]] || [[ /$apkpath/ == */../* ]]; then
      echo "unsafe .apk archive member: $apkpath" >&2
      return 1
    fi
    listing=$(tar -tzvf "$asset" -- "$apkpath")
    [ "${listing:0:1}" = - ] || { echo ".apk archive member is not a regular file: $apkpath" >&2; return 1; }
    # Cap the uncompressed member size (field 3 of tar -tzv) so a small archive
    # cannot expand into an arbitrarily large APK on disk.
    member_size=$(awk 'NR==1{print $3}' <<<"$listing")
    [[ $member_size =~ ^[0-9]+$ ]] && [ "$member_size" -le $((300 * 1024 * 1024)) ] \
      || { echo "archive member size unknown or exceeds 300M: $apkpath" >&2; return 1; }
    tmp=$(mktemp -d)
    apkfile="$tmp/app.apk"
    tar -xzOf "$asset" -- "$apkpath" > "$apkfile"
  fi
  badging=$(aapt2 dump badging "$apkfile") || { [ -z "${tmp:-}" ] || rm -rf "$tmp"; return 1; }
  got_pkg=$(sed -n "s/^package: name='\([^']*\)'.*/\1/p" <<<"$badging")
  [ "$got_pkg" = "$p" ] || { echo "package mismatch: declared $p, APK says $got_pkg" >&2; [ -z "${tmp:-}" ] || rm -rf "$tmp"; return 1; }
  # Source identity is the signing certificate, not the package id. Require a
  # valid signature and record every signer SHA-256 so callers can confirm the
  # signer they trust (package-id match alone is only compatibility).
  local certs signers_json
  if ! certs=$(apksigner verify --print-certs "$apkfile" 2>/dev/null); then
    echo "APK signature did not verify for $p" >&2; [ -z "${tmp:-}" ] || rm -rf "$tmp"; return 1
  fi
  [ -z "${tmp:-}" ] || rm -rf "$tmp"
  # apksigner prints either "Signer #N certificate SHA-256 digest: <hex>" or,
  # for v3.1 key rotation, "Signer (minSdkVersion=.., maxSdkVersion=..)
  # certificate SHA-256 digest: <hex>". Match both by anchoring on the digest
  # line, not the signer prefix; the {64} length excludes SHA-1/MD5 lines.
  signers_json=$(sed -n 's/.*certificate SHA-256 digest:[[:space:]]*\([0-9A-Fa-f]\{64\}\).*/\1/p' <<<"$certs" \
    | tr 'A-F' 'a-f' | sort -u | jq -R . | jq -sc .)
  [ "$(jq -r 'length' <<<"$signers_json")" -gt 0 ] \
    || { echo "no APK signer certificate for $p" >&2; return 1; }
  jq -n --arg sha "$sha" --arg apkpath "$apkpath" --argjson signers "$signers_json" \
    --arg code "$(sed -n "s/.*versionCode='\([0-9]*\)'.*/\1/p" <<<"$badging")" \
    --arg name "$(sed -n "s/.*versionName='\([^']*\)'.*/\1/p" <<<"$badging")" \
    '{sha256: $sha, apkPath: $apkpath, versionCode: ($code | tonumber), versionName: $name, signerSha256: $signers}'
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
  --url)
    [ $# -ge 2 ] && [[ $2 == *=* ]] || { echo "--url requires PACKAGE=HTTPS_URL" >&2; exit 2; }
    uspecs+=("$2"); shift 2
    ;;
  --urljson)
    [ $# -ge 2 ] && [[ $2 == *=* ]] || { echo "--urljson requires PACKAGE=HTTPS_URL" >&2; exit 2; }
    ujspecs+=("$2"); shift 2
    ;;
  --html)
    [ $# -ge 3 ] && [[ $2 == *=* ]] || { echo "--html requires PACKAGE=PAGE_URL LINK_REGEX" >&2; exit 2; }
    hspecs+=("${2}${US}${3}"); shift 3
    ;;
  --allow-signer-rotation)
    [ $# -ge 2 ] || { echo "--allow-signer-rotation requires PACKAGE" >&2; exit 2; }
    allow_rotation+=("$2"); shift 2
    ;;
  --inspect-release-asset)
    [ $# -ge 3 ] || { echo "--inspect-release-asset requires PACKAGE ASSET" >&2; exit 2; }
    test_asset=("$2" "$3"); shift 3
    ;;
  --fetch-index)
    # Print the trust-verified index-v2 path for one repo and exit. Reused by
    # suggest-sources so read-only curation shares this signed entry.jar chain
    # instead of duplicating it.
    [ $# -ge 3 ] || { echo "--fetch-index requires REPO_URL FINGERPRINT" >&2; exit 2; }
    fetch_index_spec=("$2" "$3"); shift 3
    ;;
  *) pkgs+=("$1"); shift ;;
  esac
done
if [ "${#test_asset[@]}" -gt 0 ]; then
  inspect_release_asset "${test_asset[0]}" "${test_asset[1]}" "${test_asset[1]}"
  exit
fi
if [ "${#fetch_index_spec[@]}" -eq 0 ] \
  && [ $(( ${#pkgs[@]} + ${#fspecs[@]} + ${#ghspecs[@]} + ${#gtspecs[@]} + ${#uspecs[@]} + ${#ujspecs[@]} + ${#hspecs[@]} )) -eq 0 ] && [ -f "$lock" ]; then
  if ! jq -e '
    (.abi | IN("arm64-v8a", "armeabi-v7a", "x86_64"))
    and (.packages | type == "object" and all(to_entries[];
      (.key | type == "string")
      and (.value | type == "object")
      and (.value.source == null
        or (.value.source | type == "string" and test("^(fdroid:|github:|gitea:|url:|urljson:|html:).+")))
      and (if (.value.source // "" | startswith("fdroid:"))
        then (.value.repoFingerprint | type == "string" and test("^[0-9A-Fa-f]{64}$"))
        else true end)
      and (if (.value.source // "" | startswith("html:"))
        then (.value.linkFilter | type == "string" and length > 0)
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
        | "\(.key)=\(.value.source | sub("^gitea:"; ""))"],
      url: [.packages | to_entries[] | select(.value.source // "" | startswith("url:"))
        | "\(.key)=\(.value.source | sub("^url:"; ""))"],
      urljson: [.packages | to_entries[] | select(.value.source // "" | startswith("urljson:"))
        | "\(.key)=\(.value.source | sub("^urljson:"; ""))"],
      html: [.packages | to_entries[] | select(.value.source // "" | startswith("html:"))
        | "\(.key)=\(.value.source | sub("^html:"; ""))\u001f\(.value.linkFilter)"]
    }
  ' "$lock")
  mapfile -t pkgs < <(jq -r '.plain[]' <<<"$refresh")
  while IFS=$'\t' read -r p r fp; do
    fspecs+=("${p}${US}${r}${US}${fp}")
  done < <(jq -r '.fdroid[] | @tsv' <<<"$refresh")
  mapfile -t ghspecs < <(jq -r '.github[]' <<<"$refresh")
  mapfile -t gtspecs < <(jq -r '.gitea[]' <<<"$refresh")
  mapfile -t uspecs < <(jq -r '.url[]' <<<"$refresh")
  mapfile -t ujspecs < <(jq -r '.urljson[]' <<<"$refresh")
  while IFS= read -r hspec; do
    [ -n "$hspec" ] && hspecs+=("$hspec")
  done < <(jq -r '.html[]' <<<"$refresh")
  [ "$abi_set" -eq 1 ] || abi=$(jq -r '.abi' "$lock")
fi
[ "${#fetch_index_spec[@]}" -gt 0 ] \
  || [ $(( ${#pkgs[@]} + ${#fspecs[@]} + ${#ghspecs[@]} + ${#gtspecs[@]} + ${#uspecs[@]} + ${#ujspecs[@]} + ${#hspecs[@]} )) -gt 0 ] \
  || { echo "no packages to lock" >&2; exit 1; }

# Pre-update snapshot for the url/urljson signer-continuity check; tolerate a
# missing or malformed lock (the malformed-refresh guard above already handles
# the refresh path).
old_packages='{}'
if [ -f "$lock" ]; then
  old_packages=$(jq '.packages // {}' "$lock" 2>/dev/null) || old_packages='{}'
fi

# Entries resolved for one ABI must never silently coexist with (or silently
# drop) entries locked for another.
existing='{}'
if [ "${#fetch_index_spec[@]}" -eq 0 ] && [ "$replace" -eq 0 ] && [ -f "$lock" ]; then
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

if [ "${#fetch_index_spec[@]}" -gt 0 ]; then
  fetch_index "${fetch_index_spec[0]}" "${fetch_index_spec[1]}"
  exit
fi

resolve_fdroid() { # $1=pkg $2=repo-url $3=fingerprint $4=source-tag-or-empty
  local p=$1 r=$2 fp=${3,,} srctag=$4 index
  index=$(fetch_index "$r" "$fp")
  # Version/lineage selection lives in FDROID_ELIGIBILITY_JQ, shared with
  # suggest-sources so availability never diverges from lockability.
  jq --arg p "$p" --arg abi "$abi" --arg repo "$r" --arg fp "$fp" --arg src "$srctag" \
    "$FDROID_ELIGIBILITY_JQ"'
    require_packages_object
    | .packages[$p] // error("package not in index \($repo): \($p)")
    | . as $pkg
    | (.metadata.preferredSigner // null) as $preferred
    | if $preferred == null
        and (($pkg | stable_abi_versions($abi)) | [.[].manifest.signer.sha256[]] | unique | length) > 1
        then error("multiple signing lineages without metadata.preferredSigner: \($p)") else . end
    | ($pkg | lockable_version($abi))
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
    local p=$1 api=$2 srctag=$3 rel assets asset_name url tmp inspected apkpath sha matched tried=0
    rel=$(curl --proto '=https' --tlsv1.2 -fsS --max-time 60 --max-filesize 10M "$api")
    # Rank candidate assets: universal APK (no abi in the name) → abi-suffixed
    # APK → abi-matching .tar.gz → universal .tar.gz. A release may carry
    # several flavors (e.g. app-release.apk and app-fdroid-release.apk); the
    # package id — not the filename — decides, so try them in order until one
    # matches instead of guessing the first.
    assets=$(jq -c --arg abi "$abi" '
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
      | map({name, url: .browser_download_url})' <<<"$rel")
    [ "$(jq -r 'length' <<<"$assets")" -gt 0 ] || { echo "no suitable .apk/.tar.gz asset in release for $p" >&2; exit 1; }
    tmp=$(mktemp -d)
    matched=
    # Bound the work an untrusted release can impose: at most 8 candidate
    # downloads, each time- and size-capped.
    while IFS=$'\t' read -r asset_name url; do
      [ -z "$asset_name" ] && continue
      [[ $url == https://* ]] || { echo "release asset URL is not HTTPS: $url" >&2; rm -rf "$tmp"; exit 1; }
      [ "$tried" -lt 8 ] || { echo "gave up after $tried release assets for $p" >&2; break; }
      tried=$((tried + 1))
      curl --proto '=https' --tlsv1.2 -fsSL --max-time 300 --max-filesize 500M "$url" -o "$tmp/asset" \
        || { echo "download failed or exceeded limits for $asset_name" >&2; continue; }
      # inspect_release_asset returns non-zero (not exit) on a package-id,
      # signature, or archive mismatch, so a wrong-flavor asset advances the loop.
      if inspected=$(inspect_release_asset "$p" "$tmp/asset" "$asset_name" 2>/dev/null); then
        matched=$url
        break
      fi
    done < <(jq -r '.[] | [.name, .url] | @tsv' <<<"$assets")
    rm -rf "$tmp"
    [ -n "$matched" ] || { echo "no release asset matched package id $p (tried $tried)" >&2; exit 1; }
    sha=$(jq -r .sha256 <<<"$inspected")
    apkpath=$(jq -r .apkPath <<<"$inspected")
    jq -n --arg p "$p" --arg src "$srctag" --arg url "$matched" --arg sha "$sha" --arg apkpath "$apkpath" \
      --argjson signers "$(jq -c .signerSha256 <<<"$inspected")" \
      --arg code "$(jq -r .versionCode <<<"$inspected")" \
      --arg name "$(jq -r .versionName <<<"$inspected")" \
      '{($p): ({versionCode: ($code | tonumber), versionName: $name, url: $url, sha256: $sha, signerSha256: $signers, source: $src}
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

  # Direct vendor URL: no discovery API — the declared URL is downloaded and
  # inspected exactly like a release asset (package id, signature, archive
  # safety all enforced by inspect_release_asset).
  resolve_url_direct() { # $1=pkg $2=apk-url $3=source-tag $4=recorded-url
    local p=$1 url=$2 srctag=$3 rec=$4 tmp inspected
    [[ $url == https://* ]] || { echo "vendor APK URL is not HTTPS for $p: $url" >&2; exit 1; }
    tmp=$(mktemp -d)
    curl --proto '=https' --tlsv1.2 -fsSL --max-time 300 --max-filesize 500M "$url" -o "$tmp/asset" \
      || { echo "download failed or exceeded limits for $p: $url" >&2; rm -rf "$tmp"; exit 1; }
    inspected=$(inspect_release_asset "$p" "$tmp/asset" "$url") || { rm -rf "$tmp"; exit 1; }
    rm -rf "$tmp"
    jq --arg p "$p" --arg src "$srctag" --arg url "$rec" \
      '{($p): ({versionCode: .versionCode, versionName: .versionName, url: $url, sha256: .sha256, signerSha256: .signerSha256, source: $src}
               + (if .apkPath != "" then {apkPath: .apkPath} else {} end))}' <<<"$inspected"
  }

  for spec in "${uspecs[@]}"; do
    p=${spec%%=*} u=${spec#*=}
    resolve_url_direct "$p" "$u" "url:$u" "$u"
  done
  for spec in "${ujspecs[@]}"; do
    p=${spec%%=*} ju=${spec#*=}
    [[ $ju == https://* ]] || { echo "update-manifest URL is not HTTPS for $p: $ju" >&2; exit 1; }
    manifest=$(curl --proto '=https' --tlsv1.2 -fsS --max-time 60 --max-filesize 1M "$ju") \
      || { echo "failed to fetch update manifest for $p: $ju" >&2; exit 1; }
    apk_url=$(jq -er '.url' <<<"$manifest") || { echo "update manifest for $p has no .url: $ju" >&2; exit 1; }
    # The manifest points at a versioned (immutable) APK; record THAT url so a
    # stale lock still fetches, while the source tag binds the manifest url.
    entry=$(resolve_url_direct "$p" "$apk_url" "urljson:$ju" "$apk_url")
    expected_sha=$(jq -r '.sha256sum // empty' <<<"$manifest")
    if [ -n "$expected_sha" ]; then
      got_sha=$(jq -r --arg p "$p" '.[$p].sha256' <<<"$entry")
      [ "${expected_sha,,}" = "$got_sha" ] \
        || { echo "update manifest sha256sum mismatch for $p: manifest ${expected_sha,,} != downloaded $got_sha" >&2; exit 1; }
    fi
    printf '%s\n' "$entry"
  done
  for spec in "${hspecs[@]}"; do
    IFS=$US read -r pu lf <<<"$spec"
    p=${pu%%=*} page=${pu#*=}
    [[ $page == https://* ]] || { echo "discovery page URL is not HTTPS for $p: $page" >&2; exit 1; }
    body=$(curl --proto '=https' --tlsv1.2 -fsSL --max-time 60 --max-filesize 5M "$page") \
      || { echo "failed to fetch discovery page for $p: $page" >&2; exit 1; }
    # The page only nominates a link; everything downstream is verified.
    mapfile -t matched < <(grep -oiE "href=[\"'][^\"']+[\"']" <<<"$body" \
      | sed -E "s/^[hH][rR][eE][fF]=[\"']//; s/[\"']\$//" \
      | { grep -E -- "$lf" || true; } | sort -u)
    if [ "${#matched[@]}" -ne 1 ]; then
      echo "link filter for $p matched ${#matched[@]} page link(s), need exactly 1 — adjust linkFilter" >&2
      printf '  %s\n' "${matched[@]:0:8}" >&2
      exit 1
    fi
    link=${matched[0]}
    # Root-relative links resolve against the page's origin; anything else
    # must already be absolute HTTPS (resolve_url_direct enforces it).
    if [[ $link == /* ]]; then
      origin=$(sed -E 's#^(https://[^/]+).*#\1#' <<<"$page")
      link="$origin$link"
    fi
    entry=$(resolve_url_direct "$p" "$link" "html:$page" "$link")
    jq --arg p "$p" --arg lf "$lf" '.[$p] += {linkFilter: $lf}' <<<"$entry"
  done
} | jq -s 'add')

expected=$(( ${#pkgs[@]} + ${#fspecs[@]} + ${#ghspecs[@]} + ${#gtspecs[@]} + ${#uspecs[@]} + ${#ujspecs[@]} + ${#hspecs[@]} ))
actual=$(jq -r 'length' <<<"$resolved")
[ "$actual" -eq "$expected" ] || { echo "resolved $actual unique packages, expected $expected — duplicate or missing declaration" >&2; exit 1; }

# url/urljson lanes have only TLS + the recorded signer as trust anchors:
# refuse to re-lock a package whose signer set no longer overlaps the previous
# lock's, unless explicitly allowed (a verified vendor key rotation).
allow_json=$(printf '%s\n' ${allow_rotation[@]+"${allow_rotation[@]}"} | jq -R . | jq -sc 'map(select(length > 0))')
rotated=$(jq -nc --argjson old "$old_packages" --argjson new "$resolved" --argjson allow "$allow_json" '
  [$new | to_entries[]
    | select(.value.source // "" | test("^(url(json)?|html):"))
    | select(.key as $k | ($allow | index($k)) == null)
    | select(($old[.key] // null) != null)
    | select(($old[.key].source // "" | test("^(url(json)?|html):")))
    | select((($old[.key].signerSha256 // []) | length) > 0)
    | select((.value.signerSha256 - ($old[.key].signerSha256 // [])) == .value.signerSha256)
    | "\(.key): locked \($old[.key].signerSha256 | join(",")) -> now \(.value.signerSha256 | join(","))"]')
if [ "$(jq -r 'length' <<<"$rotated")" -gt 0 ]; then
  echo "signer changed for direct-URL package(s) — refusing to re-lock:" >&2
  jq -r '.[]' <<<"$rotated" >&2
  echo "if the vendor really rotated its signing key, re-run with --allow-signer-rotation PACKAGE" >&2
  exit 1
fi

lock_tmp="$lock.tmp.$$"
trap 'rm -f "$lock_tmp"' EXIT
jq -n --argjson existing "$existing" --argjson packages "$resolved" --arg abi "$abi" --arg ts "$(date +%s)" \
  '{abi: $abi, lockedAt: ($ts | tonumber), packages: ($existing + $packages)}' > "$lock_tmp"
mv "$lock_tmp" "$lock"
trap - EXIT
echo "wrote $lock ($(jq -r '.packages | length' "$lock") packages, abi=$abi)"
