#!/usr/bin/env python3
"""Normalize read-only Android evidence into nix-android snapshot v2."""

import argparse
import json
import re
import sys
from pathlib import Path

from google.protobuf import descriptor_pb2, descriptor_pool, message_factory


PACKAGE_NAME = re.compile(r"[A-Za-z0-9_]+(?:\.[A-Za-z0-9_]+)+")
SYSTEM_PACKAGE_NAME = re.compile(r"[A-Za-z0-9_]+(?:\.[A-Za-z0-9_]+)*")
ROLE_NAMES = {"browser", "sms", "dialer", "home"}
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


# Wire numbers and types come from AOSP's Apache-2.0 licensed package.proto:
# https://android.googlesource.com/platform/frameworks/base/+/refs/heads/main/core/proto/android/service/package.proto
def package_dump_class():
    file = descriptor_pb2.FileDescriptorProto(
        name="nix_android_package_snapshot.proto",
        package="nix_android.aosp",
        syntax="proto2",
    )

    def message(name):
        item = file.message_type.add()
        item.name = name
        return item

    def field(owner, name, number, kind, repeated=False, type_name=None):
        item = owner.field.add()
        item.name = name
        item.number = number
        item.type = kind
        item.label = (
            descriptor_pb2.FieldDescriptorProto.LABEL_REPEATED
            if repeated
            else descriptor_pb2.FieldDescriptorProto.LABEL_OPTIONAL
        )
        if type_name:
            item.type_name = type_name

    split = message("Split")
    field(split, "name", 1, descriptor_pb2.FieldDescriptorProto.TYPE_STRING)
    field(split, "revision_code", 2, descriptor_pb2.FieldDescriptorProto.TYPE_INT32)

    user = message("UserInfo")
    field(user, "id", 1, descriptor_pb2.FieldDescriptorProto.TYPE_INT32)
    field(user, "install_type", 2, descriptor_pb2.FieldDescriptorProto.TYPE_INT32)
    field(user, "is_hidden", 3, descriptor_pb2.FieldDescriptorProto.TYPE_BOOL)
    field(user, "is_suspended", 4, descriptor_pb2.FieldDescriptorProto.TYPE_BOOL)
    field(user, "is_stopped", 5, descriptor_pb2.FieldDescriptorProto.TYPE_BOOL)
    field(user, "is_launched", 6, descriptor_pb2.FieldDescriptorProto.TYPE_BOOL)
    field(user, "enabled_state", 7, descriptor_pb2.FieldDescriptorProto.TYPE_INT32)
    field(user, "last_disabled_app_caller", 8, descriptor_pb2.FieldDescriptorProto.TYPE_STRING)
    field(
        user,
        "suspending_package",
        9,
        descriptor_pb2.FieldDescriptorProto.TYPE_STRING,
        repeated=True,
    )
    field(user, "distraction_flags", 10, descriptor_pb2.FieldDescriptorProto.TYPE_INT32)
    field(user, "first_install_time_ms", 11, descriptor_pb2.FieldDescriptorProto.TYPE_INT32)
    field(
        user,
        "suspending_user",
        13,
        descriptor_pb2.FieldDescriptorProto.TYPE_INT32,
        repeated=True,
    )

    install_source = message("InstallSource")
    field(
        install_source,
        "initiating_package_name",
        1,
        descriptor_pb2.FieldDescriptorProto.TYPE_STRING,
    )
    field(
        install_source,
        "originating_package_name",
        2,
        descriptor_pb2.FieldDescriptorProto.TYPE_STRING,
    )
    field(
        install_source,
        "update_owner_package_name",
        3,
        descriptor_pb2.FieldDescriptorProto.TYPE_STRING,
    )

    user_permissions = message("UserPermissions")
    field(user_permissions, "id", 1, descriptor_pb2.FieldDescriptorProto.TYPE_INT32)
    field(
        user_permissions,
        "granted_permissions",
        2,
        descriptor_pb2.FieldDescriptorProto.TYPE_STRING,
        repeated=True,
    )

    package = message("Package")
    field(package, "name", 1, descriptor_pb2.FieldDescriptorProto.TYPE_STRING)
    field(package, "uid", 2, descriptor_pb2.FieldDescriptorProto.TYPE_INT32)
    field(package, "version_code", 3, descriptor_pb2.FieldDescriptorProto.TYPE_INT32)
    field(package, "version_string", 4, descriptor_pb2.FieldDescriptorProto.TYPE_STRING)
    field(package, "update_time_ms", 6, descriptor_pb2.FieldDescriptorProto.TYPE_INT64)
    field(package, "installer_name", 7, descriptor_pb2.FieldDescriptorProto.TYPE_STRING)
    field(
        package,
        "splits",
        8,
        descriptor_pb2.FieldDescriptorProto.TYPE_MESSAGE,
        repeated=True,
        type_name=".nix_android.aosp.Split",
    )
    field(
        package,
        "users",
        9,
        descriptor_pb2.FieldDescriptorProto.TYPE_MESSAGE,
        repeated=True,
        type_name=".nix_android.aosp.UserInfo",
    )
    field(
        package,
        "install_source",
        10,
        descriptor_pb2.FieldDescriptorProto.TYPE_MESSAGE,
        type_name=".nix_android.aosp.InstallSource",
    )
    field(
        package,
        "user_permissions",
        12,
        descriptor_pb2.FieldDescriptorProto.TYPE_MESSAGE,
        repeated=True,
        type_name=".nix_android.aosp.UserPermissions",
    )

    dump = message("PackageServiceDump")
    field(
        dump,
        "packages",
        5,
        descriptor_pb2.FieldDescriptorProto.TYPE_MESSAGE,
        repeated=True,
        type_name=".nix_android.aosp.Package",
    )

    pool = descriptor_pool.DescriptorPool()
    pool.Add(file)
    return message_factory.GetMessageClass(
        pool.FindMessageTypeByName("nix_android.aosp.PackageServiceDump")
    )


def optional(message, name):
    return getattr(message, name) if message.HasField(name) else None


def normalize_android(
    night_mode,
    private_dns_mode,
    private_dns_specifier,
    role_lines,
    disabled_lines,
    device_idle_lines,
    permission_definition_lines,
):
    roles = {role: [] for role in sorted(ROLE_NAMES)}
    for line in role_lines:
        if not line:
            continue
        try:
            role, package = line.split("\t", 1)
        except ValueError as error:
            raise ValueError(f"invalid role evidence: {line!r}") from error
        if role not in ROLE_NAMES or not PACKAGE_NAME.fullmatch(package):
            raise ValueError(f"invalid role evidence: {line!r}")
        roles[role].append(package)

    disabled = set()
    for line in disabled_lines:
        if not line:
            continue
        package = line.removeprefix("package:").strip()
        if not SYSTEM_PACKAGE_NAME.fullmatch(package):
            raise ValueError(f"invalid disabled package evidence: {line!r}")
        disabled.add(package)

    whitelist = []
    unparsed_device_idle = []
    for line in device_idle_lines:
        if not line:
            continue
        fields = line.split(",")
        if (
            len(fields) != 3
            or not fields[0]
            or not PACKAGE_NAME.fullmatch(fields[1])
            or not fields[2].isdigit()
        ):
            unparsed_device_idle.append(line)
            continue
        whitelist.append(
            {"source": fields[0], "package": fields[1], "appId": int(fields[2])}
        )

    permission_definitions = set()
    unparsed_permission_definitions = []
    for line in permission_definition_lines:
        if "permission:" not in line:
            continue
        match = re.fullmatch(r"\s*\+?\s*permission:([A-Za-z0-9_.]+)\s*", line)
        if match:
            permission_definitions.add(match.group(1))
        else:
            unparsed_permission_definitions.append(line)

    def setting(value):
        value = value.strip()
        return None if value in {"", "null"} else value

    return {
        "nightMode": night_mode.strip(),
        "privateDns": {
            "mode": setting(private_dns_mode),
            "specifier": setting(private_dns_specifier),
        },
        "roles": {role: sorted(set(packages)) for role, packages in roles.items()},
        "disabledPackages": sorted(disabled),
        "deviceIdleWhitelist": {
            "entries": sorted(
                whitelist,
                key=lambda entry: (
                    entry["source"],
                    entry["package"],
                    entry["appId"],
                ),
            ),
            "unparsed": sorted(set(unparsed_device_idle)),
        },
        "runtimePermissionDefinitions": sorted(permission_definitions),
        "unparsedPermissionDefinitionRows": sorted(
            set(unparsed_permission_definitions)
        ),
    }


def normalize_permission_details(lines, managed_user):
    states = {}
    unparsed = []
    package = None
    active_user = None
    in_runtime_permissions = False
    managed_user_seen = False
    for line in lines:
        marker = re.fullmatch(r"### nix-android package ([A-Za-z0-9_]+(?:\.[A-Za-z0-9_]+)+)", line)
        if marker:
            if package is not None and not managed_user_seen:
                unparsed.append(f"{package}: managed user section not found")
            package = marker.group(1)
            active_user = None
            in_runtime_permissions = False
            managed_user_seen = False
            continue
        user = re.match(r"^\s+User (\d+):", line)
        if user:
            active_user = int(user.group(1))
            managed_user_seen |= active_user == managed_user
            in_runtime_permissions = False
            continue
        if re.match(r"^\s+User all:", line):
            active_user = None
            in_runtime_permissions = False
            continue
        if re.match(r"^\s+User\b", line):
            unparsed.append(f"{package}: {line.strip()}")
            active_user = None
            in_runtime_permissions = False
            continue
        if line.strip() == "runtime permissions:":
            in_runtime_permissions = package is not None and active_user == managed_user
            continue
        if "runtime permissions" in line:
            unparsed.append(f"{package}: {line.strip()}")
            in_runtime_permissions = False
            continue
        if not in_runtime_permissions:
            continue
        if not line.startswith("        "):
            in_runtime_permissions = False
            continue
        match = re.fullmatch(
            r"\s+([A-Za-z0-9_.]+): granted=(true|false)(?:, flags=\[\s*([A-Z0-9_|]*)\s*\])?",
            line,
        )
        if not match:
            if line.strip():
                unparsed.append(f"{package}: {line.strip()}")
            continue
        flags = match.group(3).split("|") if match.group(3) else []
        states.setdefault(package, []).append(
            {
                "permission": match.group(1),
                "granted": match.group(2) == "true",
                "flags": sorted(flags),
            }
        )
    if package is not None and not managed_user_seen:
        unparsed.append(f"{package}: managed user section not found")
    return {
        package: sorted(entries, key=lambda entry: entry["permission"])
        for package, entries in sorted(states.items())
    }, sorted(set(unparsed))


def normalize_permission_restrictions(lines):
    """Read PermissionInfo hard/soft restriction bits from dumpsys package permissions."""
    restrictions = {}
    unparsed = []
    permission = None
    for line in lines:
        header = re.fullmatch(r"  Permission \[([^\]\r\n]+)\] \([^)]+\):", line)
        if header:
            if permission is not None:
                unparsed.append(f"{permission}: missing PermissionInfo flags")
            permission = header.group(1)
            continue
        if line.startswith("  Permission ["):
            unparsed.append(line.strip())
            permission = None
            continue
        if permission is None:
            continue
        flags = re.fullmatch(r"    flags=0x([0-9a-fA-F]+)", line)
        if flags:
            value = int(flags.group(1), 16)
            names = []
            # PermissionInfo.FLAG_HARD_RESTRICTED / FLAG_SOFT_RESTRICTED.
            # https://android.googlesource.com/platform/frameworks/base/+/refs/heads/main/core/java/android/content/pm/PermissionInfo.java
            if value & 0x4:
                names.append("hard-restricted")
            if value & 0x8:
                names.append("soft-restricted")
            if names:
                restrictions[permission] = names
            permission = None
    if permission is not None:
        unparsed.append(f"{permission}: missing PermissionInfo flags")
    return dict(sorted(restrictions.items())), sorted(set(unparsed))


def normalize_app_ops(lines, managed_user):
    app_ops = {}
    unparsed = []
    derived = []
    active_user = None
    package = None
    for line in lines:
        uid = re.fullmatch(r"  Uid (?:u(\d+)[a-z](\d+)|(\d+)):", line)
        if uid:
            active_user = int(uid.group(1)) if uid.group(1) is not None else int(uid.group(3)) // 100000
            package = None
            continue
        if line.startswith("  Uid "):
            unparsed.append(line.strip())
            active_user = None
            package = None
            continue
        package_line = re.fullmatch(
            r"    Package ([A-Za-z0-9_]+(?:\.[A-Za-z0-9_]+)*):", line
        )
        if package_line:
            package = package_line.group(1) if active_user == managed_user else None
            continue
        if line.startswith("    Package "):
            unparsed.append(line.strip())
            package = None
            continue
        if package is None or not line.startswith("      "):
            continue
        operation = re.fullmatch(
            r"      ([A-Z][A-Z0-9_]*) \((allow|ignore|deny|default|foreground)\):\s*",
            line,
        )
        if operation:
            app_ops.setdefault(package, {})[operation.group(1)] = operation.group(2)
        elif re.fullmatch(
            r"      [A-Z][A-Z0-9_]* \((allow|ignore|deny|default|foreground) / switch [A-Z][A-Z0-9_]*=(allow|ignore|deny|default|foreground)\):\s*",
            line,
        ):
            derived.append(f"{package}: {line.strip()}")
        elif re.match(r"^      [A-Z][A-Z0-9_]* \(", line):
            unparsed.append(f"{package}: {line.strip()}")
    return (
        {
            package: dict(sorted(ops.items()))
            for package, ops in sorted(app_ops.items())
        },
        sorted(set(unparsed)),
        sorted(set(derived)),
    )


def normalize_app_locales(lines, managed_user):
    locales = {}
    unparsed = []
    package = None
    for line in lines:
        marker = re.fullmatch(
            r"### nix-android package ([A-Za-z0-9_]+(?:\.[A-Za-z0-9_]+)+)", line
        )
        if marker:
            package = marker.group(1)
            continue
        if not line or package is None:
            continue
        match = re.fullmatch(
            rf"Locales for {re.escape(package)} for user (\d+) are \[(.*)\]", line
        )
        if not match or int(match.group(1)) != managed_user:
            unparsed.append(f"{package}: {line}")
            continue
        tags = [] if not match.group(2) else match.group(2).split(",")
        if not all(len(tag) <= 100 and LOCALE_TAG.fullmatch(tag) for tag in tags):
            unparsed.append(f"{package}: {line}")
            continue
        locales[package] = tags
    return dict(sorted(locales.items())), sorted(set(unparsed))


def normalize_input_method(enabled_lines, selected):
    enabled = sorted(
        {line.strip() for line in enabled_lines if COMPONENT_NAME.fullmatch(line.strip())}
    )
    unparsed = sorted(
        {line for line in enabled_lines if line and not COMPONENT_NAME.fullmatch(line.strip())}
    )
    selected = selected.strip()
    if selected in {"", "null"}:
        selected = None
    elif not COMPONENT_NAME.fullmatch(selected):
        unparsed.append(f"selected: {selected}")
        selected = None
    return {"enabled": enabled, "selected": selected, "unparsed": sorted(set(unparsed))}


def _uid_list(line, prefix):
    match = re.fullmatch(
        re.escape(prefix) + r": (none|\d+(?: \d+)*)", line.strip()
    )
    if not match:
        raise ValueError(f"invalid network-policy evidence: {line!r}")
    return [] if match.group(1) == "none" else sorted({int(uid) for uid in match.group(1).split()})


def normalize_network_policy(status, restricted, exempt):
    status_match = re.fullmatch(
        r"Restrict background status: (enabled|disabled)", status.strip()
    )
    if not status_match:
        raise ValueError(f"invalid Data Saver evidence: {status!r}")
    return {
        "enabled": status_match.group(1) == "enabled",
        "restrictedUids": _uid_list(
            restricted, "Restrict background blacklisted UIDs"
        ),
        "exemptUids": _uid_list(exempt, "Restrict background whitelisted UIDs"),
    }


def normalize_app_links(lines, managed_user):
    links = {}
    unparsed = []
    package = None
    section = None
    domain_packages = set()
    managed_user_packages = set()
    allowed_packages = set()
    for line in lines:
        marker = re.fullmatch(
            r"### nix-android package ([A-Za-z0-9_]+(?:\.[A-Za-z0-9_]+)+)", line
        )
        if marker:
            package = marker.group(1)
            links[package] = {
                "allowed": None,
                "invalidAutoVerifyDomains": [],
                "selected": [],
                "unselected": [],
                "verification": {},
            }
            section = None
            continue
        if package is None:
            if line:
                unparsed.append(line)
            continue
        if line == f"  {package}:":
            continue
        if re.fullmatch(r"    ID: \S+", line) or re.fullmatch(
            r"    Signatures: \[.*\]", line
        ):
            continue
        if line == "    Domain verification state:":
            section = "verification"
            domain_packages.add(package)
            continue
        if line == "    Invalid autoVerify domains:":
            section = "invalid-auto-verify"
            continue
        user = re.fullmatch(r"    User (\d+):", line)
        if user:
            section = "user" if int(user.group(1)) == managed_user else None
            if section == "user":
                managed_user_packages.add(package)
            continue
        allowed = re.fullmatch(
            r"      Verification link handling allowed: (true|false)", line
        )
        if allowed and section == "user":
            links[package]["allowed"] = allowed.group(1) == "true"
            allowed_packages.add(package)
            continue
        if line == "        Enabled:" and section == "user":
            section = "selected"
            continue
        if line == "        Disabled:" and section in {"user", "selected"}:
            section = "unselected"
            continue
        if line == "      Selection state:" and section == "user":
            continue
        domain = re.fullmatch(r"          (\S+)", line)
        if domain and section in {"selected", "unselected"}:
            value = domain.group(1)
            # <= 253 mirrors lib/default.nix validDomain and the engine's jq
            # `domain` so the snapshot never carries a value downstream
            # validators reject.
            if len(value) <= 253 and DOMAIN_NAME.fullmatch(value):
                links[package][section].append(value)
            else:
                unparsed.append(f"{package}: {line.strip()}")
            continue
        invalid_domain = re.fullmatch(r"      (\S.*)", line)
        if invalid_domain and section == "invalid-auto-verify":
            value = invalid_domain.group(1)
            if len(value) <= 2048:
                links[package]["invalidAutoVerifyDomains"].append(value)
            else:
                unparsed.append(f"{package}: invalid autoVerify domain exceeded 2048 bytes")
            continue
        verification = re.fullmatch(r"      (\S+): (\S+)", line)
        if verification and section == "verification":
            domain, state = verification.groups()
            if len(domain) <= 253 and DOMAIN_NAME.fullmatch(domain):
                links[package]["verification"][domain] = state
            else:
                unparsed.append(f"{package}: {line.strip()}")
            continue
        if line:
            unparsed.append(f"{package}: {line.strip()}")
    for state in links.values():
        state["invalidAutoVerifyDomains"] = sorted(
            set(state["invalidAutoVerifyDomains"])
        )
        state["selected"] = sorted(set(state["selected"]))
        state["unselected"] = sorted(set(state["unselected"]))
        state["verification"] = dict(sorted(state["verification"].items()))
    for name in sorted(domain_packages):
        if name not in managed_user_packages:
            unparsed.append(f"{name}: managed user app-link section not found")
        elif name not in allowed_packages:
            unparsed.append(f"{name}: app-link allowed state not found")
    return dict(sorted(links.items())), sorted(set(unparsed))


def normalize(dump, third_party, installed, device, android, permission_details, app_ops):
    invalid_third_party = sorted(
        name for name in third_party if not PACKAGE_NAME.fullmatch(name)
    )
    if invalid_third_party:
        raise ValueError(
            f"invalid package name in third-party inventory: {invalid_third_party[0]!r}"
        )
    invalid_installed = sorted(
        name for name in installed if not SYSTEM_PACKAGE_NAME.fullmatch(name)
    )
    if invalid_installed:
        raise ValueError(
            f"invalid package name in managed-user inventory: {invalid_installed[0]!r}"
        )
    missing_installed = sorted(third_party - installed)
    if missing_installed:
        raise ValueError(
            "third-party package absent from managed-user inventory: "
            f"{missing_installed[0]}"
        )
    decoded_names = {package.name for package in dump.packages if package.name}
    missing_third_party = sorted(third_party - decoded_names)
    if missing_third_party:
        raise ValueError(
            "package protobuf omitted third-party package: "
            f"{missing_third_party[0]}"
        )

    packages = []
    for package in dump.packages:
        if not package.name:
            continue
        is_third_party = package.name in third_party
        install_source = None
        if package.HasField("install_source"):
            source = package.install_source
            install_source = {
                "initiatingPackage": optional(source, "initiating_package_name"),
                "originatingPackage": optional(source, "originating_package_name"),
                "updateOwnerPackage": optional(source, "update_owner_package_name"),
            }
        packages.append(
            {
                "name": package.name,
                "uid": optional(package, "uid"),
                "versionCode": optional(package, "version_code"),
                "versionName": optional(package, "version_string"),
                "updateTimeMs": optional(package, "update_time_ms"),
                "installerName": optional(package, "installer_name"),
                "installSource": install_source,
                "splits": sorted(
                    (
                        {
                            "name": optional(split, "name"),
                            "revisionCode": optional(split, "revision_code"),
                        }
                        for split in package.splits
                    ),
                    key=lambda split: split["name"] or "",
                ),
                "users": sorted(
                    (
                        {
                            # Proto2 omits scalar fields holding their default.
                            # Owner user 0 therefore appears absent on the wire.
                            "id": user.id,
                            "installType": optional(user, "install_type"),
                            "hidden": optional(user, "is_hidden"),
                            "suspended": optional(user, "is_suspended"),
                            "stopped": optional(user, "is_stopped"),
                            "launched": optional(user, "is_launched"),
                            "enabledState": optional(user, "enabled_state"),
                            "lastDisabledAppCaller": optional(
                                user, "last_disabled_app_caller"
                            ),
                            "suspendingPackages": sorted(user.suspending_package),
                            "suspendingUsers": sorted(user.suspending_user),
                            "distractionFlags": optional(user, "distraction_flags"),
                            # AOSP declares this *_ms field as signed int32;
                            # preserve its potentially overflowed wire value.
                            "firstInstallTimeMsWire": optional(
                                user, "first_install_time_ms"
                            ),
                        }
                        for user in package.users
                    ),
                    key=lambda user: user["id"] if user["id"] is not None else -1,
                ),
                "userPermissions": sorted(
                    (
                        {
                            "id": permissions.id,
                            "granted": sorted(permissions.granted_permissions),
                        }
                        for permissions in package.user_permissions
                    ),
                    key=lambda permissions: (
                        permissions["id"]
                        if permissions["id"] is not None
                        else -1
                    ),
                ),
                "runtimePermissionStates": permission_details.get(package.name, []),
                "thirdPartyForManagedUser": is_third_party,
            }
        )
    if not packages:
        raise ValueError("package protobuf contained no packages")
    return {
        "schemaVersion": 2,
        "device": device,
        "android": android
        | {
            "installedPackagesForManagedUser": sorted(installed),
            "appOps": {
                package: operations
                for package, operations in app_ops.items()
                if package in third_party
            },
        },
        "packages": sorted(packages, key=lambda package: package["name"]),
    }


def parse_args():
    parser = argparse.ArgumentParser()
    parser.add_argument("--proto", required=True, type=Path)
    parser.add_argument("--installed", required=True, type=Path)
    parser.add_argument("--third-party", required=True, type=Path)
    parser.add_argument("--model", required=True)
    parser.add_argument("--product", required=True)
    parser.add_argument("--abi", required=True)
    parser.add_argument("--sdk", required=True, type=int)
    parser.add_argument("--security-patch", required=True)
    parser.add_argument("--managed-user", default=0, type=int)
    parser.add_argument("--night-mode", required=True, type=Path)
    parser.add_argument("--private-dns-mode", required=True, type=Path)
    parser.add_argument("--private-dns-specifier", required=True, type=Path)
    parser.add_argument("--roles", required=True, type=Path)
    parser.add_argument("--disabled", required=True, type=Path)
    parser.add_argument("--device-idle", required=True, type=Path)
    parser.add_argument("--permission-definitions", required=True, type=Path)
    parser.add_argument("--permission-restrictions", required=True, type=Path)
    parser.add_argument("--permission-details", required=True, type=Path)
    parser.add_argument("--app-ops", required=True, type=Path)
    parser.add_argument("--app-locales", required=True, type=Path)
    parser.add_argument("--ime-enabled", required=True, type=Path)
    parser.add_argument("--ime-default", required=True, type=Path)
    parser.add_argument("--data-saver", required=True, type=Path)
    parser.add_argument("--data-restricted", required=True, type=Path)
    parser.add_argument("--data-exempt", required=True, type=Path)
    parser.add_argument("--app-links", required=True, type=Path)
    return parser.parse_args()


def main():
    args = parse_args()
    third_party = {
        line.removeprefix("package:").strip()
        for line in args.third_party.read_text().splitlines()
        if line.strip()
    }
    installed = {
        line.removeprefix("package:").strip()
        for line in args.installed.read_text().splitlines()
        if line.strip()
    }
    dump = package_dump_class()()
    dump.ParseFromString(args.proto.read_bytes())
    permission_details, unparsed_permission_details = normalize_permission_details(
        args.permission_details.read_text().splitlines(), args.managed_user
    )
    app_ops, unparsed_app_ops, derived_app_ops = normalize_app_ops(
        args.app_ops.read_text().splitlines(), args.managed_user
    )
    app_locales, unparsed_app_locales = normalize_app_locales(
        args.app_locales.read_text().splitlines(), args.managed_user
    )
    app_links, unparsed_app_links = normalize_app_links(
        args.app_links.read_text().splitlines(), args.managed_user
    )
    permission_restrictions, unparsed_permission_restrictions = (
        normalize_permission_restrictions(
            args.permission_restrictions.read_text().splitlines()
        )
    )
    android = normalize_android(
        args.night_mode.read_text(),
        args.private_dns_mode.read_text(),
        args.private_dns_specifier.read_text(),
        args.roles.read_text().splitlines(),
        args.disabled.read_text().splitlines(),
        args.device_idle.read_text().splitlines(),
        args.permission_definitions.read_text().splitlines(),
    ) | {
        "unparsedPermissionStateRows": unparsed_permission_details,
        "runtimePermissionRestrictions": permission_restrictions,
        "unparsedPermissionRestrictionRows": unparsed_permission_restrictions,
        "derivedAppOpRows": derived_app_ops,
        "unparsedAppOpRows": unparsed_app_ops,
        "appLocales": app_locales,
        "unparsedAppLocaleRows": unparsed_app_locales,
        "inputMethod": normalize_input_method(
            args.ime_enabled.read_text().splitlines(), args.ime_default.read_text()
        ),
        "dataSaver": normalize_network_policy(
            args.data_saver.read_text(),
            args.data_restricted.read_text(),
            args.data_exempt.read_text(),
        ),
        "appLinks": app_links,
        "unparsedAppLinkRows": unparsed_app_links,
    }
    snapshot = normalize(
        dump,
        third_party,
        installed,
        {
            "model": args.model,
            "product": args.product,
            "abi": args.abi,
            "sdk": args.sdk,
            "securityPatch": args.security_patch,
            "managedUser": args.managed_user,
        },
        android,
        permission_details,
        app_ops,
    )
    json.dump(snapshot, fp=sys.stdout, indent=2, sort_keys=True)
    print()


if __name__ == "__main__":
    main()
