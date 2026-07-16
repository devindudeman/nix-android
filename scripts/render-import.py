#!/usr/bin/env python3
"""Render a normalized nix-android snapshot as conservative starter Nix."""

import argparse
import json
import re
from pathlib import Path


PACKAGE_NAME = re.compile(r"[A-Za-z0-9_]+(?:\.[A-Za-z0-9_]+)+")
PERMISSION_NAME = re.compile(r"[A-Za-z0-9_.]+")
COMPONENT_NAME = re.compile(
    r"[A-Za-z0-9_]+(?:\.[A-Za-z0-9_]+)+/[.]?[A-Za-z0-9_$]+(?:\.[A-Za-z0-9_$]+)*"
)
LOCALE_TAG = re.compile(
    r"[a-z]{2,8}(?:-[A-Z][a-z]{3})?(?:-(?:[A-Z]{2}|[0-9]{3}))?"
    r"(?:-(?:[a-z0-9]{5,8}|[0-9][a-z0-9]{3}))*"
    r"(?:-[0-9a-wy-z](?:-[a-z0-9]{2,8})+)*(?:-x(?:-[a-z0-9]{1,8})+)?"
)
DOMAIN_NAME = re.compile(
    r"(?:\*\.)?[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?)+"
)
FDROID_INSTALLERS = {
    "org.fdroid.fdroid",
    "org.fdroid.basic",
    "com.looker.droidify",
    "com.machiav3lli.fdroid",
}
OBTAINIUM_INSTALLERS = {
    "dev.imranr.obtainium",
    "dev.imranr.obtainium.fdroid",
}
PLAY_INSTALLER = "com.android.vending"
# Mirrors writable_permission_flags in engine/read-state.sh (the engine/bench
# source) and the enum in modules/options.nix; change all three together.
WRITABLE_PERMISSION_FLAGS = {
    # REVIEW_REQUIRED stays Android-owned evidence: PermissionController
    # rewrites it from the app's targetSdk, so shell cannot own it.
    "REVOKED_COMPAT": "revoked-compat",
    "REVOKE_WHEN_REQUESTED": "revoke-when-requested",
    "USER_FIXED": "user-fixed",
    "USER_SET": "user-set",
}
SHA256 = re.compile(r"[0-9A-Fa-f]{64}")


def nix_list(values, indent="    "):
    return "\n".join(f"{indent}{json.dumps(value)}" for value in values)


def comments(values):
    return "\n".join(f"  # {comment(value)}" for value in values)


def comment(value):
    return str(value).replace("\r", " ").replace("\n", " ")


def private_dns_value(private_dns):
    mode = private_dns.get("mode")
    specifier = private_dns.get("specifier")
    if mode in {"off", "opportunistic"}:
        return mode
    if mode == "hostname" and isinstance(specifier, str):
        labels = specifier.split(".")
        if len(specifier) <= 253 and labels and all(
            re.fullmatch(r"[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?", label)
            for label in labels
        ):
            return specifier
    return None


def render_with_coverage(snapshot):
    if snapshot.get("schemaVersion") != 2:
        raise ValueError("unsupported nix-android snapshot schema")
    device = snapshot.get("device", {})
    abi = device.get("abi")
    if abi not in {"arm64-v8a", "armeabi-v7a", "x86_64"}:
        raise ValueError(f"unsupported device ABI: {abi!r}")
    model = str(device.get("model", "unknown")).replace("\r", " ").replace("\n", " ")

    packages = []
    third_party_by_name = {}
    for package in snapshot.get("packages", []):
        if not package.get("thirdPartyForManagedUser"):
            continue
        name = package.get("name")
        if not isinstance(name, str) or not PACKAGE_NAME.fullmatch(name):
            raise ValueError(f"invalid Android package name in snapshot: {name!r}")
        packages.append((name, package.get("installerName")))
        third_party_by_name[name] = package
    packages.sort()

    installers = dict(packages)
    provenance = snapshot.get("provenance", {})
    obtainium_entries = provenance.get("obtainium", {}).get("apps", [])
    release_github = {}
    release_gitea = {}
    unresolved_obtainium = []
    for entry in obtainium_entries:
        name = entry.get("package") if isinstance(entry, dict) else None
        if not isinstance(name, str) or not PACKAGE_NAME.fullmatch(name):
            raise ValueError(f"invalid Obtainium provenance package: {name!r}")
        source = entry.get("source")
        if installers.get(name) not in OBTAINIUM_INSTALLERS or not isinstance(source, dict):
            unresolved_obtainium.append(name)
            continue
        kind = source.get("kind")
        value = source.get("value")
        if kind == "github" and isinstance(value, str):
            release_github[name] = value
        elif kind == "gitea" and isinstance(value, str):
            release_gitea[name] = value
        else:
            unresolved_obtainium.append(name)
    release_packages = set(release_github) | set(release_gitea)

    play = [name for name, installer in packages if installer == PLAY_INSTALLER]
    attended = [
        name
        for name, installer in packages
        if installer != PLAY_INSTALLER and name not in release_packages
    ]
    fdroid = [name for name, installer in packages if installer in FDROID_INSTALLERS]
    obtainium = [
        name
        for name, installer in packages
        if installer in OBTAINIUM_INSTALLERS and name not in release_packages
    ]

    app_manager_entries = provenance.get("appManager", {}).get("packages", [])
    signer_notes = []
    installer_mismatches = 0
    signer_count = 0
    for entry in app_manager_entries:
        name = entry.get("package") if isinstance(entry, dict) else None
        signatures = entry.get("signerSha256") if isinstance(entry, dict) else None
        if (
            not isinstance(name, str)
            or not PACKAGE_NAME.fullmatch(name)
            or not isinstance(signatures, list)
            or not all(
                isinstance(signature, str) and SHA256.fullmatch(signature)
                for signature in signatures
            )
        ):
            raise ValueError("invalid App Manager provenance entry")
        signer_count += len(signatures)
        signer_notes.append(f"App Manager signer {name}: {', '.join(signatures)}")
        exported_installer = entry.get("installerPackage")
        if exported_installer is not None and exported_installer != installers.get(name):
            installer_mismatches += 1

    android = snapshot.get("android", {})
    state_lines = []
    report = []
    facts = []

    def fact(surface, status, item_count, reason):
        facts.append(
            {
                "surface": surface,
                "status": status,
                "itemCount": item_count,
                "reason": reason,
            }
        )

    fact(
        "apps.packageMetadata",
        "observed-only",
        len(snapshot.get("packages", [])),
        "version, split, installer, and per-user package evidence is preserved in the snapshot",
    )
    fact(
        "apps.play",
        "declarable",
        len(play),
        "recorded Play installer becomes an attended Play presence assertion",
    )
    fact(
        "apps.attended",
        "declarable",
        len(attended),
        "third-party packages without verified Play attribution remain attended",
    )
    fact(
        "apps.release.obtainium",
        "declarable",
        len(release_packages),
        "credential-free Obtainium repository URLs can restore supported GitHub or Forgejo release declarations",
    )
    if unresolved_obtainium:
        report.extend(
            f"Obtainium source for {name} was retained as evidence but not activated"
            for name in sorted(set(unresolved_obtainium))
        )
        fact(
            "apps.release.obtainiumUnsupported",
            "ambiguous",
            len(set(unresolved_obtainium)),
            "the source was unsupported or its current installer did not confirm Obtainium delivery",
        )
    fact(
        "apps.provenance.signers",
        "observed-only",
        signer_count,
        "App Manager signer hashes are preserved for curation but not yet enforced during plan",
    )
    if installer_mismatches:
        report.append(
            f"{installer_mismatches} App Manager installer value(s) disagreed with the ADB package snapshot"
        )
        fact(
            "apps.provenance.installerMismatch",
            "ambiguous",
            installer_mismatches,
            "App Manager and ADB installer observations disagreed",
        )
    fact(
        "apps.provenance",
        "ambiguous",
        len(packages) - len(release_packages),
        "remaining installer evidence does not prove repository, release URL, signer, or future delivery",
    )

    night_mode = android.get("nightMode")
    if night_mode == "Night mode: yes":
        state_lines.append("  android.darkMode = true;")
        fact("android.darkMode", "declarable", 1, "observed boolean night mode")
    elif night_mode == "Night mode: no":
        state_lines.append("  android.darkMode = false;")
        fact("android.darkMode", "declarable", 1, "observed boolean night mode")
    else:
        report.append(
            f"android.darkMode observed as {json.dumps(comment(night_mode))}; omitted because the public option supports yes/no only"
        )
        fact(
            "android.darkMode",
            "observed-only",
            1,
            "observed mode is not representable by the public boolean option",
        )

    dns = private_dns_value(android.get("privateDns", {}))
    if dns is not None:
        state_lines.append(f"  android.privateDns = {json.dumps(dns)};")
        fact("android.privateDns", "declarable", 1, "mode/specifier form a valid typed value")
    else:
        report.append("android.privateDns evidence was incomplete or unsupported; omitted")
        fact("android.privateDns", "ambiguous", 1, "mode/specifier evidence was incomplete or unsupported")

    for role in ("browser", "sms", "dialer", "home"):
        holders = android.get("roles", {}).get(role, [])
        if len(holders) == 1 and PACKAGE_NAME.fullmatch(holders[0]):
            state_lines.append(
                f"  android.defaultApps.{role} = {json.dumps(holders[0])};"
            )
            fact(f"android.defaultApps.{role}", "declarable", 1, "one valid role holder was observed")
        elif holders:
            report.append(
                f"android.defaultApps.{role} had {len(holders)} holders; omitted"
            )
            fact(f"android.defaultApps.{role}", "ambiguous", len(holders), "multiple role holders were observed")
        else:
            fact(f"android.defaultApps.{role}", "observed-only", 0, "no role holder was observed")

    third_party_names = {name for name, _installer in packages}
    disabled_all = android.get("disabledPackages", [])
    disabled = sorted(set(disabled_all) & third_party_names)
    if disabled:
        state_lines.extend(
            ["", "  android.packages.disabled = [", nix_list(disabled), "  ];"]
        )
    fact(
        "android.packages.disabled",
        "declarable",
        len(disabled),
        "disabled third-party packages are portable ensure-disabled intent",
    )
    omitted_disabled = len(set(disabled_all) - third_party_names)
    if omitted_disabled:
        report.append(
            f"{omitted_disabled} disabled system package(s) were preserved in the snapshot and omitted from the portable declaration"
        )
        fact(
            "android.packages.disabled.system",
            "observed-only",
            omitted_disabled,
            "system-package disablement is image-specific and omitted",
        )

    managed_user = device.get("managedUser", 0)
    runtime_permissions = set(android.get("runtimePermissionDefinitions", []))
    runtime_permissions = {
        permission
        for permission in runtime_permissions
        if isinstance(permission, str) and PERMISSION_NAME.fullmatch(permission)
    }
    restricted_permissions = set(android.get("runtimePermissionRestrictions", {}))
    # Unparsed restriction rows usually name the affected permission; omit only
    # its grants instead of zeroing the whole import. Rows that cannot be
    # attributed to one permission keep the conservative global omission.
    unknown_restriction_permissions = set()
    unattributed_restriction_rows = 0
    for row in android.get("unparsedPermissionRestrictionRows") or []:
        match = re.search(r"Permission \[([A-Za-z0-9_.]+)\]", str(row)) or re.fullmatch(
            r"([A-Za-z0-9_.]+): missing PermissionInfo flags", str(row)
        )
        if match:
            unknown_restriction_permissions.add(match.group(1))
        else:
            unattributed_restriction_rows += 1
    restriction_evidence_complete = unattributed_restriction_rows == 0
    if not runtime_permissions:
        report.append(
            "no supported runtime-permission definitions were observed; all permission grants were omitted"
        )
        fact(
            "android.permissions.definitions",
            "ambiguous",
            0,
            "no supported dangerous/runtime permission definitions were observed",
        )
    else:
        fact(
            "android.permissions.definitions",
            "observed-only",
            len(runtime_permissions),
            "permission definitions constrain which broad grants can be declared",
        )
    observed_grants = 0
    rendered_grants = 0
    omitted_system_runtime_grants = 0
    omitted_restricted_grants = 0
    omitted_unknown_restriction_grants = 0
    rendered_grant_sets = {}
    for package in snapshot.get("packages", []):
        name = package.get("name")
        grants = set()
        for permissions in package.get("userPermissions", []):
            if permissions.get("id") == managed_user:
                grants.update(permissions.get("granted", []))
        runtime_grants = {
            permission
            for permission in grants
            if isinstance(permission, str)
            and PERMISSION_NAME.fullmatch(permission)
            and permission in runtime_permissions
        }
        if not package.get("thirdPartyForManagedUser"):
            # Count restricted grants too: every observed system runtime grant
            # lands in exactly this bucket.
            omitted_system_runtime_grants += len(runtime_grants)
            continue
        observed_grants += len(grants)
        omitted_restricted_grants += len(runtime_grants & restricted_permissions)
        runtime_grants -= restricted_permissions
        omitted_unknown_restriction_grants += len(
            runtime_grants & unknown_restriction_permissions
        )
        runtime_grants -= unknown_restriction_permissions
        if not restriction_evidence_complete:
            omitted_unknown_restriction_grants += len(runtime_grants)
            runtime_grants = set()
        grants = runtime_grants
        rendered_grants += len(grants)
        rendered_grant_sets[name] = grants
        if grants:
            state_lines.extend(
                [
                    "",
                    f"  android.permissions.{json.dumps(name)}.grant = [",
                    nix_list(sorted(grants)),
                    "  ];",
                ]
            )
    omitted_grants = (
        observed_grants
        - rendered_grants
        - omitted_restricted_grants
        - omitted_unknown_restriction_grants
    )
    fact(
        "android.permissions.grants",
        "declarable",
        rendered_grants,
        "third-party dangerous/runtime grant bits are representable",
    )
    if omitted_grants:
        report.append(
            f"{omitted_grants} non-runtime granted-permission entries were preserved in the snapshot and omitted"
        )
        fact(
            "android.permissions.nonRuntimeGrants",
            "observed-only",
            omitted_grants,
            "normal and app-defined grants are not valid pm grant declarations",
        )
    if omitted_system_runtime_grants:
        report.append(
            f"{omitted_system_runtime_grants} granted runtime-permission entries for system packages were preserved in the snapshot and omitted as non-portable"
        )
        fact(
            "android.permissions.systemGrants",
            "observed-only",
            omitted_system_runtime_grants,
            "system-package runtime grants are image-specific",
        )
    if omitted_restricted_grants:
        report.append(
            f"{omitted_restricted_grants} restricted runtime-permission grant(s) were preserved and omitted because installer/platform allowlisting is not portable"
        )
        fact(
            "android.permissions.restrictedGrants",
            "ambiguous",
            omitted_restricted_grants,
            "hard/soft restricted grants depend on installer or platform allowlisting",
        )
    if omitted_unknown_restriction_grants:
        report.append(
            f"{omitted_unknown_restriction_grants} runtime-permission grant(s) were omitted because restriction evidence was incomplete"
        )
        fact(
            "android.permissions.unknownRestrictionGrants",
            "ambiguous",
            omitted_unknown_restriction_grants,
            "incomplete PermissionInfo evidence makes automatic grant portability unknown",
        )
    if android.get("unparsedPermissionDefinitionRows"):
        report.append(
            f"{len(android['unparsedPermissionDefinitionRows'])} permission-definition row(s) were unparsed; affected grants may be omitted"
        )
        fact(
            "android.permissions.unparsedDefinitions",
            "ambiguous",
            len(android["unparsedPermissionDefinitionRows"]),
            "permission-definition rows did not match the supported grammar",
        )

    rendered_permission_flag_rows = 0
    omitted_flag_rows = 0
    android_owned_permission_flags = 0
    for package in snapshot.get("packages", []):
        if not package.get("thirdPartyForManagedUser"):
            continue
        name = package.get("name")
        for state in package.get("runtimePermissionStates", []):
            permission = state.get("permission")
            if not isinstance(permission, str) or not PERMISSION_NAME.fullmatch(permission):
                continue
            if not (
                state.get("granted")
                and permission in rendered_grant_sets.get(name, set())
            ):
                # Flags are rendered only when the declaration also reproduces
                # the row's grant state. A granted-but-omitted row would assert
                # user-fixed on a permission the config leaves denied, and a
                # denied row has no rendered revoke (import never infers one),
                # so its flags could pin the wrong state on a target where the
                # permission happens to be granted.
                omitted_flag_rows += 1
                continue
            observed_flags = set(state.get("flags", []))
            writable = sorted(
                WRITABLE_PERMISSION_FLAGS[flag]
                for flag in observed_flags
                if flag in WRITABLE_PERMISSION_FLAGS
            )
            android_owned_permission_flags += len(
                observed_flags - WRITABLE_PERMISSION_FLAGS.keys()
            )
            if writable:
                state_lines.extend(
                    [
                        "",
                        f"  android.permissions.{json.dumps(name)}.flags.{json.dumps(permission)} = [",
                        nix_list(writable),
                        "  ];",
                    ]
                )
            else:
                state_lines.append(
                    f"  android.permissions.{json.dumps(name)}.flags.{json.dumps(permission)} = [];"
                )
            rendered_permission_flag_rows += 1
    fact(
        "android.permissions.flags",
        "declarable",
        rendered_permission_flag_rows,
        "writable PackageManager policy flags are represented for rows whose grant state the declaration reproduces",
    )
    if omitted_flag_rows:
        report.append(
            f"{omitted_flag_rows} permission-flag row(s) were preserved and omitted because the declaration does not reproduce the row's grant state"
        )
        fact(
            "android.permissions.flagsForOmittedGrants",
            "ambiguous",
            omitted_flag_rows,
            "flags without their reproduced grant state could pin the wrong state (import never infers revocations)",
        )
    if android_owned_permission_flags:
        report.append(
            f"{android_owned_permission_flags} Android-owned permission flag(s) were preserved in the snapshot and omitted"
        )
        fact(
            "android.permissions.androidOwnedFlags",
            "observed-only",
            android_owned_permission_flags,
            "PackageManager exposes these flags but adb shell cannot safely own them",
        )
    if android.get("unparsedPermissionStateRows"):
        report.append(
            f"{len(android['unparsedPermissionStateRows'])} runtime-permission state row(s) were unparsed"
        )
        fact(
            "android.permissions.unparsedState",
            "ambiguous",
            len(android["unparsedPermissionStateRows"]),
            "runtime-permission state rows did not match the supported grammar",
        )
    if android.get("unparsedPermissionRestrictionRows"):
        report.append(
            f"{len(android['unparsedPermissionRestrictionRows'])} permission-restriction row(s) were unparsed"
        )
        fact(
            "android.permissions.unparsedRestrictions",
            "ambiguous",
            len(android["unparsedPermissionRestrictionRows"]),
            "PermissionInfo restriction rows did not match the supported grammar",
        )

    rendered_app_ops = 0
    default_app_ops = 0
    for name, operations in sorted(android.get("appOps", {}).items()):
        if name not in third_party_names or not PACKAGE_NAME.fullmatch(name):
            continue
        for operation, mode in sorted(operations.items()):
            if not re.fullmatch(r"[A-Z][A-Z0-9_]*", operation):
                continue
            if mode == "default":
                default_app_ops += 1
                continue
            if mode not in {"allow", "ignore", "deny", "foreground"}:
                continue
            state_lines.append(
                f"  android.appOps.{json.dumps(name)}.{json.dumps(operation)} = {json.dumps(mode)};"
            )
            rendered_app_ops += 1
    fact(
        "android.appOps.packageModes",
        "declarable",
        rendered_app_ops,
        "non-default package-level AppOps overrides are representable",
    )
    if default_app_ops:
        fact(
            "android.appOps.explicitDefault",
            "observed-only",
            default_app_ops,
            "explicit default rows carry no portable non-default policy",
        )
    fact(
        "android.appOps.uidModes",
        "observed-only",
        None,
        "UID-wide modes often derive from permission state and are not imported as package overrides",
    )
    if android.get("derivedAppOpRows"):
        fact(
            "android.appOps.switchDerivedModes",
            "observed-only",
            len(android["derivedAppOpRows"]),
            "switch-op-derived effective modes are not explicit package overrides",
        )
    if android.get("unparsedAppOpRows"):
        report.append(
            f"{len(android['unparsedAppOpRows'])} package AppOps row(s) were unparsed"
        )
        fact(
            "android.appOps.unparsed",
            "ambiguous",
            len(android["unparsedAppOpRows"]),
            "package AppOps rows did not match the supported grammar",
        )

    shell_suspended = []
    other_suspensions = 0
    for name, package in sorted(third_party_by_name.items()):
        user_state = next(
            (
                user
                for user in package.get("users", [])
                if user.get("id") == managed_user
            ),
            {},
        )
        if not user_state.get("suspended"):
            continue
        suspenders = set(user_state.get("suspendingPackages", []))
        if "com.android.shell" in suspenders:
            shell_suspended.append(name)
        if suspenders - {"com.android.shell"} or not suspenders:
            other_suspensions += 1
    if shell_suspended:
        state_lines.extend(
            ["", "  android.packages.suspended = [", nix_list(shell_suspended), "  ];"]
        )
    fact(
        "android.packages.suspended.shell",
        "declarable",
        len(shell_suspended),
        "adb-shell suspension authority can be restored without claiming other authorities",
    )
    if other_suspensions:
        report.append(
            f"{other_suspensions} third-party package suspension(s) involved another or unknown authority and were omitted"
        )
        fact(
            "android.packages.suspended.otherAuthority",
            "observed-only",
            other_suspensions,
            "nix-android cannot portably recreate another package or administrator as suspender",
        )

    rendered_locales = 0
    for name, locales in sorted(android.get("appLocales", {}).items()):
        if name not in third_party_names or not locales:
            continue
        if not all(
            isinstance(locale, str)
            and len(locale) <= 100
            and LOCALE_TAG.fullmatch(locale)
            for locale in locales
        ):
            continue
        state_lines.extend(
            [
                "",
                f"  android.locales.{json.dumps(name)} = [",
                nix_list(locales),
                "  ];",
            ]
        )
        rendered_locales += len(locales)
    fact(
        "android.locales",
        "declarable",
        rendered_locales,
        "non-default per-app locale preferences are portable package state",
    )
    if android.get("unparsedAppLocaleRows"):
        report.append(
            f"{len(android['unparsedAppLocaleRows'])} app-locale row(s) were unparsed"
        )
        fact(
            "android.locales.unparsed",
            "ambiguous",
            len(android["unparsedAppLocaleRows"]),
            "app-locale output did not match the supported grammar",
        )

    input_method = android.get("inputMethod", {})
    enabled_imes = sorted(
        {
            component
            for component in input_method.get("enabled", [])
            if isinstance(component, str) and COMPONENT_NAME.fullmatch(component)
        }
    )
    selected_ime = input_method.get("selected")
    if selected_ime is not None and (
        not isinstance(selected_ime, str)
        or not COMPONENT_NAME.fullmatch(selected_ime)
        or selected_ime not in enabled_imes
    ):
        selected_ime = None
        report.append("selected input method was invalid or not enabled; omitted")
        fact(
            "android.inputMethod.selected",
            "ambiguous",
            1,
            "selected component was invalid or absent from the enabled set",
        )
    if enabled_imes:
        state_lines.extend(
            ["", "  android.inputMethod.enabled = [", nix_list(enabled_imes), "  ];"]
        )
    if selected_ime is not None:
        state_lines.append(
            f"  android.inputMethod.default = {json.dumps(selected_ime)};"
        )
    fact(
        "android.inputMethod.enabled",
        "declarable",
        len(enabled_imes),
        "enabled input-method components can be restored after their packages exist",
    )
    if selected_ime is not None:
        fact(
            "android.inputMethod.selected",
            "declarable",
            1,
            "the selected enabled input-method component is representable",
        )
    if input_method.get("unparsed"):
        fact(
            "android.inputMethod.unparsed",
            "ambiguous",
            len(input_method["unparsed"]),
            "input-method component output did not match the supported grammar",
        )

    data_saver = android.get("dataSaver", {})
    if isinstance(data_saver.get("enabled"), bool):
        state_lines.append(
            f"  android.dataSaver.enabled = {str(data_saver['enabled']).lower()};"
        )
        fact(
            "android.dataSaver.enabled",
            "declarable",
            1,
            "global Data Saver state is directly readable and writable",
        )
    restricted_uids = set(data_saver.get("restrictedUids", []))
    exempt_uids = set(data_saver.get("exemptUids", []))
    uid_policy_count = len(restricted_uids | exempt_uids)
    fact(
        "android.dataSaver.packages",
        "observed-only",
        uid_policy_count,
        "per-app UID policies pass read-back but are removed for user-installed apps by the supported AOSP reboot bench",
    )
    if uid_policy_count:
        report.append(
            f"{uid_policy_count} per-UID Data Saver override(s) were preserved as evidence but omitted because reboot persistence failed"
        )

    rendered_link_packages = 0
    verifier_domains = 0
    invalid_auto_verify_domains = 0
    for name, link_state in sorted(android.get("appLinks", {}).items()):
        if name not in third_party_names or not isinstance(link_state, dict):
            continue
        allowed = link_state.get("allowed")
        selected = sorted(
            {
                domain
                for domain in link_state.get("selected", [])
                # <= 253 mirrors lib/default.nix validDomain and the engine's
                # jq `domain`; a longer observed domain must not render output
                # that the generated configuration then rejects at eval.
                if isinstance(domain, str)
                and len(domain) <= 253
                and DOMAIN_NAME.fullmatch(domain)
            }
        )
        verifier_domains += len(link_state.get("verification", {}))
        invalid_auto_verify_domains += len(
            link_state.get("invalidAutoVerifyDomains", [])
        )
        declarations = []
        if allowed is False:
            declarations.append("    allowed = false;")
        if selected:
            declarations.extend(
                ["    selected = [", nix_list(selected, indent="      "), "    ];"]
            )
        if declarations:
            state_lines.extend(
                ["", f"  android.appLinks.{json.dumps(name)} = {{", *declarations, "  };"]
            )
            rendered_link_packages += 1
    fact(
        "android.appLinks.userState",
        "declarable",
        rendered_link_packages,
        "non-default link-handling denial and positive user domain selections are representable",
    )
    fact(
        "android.appLinks.verification",
        "observed-only",
        verifier_domains,
        "domain verification belongs to the OS verifier and signer/domain relationship",
    )
    fact(
        "android.appLinks.invalidAutoVerifyDomains",
        "observed-only",
        invalid_auto_verify_domains,
        "invalid manifest autoVerify declarations are app metadata, not portable user state",
    )
    fact(
        "android.appLinks.unselected",
        "ambiguous",
        sum(
            len(state.get("unselected", []))
            for state in android.get("appLinks", {}).values()
            if isinstance(state, dict)
        ),
        "shell output does not distinguish never-selected domains from an explicit user deselection",
    )
    if android.get("unparsedAppLinkRows"):
        report.append(
            f"{len(android['unparsedAppLinkRows'])} app-link row(s) were unparsed; affected declarations may be omitted"
        )
        fact(
            "android.appLinks.unparsed",
            "ambiguous",
            len(android["unparsedAppLinkRows"]),
            "app-link rows did not match the supported stock/Graphene grammar",
        )

    whitelist = android.get("deviceIdleWhitelist", {})
    installed_for_managed_user = set(
        android.get("installedPackagesForManagedUser", [])
    )
    user_exempt = sorted(
        {
            entry.get("package")
            for entry in whitelist.get("entries", [])
            if entry.get("source") == "user"
            and isinstance(entry.get("package"), str)
            and PACKAGE_NAME.fullmatch(entry["package"])
            and entry["package"] in installed_for_managed_user
        }
    )
    if user_exempt:
        state_lines.extend(
            ["", "  android.batteryOptimization.exempt = [", nix_list(user_exempt), "  ];"]
        )
    fact(
        "android.batteryOptimization.exempt",
        "declarable",
        len(user_exempt),
        "user-added rows installed for managed user 0 are ensure-present intent",
    )
    if whitelist.get("unparsed"):
        report.append(
            f"{len(whitelist['unparsed'])} DeviceIdle row(s) were unparsed and omitted"
        )
        fact(
            "android.batteryOptimization.unparsed",
            "ambiguous",
            len(whitelist["unparsed"]),
            "DeviceIdle rows did not match the supported grammar",
        )
    system_whitelist_rows = sum(
        1
        for entry in whitelist.get("entries", [])
        if entry.get("source") != "user"
    )
    if system_whitelist_rows:
        report.append(
            f"{system_whitelist_rows} system-owned DeviceIdle row(s) were preserved in the snapshot and omitted"
        )
        fact(
            "android.batteryOptimization.system",
            "observed-only",
            system_whitelist_rows,
            "system-owned DeviceIdle rows are not user intent",
        )
    out_of_scope_user_whitelist_rows = sum(
        1
        for entry in whitelist.get("entries", [])
        if entry.get("source") == "user"
        and entry.get("package") not in installed_for_managed_user
    )
    if out_of_scope_user_whitelist_rows:
        report.append(
            f"{out_of_scope_user_whitelist_rows} user-added DeviceIdle row(s) for packages outside managed user {managed_user} were preserved in the snapshot and omitted"
        )
        fact(
            "android.batteryOptimization.otherProfiles",
            "observed-only",
            out_of_scope_user_whitelist_rows,
            "global user-added rows can refer to packages outside managed user 0",
        )

    fact(
        "android.settings.unallowlisted",
        "observed-only",
        None,
        "bulk settings mix desired, derived, sensitive, and component-owned state",
    )
    for surface, reason in (
        ("protected.appData", "adb shell cannot faithfully restore app-private or backup-opted-out data"),
        ("protected.keystore", "adb shell cannot export Android Keystore keys"),
        ("protected.esim", "adb shell cannot faithfully restore eSIM state"),
        ("play.silentDelivery", "consumer Play installation requires account and user consent"),
    ):
        fact(surface, "unreachable", None, reason)

    release_lines = [
        f"  apps.release.{json.dumps(name)}.github = {json.dumps(value)};"
        for name, value in sorted(release_github.items())
    ] + [
        f"  apps.release.{json.dumps(name)}.gitea = {json.dumps(value)};"
        for name, value in sorted(release_gitea.items())
    ]

    rendered = f'''# Generated by android-rebuild import from a read-only package snapshot.
# Observed device model: {model}
# CURATE BEFORE CONVERGING. Notes:
#  - Packages recorded with Play as installer are labeled apps.play; this is
#    evidence, not verified provenance.
#  - Credential-free Obtainium exports can recover supported release sources;
#    every remaining third-party app stays attended instead of guessing.
#  - Recovered apps.release entries are lock-backed: run `android-rebuild
#    update` once before the first build/plan, or evaluation fails with
#    "not in apps.lock.json".
#  - The commented candidates below are evidence for manual curation only.
#  - Runtime grant bits, writable permission-policy flags, and package-level
#    app-op overrides are separate declarations; UID-wide app-ops stay evidence.
{{
  device.name = "CHANGEME";
  device.abi = {json.dumps(abi)};

  apps.play = [
{nix_list(play)}
  ];

  apps.attended = [
{nix_list(attended)}
  ];

{chr(10).join(release_lines)}

  apps.cleanup = "none";

{chr(10).join(state_lines)}

  # Candidate main-F-Droid installs; verify repository and signing source:
{comments(fdroid)}
  # Candidate Obtainium installs; recover the upstream URL from Obtainium:
{comments(obtainium)}
  # App Manager signing-certificate evidence (not yet enforced by plan):
{comments(signer_notes)}

  # Import omissions / observations that are not safely declarable:
{comments(report)}
}}
'''

    facts.sort(key=lambda item: (item["surface"], item["status"], item["reason"]))
    coverage = {
        "schemaVersion": 1,
        "snapshotSchemaVersion": snapshot["schemaVersion"],
        "device": {
            "model": device.get("model"),
            "product": device.get("product"),
            "abi": abi,
            "sdk": device.get("sdk"),
            "securityPatch": device.get("securityPatch"),
            "managedUser": device.get("managedUser", 0),
        },
        "summary": {
            status: sum(1 for item in facts if item["status"] == status)
            for status in ("declarable", "observed-only", "ambiguous", "unreachable")
        },
        "facts": facts,
    }
    return rendered, coverage


def render(snapshot):
    return render_with_coverage(snapshot)[0]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("snapshot", type=Path)
    parser.add_argument("--report-out", type=Path)
    args = parser.parse_args()
    rendered, coverage = render_with_coverage(json.loads(args.snapshot.read_text()))
    if args.report_out:
        args.report_out.write_text(json.dumps(coverage, indent=2, sort_keys=True) + "\n")
    print(rendered, end="")


if __name__ == "__main__":
    main()
