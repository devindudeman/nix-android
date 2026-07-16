#!/usr/bin/env bash
# Offline test for suggest-sources.sh. A fake resolver returns fixture index-v2
# files instead of fetching, so the abi-eligibility, first-repo-wins,
# missing-set, config-block, and repo-verify-failure paths are all exercised
# without network. The real trust chain lives in update-lock.sh and is covered
# by update-lock-safety.
set -euo pipefail

suggest=${1:?usage: test-suggest-sources.sh SUGGEST_SCRIPT}
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# --- fixture indexes ---------------------------------------------------------
# lockable_version requires the resolver's full field set: signer, a numeric
# versionCode, an apk filename, and a 64-hex sha256. A version missing any of
# these — like an ambiguous multi-signer lineage or beta channel — is not
# lockable, mirroring the production resolver.
H='aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
cat > "$tmp/main.json" <<EOF
{
  "packages": {
    "org.example.universal": {
      "versions": { "aa": { "file": {"name": "/u.apk", "sha256": "$H"}, "manifest": { "versionCode": 5, "versionName": "1.0", "signer": { "sha256": ["s1"] } } } }
    },
    "org.example.termux": {
      "versions": { "bb": { "file": {"name": "/t.apk", "sha256": "$H"}, "manifest": { "versionCode": 3, "versionName": "1.0", "nativecode": [], "signer": { "sha256": ["s1"] } } } }
    },
    "org.example.armonly": {
      "versions": { "cc": { "file": {"name": "/a.apk", "sha256": "$H"}, "manifest": { "versionCode": 2, "versionName": "1.0", "nativecode": ["arm64-v8a"], "signer": { "sha256": ["s1"] } } } }
    },
    "org.example.betaonly": {
      "versions": { "dd": { "file": {"name": "/b.apk", "sha256": "$H"}, "manifest": { "versionCode": 9, "versionName": "1.0", "signer": { "sha256": ["s1"] } }, "releaseChannels": ["Beta"] } }
    },
    "org.example.nosigner": {
      "versions": { "ee": { "file": {"name": "/n.apk", "sha256": "$H"}, "manifest": { "versionCode": 1, "versionName": "1.0" } } }
    },
    "org.example.twolineage": {
      "versions": {
        "f1": { "file": {"name": "/f1.apk", "sha256": "$H"}, "manifest": { "versionCode": 2, "versionName": "2.0", "signer": { "sha256": ["s1"] } } },
        "f2": { "file": {"name": "/f2.apk", "sha256": "$H"}, "manifest": { "versionCode": 1, "versionName": "1.0", "signer": { "sha256": ["s2"] } } }
      }
    },
    "org.example.preferred": {
      "metadata": { "preferredSigner": "s2" },
      "versions": {
        "g1": { "file": {"name": "/g1.apk", "sha256": "$H"}, "manifest": { "versionCode": 2, "versionName": "2.0", "signer": { "sha256": ["s1"] } } },
        "g2": { "file": {"name": "/g2.apk", "sha256": "$H"}, "manifest": { "versionCode": 1, "versionName": "1.0", "signer": { "sha256": ["s2"] } } }
      }
    },
    "org.example.incomplete": {
      "versions": { "hh": { "manifest": { "versionCode": 7, "versionName": "1.0", "signer": { "sha256": ["s1"] } } } }
    },
    "org.example.fracver": {
      "versions": { "k1": { "file": {"name": "/k.apk", "sha256": "$H"}, "manifest": { "versionCode": 1.5, "versionName": "1.5", "signer": { "sha256": ["s1"] } } } }
    },
    "org.example.negver": {
      "versions": { "k2": { "file": {"name": "/k.apk", "sha256": "$H"}, "manifest": { "versionCode": -1, "versionName": "1.0", "signer": { "sha256": ["s1"] } } } }
    },
    "org.example.relname": {
      "versions": { "k3": { "file": {"name": "rel.apk", "sha256": "$H"}, "manifest": { "versionCode": 4, "versionName": "1.0", "signer": { "sha256": ["s1"] } } } }
    }
  }
}
EOF
# izzy: has universal (dup — main must win) and an izzy-exclusive package.
cat > "$tmp/izzy.json" <<EOF
{
  "packages": {
    "org.example.universal": { "versions": { "ii": { "file": {"name": "/u.apk", "sha256": "$H"}, "manifest": { "versionCode": 5, "versionName": "1.0", "signer": { "sha256": ["s3"] } } } } },
    "org.example.izzyonly": { "versions": { "jj": { "file": {"name": "/j.apk", "sha256": "$H"}, "manifest": { "versionCode": 4, "versionName": "1.0", "signer": { "sha256": ["s3"] } } } } }
  }
}
EOF
# an index with no packages object must fail closed, not report all-missing.
printf '{}' > "$tmp/empty.json"

# --- fake resolver: map --fetch-index URL FP -> fixture path ------------------
# Absolute bash path in the shebang: the nix check sandbox has no /usr/bin/env.
bash_path=$(command -v bash)
cat > "$tmp/resolver" <<EOF
#!$bash_path
set -euo pipefail
[ "\$1" = --fetch-index ] || { echo "unexpected: \$*" >&2; exit 2; }
case "\$2" in
  *malformed*) echo "$tmp/malformed.json" ;;
  *emptyidx*)  echo "$tmp/empty.json" ;;
  *main*) echo "$tmp/main.json" ;;
  *izzy*) echo "$tmp/izzy.json" ;;
  *bad*)  echo "boom" >&2; exit 1 ;;
  *) echo "unknown repo \$2" >&2; exit 1 ;;
esac
EOF
printf 'this is not json {' > "$tmp/malformed.json"
chmod +x "$tmp/resolver"

candidates=$(cat <<'EOF'
org.example.universal
org.example.termux
org.example.armonly
org.example.betaonly
org.example.nosigner
org.example.twolineage
org.example.preferred
org.example.incomplete
org.example.fracver
org.example.negver
org.example.relname
org.example.izzyonly
com.google.play.only
not a package
EOF
)

# The main archive is passed under its OFFICIAL f-droid.org fingerprint so it
# renders as apps.fdroid.packages; IzzyOnDroid (any other fingerprint) must
# render as apps.fdroid.repos.<name>.
official_fp=43238d512c1e5eb2d6569f4a3afbf5523418b82e0a3ed1552770abb9a9c9ccab
run() { # abi extra-args... ; candidates on stdin
  local abi=$1; shift
  bash "$suggest" --resolver "$tmp/resolver" --abi "$abi" \
    --repo "https://main.fdroid.example/repo" "$official_fp" f-droid.org \
    --repo "https://izzy.example/repo" "$(printf '%064d' 2)" IzzyOnDroid \
    "$@" <<<"$candidates"
}

# --- arm64: eligibility mirrors the resolver's signer/lineage rules -----------
out=$(run arm64-v8a)
grep -q 'org.example.universal *f-droid.org' <<<"$out" || { echo "universal not attributed to main" >&2; exit 1; }
grep -q 'org.example.termux *f-droid.org' <<<"$out" || { echo "termux missing" >&2; exit 1; }
grep -q 'org.example.armonly *f-droid.org' <<<"$out" || { echo "arm64 package excluded on arm64" >&2; exit 1; }
grep -q 'org.example.preferred *f-droid.org' <<<"$out" || { echo "preferredSigner package missing" >&2; exit 1; }
grep -q 'org.example.izzyonly *IzzyOnDroid' <<<"$out" || { echo "izzy-only package missing" >&2; exit 1; }
# not lockable: beta-only, no-signer, ambiguous lineage, missing apk metadata,
# a fractional or negative versionCode, and a relative apk filename → all must
# stay keep-as-play only (each would produce a lock the engine or URL rejects).
for np in betaonly nosigner twolineage incomplete fracver negver relname; do
  grep -Eq "$np +(f-droid.org|IzzyOnDroid)" <<<"$out" && { echo "$np was offered as lockable" >&2; exit 1; }
  grep -q "\"org.example.$np\"" <<<"$out" && { echo "$np leaked into a config block" >&2; exit 1; }
  grep -q "org.example.$np" <<<"$out" || { echo "$np missing from keep-as-play list" >&2; exit 1; }
done
# first repo wins: universal must not appear under the IzzyOnDroid block
awk '/apps.fdroid.repos/{izzy=1} izzy && /org.example.universal/{found=1} END{exit found?1:0}' <<<"$out" \
  || { echo "universal leaked into the izzy repo block" >&2; exit 1; }
grep -q 'com.google.play.only' <<<"$out" || { echo "unavailable package not listed as keep-as-play" >&2; exit 1; }
grep -q 'not a package' <<<"$out" && { echo "malformed id was not filtered" >&2; exit 1; }
# migration shape: removal note + official packages block + izzy repos block
grep -q 'Remove these' <<<"$out" || { echo "no removal instruction" >&2; exit 1; }
grep -q 'apps.fdroid.packages = \[' <<<"$out" || { echo "no fdroid.packages block" >&2; exit 1; }
grep -q 'apps.fdroid.repos.izzyondroid = {' <<<"$out" || { echo "no izzy repo block" >&2; exit 1; }
# a custom (non-official) first repo must NOT become apps.fdroid.packages
custom=$(bash "$suggest" --resolver "$tmp/resolver" --abi arm64-v8a \
  --repo "https://izzy.example/repo" "$(printf '%064d' 2)" IzzyOnDroid <<<"$candidates")
grep -q 'apps.fdroid.packages = \[' <<<"$custom" && { echo "non-official repo rendered as official packages" >&2; exit 1; }
grep -q 'apps.fdroid.repos.izzyondroid = {' <<<"$custom" || { echo "custom-only repo not rendered as a repos block" >&2; exit 1; }

# --- x86_64: arm64-only package must drop out ---------------------------------
out=$(run x86_64)
grep -Eq 'armonly +(f-droid.org|IzzyOnDroid)' <<<"$out" && { echo "arm64-only package offered for x86_64" >&2; exit 1; }
grep -q '"org.example.armonly"' <<<"$out" && { echo "arm64-only package leaked into x86_64 config block" >&2; exit 1; }
grep -q 'org.example.universal *f-droid.org' <<<"$out" || { echo "universal missing for x86_64" >&2; exit 1; }

# --- a repo whose index cannot be verified is skipped with a warning ----------
warn=$(bash "$suggest" --resolver "$tmp/resolver" --abi arm64-v8a \
  --repo "https://bad.example/repo" "$(printf '%064d' 3)" Bad \
  --repo "https://main.example/repo" "$(printf '%064d' 1)" main \
  <<<"$candidates" 2>&1)
grep -q 'skipping Bad' <<<"$warn" || { echo "unverifiable repo did not warn" >&2; exit 1; }
grep -q 'org.example.universal *main' <<<"$warn" || { echo "did not continue past a bad repo" >&2; exit 1; }

# --- an index that fetches but does not parse is skipped, not "all missing" ---
parse=$(bash "$suggest" --resolver "$tmp/resolver" --abi arm64-v8a \
  --repo "https://malformed.example/repo" "$(printf '%064d' 4)" Malformed \
  --repo "https://main.fdroid.example/repo" "$official_fp" f-droid.org \
  <<<"$candidates" 2>&1)
grep -q 'skipping Malformed' <<<"$parse" || { echo "malformed index did not warn" >&2; exit 1; }
grep -q 'org.example.universal *f-droid.org' <<<"$parse" || { echo "did not continue past a malformed index" >&2; exit 1; }

# --- an index with no packages object fails closed (not "all unavailable") ----
emptyidx=$(bash "$suggest" --resolver "$tmp/resolver" --abi arm64-v8a \
  --repo "https://emptyidx.example/repo" "$(printf '%064d' 5)" EmptyIdx \
  <<<"$candidates" 2>&1) && rc=0 || rc=$?
grep -q 'skipping EmptyIdx' <<<"$emptyidx" || { echo "empty-packages index did not warn" >&2; exit 1; }
[ "${rc:-0}" -ne 0 ] || { echo "empty-only checked set should have errored" >&2; exit 1; }

# --- no candidates is a friendly no-op, not an error -------------------------
empty_out=$(bash "$suggest" --resolver "$tmp/resolver" --abi arm64-v8a </dev/null) \
  || { echo "empty candidate set errored" >&2; exit 1; }
grep -q 'nothing to migrate\|no apps.play' <<<"$empty_out" || { echo "empty case message missing" >&2; exit 1; }

# --- every checked repo failing is a hard error -------------------------------
if bash "$suggest" --resolver "$tmp/resolver" --abi arm64-v8a \
  --repo "https://bad.example/repo" "$(printf '%064d' 3)" Bad \
  <<<"$candidates" >/dev/null 2>&1; then
  echo "all-repos-failed did not error" >&2
  exit 1
fi

echo "✓ suggest-sources fixtures passed"
