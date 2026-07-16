# shellcheck shell=bash
# Shared F-Droid index-v2 eligibility logic, sourced by update-lock.sh (which
# resolves and pins) and suggest-sources.sh (which only reports availability).
# Keeping the selection in one place stops the advisory tool from suggesting a
# package the real resolver would reject — the two must agree on exactly which
# versions are lockable.
#
# Exposes FDROID_ELIGIBILITY_JQ, a jq prelude of pure functions on one
# index-v2 package object:
#   stable_abi_versions($abi) — stable-channel versions whose native code is
#     empty or includes $abi.
#   lineage_versions($abi)    — those restricted to the resolvable signing
#     lineage: metadata.preferredSigner when set, else the single signer shared
#     by every candidate, or [] when the lineage is ambiguous.
#   lockable_version($abi)    — the one version the resolver would pin (highest
#     versionCode of the lineage) only when it carries every field the lock
#     needs: signer, a numeric versionCode, an apk filename, and a 64-hex
#     sha256. Otherwise empty, so a semantically incomplete or hostile index
#     is never reported available.
#   require_packages_object     — errors unless the input is an index with a
#     packages object, so a {} or truncated index fails closed instead of
#     silently reporting every candidate unavailable.
# shellcheck disable=SC2034  # consumed by callers that source this file
# shellcheck disable=SC2016  # $abi and jq operators are jq syntax, not shell
FDROID_ELIGIBILITY_JQ='
  def require_packages_object:
    if (.packages | type) == "object" then .
    else error("index has no packages object") end;

  def stable_abi_versions($abi):
    [ (.versions // {}) | to_entries[] | .value
      | select((.releaseChannels // []) | length == 0)
      | select((.manifest.nativecode // []) as $n
          | ($n | length == 0) or ($n | index($abi))) ];

  def lineage_versions($abi):
    (.metadata.preferredSigner // null) as $preferred
    | (stable_abi_versions($abi)) as $vs
    | if $preferred == null
        then (if ([$vs[] | (.manifest.signer.sha256 // [])[]] | unique | length) <= 1
                then $vs else [] end)
        else [ $vs[] | select((.manifest.signer.sha256 // []) | index($preferred)) ]
      end;

  # Complete AND well-formed enough to produce a lock entry the rest of the
  # pipeline accepts: a signer, a nonnegative integer versionCode (the engine
  # rejects anything else), an apk filename that is absolute so repo + name is
  # a valid URL, and a 64-hex sha256. Mirrors update-lock plus the manifest
  # schema converge.sh enforces.
  def lockable_version($abi):
    lineage_versions($abi)
    | sort_by(-(.manifest.versionCode // -1)) | .[0]
    | select(. != null
        and ((.manifest.signer.sha256 // []) | length > 0)
        and (.manifest.versionCode | type == "number" and . >= 0 and floor == .)
        and ((.file.name // "") | type == "string" and startswith("/"))
        and ((.file.sha256 // "") | test("^[0-9A-Fa-f]{64}$")));
'
