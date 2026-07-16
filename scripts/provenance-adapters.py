#!/usr/bin/env python3
"""Merge credential-free app-export facts into a nix-android snapshot."""

import argparse
import json
import re
import sys
from pathlib import Path
from urllib.parse import urlsplit


PACKAGE_NAME = re.compile(r"[A-Za-z0-9_]+(?:\.[A-Za-z0-9_]+)+")
REPO_PART = re.compile(r"[A-Za-z0-9_.-]+")
HOST = re.compile(r"[A-Za-z0-9.-]+")
SHA256 = re.compile(r"[0-9A-Fa-f]{64}")


def normalize_repo_url(url, override_source):
    if not isinstance(url, str) or not isinstance(override_source, (str, type(None))):
        return None
    parsed = urlsplit(url)
    if (
        parsed.scheme != "https"
        or parsed.username is not None
        or parsed.password is not None
        or parsed.port is not None
        or parsed.query
        or parsed.fragment
        or not HOST.fullmatch(parsed.hostname or "")
    ):
        return None
    parts = [part for part in parsed.path.split("/") if part]
    if len(parts) != 2 or not all(REPO_PART.fullmatch(part) for part in parts):
        return None
    host = parsed.hostname.lower()
    repo = "/".join(parts)
    if override_source not in {None, "GitHub", "Codeberg"}:
        return {"kind": "unsupported"}
    if host == "github.com":
        return (
            {"kind": "github", "value": repo}
            if override_source in {None, "GitHub"}
            else {"kind": "unsupported"}
        )
    if host == "codeberg.org" and override_source in {None, "Codeberg"}:
        return {"kind": "gitea", "value": f"{host}/{repo}"}
    if override_source == "Codeberg":
        return {"kind": "gitea", "value": f"{host}/{repo}"}
    return {"kind": "unsupported"}


def obtainium_facts(path, installed_third_party):
    exported = json.loads(path.read_text())
    if not isinstance(exported, dict) or exported.get("schemaVersion") != 2:
        raise ValueError("Obtainium adapter requires a schemaVersion 2 export")
    apps = exported.get("apps")
    if not isinstance(apps, list):
        raise ValueError("Obtainium export apps must be an array")
    result = []
    seen = set()
    for app in apps:
        if not isinstance(app, dict):
            raise ValueError("Obtainium export app entry must be an object")
        package = app.get("id")
        if not isinstance(package, str) or not PACKAGE_NAME.fullmatch(package):
            raise ValueError(f"invalid Obtainium package id: {package!r}")
        if package in seen:
            raise ValueError(f"duplicate Obtainium package id: {package}")
        seen.add(package)
        if package not in installed_third_party:
            continue
        source = normalize_repo_url(app.get("url"), app.get("overrideSource"))
        result.append({"package": package, "source": source})
    return {"schemaVersion": 2, "apps": sorted(result, key=lambda item: item["package"])}


def normalize_signatures(value):
    if not isinstance(value, str):
        return []
    signatures = []
    for signature in value.split(","):
        normalized = signature.replace(":", "").strip().lower()
        if not SHA256.fullmatch(normalized):
            raise ValueError(f"invalid App Manager signer SHA-256: {signature!r}")
        signatures.append(normalized)
    return sorted(set(signatures))


def app_manager_facts(path, installed_third_party):
    exported = json.loads(path.read_text())
    if not isinstance(exported, list):
        raise ValueError("App Manager adapter requires its JSON app-list export")
    result = []
    seen = set()
    for app in exported:
        if not isinstance(app, dict):
            raise ValueError("App Manager export entry must be an object")
        package = app.get("name")
        if not isinstance(package, str) or not PACKAGE_NAME.fullmatch(package):
            raise ValueError(f"invalid App Manager package id: {package!r}")
        if package in seen:
            raise ValueError(f"duplicate App Manager package id: {package}")
        seen.add(package)
        if package not in installed_third_party:
            continue
        signatures = normalize_signatures(app.get("signature"))
        if not signatures:
            continue
        installer = app.get("installerPackageName")
        if installer is not None and (
            not isinstance(installer, str) or not PACKAGE_NAME.fullmatch(installer)
        ):
            raise ValueError(f"invalid App Manager installer package: {installer!r}")
        result.append(
            {
                "package": package,
                "signerSha256": signatures,
                "installerPackage": installer,
            }
        )
    return {"format": "app-list-json", "packages": sorted(result, key=lambda item: item["package"])}


def enrich(snapshot, obtainium=None, app_manager=None):
    if snapshot.get("schemaVersion") != 2:
        raise ValueError("unsupported nix-android snapshot schema")
    installed_third_party = {
        package["name"]
        for package in snapshot.get("packages", [])
        if package.get("thirdPartyForManagedUser")
    }
    provenance = {}
    if obtainium is not None:
        provenance["obtainium"] = obtainium_facts(obtainium, installed_third_party)
    if app_manager is not None:
        provenance["appManager"] = app_manager_facts(app_manager, installed_third_party)
    if provenance:
        snapshot["provenance"] = provenance
    return snapshot


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--snapshot", required=True, type=Path)
    parser.add_argument("--obtainium", type=Path)
    parser.add_argument("--app-manager", type=Path)
    args = parser.parse_args()
    snapshot = enrich(
        json.loads(args.snapshot.read_text()),
        obtainium=args.obtainium,
        app_manager=args.app_manager,
    )
    json.dump(snapshot, fp=sys.stdout, indent=2, sort_keys=True)
    print()


if __name__ == "__main__":
    main()
