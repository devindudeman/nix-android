# Developing nix-android

Read [CAPABILITIES.md](./CAPABILITIES.md) for the public ADB-to-Nix map,
[SUPPORT.md](./SUPPORT.md) for the target-family contract,
[PRIMITIVES.md](./PRIMITIVES.md) before adding an option,
[LIMITS.md](./LIMITS.md) before widening scope, and [IMPORT.md](./IMPORT.md)
before changing device discovery or generated declarations.

## Architecture

```text
devices/<name>.nix ── evalModules ──> manifest.json ── converge.sh ──> adb ──> device
+ modules/options.nix  typed config     pure data         plan/apply
                       + locked APKs    + store paths     no Nix logic
```

The manifest/engine split is load-bearing. Nix owns option types, assertions,
source authentication, artifact fetching, and manifest construction. The Bash
engine validates the complete JSON document, reads device state, prints a plan,
and writes only with `--apply`. Keep source-specific logic out of the engine.
Any semantic field addition must bump `manifestVersion`; old and new engine
pairs must fail closed instead of ignoring desired state.

## File map

| Path | Responsibility |
| --- | --- |
| `modules/options.nix` | Public option surface; every device option needs a verified primitive |
| `lib/default.nix` | `mkDevice`, assertions, lock/source binding, store APKs, manifest, packaged engine |
| `engine/converge.sh` | Strict manifest preflight and plan/apply reconciliation |
| `engine/read-state.sh` | Shared device-output parsers, sourced by the engine and the bench oracle |
| `scripts/android-rebuild.sh` | `build`, `update`, `plan`, `switch`, `assist`, `bootstrap`, and `import` CLI |
| `scripts/update-lock.sh` | Signed F-Droid metadata and GitHub/Gitea release resolution |
| `scripts/import.sh` | Read-only capture orchestration and starter Nix rendering |
| `scripts/package-snapshot.py` | AOSP package-protobuf decoder and normalized snapshot writer |
| `scripts/render-import.py` | Deterministic snapshot-to-Nix renderer and attended-source classification |
| `scripts/provenance-adapters.py` | Credential-free Obtainium/App Manager export normalization |
| `scripts/assist-play.sh` | Official Play listing queue; watch mode advances only after package presence |
| `scripts/bootstrap.sh` | Resumable managed-APK, Play-consent, and full-state orchestration |
| `scripts/atlas-probe.sh` | Read-only `cmd`/settings capability capture |
| `docs/CAPABILITIES.md` | Public ADB read/write/semantics/import coverage map |
| `docs/SUPPORT.md` | Stock-Pixel/GrapheneOS support contract and executed evidence matrix |
| `scripts/bench-e2e.sh` | Two-cycle emulator apply, direct verification, reboot persistence, no-op, and teardown gate |
| `scripts/test-update-lock.sh` | Offline signed-index, signer, archive, package-ID, atomic-failure, and lock merge/replace resolver tests |
| `devices/bench.nix` | x86_64 AOSP mutation-test configuration |
| `.github/workflows/ci.yml` | x86_64 Linux checks and Apple Silicon package/CLI gate |

## Non-negotiable safety rules

1. Every device operation names an adb serial. Never remove `--serial` from a
   command or engine call.
2. Real daily phones receive read-only probes unless emulator proof and the
   owner's explicit mutation approval already exist.
3. A new option requires a working read, write, real-change read-back, and
   graceful-reboot persistence test on the emulator. Record the result in
   `PRIMITIVES.md` in the same change.
4. Plan is read-only. Apply behavior must remain behind `switch`, `bootstrap`,
   or internal `--apply`, and destructive behavior behind explicit configuration.
5. Raw phone captures are personal data. Store them under
   `~/Documents/phone-migration/`, never in this repository.
6. Never use an abrupt `adb reboot` after writes. Allow state to settle and use
   a graceful user-requested reboot for persistence testing.

## Development shell and checks

```console
direnv --version # contributor prerequisite
direnv allow
just fmt
just check
```

`just check` builds native-host formatting, shellcheck, statix, deadnix,
packaged CLI safety, strict-manifest, import rendering, Play-assist and
bootstrap safety, signed-lock resolver, and negative module-validation checks, plus the
platform's positive controller build.
The whole `nix flake check` remains intentionally unused because devenv task
evaluation currently produces a spurious `path .drv is not valid` failure.

Use the emulator gate proportionally. Parser, renderer, and documentation
changes normally need `just check` plus a read-only generated-module/no-op
check. Run one fresh emulator cycle while developing a mutation-class engine
change. Reserve two independent cycles for a release boundary or before
proposing the corresponding real-phone mutation; do not turn the release gate
into the inner edit loop.

For a clean CI-equivalent Linux run:

```console
nix build \
  .#checks.x86_64-linux.{bench-manifest,formatting,shellcheck,statix,deadnix,cli-safety,manifest-safety,import-snapshot,assist-safety,bootstrap-safety,update-lock-safety,validation} \
  --accept-flake-config --no-link
nix build \
  .#packages.x86_64-linux.{android-rebuild,update-lock} \
  --accept-flake-config --no-link
```

The public host matrix is deliberately narrow: x86_64 Linux and Apple Silicon
macOS. `mkDevice.system` is required so a Darwin caller cannot silently build a
Linux engine. Packaged entry points use the Nix Bash path; never reintroduce an
ambient `bash`, because Apple's system Bash lacks `mapfile` and
`inherit_errexit`.

## Emulator loop

On x86_64 Linux:

```console
just emu
nix run .#android-rebuild -- \
  plan --flake .#bench --serial emulator-5554
nix run .#android-rebuild -- \
  bootstrap --flake .#bench --serial emulator-5554
nix run .#android-rebuild -- \
  plan --flake .#bench --serial emulator-5554
adb -s emulator-5554 emu kill
```

`just emu` puts the headless AOSP emulator in a user systemd scope capped at
12 GiB, disables swap growth for the scope, requests 2 GiB guest RAM, and uses
SwiftShader rather than host Vulkan. Do not launch the flake emulator naked on
a laptop; an earlier host-GPU run exhausted unreclaimable memory and hung the
machine.

The release persistence pass is:

1. plan a fresh emulator;
2. bootstrap the fresh device;
3. verify the declared state directly;
4. re-plan and require no changes;
5. apply the inverse fixture for permission flags, package AppOps, suspension,
   locales, input-method selection, Data Saver, and app links; verify it and
   require a no-op plan;
6. allow inverse state to settle, run a graceful reboot, then verify and
   require a no-op plan again;
7. restore the forward declaration and verify it;
8. allow state to settle, run
   `adb -s emulator-5554 shell svc power reboot userrequested`, and wait for
   boot completion;
9. re-plan and require no changes again.

Run that gate twice on independent fresh userdata with `just bench-e2e 2`.
It owns emulator-5554, enforces boot/readiness deadlines, verifies exact state,
requires a new boot ID after graceful reboot, exercises the structured importer
and its Play/attended coverage, evaluates the generated module through
`lib.mkDevice`, requires its plan to be a no-op, proves cleanup preserves a Play
declaration, uses HeliBoard as a real second input method, proves the phased
bootstrap path, removes each temporary AVD, and waits for the ADB transport to
disappear. Both
cycles must pass before any real-phone mutation is proposed.

## Engine traps already found

- `adb` reads stdin. Every call goes through the wrapper that redirects
  `/dev/null`, or it can drain a surrounding `while read` loop.
- adb's client joins `adb shell ARG...` with spaces. Every remote argv call in
  the engine goes through `adb_shell`, which constructs one POSIX-single-quoted
  command. Local Bash quotes alone do not protect the device shell.
- Tab is a whitespace-class `IFS` separator and collapses empty fields. Engine
  tuples use ASCII Unit Separator (`\037`) after the schema rejects conflicting
  control characters.
- Process substitutions do not make `set -e` notice producer failures. The
  strict manifest preflight runs before the first adb read, so malformed JSON
  can never turn into an empty destructive declaration set.
- Android writes several `/data/system` files asynchronously. Hard reboot tests
  produced false persistence failures; graceful shutdown persisted them.
- Keep shell-variable boundaries ASCII-obvious (`${name}` or ASCII punctuation).
  Darwin's Nix Bash treated a variable immediately followed by a Unicode
  ellipsis as a longer name under `set -u`; the physical-Mac gate caught it.

## Adding a fetched app source

End with one uniform managed entry: package ID, integer versionCode, and a
hash-addressed APK store path.

- Authenticate repository metadata before trusting hashes.
- Bind the lock entry to the configured source and trust anchor.
- Fail atomically; an unsuccessful refresh must not replace the lock.
- Validate release package ID with aapt2.
- Treat archive member names as untrusted, require exactly one regular APK,
  stream it with `tar --`, and shell-escape it again at build time.
- Test correct resolution, wrong trust anchor, wrong package ID, duplicate
  declarations, and stale-source rejection.

Attended sources are deliberately different: they create no APK store path and
never automate a consent screen. `apps.play` only asserts package presence and
lets `assist` open the official listing. Any new attended source must preserve
explicit user consent, participate in duplicate-source and cleanup safety, and
have source-specific diagnostics plus an offline command fixture.

## Adding a device option

Follow the whole flow in one change:

1. emulator read/write/read-back/persistence proof;
2. a `PRIMITIVES.md` row;
3. typed option and conflict assertions;
4. manifest field;
5. engine read, diff, plan line, and apply action;
6. one small negative or idempotence check;
7. user and developer documentation.

The raw `android.settings` namespace is an expert escape hatch, not evidence
that every settings key is supported. SystemUI-owned Quick Settings state is a
known example that accepts a write and then reverts it.
