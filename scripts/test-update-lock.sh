#!/usr/bin/env bash
# Offline, executable regression test for the signed F-Droid resolver.
set -euo pipefail

updater=${1:?usage: test-update-lock.sh UPDATE_LOCK_SCRIPT}
fixture_apk=${2:?usage: test-update-lock.sh UPDATE_LOCK_SCRIPT FIXTURE_APK}
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
repo="$tmp/repo"
mkdir -p "$repo" "$tmp/jar"

preferred=$(printf '11%.0s' {1..32})
other=$(printf '22%.0s' {1..32})
apk_sha=$(printf 'aa%.0s' {1..32})
jq -n --arg preferred "$preferred" --arg other "$other" --arg sha "$apk_sha" '{
  packages: {
    "org.example.test": {
      metadata: {preferredSigner: $preferred},
      versions: {
        preferred: {
          releaseChannels: [],
          manifest: {versionCode: 7, versionName: "7", nativecode: [], signer: {sha256: [$preferred]}},
          file: {name: "/org.example.test_7.apk", sha256: $sha}
        },
        newerWrongLineage: {
          releaseChannels: [],
          manifest: {versionCode: 9, versionName: "9", nativecode: [], signer: {sha256: [$other]}},
          file: {name: "/org.example.test_9.apk", sha256: $sha}
        }
      }
    },
    "org.example.second": {
      versions: {
        only: {
          releaseChannels: [],
          manifest: {versionCode: 3, versionName: "3", nativecode: [], signer: {sha256: [$preferred]}},
          file: {name: "/org.example.second_3.apk", sha256: $sha}
        }
      }
    }
  }
}' > "$repo/index-v2.json"
index_sha=$(sha256sum "$repo/index-v2.json" | cut -d' ' -f1)
jq -n --arg sha "$index_sha" '{index: {name: "/index-v2.json", sha256: $sha}}' > "$tmp/jar/entry.json"

keytool -genkeypair -alias repo -keyalg RSA -keysize 2048 -validity 1 \
  -dname CN=nix-android-test -keystore "$tmp/repo.jks" \
  -storepass changeit -keypass changeit >/dev/null 2>&1
jar --create --file "$repo/entry.jar" -C "$tmp/jar" entry.json
jarsigner -keystore "$tmp/repo.jks" -storepass changeit -keypass changeit \
  "$repo/entry.jar" repo >/dev/null 2>&1
fingerprint=$(keytool -printcert -jarfile "$repo/entry.jar" 2>/dev/null \
  | sed -n 's/^[[:space:]]*SHA256: //p' | tr -d ':[:space:]' \
  | tr '[:upper:]' '[:lower:]')
repo_url="file://$repo"

XDG_CACHE_HOME="$tmp/cache-good" "$updater" --lock "$tmp/lock.json" \
  --abi x86_64 --fdroid org.example.test "$repo_url" "$fingerprint" >/dev/null
jq -e --arg preferred "$preferred" '
  .packages."org.example.test"
  | .versionCode == 7
    and .preferredSigner == $preferred
    and .signerSha256 == [$preferred]
' "$tmp/lock.json" >/dev/null

# Partial invocations merge into a same-ABI lock instead of wiping it;
# cross-ABI merges fail closed; --replace rewrites; a no-arg refresh keeps
# the lock's recorded ABI.
XDG_CACHE_HOME="$tmp/cache-good" "$updater" --lock "$tmp/lock.json" \
  --abi x86_64 --fdroid org.example.second "$repo_url" "$fingerprint" >/dev/null
jq -e '.packages | has("org.example.test") and has("org.example.second")' "$tmp/lock.json" >/dev/null
if XDG_CACHE_HOME="$tmp/cache-good" "$updater" --lock "$tmp/lock.json" \
  --abi arm64-v8a --fdroid org.example.second "$repo_url" "$fingerprint" >/dev/null 2>&1; then
  echo "cross-abi merge unexpectedly succeeded" >&2
  exit 1
fi
jq -e '.abi == "x86_64" and (.packages | has("org.example.test"))' "$tmp/lock.json" >/dev/null
XDG_CACHE_HOME="$tmp/cache-good" "$updater" --lock "$tmp/lock.json" \
  --abi x86_64 --replace --fdroid org.example.test "$repo_url" "$fingerprint" >/dev/null
jq -e '.packages | keys == ["org.example.test"]' "$tmp/lock.json" >/dev/null
XDG_CACHE_HOME="$tmp/cache-good" "$updater" --lock "$tmp/lock.json" >/dev/null
jq -e '.abi == "x86_64" and (.packages | keys == ["org.example.test"])' "$tmp/lock.json" >/dev/null

cp "$tmp/lock.json" "$tmp/atomic.json"
cp "$tmp/atomic.json" "$tmp/atomic.before"
zeros=$(printf '00%.0s' {1..32})
if XDG_CACHE_HOME="$tmp/cache-wrong" "$updater" --lock "$tmp/atomic.json" \
  --abi x86_64 --fdroid org.example.test "$repo_url" "$zeros" >/dev/null 2>&1; then
  echo "wrong repository fingerprint unexpectedly succeeded" >&2
  exit 1
fi
cmp "$tmp/atomic.before" "$tmp/atomic.json"

jq '.packages."org.example.test".repoFingerprint = 7' "$tmp/atomic.json" > "$tmp/malformed.json"
cp "$tmp/malformed.json" "$tmp/malformed.before"
if XDG_CACHE_HOME="$tmp/cache-malformed" "$updater" --lock "$tmp/malformed.json" >/dev/null 2>&1; then
  echo "malformed lock refresh unexpectedly succeeded" >&2
  exit 1
fi
cmp "$tmp/malformed.before" "$tmp/malformed.json"

jq '.index.sha256 = "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"' \
  "$tmp/jar/entry.json" > "$tmp/jar/tampered.json"
mv "$tmp/jar/tampered.json" "$tmp/jar/entry.json"
jar --update --file "$repo/entry.jar" -C "$tmp/jar" entry.json
if XDG_CACHE_HOME="$tmp/cache-tampered" "$updater" --lock "$tmp/tampered-lock.json" \
  --abi x86_64 --fdroid org.example.test "$repo_url" "$fingerprint" >/dev/null 2>&1; then
  echo "tampered signed entry unexpectedly succeeded" >&2
  exit 1
fi
[ ! -e "$tmp/tampered-lock.json" ]

mkdir -p "$tmp/assets/one" "$tmp/assets/two" "$tmp/assets/link"
cp "$fixture_apk" "$tmp/assets/one/app.apk"
cp "$fixture_apk" "$tmp/assets/two/one.apk"
cp "$fixture_apk" "$tmp/assets/two/two.apk"
ln -s "$fixture_apk" "$tmp/assets/link/app.apk"
tar -czf "$tmp/good.tar.gz" -C "$tmp/assets/one" app.apk
tar -czf "$tmp/multiple.tar.gz" -C "$tmp/assets/two" one.apk two.apk
tar -czf "$tmp/symlink.tar.gz" -C "$tmp/assets/link" app.apk
tar -czf "$tmp/traversal.tar.gz" --transform='s|^|../|' -C "$tmp/assets/one" app.apk
"$updater" --inspect-release-asset org.fdroid.fdroid "$fixture_apk" >/dev/null
"$updater" --inspect-release-asset org.fdroid.fdroid "$tmp/good.tar.gz" >/dev/null
for bad in multiple symlink traversal; do
  if "$updater" --inspect-release-asset org.fdroid.fdroid "$tmp/$bad.tar.gz" >/dev/null 2>&1; then
    echo "$bad release archive unexpectedly succeeded" >&2
    exit 1
  fi
done
if "$updater" --inspect-release-asset org.example.wrong "$fixture_apk" >/dev/null 2>&1; then
  echo "release APK package mismatch unexpectedly succeeded" >&2
  exit 1
fi

echo "signed F-Droid and release-asset resolver tests passed"
