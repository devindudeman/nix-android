#!/usr/bin/env bash
# suggest-sources — read-only curation aid for de-Play migration.
#
# Reads candidate package ids (one per line on stdin: the apps.play and
# apps.attended entries an import produced) and reports which are published on
# a hash-lockable F-Droid source, so they can move off the per-app Play
# install-consent path. It changes nothing: the authoritative verification
# still happens later in `android-rebuild update`, which re-fetches and pins.
#
# Trust: index fetches go through the packaged update-lock's --fetch-index,
# which authenticates each repo's signed entry.jar and index-v2 hash — this
# script never fetches an index itself. Availability is a suggestion; a wrong
# index cannot install anything, because update re-verifies before locking.
#
# Usage: suggest-sources.sh --resolver PATH --abi ABI [--repo URL FP LABEL ...]
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
  -h | --help)
    sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'
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

found=0
for p in "${candidates[@]}"; do [ -n "${hit_label[$p]:-}" ] && found=$((found + 1)); done
missing=$(( ${#candidates[@]} - found ))

[ "${#checked_labels[@]}" -gt 0 ] || { echo "no repo index could be verified; nothing to suggest" >&2; exit 1; }
printf '%s candidate package(s) checked against %s for abi %s.\n\n' \
  "${#candidates[@]}" "$(IFS=', '; echo "${checked_labels[*]}")" "$abi"

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
echo "# 2. Add them to apps.fdroid:"
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
