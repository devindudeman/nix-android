#!/usr/bin/env bash
# android-rebuild — the nix-android CLI, deliberately shaped like darwin-rebuild.
#
#   android-rebuild build  --flake .#pixel            eval + fetch closure, no device
#   android-rebuild plan   --flake .#pixel --serial S     diff manifest vs device
#   android-rebuild switch --flake .#pixel --serial S     plan + apply
#   android-rebuild status --flake .#pixel --serial S     drift since last switch
#   android-rebuild generations --flake .#pixel           list recorded convergences
#   android-rebuild assist --flake .#pixel --serial S     open next missing Play app
#   android-rebuild bootstrap --flake .#pixel --serial S  phased wiped-device rebuild
#   android-rebuild update --flake .#pixel [--lock PATH]  refresh apps.lock.json
#   android-rebuild import --serial S [--snapshot-out PATH] [--report-out PATH]
#     [--obtainium-export PATH] [--app-manager-export PATH]
#
# Runs from the config repo (the flake). NIX_ANDROID_SRC points at the
# nix-android checkout for helper scripts; the packaged CLI bakes it in.
set -euo pipefail

src=${NIX_ANDROID_SRC:?NIX_ANDROID_SRC not set (use the packaged android-rebuild)}
nix_android_bash=${NIX_ANDROID_BASH:?NIX_ANDROID_BASH not set (use the packaged android-rebuild)}
nixargs=(--impure --accept-flake-config)
# Device closures are dozens of independent APK fetchurl derivations; build
# them concurrently whatever the controller's nix.conf says. max-jobs is part
# of the client options the daemon applies even for untrusted users.
max_jobs=${NIX_ANDROID_MAX_JOBS:-8}
[[ $max_jobs =~ ^([1-9][0-9]*|auto)$ ]] || { echo "NIX_ANDROID_MAX_JOBS must be a positive integer or 'auto'" >&2; exit 2; }
buildargs=("${nixargs[@]}" --max-jobs "$max_jobs")

usage() {
  cat <<'EOF'
Usage:
  android-rebuild build  --flake REF#DEVICE
  android-rebuild plan   --flake REF#DEVICE --serial SERIAL
  android-rebuild switch --flake REF#DEVICE --serial SERIAL
  android-rebuild status --flake REF#DEVICE --serial SERIAL
  android-rebuild generations --flake REF#DEVICE
  android-rebuild assist --flake REF#DEVICE --serial SERIAL [--watch]
  android-rebuild bootstrap --flake REF#DEVICE --serial SERIAL
  android-rebuild update --flake REF#DEVICE [--lock apps.lock.json]
  android-rebuild import --serial SERIAL [--snapshot-out PATH] [--report-out PATH]
                         [--obtainium-export PATH] [--app-manager-export PATH]
  android-rebuild suggest-sources --flake REF#DEVICE [--discover [--verify]]
    [--repo URL FINGERPRINT LABEL ...] [--release-hint PKG=owner/repo ...]

The --serial argument (or ANDROID_SERIAL) is mandatory for every device command.
APK fetches run in parallel: NIX_ANDROID_MAX_JOBS (default 8, or 'auto') is
passed to nix build as --max-jobs.
suggest-sources is read-only and device-free: it reports which apps.play /
apps.attended entries are published on a hash-lockable F-Droid source. Add
--repo to also check a third-party F-Droid repo (e.g. FUTO). --release-hint
checks a named GitHub/Gitea repo for package-id compatibility (recording its
signer for you to confirm). --discover proposes candidate repos from the
Obtainium catalog (a network query to a third-party host with your candidate
package ids); add --verify to resolve those proposals into verified
apps.release entries.
EOF
}

cmd=${1:-}
case $cmd in
help | -h | --help) usage; exit 0 ;;
"") usage >&2; exit 2 ;;
esac
shift
flakeref="."
serial=${ANDROID_SERIAL:-}
lock=apps.lock.json
snapshot_out=
report_out=
obtainium_export=
app_manager_export=
watch=0
flake_set=0
lock_set=0
release_hints=()
discover=0
verify=0
repo_specs=()
while [ $# -gt 0 ]; do
  case $1 in
  --flake)
    [ $# -ge 2 ] || { echo "--flake requires a value" >&2; exit 2; }
    flakeref=$2; flake_set=1; shift 2
    ;;
  --release-hint)
    [ $# -ge 2 ] || { echo "--release-hint requires PKG=owner/repo" >&2; exit 2; }
    release_hints+=("$2"); shift 2
    ;;
  --discover) discover=1; shift ;;
  --verify) verify=1; shift ;;
  --repo)
    [ $# -ge 4 ] || { echo "--repo requires URL FINGERPRINT LABEL" >&2; exit 2; }
    repo_specs+=("$2" "$3" "$4"); shift 4
    ;;
  --serial)
    [ $# -ge 2 ] || { echo "--serial requires a value" >&2; exit 2; }
    serial=$2; shift 2
    ;;
  --lock)
    [ $# -ge 2 ] || { echo "--lock requires a value" >&2; exit 2; }
    lock=$2; lock_set=1; shift 2
    ;;
  --snapshot-out)
    [ $# -ge 2 ] || { echo "--snapshot-out requires a value" >&2; exit 2; }
    snapshot_out=$2; shift 2
    ;;
  --report-out)
    [ $# -ge 2 ] || { echo "--report-out requires a value" >&2; exit 2; }
    report_out=$2; shift 2
    ;;
  --obtainium-export)
    [ $# -ge 2 ] || { echo "--obtainium-export requires a value" >&2; exit 2; }
    obtainium_export=$2; shift 2
    ;;
  --app-manager-export)
    [ $# -ge 2 ] || { echo "--app-manager-export requires a value" >&2; exit 2; }
    app_manager_export=$2; shift 2
    ;;
  --watch) watch=1; shift ;;
  -h | --help) usage; exit 0 ;;
  *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

# build/plan/switch read the lock baked in via mkDevice.lockFile; accepting
# --lock there would silently do nothing.
if [ "$lock_set" -eq 1 ] && [ "$cmd" != update ]; then
  echo "--lock is only valid with update" >&2
  exit 2
fi
if [ -n "$snapshot_out" ] && [ "$cmd" != import ]; then
  echo "--snapshot-out is only valid with import" >&2
  exit 2
fi
if [ -n "$report_out" ] && [ "$cmd" != import ]; then
  echo "--report-out is only valid with import" >&2
  exit 2
fi
if [ -n "$obtainium_export" ] && [ "$cmd" != import ]; then
  echo "--obtainium-export is only valid with import" >&2
  exit 2
fi
if [ -n "$app_manager_export" ] && [ "$cmd" != import ]; then
  echo "--app-manager-export is only valid with import" >&2
  exit 2
fi
if [ "$watch" -eq 1 ] && [ "$cmd" != assist ]; then
  echo "--watch is only valid with assist" >&2
  exit 2
fi
if [ "${#release_hints[@]}" -gt 0 ] && [ "$cmd" != suggest-sources ]; then
  echo "--release-hint is only valid with suggest-sources" >&2
  exit 2
fi
if [ "$discover" -eq 1 ] && [ "$cmd" != suggest-sources ]; then
  echo "--discover is only valid with suggest-sources" >&2
  exit 2
fi
if [ "$verify" -eq 1 ] && [ "$cmd" != suggest-sources ]; then
  echo "--verify is only valid with suggest-sources" >&2
  exit 2
fi
if [ "${#repo_specs[@]}" -gt 0 ] && [ "$cmd" != suggest-sources ]; then
  echo "--repo is only valid with suggest-sources" >&2
  exit 2
fi

case $cmd in
import)
  [ "$flake_set" -eq 0 ] || { echo "import does not take --flake" >&2; exit 2; }
  [ -n "$serial" ] || { echo "import requires --serial SERIAL (or ANDROID_SERIAL)" >&2; exit 2; }
  import_args=(--serial "$serial")
  [ -z "$snapshot_out" ] || import_args+=(--snapshot-out "$snapshot_out")
  [ -z "$report_out" ] || import_args+=(--report-out "$report_out")
  [ -z "$obtainium_export" ] || import_args+=(--obtainium-export "$obtainium_export")
  [ -z "$app_manager_export" ] || import_args+=(--app-manager-export "$app_manager_export")
  exec "$nix_android_bash" "$src/scripts/import.sh" "${import_args[@]}"
  ;;
build | plan | switch | assist | bootstrap | update | suggest-sources | status | generations) ;;
*) echo "unknown command: $cmd" >&2; usage >&2; exit 2 ;;
esac

if [ "$cmd" = plan ] || [ "$cmd" = switch ] || [ "$cmd" = assist ] || [ "$cmd" = bootstrap ] || [ "$cmd" = status ]; then
  [ -n "$serial" ] || { echo "$cmd requires --serial SERIAL (or ANDROID_SERIAL)" >&2; exit 2; }
fi

flake=${flakeref%%#*}
flake=${flake:-.}
dev=${flakeref#*#}
if [ "$dev" = "$flakeref" ] || [ -z "$dev" ]; then
  dev=$(nix eval "${nixargs[@]}" "$flake#androidConfigurations" --apply builtins.attrNames --json | jq -r 'if length == 1 then .[0] else error("multiple devices — pass --flake .#<name>: \(join(", "))") end')
fi
attr="$flake#androidConfigurations.$dev"

engine_args=(--serial "$serial")

# Nix prints only "copying path" lines while fetching, so say up front how
# much is coming. Best-effort: any failure (or an eval slower than a few
# seconds) prints nothing and the build reports the real error.
# ponytail: `-e` on the store path assumes the controller's local /nix/store;
# a remote --store would over-count. Size is unknown for release-lane
# entries and pre-size locks: "M+ MB" when partial, no size when none known.
fetch_progress() {
  local plan path size missing=0 bytes=0 unknown=
  plan=$(timeout 5 nix eval "${nixargs[@]}" "$attr.fetchPlan" --json 2>/dev/null) || return 0
  while IFS=$'\t' read -r path size; do
    [ -n "$path" ] && [ ! -e "$path" ] || continue
    missing=$((missing + 1))
    if [[ $size =~ ^[0-9]+$ ]]; then bytes=$((bytes + size)); else unknown=+; fi
  done < <(jq -r '.[] | [.path, (.size // "")] | @tsv' <<<"$plan" 2>/dev/null)
  [ "$missing" -gt 0 ] || return 0
  if [ "$bytes" -eq 0 ]; then
    echo "fetching $missing APKs ..." >&2
  else
    echo "fetching $missing APKs ($((bytes / 1000000))$unknown MB) ..." >&2
  fi
}
case $cmd in
build | plan | switch | assist | bootstrap) fetch_progress ;;
esac

case $cmd in
build)
  out=$(nix build "${buildargs[@]}" "$attr.manifest" --no-link --print-out-paths)
  echo "manifest: $out"
  ;;
plan | switch)
  conv=$(nix build "${buildargs[@]}" "$attr.converge" --no-link --print-out-paths)
  apply=()
  # switch records a generation receipt; plan never mutates or records.
  [ "$cmd" = switch ] && apply=(--apply --record)
  exec "$conv"/bin/* "${engine_args[@]}" "${apply[@]}"
  ;;
assist)
  manifest=$(nix build "${buildargs[@]}" "$attr.manifest" --no-link --print-out-paths)
  assist_args=()
  [ "$watch" -eq 0 ] || assist_args+=(--watch)
  exec "$nix_android_bash" "$src/scripts/assist-play.sh" "$manifest" --serial "$serial" "${assist_args[@]}"
  ;;
bootstrap)
  manifest=$(nix build "${buildargs[@]}" "$attr.manifest" --no-link --print-out-paths)
  exec "$nix_android_bash" "$src/scripts/bootstrap.sh" "$manifest" --serial "$serial"
  ;;
suggest-sources)
  candidates=$(nix eval "${nixargs[@]}" "$attr.config" \
    --apply 'c: c.apps.play ++ c.apps.attended' --json | jq -r '.[]')
  abi=$(nix eval "${nixargs[@]}" "$attr.config" --apply 'c: c.device.abi' --raw)
  resolver=$(nix build "${nixargs[@]}" "$src#update-lock" --no-link --print-out-paths)/bin/nix-android-update-lock
  suggest_args=(--resolver "$resolver" --abi "$abi")
  [ "$discover" -eq 0 ] || suggest_args+=(--discover)
  [ "$verify" -eq 0 ] || suggest_args+=(--verify)
  # --repo triples: URL FP LABEL, URL FP LABEL, ...
  i=0
  while [ "$i" -lt "${#repo_specs[@]}" ]; do
    suggest_args+=(--repo "${repo_specs[$i]}" "${repo_specs[$((i + 1))]}" "${repo_specs[$((i + 2))]}")
    i=$((i + 3))
  done
  for h in ${release_hints[@]+"${release_hints[@]}"}; do suggest_args+=(--release-hint "$h"); done
  exec "$nix_android_bash" "$src/scripts/suggest-sources.sh" "${suggest_args[@]}" <<<"$candidates"
  ;;
status)
  # Drift check: re-plan the last-applied generation against the device. This
  # reports how the device has diverged from what was last converged — not what
  # the current config would do (that is `plan`). Reachable state only: it
  # cannot see app data, downgrades, or ensure-only entries the device dropped.
  name=$(nix eval "${nixargs[@]}" "$attr.config" --apply 'c: c.device.name' --raw)
  state="${XDG_STATE_HOME:-$HOME/.local/state}/nix-android/${name}"
  log="$state/log.jsonl"
  if [ ! -s "$log" ]; then
    echo "no recorded convergence for '$name' — run 'android-rebuild switch' first"
    exit 0
  fi
  last=$(tail -n1 "$log")
  gen=$(jq -r '.generation' <<<"$last")
  when=$(jq -r '.time' <<<"$last")
  recorded_serial=$(jq -r '.serial' <<<"$last")
  saved="$state/generations/${gen}.json"
  echo "last converged: generation $gen at $when (serial $recorded_serial)"
  # shellcheck source-path=SCRIPTDIR/../engine
  # shellcheck source=generations.sh
  source "$src/engine/generations.sh"
  current_fp=$(adb -s "$serial" shell getprop ro.build.fingerprint </dev/null | tr -d '\r') || current_fp=
  os_change_note "$last" "$current_fp"
  # Two devices are commonly attached; drift computed against the wrong one
  # looks authoritative. Warn loudly, but proceed: a serial can legitimately
  # change for the same device (USB vs wifi adb, re-provisioning).
  if [ "$serial" != "$recorded_serial" ]; then
    echo "warning: generation $gen was applied to serial $recorded_serial, but checking $serial — drift below is only meaningful if these are the same device" >&2
  fi
  if [ ! -f "$saved" ]; then
    echo "generation $gen's manifest is missing (deleted or never fully written); cannot check drift" >&2
    exit 1
  fi
  echo "checking device against generation $gen..."
  exec "$nix_android_bash" "$src/engine/converge.sh" "$saved" "${engine_args[@]}"
  ;;
generations)
  name=$(nix eval "${nixargs[@]}" "$attr.config" --apply 'c: c.device.name' --raw)
  state="${XDG_STATE_HOME:-$HOME/.local/state}/nix-android/${name}"
  log="$state/log.jsonl"
  if [ ! -s "$log" ]; then
    echo "no generations recorded for '$name'"
    exit 0
  fi
  jq -r '"generation \(.generation)  \(.time)  \(.changes) change(s)  serial \(.serial)  os \(.os.incremental // "unknown")"' "$log"
  ;;
update)
  config=$(nix eval "${nixargs[@]}" "$attr.config" \
    --apply 'c: { inherit (c.device) abi; inherit (c.apps) fdroid release; }' --json)
  abi=$(jq -er '.abi' <<<"$config")
  mapfile -t fdroid < <(jq -r '.fdroid.packages[]' <<<"$config")
  mapfile -t fspecs < <(jq -r '.fdroid.repos |
    to_entries[] | .value as $r | $r.packages[] | "--fdroid\n\(.)\n\($r.url)\n\($r.fingerprint)"' <<<"$config")
  mapfile -t relspecs < <(jq -r '.release |
    to_entries[] | if .value.github != null
      then "--github\n\(.key)=\(.value.github)"
      elif .value.gitea != null
      then "--gitea\n\(.key)=\(.value.gitea)"
      elif .value.url != null
      then "--url\n\(.key)=\(.value.url)"
      elif .value.updateJson != null
      then "--urljson\n\(.key)=\(.value.updateJson)"
      else "--html\n\(.key)=\(.value.html.url)\n\(.value.html.linkFilter)" end' <<<"$config")
  resolver=$(nix build "${nixargs[@]}" "$src#update-lock" --no-link --print-out-paths)
  # The config is the authoritative full set of locked packages, so a removed
  # declaration drops out of the lock: rewrite it rather than merge into it.
  exec "$resolver/bin/nix-android-update-lock" --lock "$lock" --abi "$abi" --replace "${fdroid[@]}" "${fspecs[@]}" "${relspecs[@]}"
  ;;
esac
