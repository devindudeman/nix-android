#!/usr/bin/env python3
"""Focused fixtures for credential-free import provenance adapters."""

import copy
import importlib.util
import json
import tempfile
from pathlib import Path


def load(name, filename):
    spec = importlib.util.spec_from_file_location(name, Path(__file__).with_name(filename))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


adapter = load("provenance_adapters", "provenance-adapters.py")
renderer = load("render_import", "render-import.py")

snapshot = {
    "schemaVersion": 2,
    "device": {
        "model": "Test Phone",
        "product": "test",
        "abi": "x86_64",
        "sdk": 35,
        "securityPatch": "2026-01-01",
        "managedUser": 0,
    },
    "android": {},
    "packages": [
        {
            "name": "org.example.obtainium",
            "installerName": "dev.imranr.obtainium.fdroid",
            "thirdPartyForManagedUser": True,
        },
        {
            "name": "org.example.codeberg",
            "installerName": "dev.imranr.obtainium.fdroid",
            "thirdPartyForManagedUser": True,
        },
        {
            "name": "org.example.unsupported",
            "installerName": "dev.imranr.obtainium.fdroid",
            "thirdPartyForManagedUser": True,
        },
        {
            "name": "org.example.token",
            "installerName": "dev.imranr.obtainium.fdroid",
            "thirdPartyForManagedUser": True,
        },
        {
            "name": "org.example.play",
            "installerName": "com.android.vending",
            "thirdPartyForManagedUser": True,
        },
    ],
}

with tempfile.TemporaryDirectory() as directory:
    directory = Path(directory)
    obtainium = directory / "obtainium.json"
    app_manager = directory / "app-manager.json"
    obtainium.write_text(
        json.dumps(
            {
                "schemaVersion": 2,
                "exportedAt": "ignored",
                "appVersion": "ignored",
                "settings": {"github-creds": "must-not-survive"},
                "apps": [
                    {
                        "id": "org.example.obtainium",
                        "url": "https://github.com/example/project",
                        "overrideSource": None,
                        "additionalSettings": '{"secret":"also-ignored"}',
                    },
                    {
                        "id": "org.example.codeberg",
                        "url": "https://codeberg.org/example/project",
                        "overrideSource": "Codeberg",
                    },
                    {
                        "id": "org.example.unsupported",
                        "url": "https://gitlab.com/example/project",
                        "overrideSource": "secret-token",
                    },
                    {
                        "id": "org.example.token",
                        "url": "https://github.com/example/private?token=secret",
                        "overrideSource": "GitHub",
                    },
                ],
            }
        )
    )
    app_manager.write_text(
        json.dumps(
            [
                {
                    "name": "org.example.obtainium",
                    "signature": ":".join(["AB"] * 32),
                    "installerPackageName": "dev.imranr.obtainium.fdroid",
                    "label": "ignored",
                }
            ]
        )
    )
    enriched = adapter.enrich(
        copy.deepcopy(snapshot), obtainium=obtainium, app_manager=app_manager
    )

serialized = json.dumps(enriched)
assert "must-not-survive" not in serialized
assert "also-ignored" not in serialized
assert "token=secret" not in serialized
assert "secret-token" not in serialized
assert "gitlab.com" not in serialized
assert enriched["provenance"]["obtainium"]["apps"][0]["source"] == {
    "kind": "gitea",
    "value": "codeberg.org/example/project",
}
assert enriched["provenance"]["appManager"]["packages"][0]["signerSha256"] == [
    "ab" * 32
]

rendered, coverage = renderer.render_with_coverage(enriched)
assert (
    'apps.release."org.example.obtainium".github = "example/project";' in rendered
)
assert (
    'apps.release."org.example.codeberg".gitea = "codeberg.org/example/project";'
    in rendered
)
assert '"org.example.unsupported"' in rendered
assert '"org.example.token"' in rendered
assert '"org.example.obtainium"\n  ];' not in rendered
assert f"App Manager signer org.example.obtainium: {'ab' * 32}" in rendered
assert any(
    fact["surface"] == "apps.release.obtainium" and fact["itemCount"] == 2
    for fact in coverage["facts"]
)

malicious = copy.deepcopy(enriched)
malicious["provenance"]["appManager"]["packages"][0]["signerSha256"] = [
    "ab" * 32 + '\n  apps.cleanup = "uninstall";'
]
try:
    renderer.render_with_coverage(malicious)
except ValueError as error:
    assert "invalid App Manager provenance entry" in str(error)
else:
    raise AssertionError("malformed App Manager signer was accepted")

try:
    adapter.enrich(copy.deepcopy(snapshot), obtainium=Path("does-not-exist"))
except FileNotFoundError:
    pass
else:
    raise AssertionError("missing adapter input was accepted")
