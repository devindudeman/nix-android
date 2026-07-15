#!/usr/bin/env python3
"""Normalize AOSP's package service protobuf into nix-android snapshot v1."""

import argparse
import json
import re
import sys
from pathlib import Path

from google.protobuf import descriptor_pb2, descriptor_pool, message_factory


PACKAGE_NAME = re.compile(r"[A-Za-z0-9_]+(?:\.[A-Za-z0-9_]+)+")


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


def normalize(dump, third_party, device):
    packages = []
    for package in dump.packages:
        if not package.name:
            continue
        is_third_party = package.name in third_party
        if is_third_party and not PACKAGE_NAME.fullmatch(package.name):
            raise ValueError(f"invalid Android package name in protobuf: {package.name!r}")
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
                            "id": optional(user, "id"),
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
                            "firstInstallTimeMs": optional(
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
                            "id": optional(permissions, "id"),
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
        "schemaVersion": 1,
        "device": device,
        "packages": sorted(packages, key=lambda package: package["name"]),
    }


def parse_args():
    parser = argparse.ArgumentParser()
    parser.add_argument("--proto", required=True, type=Path)
    parser.add_argument("--third-party", required=True, type=Path)
    parser.add_argument("--model", required=True)
    parser.add_argument("--product", required=True)
    parser.add_argument("--abi", required=True)
    parser.add_argument("--sdk", required=True, type=int)
    parser.add_argument("--security-patch", required=True)
    parser.add_argument("--managed-user", default=0, type=int)
    return parser.parse_args()


def main():
    args = parse_args()
    third_party = {
        line.removeprefix("package:").strip()
        for line in args.third_party.read_text().splitlines()
        if line.strip()
    }
    dump = package_dump_class()()
    dump.ParseFromString(args.proto.read_bytes())
    snapshot = normalize(
        dump,
        third_party,
        {
            "model": args.model,
            "product": args.product,
            "abi": args.abi,
            "sdk": args.sdk,
            "securityPatch": args.security_patch,
            "managedUser": args.managed_user,
        },
    )
    json.dump(snapshot, fp=sys.stdout, indent=2, sort_keys=True)
    print()


if __name__ == "__main__":
    main()
