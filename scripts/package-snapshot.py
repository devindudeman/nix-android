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


def normalize(dump, third_party, installed, device, android):
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
                "thirdPartyForManagedUser": is_third_party,
            }
        )
    if not packages:
        raise ValueError("package protobuf contained no packages")
    return {
        "schemaVersion": 2,
        "device": device,
        "android": android
        | {"installedPackagesForManagedUser": sorted(installed)},
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
        normalize_android(
            args.night_mode.read_text(),
            args.private_dns_mode.read_text(),
            args.private_dns_specifier.read_text(),
            args.roles.read_text().splitlines(),
            args.disabled.read_text().splitlines(),
            args.device_idle.read_text().splitlines(),
            args.permission_definitions.read_text().splitlines(),
        ),
    )
    json.dump(snapshot, fp=sys.stdout, indent=2, sort_keys=True)
    print()


if __name__ == "__main__":
    main()
