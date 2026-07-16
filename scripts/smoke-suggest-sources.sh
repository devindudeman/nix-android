#!/usr/bin/env bash
# Live smoke test for release-hint verification against a REAL public GitHub
# release. Deliberately NOT part of `just check` / CI: it hits the network and
# GitHub's rate limit. Run it by hand to confirm the resolver still resolves a
# real .apk and that the package-id gate rejects a wrong repo.
#
# Usage: smoke-suggest-sources.sh   (builds the resolver via nix)
set -euo pipefail

# Molly (Signal fork): actively released, publishes a single release apk
# (Molly-<ver>.apk, package im.molly.app), and is NOT on f-droid.org or
# IzzyOnDroid — so the release-hint path actually runs instead of being
# short-circuited by a preferred F-Droid source. The wrong-repo probe points
# at Seal, whose apk reports com.junkfood.seal, so the package-id gate rejects.
pkg=im.molly.app
repo=mollyim/mollyim-android
wrong_repo=JunkFood02/Seal

resolver=${NIX_ANDROID_RESOLVER:-}
if [ -z "$resolver" ]; then
  echo "building resolver..." >&2
  resolver=$(nix build .#update-lock --no-link --print-out-paths --accept-flake-config)/bin/nix-android-update-lock
fi

out=$(printf '%s\n' "$pkg" | NIX_ANDROID_RESOLVER="$resolver" \
  bash "$(dirname "${BASH_SOURCE[0]}")/suggest-sources.sh" --abi arm64-v8a \
  --release-hint "$pkg=$repo" 2>/dev/null)
grep -q "apps.release.\"$pkg\".github = \"$repo\";" <<<"$out" \
  || { echo "FAIL: real GitHub release for $pkg did not match by package id" >&2; echo "$out" >&2; exit 1; }
grep -q "apps.release.\"$pkg\".github.*# signer sha256: [0-9a-f]" <<<"$out" \
  || { echo "FAIL: no signer digest recorded for $pkg" >&2; echo "$out" >&2; exit 1; }
echo "✓ package-id matched + signer recorded: $pkg @ $repo"

# Wrong repo must be rejected by the apk package-id match.
warn=$(printf '%s\n' "$pkg" | NIX_ANDROID_RESOLVER="$resolver" \
  bash "$(dirname "${BASH_SOURCE[0]}")/suggest-sources.sh" --abi arm64-v8a \
  --release-hint "$pkg=$wrong_repo" 2>&1 || true)
grep -q "could not verify $pkg" <<<"$warn" \
  || { echo "FAIL: wrong repo for $pkg was not rejected" >&2; echo "$warn" >&2; exit 1; }
echo "✓ rejected wrong repo: $pkg @ $wrong_repo (package-id mismatch)"

echo "✓ live suggest-sources smoke passed"
