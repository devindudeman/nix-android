# Faithful device import

`android-rebuild import` is the discovery side of nix-android: observe a phone
without changing it, preserve the evidence in a versioned snapshot, and render
the subset that nix-android can safely declare. The snapshot is deliberately
richer than the generated Nix. Observation is not proof that adb-shell can
reapply a value safely.

## Model

Import has four separate layers:

1. **Evidence** — raw, read-only command output from one explicitly selected
   adb serial.
2. **Snapshot** — normalized, versioned JSON that records facts and their
   scope without depending on human-oriented `dumpsys` formatting.
3. **Declaration** — conservative Nix generated only for state whose meaning
   and convergence primitive are already documented.
4. **Coverage report** — optional deterministic JSON classifying each surface
   as `declarable`, `observed-only`, `ambiguous`, or `unreachable` from the same
   renderer decisions that generate Nix.

The snapshot is personal data. Keep it outside a public checkout, for example
under `~/Documents/phone-migration/`. Generated Nix contains an app inventory
too and needs the same review before publication.

## Package backbone

The primary package source is AOSP's binary `dumpsys package --proto` output.
Its upstream
[`PackageServiceDumpProto`](https://android.googlesource.com/platform/frameworks/base/+/refs/heads/main/core/proto/android/service/package.proto)
defines wire fields for package name, UID, version, update time,
installer, install source, split APKs, per-user install/enabled/suspended state,
and per-user granted permissions. The importer normalizes those fields
into its own schema because the diagnostic proto is an internal AOSP format,
not a public Android SDK compatibility contract.

`pm list packages --user USER` supplies the authoritative managed-user
installation set, while its `-3` form supplies the third-party classification.
This matters for global services such as DeviceIdle: a package can exist only
in another profile yet still appear in a global allowlist. Installer and
install-source fields are evidence, not provenance: adb installs may report no
installer, and an
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

The full managed-user inventory is deliberately independent evidence rather
than a required protobuf subset. A GrapheneOS capture included an installed
system package in `pm list packages --user 0` that the diagnostic protobuf
omitted. Only missing third-party packages fail closed, because those are the
entries that become active app declarations.

## Snapshot schema v2

The optional JSON snapshot has this top-level shape:

```json
{
  "schemaVersion": 2,
  "device": {
    "model": "Pixel 6",
    "product": "oriole",
    "abi": "arm64-v8a",
    "sdk": 37,
    "securityPatch": "2026-07-05",
    "managedUser": 0
  },
  "android": {
    "nightMode": "Night mode: auto",
    "privateDns": { "mode": "off", "specifier": null },
    "roles": { "browser": [], "sms": [], "dialer": [], "home": [] },
    "installedPackagesForManagedUser": [],
    "disabledPackages": [],
    "deviceIdleWhitelist": { "entries": [], "unparsed": [] },
    "runtimePermissionDefinitions": [],
    "runtimePermissionRestrictions": {},
    "unparsedPermissionDefinitionRows": [],
    "unparsedPermissionStateRows": [],
    "unparsedPermissionRestrictionRows": [],
    "appOps": {},
    "derivedAppOpRows": [],
    "unparsedAppOpRows": [],
    "appLocales": {},
    "unparsedAppLocaleRows": [],
    "inputMethod": { "enabled": [], "selected": null, "unparsed": [] },
    "dataSaver": { "enabled": false, "restrictedUids": [], "exemptUids": [] },
    "appLinks": {},
    "unparsedAppLinkRows": []
  },
  "provenance": {
    "obtainium": { "schemaVersion": 2, "apps": [] },
    "appManager": { "format": "app-list-json", "packages": [] }
  },
  "packages": []
}
```

Each package preserves the package proto's identity/version/install-source,
split, per-user state, per-user granted-permission fields, and parsed runtime
permission flags, plus `thirdPartyForManagedUser`. The Android object also
preserves package-level AppOps rows separately from UID modes. Switch-derived
effective AppOps rows are retained as observed-only evidence, not mistaken for
explicit package overrides. The Android object also preserves per-app locales,
input-method state, global/per-UID Data Saver evidence, and user plus verifier
app-link state. Arrays and packages are sorted so two identical observations
produce an identical snapshot. Capture time and adb serial are intentionally
absent: neither is desired device state, and serials should not be encouraged
into public configuration.

`provenance` is present only when an explicit export adapter is supplied. The
Obtainium adapter reads schema-v2 app IDs, source URLs, and source-type names.
It accepts canonical GitHub URLs plus Codeberg or self-hosted Forgejo URLs
identified by Obtainium's upstream `Codeberg` source identifier. It discards
settings, per-app additional settings, timestamps, versions, credentials,
unsupported host/source details, and arbitrary export fields. The App Manager
adapter accepts the current JSON app-list array and preserves only package ID,
signer SHA-256, and installer. Labels and timestamps are ignored. Both adapters
intersect with ADB's third-party owner-user inventory, which remains
authoritative for scope.

`firstInstallTimeMsWire` is intentionally named as raw wire evidence. AOSP's
schema declares its millisecond timestamp as signed `int32`, which cannot hold
a present-day Unix millisecond value and was observed overflowed on the stock
Pixel. The importer does not guess a corrected timestamp.

The `android` object comes from narrow read-only commands for dark mode,
Private DNS, four roles, disabled packages, DeviceIdle allowlist ownership, and
runtime-toggleable permission definitions. The package protobuf's granted set
is broader than runtime state: it also contains normal and app-defined
permissions. Generated grants are therefore the intersection of the managed
user's observed grants and `pm list permissions -d -g -f`, minus hard/soft
restricted permissions discovered from `dumpsys package permissions`.
Restricted grants depend on installer/platform allowlisting and remain
ambiguous evidence rather than a false post-wipe promise. An unparsed
restriction row fails closed for the permission it names; only a row that
cannot be attributed to one permission fails all automatic grant rendering
closed. Everything else is retained in JSON and counted as omitted.
Import never generates a revoke from absence, because absence alone does not
establish deliberate deny intent or
app-op/foreground/one-time scope. A separate per-package `dumpsys package`
read preserves permission flags. The four shell-owned writable flags are
rendered exactly, including explicit empty lists, but only for rows whose
granted state the declaration also reproduces — flags alone must not assert
`user-fixed` on a permission the configuration leaves denied. Android-owned
flags remain observed evidence.

Additional narrow reads capture `cmd locale`, `ime`, `cmd netpolicy`, and
`pm get-app-links --user 0` state. The package protobuf supplies suspension
authority metadata. Import activates only adb-shell suspension, non-default
locale lists, internally consistent enabled/selected input methods, global
Data Saver, and non-default user app-link choices. It retains but does not
activate per-app NetworkPolicy UID rows (they failed the AOSP reboot gate),
app-link verifier state, invalid manifest `autoVerify` domains, or
disabled-domain rows that cannot be distinguished from never-selected defaults.

Generated Nix additionally includes unambiguous roles, representable dark and
Private DNS state, disabled third-party packages, user-added DeviceIdle
exemptions whose packages are installed for the managed user, and filtered
granted runtime permissions and writable permission flags for third-party
packages, plus non-default package-level app-op overrides, adb-shell package
suspension, non-default app locales, consistent input-method state, global
Data Saver, and non-default user app-link choices. UID-wide app-op
modes are retained as a separate boundary because they commonly mirror
permission state and are not equivalent to package overrides. Automatic/custom dark
mode, multiple role holders, disabled system packages, system-package
permission state, system allowlists, other-profile DeviceIdle rows, and
unparsed rows remain snapshot evidence with explicit omission comments.

## Stock and GrapheneOS comparison

The same importer is the comparison instrument; no second probing mode is
needed. Capture each phone with a distinct explicit serial and keep both outputs
private:

```console
(umask 077
nix run .#android-rebuild -- import --serial STOCK_SERIAL \
  --snapshot-out ~/Documents/phone-migration/stock.snapshot.json \
  > ~/Documents/phone-migration/stock.nix)

(umask 077
nix run .#android-rebuild -- import --serial GRAPHENE_SERIAL \
  --snapshot-out ~/Documents/phone-migration/graphene.snapshot.json \
  --report-out ~/Documents/phone-migration/graphene.coverage.json \
  > ~/Documents/phone-migration/graphene.nix)
```

Compare normalized fields, not raw ordering or serials (the schema already
sorts arrays and deliberately stores no serial). A useful compatibility review
starts with SDK/security patch, `runtimePermissionDefinitions`, roles, disabled
packages, DeviceIdle row sources, and the generated omission comments. A
difference establishes behavior only for those two builds; it is not a claim
about every stock OEM image or every GrapheneOS release.

Schema changes must increment `schemaVersion`. A decoder failure is fatal; the
importer must never silently fall back to an empty inventory. A future AOSP
wire change may add a separately tested text fallback, but it must retain the
same normalized schema and visibly identify weaker evidence.

## Prior art and adapters

None of the prior art reviewed for this design supplies the same locked-device,
external-Nix, read-current-state workflow. The useful neighboring designs are:

- [App Manager](https://muntashir.dev/AppManager/en/) inventories broad app
  state. Its GPL-3.0 code is not copied into this MIT project; the implemented
  adapter independently consumes the user-supplied JSON app-list format and
  keeps only signer and installer evidence.
- The [Android Management API policy](https://developers.google.com/android/management/reference/rest/v1/enterprises.policies)
  and [device](https://developers.google.com/android/management/reference/rest/v1/enterprises.devices)
  resources cleanly separate desired policy, observed state, and compliance,
  but require enterprise management/enrollment that nix-android intentionally
  does not impose.
- [Universal Android Debloater Next Generation](https://github.com/Universal-Debloater-Alliance/universal-android-debloater-next-generation)
  models per-user package state and backup/restore. Its catalog and GPL-3.0
  implementation remain external prior art.
- [Obtainium](https://github.com/ImranR98/Obtainium) export schema v2 carries
  upstream release configuration that adb cannot infer. The implemented
  adapter consumes a user-provided export without copying credentials or
  application settings.
- [Nix-on-Droid](https://github.com/nix-community/nix-on-droid) manages a Nix
  userspace inside Termux; [robotnix](https://github.com/danielfullmer/robotnix)
  builds Android images. Neither imports/converges a stock locked device over
  adb.

## Fidelity status

The importer layers were implemented in evidence order:

1. **implemented:** package-protobuf snapshot plus conservative Play/attended
   rendering;
2. **implemented:** targeted reads and safe rendering for already-supported
   roles, dark mode, Private DNS, user-added DeviceIdle exemptions, and disabled
   third-party packages;
3. **implemented:** runtime-permission definition filtering and conservative
   grant-only rendering;
4. **implemented:** writable permission-flag and package-level app-op capture,
   modeling, rendering, and convergence without conflating UID modes;
5. **implemented:** credential-free App Manager and Obtainium export adapters
   for signer and supported release-source facts adb cannot recover;
6. **implemented:** a minimal machine-readable coverage report generated by the
   same branches as the starter Nix and omission comments.
7. **implemented:** suspension authority, per-app locale, input-method,
   global Data Saver, and user app-link import/convergence; per-app Data Saver
   UID rows remain observed-only after a reproduced reboot-persistence failure.

[CAPABILITIES.md](./CAPABILITIES.md) is the complete classification map for
publicly managed, candidate, observed-only, and unreachable state.

Raw settings-table dumps are not a faithful declaration source: they mix
defaults, derived state, component-owned values, and sensitive data. New
setting imports require a narrow allowlist and the same read/write/read-back/
reboot proof required for a normal module option.
