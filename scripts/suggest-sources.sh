#!/usr/bin/env bash
# suggest-sources — read-only curation aid for de-Play migration.
#
# Reads candidate package ids (one per line on stdin: the apps.play and
# apps.attended entries an import produced) and reports which are published on
# a hash-lockable F-Droid source, so they can move off the per-app Play
# install-consent path. It changes nothing: the authoritative verification
# still happens later in `android-rebuild update`, which re-fetches and pins.
#
# GitHub/Gitea releases have no signed package-id -> repo index. --discover
# proposes candidate repos from the crowdsourced Obtainium catalog (opt-in,
# untrusted); a --release-hint PKG=owner/repo (or PKG=host/owner/repo) confirms
# package-id COMPATIBILITY by resolving that release and matching the apk
# package id. That is not source identity — a same-id apk from another signer
# installs on a clean phone, and the signer also governs signature permissions
# and shared-uid identity — so the resolved signer is surfaced for the user to
# confirm, and nothing is auto-promoted from discovery.
#
# Trust: index fetches and release resolution go through the packaged
# update-lock, which authenticates each repo's signed entry.jar / index hash
# and matches the apk package id. Availability is a suggestion; update
# re-verifies before locking.
#
# Usage: suggest-sources.sh --resolver PATH --abi ABI [--repo URL FP LABEL ...]
#        [--discover] [--catalog-base URL] [--release-hint PKG=owner/repo ...]
#        candidate ids arrive on stdin.
set -euo pipefail

# shellcheck source-path=SCRIPTDIR
# shellcheck source=fdroid-eligibility.sh
source "$(dirname "${BASH_SOURCE[0]}")/fdroid-eligibility.sh"

US=$'\037'
# The main-archive fingerprint. Only this repo maps to apps.fdroid.packages;
# every other repo (IzzyOnDroid, a third party) needs apps.fdroid.repos.<name>
# with its url + fingerprint.
official_fdroid_fp=43238d512c1e5eb2d6569f4a3afbf5523418b82e0a3ed1552770abb9a9c9ccab
resolver=${NIX_ANDROID_RESOLVER:-}
abi=arm64-v8a
# Default repos: the main archive and IzzyOnDroid (published fingerprints).
repos=(
  "https://f-droid.org/repo${US}${official_fdroid_fp}${US}f-droid.org"
  "https://apt.izzysoft.de/fdroid/repo${US}3bf0d6abfeae2f401707b6d966be743bf0eee49c2561b9ba39073711f628937a${US}IzzyOnDroid"
)
repos_overridden=0
hints=()   # user-named release candidates: "pkg=owner/repo" or "pkg=host/owner/repo"
discover=0
# The Obtainium crowdsourced catalog, keyed by package id. Untrusted discovery
# data: it only proposes a candidate repo. Verifying that repo checks package-id
# compatibility, not source identity — the user still confirms the signer.
# Overridable for tests.
catalog_base=${NIX_ANDROID_CATALOG_BASE:-https://raw.githubusercontent.com/ImranR98/apps.obtainium.imranr.dev/main/public/data/apps}

while [ $# -gt 0 ]; do
  case $1 in
  --resolver)
    [ $# -ge 2 ] || { echo "--resolver requires a path" >&2; exit 2; }
    resolver=$2; shift 2
    ;;
  --abi)
    [ $# -ge 2 ] || { echo "--abi requires a value" >&2; exit 2; }
    abi=$2; shift 2
    ;;
  --repo)
    [ $# -ge 4 ] || { echo "--repo requires URL FINGERPRINT LABEL" >&2; exit 2; }
    [ "$repos_overridden" -eq 1 ] || repos=()
    repos_overridden=1
    repos+=("${2}${US}${3}${US}${4}"); shift 4
    ;;
  --release-hint)
    # A GitHub/Gitea release repo to VERIFY (not discover): PKG=owner/repo for
    # GitHub, PKG=host/owner/repo for Gitea. GitHub has no package-id→repo
    # index, so a candidate can only be confirmed by resolving its release and
    # matching the apk package id — which is what the real resolver does.
    [ $# -ge 2 ] || { echo "--release-hint requires PKG=owner/repo" >&2; exit 2; }
    hints+=("$2"); shift 2
    ;;
  --discover)
    # Opt-in: look up not-yet-resolved candidates in the Obtainium catalog and
    # propose repos to verify. This sends the candidate package ids to a
    # third-party host over the network — off by default for that reason.
    discover=1; shift
    ;;
  --catalog-base)
    [ $# -ge 2 ] || { echo "--catalog-base requires a URL" >&2; exit 2; }
    catalog_base=$2; shift 2
    ;;
  -h | --help)
    # Print the whole leading comment block, however long it grows.
    awk 'NR==1{next} /^#/{sub(/^# ?/,""); print; next} {exit}' "$0"
    exit 0
    ;;
  *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

[ -n "$resolver" ] || { echo "suggest-sources requires --resolver PATH (or NIX_ANDROID_RESOLVER)" >&2; exit 2; }
[ -x "$resolver" ] || { echo "resolver is not executable: $resolver" >&2; exit 2; }

mapfile -t candidates < <(grep -E '^[A-Za-z0-9_]+(\.[A-Za-z0-9_]+)+$' || true)
if [ "${#candidates[@]}" -eq 0 ]; then
  # A config with no apps.play/apps.attended has nothing to migrate — a valid
  # state, not an error.
  echo "no apps.play or apps.attended entries to check."
  exit 0
fi
# Stable, de-duplicated candidate order.
mapfile -t candidates < <(printf '%s\n' "${candidates[@]}" | sort -u)

# One jq pass per repo (not per package): the index file is the input, and the
# candidate ids arrive as $want. Emit the subset whose lockable_version is
# non-empty — the exact version/lineage the production resolver would pin, so a
# suggestion never outruns what `update` can actually lock.
# shellcheck disable=SC2016  # $abi/$want are jq variables, not shell expansions
available_subset_jq='
  require_packages_object
  | .packages as $pkgs
  | ($want | fromjson)[]
  | . as $p
  | ($pkgs[$p] // null) as $meta
  | select($meta != null)
  | select(($meta | lockable_version($abi)) != null)
  | $p
'
want_json=$(printf '%s\n' "${candidates[@]}" | jq -R . | jq -s -c .)

declare -A hit_label=()   # pkg -> first repo label that has a lockable build
declare -A repo_hits=()   # "label" -> newline list of pkgs (for the config block)
declare -A repo_url=()
declare -A repo_fp=()
checked_labels=()

for spec in "${repos[@]}"; do
  IFS=$US read -r url fp label <<<"$spec"
  repo_url[$label]=$url
  repo_fp[$label]=$fp
  index=$("$resolver" --fetch-index "$url" "$fp") \
    || { echo "warning: skipping $label — index fetch/verify failed" >&2; continue; }
  # Capture the jq result and its status explicitly: a producer failure inside
  # process substitution does not trip set -e, so a malformed/changed signed
  # index would otherwise report every candidate as unavailable.
  if ! subset=$(jq -r --arg abi "$abi" --arg want "$want_json" \
      "$FDROID_ELIGIBILITY_JQ$available_subset_jq" "$index"); then
    echo "warning: skipping $label — index did not parse as expected" >&2
    continue
  fi
  checked_labels+=("$label")
  while read -r p; do
    [ -z "$p" ] && continue
    [ -n "${hit_label[$p]:-}" ] && continue   # first repo wins; main archive first
    hit_label[$p]=$label
    repo_hits[$label]+="$p"$'\n'
  done <<<"$subset"
done

# Verify each --release-hint by asking the real resolver to lock it: success
# means the release resolves AND its apk package id matches the candidate.
# This is package-id COMPATIBILITY, not proof of source identity — a same-id
# apk from a different signer installs fine on a clean phone; the signer is
# what protects updates. So the resolved signer is surfaced for the user to
# confirm, and F-Droid is not silently preferred over an explicit hint. Runs
# independently of the F-Droid indexes.
declare -A release_kind=()   # pkg -> "github" | "gitea"
declare -A release_spec=()   # pkg -> owner/repo | host/owner/repo
declare -A release_signer=() # pkg -> resolved signer sha256 (for the user to confirm)
if [ "${#hints[@]}" -gt 0 ]; then
  hint_lock=$(mktemp -d)
  for hint in "${hints[@]}"; do
    p=${hint%%=*} rest=${hint#*=}
    [[ $p =~ ^[A-Za-z0-9_]+(\.[A-Za-z0-9_]+)+$ ]] || { echo "warning: ignoring malformed release hint: $hint" >&2; continue; }
    printf '%s' "$rest" | grep -Eq '^[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)+$' || { echo "warning: ignoring malformed repo in hint: $hint" >&2; continue; }
    if [[ " ${candidates[*]} " != *" $p "* ]]; then
      echo "warning: release hint $p is not an apps.play/apps.attended entry — skipping" >&2
      continue
    fi
    # GitHub = owner/repo (one slash); Gitea = host/owner/repo (two+).
    if [ "$(tr -cd '/' <<<"$rest" | wc -c)" -eq 1 ]; then kind=github; else kind=gitea; fi
    # Keep the resolver's own diagnostic (rate limit, transport, mismatch)
    # instead of flattening every failure to "no matching apk".
    if "$resolver" --lock "$hint_lock/lock.json" --abi "$abi" --replace \
        "--$kind" "$p=$rest" >/dev/null 2>"$hint_lock/err"; then
      # Require the resolver to have recorded at least one signer before
      # promoting; render all of them (v3.1 key rotation and multi-signer apks
      # have more than one). Checked before touching F-Droid state below.
      signers=$(jq -r --arg p "$p" '.packages[$p].signerSha256 // [] | join(", ")' "$hint_lock/lock.json" 2>/dev/null || true)
      if [ -z "$signers" ]; then
        echo "warning: $p at $rest verified but recorded no signer — not promoting" >&2
        continue
      fi
      # An explicit hint expresses intent, so it wins even when F-Droid also
      # has the package id (F-Droid availability is not signer equivalence).
      if [ -n "${hit_label[$p]:-}" ]; then
        prev=${hit_label[$p]}
        repo_hits[$prev]=$({ grep -vxF "$p" <<<"${repo_hits[$prev]:-}" || true; })
        echo "note: $p is also on $prev, but the explicit hint $rest was verified and takes precedence" >&2
      fi
      release_kind[$p]=$kind
      release_spec[$p]=$rest
      release_signer[$p]=$signers
      hit_label[$p]="$kind release"
    else
      reason=$({ grep -v '^$' "$hint_lock/err" || true; } | tail -1)
      echo "warning: could not verify $p at $rest — keeping as play/attended${reason:+ (${reason})}" >&2
    fi
  done
  rm -rf "$hint_lock"
fi

# Discovery: for candidates still without a source, look up a candidate repo in
# the Obtainium catalog. This is UNTRUSTED, UNVERIFIED discovery data — it only
# names a repo to check; nothing is promoted until the package-id match at
# verify time. Kept out of the migration block for that reason.
declare -A candidate_kind=()   # pkg -> github | gitea (proposed, not verified)
declare -A candidate_spec=()
if [ "$discover" -eq 1 ]; then
  discover_queried=0
  for p in "${candidates[@]}"; do
    [ -n "${hit_label[$p]:-}" ] && continue
    entry=
    for d in simple complex; do
      # Time- and size-cap each fetch: the catalog is a third-party host.
      entry=$(curl -fsS --max-time 15 --max-filesize 2M "$catalog_base/$d/$p.json" 2>/dev/null) && break
      entry=
    done
    discover_queried=$((discover_queried + 1))
    [ -n "$entry" ] || continue
    # Both catalog schemas (complex .configs[].url, simple .config.url) and every
    # config are examined, so an entry whose first source is unsupported but a
    # later one is GitHub/Codeberg is still found. Untrusted data — a parse
    # failure warns and continues instead of aborting the scan.
    if ! urls_raw=$(jq -r '[.configs[]?.url, .config?.url, .url] | map(select(type == "string"))[]' <<<"$entry" 2>/dev/null); then
      echo "warning: skipping $p — unparseable catalog entry" >&2
      continue
    fi
    mapfile -t urls <<<"$urls_raw"
    for url in ${urls[@]+"${urls[@]}"}; do
      # Strict anchored segment chars keep control characters and path junk from
      # untrusted URLs out of owner/repo and the terminal. Only kinds the
      # resolver can verify: GitHub and Codeberg/Forgejo (Gitea).
      if [[ $url =~ ^https?://github\.com/([A-Za-z0-9._-]+)/([A-Za-z0-9._-]+) ]]; then
        candidate_kind[$p]=github
        candidate_spec[$p]="${BASH_REMATCH[1]}/${BASH_REMATCH[2]%.git}"
        break
      elif [[ $url =~ ^https?://codeberg\.org/([A-Za-z0-9._-]+)/([A-Za-z0-9._-]+) ]]; then
        candidate_kind[$p]=gitea
        candidate_spec[$p]="codeberg.org/${BASH_REMATCH[1]}/${BASH_REMATCH[2]%.git}"
        break
      fi
    done
  done
  echo "note: --discover queried the Obtainium catalog for ${discover_queried} package id(s) over the network." >&2
fi

# Nothing to report only when nothing at all was produced.
if [ "${#checked_labels[@]}" -eq 0 ] && [ "${#release_kind[@]}" -eq 0 ] \
  && [ "${#candidate_kind[@]}" -eq 0 ]; then
  echo "no repo index could be verified and no release hint checked out; nothing to suggest" >&2
  exit 1
fi

found=0
for p in "${candidates[@]}"; do [ -n "${hit_label[$p]:-}" ] && found=$((found + 1)); done
missing=$(( ${#candidates[@]} - found ))

sources_checked=$(IFS=', '; echo "${checked_labels[*]:-none (indexes unavailable)}")
printf '%s candidate package(s) checked against %s for abi %s.\n\n' \
  "${#candidates[@]}" "$sources_checked" "$abi"

if [ "$found" -gt 0 ]; then
  echo "Available on a hash-lockable source ($found):"
  for p in "${candidates[@]}"; do
    [ -n "${hit_label[$p]:-}" ] && printf '  %-45s %s\n' "$p" "${hit_label[$p]}"
  done
  echo
fi
echo "Not found on the checked repos ($missing) — keep as apps.play / apps.attended:"
for p in "${candidates[@]}"; do
  [ -z "${hit_label[$p]:-}" ] && printf '  %s\n' "$p"
done
echo

# Discovered candidates are NOT promoted: the catalog is crowdsourced and
# package-id-match alone does not prove signer continuity (which nix-android
# does not yet enforce). Present them for the user to verify.
if [ "${#candidate_kind[@]}" -gt 0 ]; then
  echo "Candidate release sources from the Obtainium catalog (${#candidate_kind[@]}) —"
  echo "UNVERIFIED crowdsourced data; confirm each (its apk package id, and ideally"
  echo "its signer) before adding:"
  for p in "${candidates[@]}"; do
    [ -n "${candidate_kind[$p]:-}" ] && printf '  %-45s %s\n' "$p" "${candidate_spec[$p]}"
  done
  echo "  verify one with:  … suggest-sources --flake .#DEVICE \\"
  echo "                      --release-hint <pkg>=<owner/repo>"
  echo
fi

[ "$found" -gt 0 ] || exit 0

# A package may have exactly one source: each migrated entry must be REMOVED
# from apps.play/apps.attended as it is added to apps.fdroid, or the config
# fails evaluation with a duplicate-source error. Present both halves.
echo "# Migration (apply BOTH parts, then run android-rebuild update):"
echo "#"
echo "# 1. Remove these ${found} package(s) from apps.play / apps.attended:"
for p in "${candidates[@]}"; do
  [ -n "${hit_label[$p]:-}" ] && printf '#      %s\n' "$p"
done
echo "#"
echo "# 2. Add them to apps.fdroid / apps.release:"
# Only the official main-archive fingerprint uses apps.fdroid.packages; every
# other repo needs an apps.fdroid.repos.<name> block carrying its url + pin.
for spec in "${repos[@]}"; do
  IFS=$US read -r _ fp label <<<"$spec"
  [ "${fp,,}" = "$official_fdroid_fp" ] || continue
  [ -n "${repo_hits[$label]:-}" ] || continue
  echo "apps.fdroid.packages = ["
  while read -r p; do [ -n "$p" ] && printf '  "%s"\n' "$p"; done <<<"${repo_hits[$label]}"
  echo "];"
done
for spec in "${repos[@]}"; do
  IFS=$US read -r _ fp label <<<"$spec"
  [ "${fp,,}" = "$official_fdroid_fp" ] && continue
  [ -n "${repo_hits[$label]:-}" ] || continue
  attr=$(printf '%s' "$label" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9' '_')
  printf 'apps.fdroid.repos.%s = {\n  url = "%s";\n  fingerprint = "%s";\n  packages = [\n' \
    "$attr" "${repo_url[$label]}" "${repo_fp[$label]}"
  while read -r p; do [ -n "$p" ] && printf '    "%s"\n' "$p"; done <<<"${repo_hits[$label]}"
  printf '  ];\n};\n'
done
# Package-id-verified GitHub/Gitea releases, in stable package order. The
# package id is quoted because its dots are Nix attribute separators. The
# resolved signer is shown so the user can confirm source identity — package-id
# match alone does not (a different signer installs on a clean phone).
release_shown=0
for p in "${candidates[@]}"; do
  [ -n "${release_kind[$p]:-}" ] || continue
  [ "$release_shown" -eq 0 ] && echo "# apps.release below: package-id verified, NOT signer — confirm the signer you trust:"
  release_shown=1
  printf 'apps.release."%s".%s = "%s";' "$p" "${release_kind[$p]}" "${release_spec[$p]}"
  [ -n "${release_signer[$p]:-}" ] && printf '  # signer sha256: %s' "${release_signer[$p]}"
  printf '\n'
done
