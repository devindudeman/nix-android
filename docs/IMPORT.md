# Faithful device import

`android-rebuild import` is the discovery side of nix-android: observe a phone
without changing it, preserve the evidence in a versioned snapshot, and render
the subset that nix-android can safely declare. The snapshot is deliberately
richer than the generated Nix. Observation is not proof that adb-shell can
reapply a value safely.

## Model

Import has three separate layers:

1. **Evidence** — raw, read-only command output from one explicitly selected
   adb serial.
2. **Snapshot** — normalized, versioned JSON that records facts and their
   scope without depending on human-oriented `dumpsys` formatting.
3. **Declaration** — conservative Nix generated only for state whose meaning
   and convergence primitive are already documented.

The snapshot is personal data. Keep it outside a public checkout, for example
under `~/Documents/phone-migration/`. Generated Nix contains an app inventory
too and needs the same review before publication.

## Package backbone

The primary package source is AOSP's binary `dumpsys package --proto` output.
Its upstream
[`PackageServiceDumpProto`](https://android.googlesource.com/platform/frameworks/base/+/refs/heads/main/core/proto/android/service/package.proto)
defines wire fields for package name, UID, version, update time,
installer, install source, split APKs, per-user install/enabled/suspended state,
and per-user granted runtime permissions. The importer normalizes those fields
into its own schema because the diagnostic proto is an internal AOSP format,
not a public Android SDK compatibility contract.

`pm list packages -3 --user USER` supplements the proto with the managed
user's third-party classification. Installer and install-source fields are
evidence, not provenance: adb installs may report no installer, and an
installer package does not identify a repository, release URL, or signing
trust anchor. Import fails if that independent package list names an app absent
from the decoded protobuf, preventing a partial diagnostic dump from silently
dropping declarations. Consequently, generated source declarations remain
explicitly conservative:

- packages whose recorded installer is `com.android.vending` become
  `apps.play`, retaining the source identity and user-consent boundary;
- every other observed third-party package becomes an `apps.attended` presence
  assertion, which is safe to plan without inventing a fetched source;
- recognized main-F-Droid and Obtainium installers add commented curation
  candidates, never active managed-source declarations.

## Snapshot schema v1

The optional JSON snapshot has this top-level shape:

```json
{
  "schemaVersion": 1,
  "device": {
    "model": "Pixel 6",
    "product": "oriole",
    "abi": "arm64-v8a",
    "sdk": 37,
    "securityPatch": "2026-07-05",
    "managedUser": 0
  },
  "packages": []
}
```

Each package preserves the package proto's identity/version/install-source,
split, per-user state, and per-user granted-permission fields, plus
`thirdPartyForManagedUser`. Arrays and packages are sorted so two identical
observations produce an identical snapshot. Capture time and adb serial are
intentionally absent: neither is desired device state, and serials should not
be encouraged into public configuration.

Schema changes must increment `schemaVersion`. A decoder failure is fatal; the
importer must never silently fall back to an empty inventory. A future AOSP
wire change may add a separately tested text fallback, but it must retain the
same normalized schema and visibly identify weaker evidence.

## Prior art and adapters

None of the prior art reviewed for this design supplies the same locked-device,
external-Nix, read-current-state workflow. The useful neighboring designs are:

- [App Manager](https://muntashir.dev/AppManager/en/) inventories broad app
  state and exports profiles. Its GPL-3.0 code is not copied into this MIT
  project; a user-supplied export can become an optional adapter.
- The [Android Management API policy](https://developers.google.com/android/management/reference/rest/v1/enterprises.policies)
  and [device](https://developers.google.com/android/management/reference/rest/v1/enterprises.devices)
  resources cleanly separate desired policy, observed state, and compliance,
  but require enterprise management/enrollment that nix-android intentionally
  does not impose.
- [Universal Android Debloater Next Generation](https://github.com/Universal-Debloater-Alliance/universal-android-debloater-next-generation)
  models per-user package state and backup/restore. Its catalog and GPL-3.0
  implementation remain external prior art.
- [Obtainium](https://github.com/ImranR98/Obtainium) export schema v2 can carry
  the upstream release configuration that adb cannot infer. A future optional
  adapter should consume a user-provided credential-free export.
- [Nix-on-Droid](https://github.com/nix-community/nix-on-droid) manages a Nix
  userspace inside Termux; [robotnix](https://github.com/danielfullmer/robotnix)
  builds Android images. Neither imports/converges a stock locked device over
  adb.

## Roadmap

The next fidelity slices are deliberately ordered by evidence quality:

1. package-protobuf snapshot plus conservative Play/attended rendering;
2. targeted reads for already-supported roles, dark mode, Private DNS,
   user-added device-idle exemptions, and disabled third-party packages;
3. runtime-permission filtering against permission definitions before
   rendering grants or revocations;
4. explicit App Manager and Obtainium export adapters for facts adb cannot
   recover;
5. an import report that labels every fact `declarable`, `observed-only`,
   `ambiguous`, or `unreachable` and explains every omission.

Raw settings-table dumps are not a faithful declaration source: they mix
defaults, derived state, component-owned values, and sensitive data. New
setting imports require a narrow allowlist and the same read/write/read-back/
reboot proof required for a normal module option.
