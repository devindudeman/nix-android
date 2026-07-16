#!/usr/bin/env python3
"""Render a normalized nix-android snapshot as conservative starter Nix."""

import argparse
import json
import re
from pathlib import Path


PACKAGE_NAME = re.compile(r"[A-Za-z0-9_]+(?:\.[A-Za-z0-9_]+)+")
PERMISSION_NAME = re.compile(r"[A-Za-z0-9_.]+")
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


def nix_list(values, indent="    "):
    return "\n".join(f"{indent}{json.dumps(value)}" for value in values)


def comments(values):
    return "\n".join(f"  # {value}" for value in values)


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
    for package in snapshot.get("packages", []):
        if not package.get("thirdPartyForManagedUser"):
            continue
        name = package.get("name")
        if not isinstance(name, str) or not PACKAGE_NAME.fullmatch(name):
            raise ValueError(f"invalid Android package name in snapshot: {name!r}")
        packages.append((name, package.get("installerName")))
    packages.sort()

    play = [name for name, installer in packages if installer == PLAY_INSTALLER]
    attended = [name for name, installer in packages if installer != PLAY_INSTALLER]
    fdroid = [name for name, installer in packages if installer in FDROID_INSTALLERS]
    obtainium = [name for name, installer in packages if installer in OBTAINIUM_INSTALLERS]

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
        "apps.provenance",
        "ambiguous",
        len(packages),
        "installer evidence does not prove repository, release URL, signer, or future delivery",
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
            omitted_system_runtime_grants += len(runtime_grants)
            continue
        observed_grants += len(grants)
        grants = runtime_grants
        rendered_grants += len(grants)
        if grants:
            state_lines.extend(
                [
                    "",
                    f"  android.permissions.{json.dumps(name)}.grant = [",
                    nix_list(sorted(grants)),
                    "  ];",
                ]
            )
    omitted_grants = observed_grants - rendered_grants
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

    rendered = f'''# Generated by android-rebuild import from a read-only package snapshot.
# Observed device model: {model}
# CURATE BEFORE CONVERGING. Notes:
#  - Packages recorded with Play as installer are labeled apps.play; this is
#    evidence, not verified provenance.
#  - Every other observed third-party app is attended, so this starter config
#    asserts presence without pretending installer attribution proves a source.
#  - The commented candidates below are evidence for manual curation only.
#  - Runtime permission declarations reproduce PackageManager grant bits only;
#    app-op modes and one-time/foreground scope remain separate Android state.
{{
  device.name = "CHANGEME";
  device.abi = {json.dumps(abi)};

  apps.play = [
{nix_list(play)}
  ];

  apps.attended = [
{nix_list(attended)}
  ];

  apps.cleanup = "none";

{chr(10).join(state_lines)}

  # Candidate main-F-Droid installs; verify repository and signing source:
{comments(fdroid)}
  # Candidate Obtainium installs; recover the upstream URL from Obtainium:
{comments(obtainium)}

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
