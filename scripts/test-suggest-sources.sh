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
# --fetch-index REPO FP -> fixture index path
if [ "\$1" = --fetch-index ]; then
  case "\$2" in
    *malformed*) echo "$tmp/malformed.json" ;;
    *emptyidx*)  echo "$tmp/empty.json" ;;
    *main*) echo "$tmp/main.json" ;;
    *izzy*) echo "$tmp/izzy.json" ;;
    *bad*)  echo "boom" >&2; exit 1 ;;
    *) echo "unknown repo \$2" >&2; exit 1 ;;
  esac
  exit 0
fi
# release verification: succeeds for a repo whose name contains "good",
# mirroring a resolved+package-id-matched release, and writes a lock carrying
# signer(s) so the caller can render them; a "twosign" repo records two signers
# (v3.1 rotation / multi-signer). Anything else fails like a real mismatch.
lock=""; spec=""; prev=""
for a in "\$@"; do
  [ "\$prev" = --lock ] && lock="\$a"
  case "\$a" in *=*good*) spec="\$a" ;; esac
  prev="\$a"
done
if [ -n "\$spec" ]; then
  pkg="\${spec%%=*}"
  if [[ "\$spec" == *twosign* ]]; then
    jq -n --arg p "\$pkg" '{packages: {(\$p): {signerSha256: ["1111111111111111111111111111111111111111111111111111111111111111","2222222222222222222222222222222222222222222222222222222222222222"]}}}' > "\$lock"
  else
    jq -n --arg p "\$pkg" '{packages: {(\$p): {signerSha256: ["1111111111111111111111111111111111111111111111111111111111111111"]}}}' > "\$lock"
  fi
  exit 0
fi
exit 1
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
two.signer.app
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

# --- release hints: verified vs unverified, gitea, non-candidate, fdroid-wins -
# com.google.play.only is not on any repo, so a verified github hint promotes it;
# a hint at a repo the resolver rejects stays play/attended; a gitea hint
# (host/owner/repo) renders .gitea; a hint for an fdroid-available package is
# ignored (fdroid preferred); a hint for a non-candidate warns.
rel=$(run arm64-v8a \
  --release-hint "com.google.play.only=owner/good" \
  --release-hint "two.signer.app=owner/twosign-good" \
  --release-hint "org.example.betaonly=owner/badrepo" \
  --release-hint "org.example.nosigner=git.example.com/owner/good" \
  --release-hint "org.example.universal=owner/good" \
  --release-hint "com.not.a.candidate=owner/good" 2>"$tmp/rel.err")
grep -q 'com.google.play.only *github release' <<<"$rel" || { echo "verified github hint not shown available" >&2; exit 1; }
# every recorded signer is rendered, not just the first
grep -q 'apps.release."two.signer.app".github = "owner/twosign-good";.*# signer sha256: 1111111111111111111111111111111111111111111111111111111111111111, 2222222222222222222222222222222222222222222222222222222222222222' <<<"$rel" \
  || { echo "multi-signer release did not render all digests" >&2; exit 1; }
grep -q 'apps.release."com.google.play.only".github = "owner/good";.*# signer sha256: 1111111111111111111111111111111111111111111111111111111111111111' <<<"$rel" \
  || { echo "github release block missing full resolved signer" >&2; exit 1; }
grep -q 'apps.release."org.example.nosigner".gitea = "git.example.com/owner/good";' <<<"$rel" || { echo "gitea release block wrong" >&2; exit 1; }
grep -q '# *com.google.play.only' <<<"$rel" || { echo "verified release not in removal list" >&2; exit 1; }
grep -q 'apps.release."org.example.betaonly"' <<<"$rel" && { echo "unverified hint was rendered" >&2; exit 1; }
grep -q 'could not verify org.example.betaonly' "$tmp/rel.err" || { echo "unverified hint did not warn" >&2; exit 1; }
# explicit hint takes precedence over an f-droid match (covered in depth below).
grep -q 'com.not.a.candidate is not' "$tmp/rel.err" || { echo "non-candidate hint did not warn" >&2; exit 1; }
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

# --- discovery: both catalog schemas, unsupported kinds skipped, malformed
#     tolerated, unanchored junk rejected ---------------------------------------
catalog="$tmp/catalog"
mkdir -p "$catalog/simple" "$catalog/complex"
# complex schema uses .configs[].url; simple schema uses .config.url.
printf '{"configs":[{"url":"https://github.com/owner/repo"}]}' > "$catalog/complex/com.google.play.only.json"
printf '{"config":{"url":"https://codeberg.org/someone/coolapp"}}' > "$catalog/simple/not.on.fdroid.json"
printf '{"configs":[{"url":"https://cdn.vendor.example/x"}]}' > "$catalog/complex/vendor.only.json"
# a malformed entry must warn and continue, not abort the whole scan.
printf 'this is not json {' > "$catalog/complex/broken.entry.json"
# an entry whose FIRST config is unsupported but a later one is GitHub must
# still be discovered (all configs examined, not just [0]).
printf '{"configs":[{"url":"https://cdn.vendor.example/x"},{"url":"https://github.com/later/repo"}]}' \
  > "$catalog/complex/later.source.json"
disc=$(printf 'com.google.play.only\nnot.on.fdroid\nvendor.only\nbroken.entry\nlater.source\n' | \
  bash "$suggest" --resolver "$tmp/resolver" --abi arm64-v8a --discover \
  --catalog-base "file://$catalog" \
  --repo "https://main.fdroid.example/repo" "$official_fp" f-droid.org 2>"$tmp/disc.err")
grep -q 'com.google.play.only *owner/repo' <<<"$disc" || { echo "github (complex schema) candidate missing" >&2; exit 1; }
grep -q 'not.on.fdroid *codeberg.org/someone/coolapp' <<<"$disc" || { echo "codeberg (simple schema) candidate missing" >&2; exit 1; }
grep -q 'later.source *later/repo' <<<"$disc" || { echo "later-config github source not discovered" >&2; exit 1; }
# vendor.only has an unsupported (CDN) url: it stays keep-as-play, never a
# discovery candidate. Check only the candidate section.
awk '/Candidate release/{c=1} /verify one with/{c=0} c' <<<"$disc" | grep -q 'vendor.only' \
  && { echo "unsupported vendor url was proposed as a candidate" >&2; exit 1; }
grep -q 'skipping broken.entry' "$tmp/disc.err" || { echo "malformed catalog entry did not warn" >&2; exit 1; }
grep -q 'com.google.play.only *owner/repo' <<<"$disc" || { echo "scan aborted on malformed entry" >&2; exit 1; }
grep -q 'UNVERIFIED' <<<"$disc" || { echo "discovery candidates not marked unverified" >&2; exit 1; }
grep -q 'apps.release."com.google.play.only"' <<<"$disc" && { echo "discovered candidate was auto-promoted (must stay unverified)" >&2; exit 1; }
grep -q 'queried the Obtainium catalog' "$tmp/disc.err" || { echo "no privacy note for --discover" >&2; exit 1; }
# discovery is opt-in: without --discover, no catalog query
nodisc=$(printf 'com.google.play.only\n' | bash "$suggest" --resolver "$tmp/resolver" --abi arm64-v8a \
  --catalog-base "file://$catalog" \
  --repo "https://main.fdroid.example/repo" "$official_fp" f-droid.org 2>"$tmp/nd.err")
grep -q 'Obtainium catalog' <<<"$nodisc$(cat "$tmp/nd.err")" && { echo "catalog queried without --discover" >&2; exit 1; }

# --- explicit --release-hint wins over an F-Droid match (intent, not override) -
# com.google.play.only is not on the (empty) fixture index, so put a package
# that IS on f-droid and give an explicit verified hint: it must move to
# apps.release, not stay under apps.fdroid.
hintwin=$(run arm64-v8a --release-hint "org.example.universal=owner/good" 2>"$tmp/hw.err")
grep -q 'apps.release."org.example.universal".github = "owner/good";' <<<"$hintwin" \
  || { echo "explicit hint did not take precedence over f-droid" >&2; exit 1; }
awk '/apps.fdroid.packages/{f=1} /^\];/{f=0} f' <<<"$hintwin" | grep -q 'org.example.universal' \
  && { echo "hint-overridden package still in apps.fdroid.packages (duplicate source)" >&2; exit 1; }
grep -q 'also on f-droid.org' "$tmp/hw.err" || { echo "no note that the package was also on f-droid" >&2; exit 1; }
grep -q 'NOT signer' <<<"$hintwin" || { echo "output does not caveat package-id vs signer" >&2; exit 1; }

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
