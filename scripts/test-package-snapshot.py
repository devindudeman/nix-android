#!/usr/bin/env python3
"""Small regression check for the package-protobuf snapshot normalizer."""

import importlib.util
import copy
import json
from pathlib import Path


path = Path(__file__).with_name("package-snapshot.py")
spec = importlib.util.spec_from_file_location("package_snapshot", path)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

render_path = Path(__file__).with_name("render-import.py")
render_spec = importlib.util.spec_from_file_location("render_import", render_path)
renderer = importlib.util.module_from_spec(render_spec)
render_spec.loader.exec_module(renderer)

fixtures = json.loads(
    (Path(__file__).parent.parent / "tests/fixtures/import-targets.json").read_text()
)
for fixture in fixtures.values():
    evidence = fixture["evidence"]
    normalized = module.normalize_android(
        evidence["nightMode"],
        evidence["privateDnsMode"],
        evidence["privateDnsSpecifier"],
        evidence["roles"],
        evidence["disabled"],
        evidence["deviceIdle"],
        evidence["permissionDefinitions"],
    )
    expected = fixture["expected"]
    assert normalized["nightMode"] == expected["nightMode"]
    assert normalized["privateDns"] == expected["privateDns"]
    assert (
        normalized["runtimePermissionDefinitions"]
        == expected["permissionDefinitions"]
    )
    assert sorted(
        entry["package"]
        for entry in normalized["deviceIdleWhitelist"]["entries"]
        if entry["source"] == "user"
    ) == expected["userDeviceIdlePackages"]
    package = expected["userDeviceIdlePackages"][0]
    permission_details, unparsed_permissions = module.normalize_permission_details(
        evidence["permissionDetails"], 0
    )
    app_ops, unparsed_app_ops, derived_app_ops = module.normalize_app_ops(
        evidence["appOps"], 0
    )
    app_locales, unparsed_app_locales = module.normalize_app_locales(
        evidence["appLocales"], 0
    )
    input_method = module.normalize_input_method(
        evidence["inputMethodEnabled"], evidence["inputMethodSelected"]
    )
    data_saver = module.normalize_network_policy(
        evidence["networkPolicyStatus"],
        evidence["networkPolicyRestricted"],
        evidence["networkPolicyExempt"],
    )
    app_links, unparsed_app_links = module.normalize_app_links(
        evidence["appLinks"], 0
    )
    assert unparsed_permissions == []
    assert unparsed_app_ops == []
    assert derived_app_ops == []
    assert unparsed_app_locales == []
    assert unparsed_app_links == []
    assert permission_details[package] == expected["permissionDetails"]
    assert app_ops[package] == expected["appOps"]
    assert app_locales[package] == expected["appLocales"]
    assert input_method["enabled"] == expected["inputMethod"]["enabled"]
    assert input_method["selected"] == expected["inputMethod"]["selected"]
    assert data_saver == expected["dataSaver"]
    assert app_links[package]["allowed"] == expected["appLinks"]["allowed"]
    assert app_links[package]["selected"] == expected["appLinks"]["selected"]
    fixture_snapshot = {
        "schemaVersion": 2,
        "device": {
            "model": "Anonymized fixture",
            "product": "fixture",
            "abi": "arm64-v8a",
            "sdk": 36,
            "securityPatch": "2026-01-01",
            "managedUser": 0,
        },
        "android": normalized
        | {
            "installedPackagesForManagedUser": [package],
            "appOps": app_ops,
            "derivedAppOpRows": [],
            "unparsedAppOpRows": [],
            "appLocales": app_locales,
            "unparsedAppLocaleRows": [],
            "inputMethod": input_method,
            "dataSaver": data_saver,
            "appLinks": app_links,
            "unparsedAppLinkRows": [],
            "unparsedPermissionStateRows": [],
            "runtimePermissionRestrictions": {},
            "unparsedPermissionRestrictionRows": [],
        },
        "packages": [
            {
                "name": package,
                "installerName": "org.example.installer",
                "thirdPartyForManagedUser": True,
                "users": [{"id": 0, "suspended": False, "suspendingPackages": []}],
                "userPermissions": [
                    {
                        "id": 0,
                        "granted": [
                            state["permission"]
                            for state in permission_details[package]
                            if state["granted"]
                        ],
                    }
                ],
                "runtimePermissionStates": permission_details[package],
            }
        ],
    }
    fixture_rendered, fixture_coverage = renderer.render_with_coverage(
        fixture_snapshot
    )
    assert f'android.locales."{package}"' in fixture_rendered
    assert expected["inputMethod"]["selected"] in fixture_rendered
    assert expected["appLinks"]["selected"][0] in fixture_rendered
    for operation, mode in expected["appOps"].items():
        assert f'android.appOps."{package}"."{operation}" = "{mode}";' in fixture_rendered
    for state in expected["permissionDetails"]:
        # Flags render only when the declaration reproduces the row's grant
        # state; a denied row has no rendered revoke, so its flags stay
        # evidence (stockPixel's denied USER_FIXED row must NOT render).
        if state["granted"]:
            for flag in state["flags"]:
                assert flag.lower().replace("_", "-") in fixture_rendered
        else:
            for flag in state["flags"]:
                writable = flag.lower().replace("_", "-")
                assert (
                    f'"{writable}"' not in fixture_rendered
                ), f"denied-row flag {flag} was rendered"
    if any(state["granted"] for state in expected["permissionDetails"]):
        granted = next(
            state["permission"]
            for state in expected["permissionDetails"]
            if state["granted"]
        )
        assert granted in fixture_rendered
    unselected_count = len(app_links[package]["unselected"])
    assert any(
        fact["surface"] == "android.appLinks.unselected"
        and fact["itemCount"] == unselected_count
        for fact in fixture_coverage["facts"]
    )

dump = module.package_dump_class()()
package = dump.packages.add()
package.name = "org.example.app"
package.uid = 10123
package.version_code = 42
package.version_string = "1.2.3"
package.installer_name = "org.fdroid.fdroid"
package.install_source.initiating_package_name = "org.fdroid.fdroid"
split = package.splits.add()
split.name = "base"
split.revision_code = 7
user = package.users.add()
user.id = 0
user.install_type = 1
user.enabled_state = 3
user.is_suspended = True
user.suspending_package.append("com.android.shell")
permissions = package.user_permissions.add()
permissions.id = 0
permissions.granted_permissions.extend(
    [
        "android.permission.POST_NOTIFICATIONS",
        "android.permission.CAMERA",
        "android.permission.READ_SMS",
        "android.permission.INTERNET",
    ]
)

# Exercise the wire decoder too, not just the Python object mapper.
decoded = module.package_dump_class()()
decoded.ParseFromString(dump.SerializeToString())
android = module.normalize_android(
    "Night mode: yes\n",
    "hostname\n",
    "dns.example.com\n",
    [
        "browser\torg.example.app",
        "dialer\tcom.example.dialer",
        "home\tcom.example.home",
        "sms\tcom.example.sms",
    ],
    ["package:android", "package:org.example.app"],
    [
        "system,com.example.system,1000",
        "user,org.example.app,10123",
        "user,com.example.otherprofile,10234",
        "unexpected-deviceidle-row",
    ],
    [
        "Dangerous Permissions:",
        "  + permission:android.permission.CAMERA",
        "    protectionLevel:dangerous",
        "  + permission:android.permission.POST_NOTIFICATIONS",
        "  + permission:android.permission.READ_SMS",
        "    protectionLevel:dangerous",
        "permission:invalid permission name",
    ],
)
permission_details, unparsed_permission_details = module.normalize_permission_details(
    [
        "### nix-android package org.example.app",
        "    User 0: installed=true",
        "      runtime permissions:",
        "        android.permission.CAMERA: granted=true, flags=[ USER_SET|USER_FIXED|USER_SENSITIVE_WHEN_GRANTED]",
        "        android.permission.POST_NOTIFICATIONS: granted=true, flags=[ USER_SENSITIVE_WHEN_GRANTED]",
        "        com.google.android.gms.permission.CAR_FUEL: granted=false",
        "        malformed permission state",
        "    User 10: installed=true",
        "      runtime permissions:",
        "        android.permission.CAMERA: granted=false, flags=[ USER_SET]",
    ],
    0,
)
permission_restrictions, unparsed_permission_restrictions = (
    module.normalize_permission_restrictions(
        [
            "  Permission [android.permission.READ_SMS] (abc123):",
            "    sourcePackage=android",
            "    flags=0x4",
            "  Permission [android.permission.ACCESS_BACKGROUND_LOCATION] (def456):",
            "    sourcePackage=android",
            "    flags=0x8",
            "  Permission [us.example.permission-group.ipc.sender] (ghi789):",
            "    sourcePackage=us.example",
            "    flags=0x0",
        ]
    )
)
assert next(
    state
    for state in permission_details["org.example.app"]
    if state["permission"] == "com.google.android.gms.permission.CAR_FUEL"
)["flags"] == []
assert permission_restrictions == {
    "android.permission.ACCESS_BACKGROUND_LOCATION": ["soft-restricted"],
    "android.permission.READ_SMS": ["hard-restricted"],
}
assert unparsed_permission_restrictions == []
app_ops, unparsed_app_ops, derived_app_ops = module.normalize_app_ops(
    [
        "  Uid u0a123:",
        "      CAMERA: mode=allow",
        "    Package org.example.app:",
        "      RUN_IN_BACKGROUND (ignore): ",
        "      ACCESS_RESTRICTED_SETTINGS (default): ",
        "      GPS (allow / switch COARSE_LOCATION=allow): ",
        "    Package android:",
        "      CAMERA (allow): ",
        "  Uid u10a123:",
        "    Package org.example.app:",
        "      RUN_IN_BACKGROUND (allow): ",
    ],
    0,
)
assert derived_app_ops == [
    "org.example.app: GPS (allow / switch COARSE_LOCATION=allow):"
]
assert app_ops["android"] == {"CAMERA": "allow"}
_, drifted_permission_rows = module.normalize_permission_details(
    [
        "### nix-android package org.example.drifted",
        "    User #0: installed=true",
        "      runtime-permissions:",
    ],
    0,
)
assert "org.example.drifted: managed user section not found" in drifted_permission_rows
cross_user_permissions, drifted_cross_user_rows = module.normalize_permission_details(
    [
        "### nix-android package org.example.crossuser",
        "    User 0: installed=true",
        "      runtime permissions:",
        "        android.permission.CAMERA: granted=true, flags=[]",
        "    User all: installed=true",
        "    User #10: installed=true",
        "      runtime permissions:",
        "        android.permission.RECORD_AUDIO: granted=true, flags=[]",
    ],
    0,
)
assert [state["permission"] for state in cross_user_permissions["org.example.crossuser"]] == [
    "android.permission.CAMERA"
]
assert "org.example.crossuser: User #10: installed=true" in drifted_cross_user_rows
drifted_app_ops_state, drifted_app_ops, drifted_derived_app_ops = (
    module.normalize_app_ops(
    [
        "  Uid u0a123:",
        "    Package org.example.owner:",
        "      CAMERA (allow): ",
        "  Uid [u10a123]:",
        "    Package org.example.profile:",
        "      RECORD_AUDIO (allow): ",
        "    Package [org.example.drifted]:",
    ],
        0,
    )
)
assert set(drifted_app_ops_state) == {"org.example.owner"}
assert "Uid [u10a123]:" in drifted_app_ops
assert "Package [org.example.drifted]:" in drifted_app_ops
assert drifted_derived_app_ops == []
app_locales, unparsed_app_locales = module.normalize_app_locales(
    [
        "### nix-android package org.example.app",
        "Locales for org.example.app for user 0 are [en-US,fr-FR]",
    ],
    0,
)
input_method = module.normalize_input_method(
    ["com.android.inputmethod.latin/.LatinIME"],
    "com.android.inputmethod.latin/.LatinIME\n",
)
data_saver = module.normalize_network_policy(
    "Restrict background status: enabled\n",
    "Restrict background blacklisted UIDs: 10124 \n",
    "Restrict background whitelisted UIDs: 9999 \n",
)
app_links, unparsed_app_links = module.normalize_app_links(
    [
        "### nix-android package org.example.app",
        "  org.example.app:",
        "    Invalid autoVerify domains:",
        "      chat",
        "      *",
        "    Domain verification state:",
        "      example.com: verified",
        "    User 0:",
        "      Verification link handling allowed: false",
        "      Selection state:",
        "        Enabled:",
        "          example.com",
        "        Disabled:",
        "          www.example.com",
        "      Future state: changed-format",
    ],
    0,
)
assert app_links["org.example.app"]["invalidAutoVerifyDomains"] == ["*", "chat"]
_, drifted_app_link_rows = module.normalize_app_links(
    [
        "### nix-android package org.example.drifted",
        "  org.example.drifted:",
        "    Domain verification state:",
        "      example.com: verified",
        "    User 0:",
        "      Link handling allowed: true",
    ],
    0,
)
assert "org.example.drifted: app-link allowed state not found" in drifted_app_link_rows
android |= {
    "unparsedPermissionStateRows": unparsed_permission_details,
    "runtimePermissionRestrictions": permission_restrictions,
    "unparsedPermissionRestrictionRows": unparsed_permission_restrictions,
    "derivedAppOpRows": derived_app_ops,
    "unparsedAppOpRows": unparsed_app_ops,
    "appLocales": app_locales,
    "unparsedAppLocaleRows": unparsed_app_locales,
    "inputMethod": input_method,
    "dataSaver": data_saver,
    "appLinks": app_links,
    "unparsedAppLinkRows": unparsed_app_links,
}
snapshot = module.normalize(
    decoded,
    {"org.example.app"},
    {"com.example.omittedsystem", "org.example.app"},
    {
        "model": "Test Phone",
        "product": "test",
        "abi": "x86_64",
        "sdk": 35,
        "securityPatch": "2026-01-01",
        "managedUser": 0,
    },
    android,
    permission_details,
    app_ops,
)

assert snapshot["schemaVersion"] == 2
assert snapshot["android"]["nightMode"] == "Night mode: yes"
assert snapshot["android"]["privateDns"] == {
    "mode": "hostname",
    "specifier": "dns.example.com",
}
assert snapshot["android"]["roles"]["browser"] == ["org.example.app"]
assert snapshot["android"]["disabledPackages"] == ["android", "org.example.app"]
assert snapshot["android"]["runtimePermissionDefinitions"] == [
    "android.permission.CAMERA",
    "android.permission.POST_NOTIFICATIONS",
    "android.permission.READ_SMS",
]
assert snapshot["android"]["installedPackagesForManagedUser"] == [
    "com.example.omittedsystem",
    "org.example.app",
]
assert snapshot["android"]["appOps"] == {
    "org.example.app": {
        "ACCESS_RESTRICTED_SETTINGS": "default",
        "RUN_IN_BACKGROUND": "ignore",
    }
}
assert snapshot["android"]["appLocales"] == {
    "org.example.app": ["en-US", "fr-FR"]
}
assert snapshot["android"]["inputMethod"]["selected"] == (
    "com.android.inputmethod.latin/.LatinIME"
)
assert snapshot["android"]["dataSaver"]["restrictedUids"] == [10124]
assert snapshot["android"]["appLinks"]["org.example.app"]["selected"] == [
    "example.com"
]
assert snapshot["android"]["unparsedAppLinkRows"] == [
    "org.example.app: Future state: changed-format"
]
assert snapshot["android"]["unparsedPermissionDefinitionRows"] == [
    "permission:invalid permission name"
]
assert snapshot["android"]["deviceIdleWhitelist"]["entries"][1]["source"] == "user"
assert snapshot["android"]["deviceIdleWhitelist"]["unparsed"] == [
    "unexpected-deviceidle-row"
]
assert snapshot["packages"][0]["name"] == "org.example.app"
assert snapshot["packages"][0]["thirdPartyForManagedUser"] is True
assert snapshot["packages"][0]["users"][0]["enabledState"] == 3
assert snapshot["packages"][0]["splits"] == [{"name": "base", "revisionCode": 7}]
assert snapshot["packages"][0]["userPermissions"][0]["granted"] == [
    "android.permission.CAMERA",
    "android.permission.INTERNET",
    "android.permission.POST_NOTIFICATIONS",
    "android.permission.READ_SMS",
]
assert snapshot["packages"][0]["runtimePermissionStates"] == [
    {
        "permission": "android.permission.CAMERA",
        "granted": True,
        "flags": ["USER_FIXED", "USER_SENSITIVE_WHEN_GRANTED", "USER_SET"],
    },
    {
        "permission": "android.permission.POST_NOTIFICATIONS",
        "granted": True,
        "flags": ["USER_SENSITIVE_WHEN_GRANTED"],
    },
    {
        "permission": "com.google.android.gms.permission.CAR_FUEL",
        "granted": False,
        "flags": [],
    },
]

framework_dump = module.package_dump_class()()
framework_dump.packages.add().name = "android"
framework_snapshot = module.normalize(
    framework_dump, set(), {"android"}, snapshot["device"], android, {}, {}
)
assert framework_snapshot["packages"][0]["name"] == "android"

bad_dump = module.package_dump_class()()
bad_dump.packages.add().name = 'org.example.bad"; builtins.abort "injected"'
try:
    module.normalize(
        bad_dump,
        {'org.example.bad"; builtins.abort "injected"'},
        {'org.example.bad"; builtins.abort "injected"'},
        snapshot["device"],
        android,
        {},
        {},
    )
except ValueError:
    pass
else:
    raise AssertionError("unsafe package name was accepted")

try:
    module.normalize(
        decoded,
        {"org.example.omitted"},
        {"org.example.omitted"},
        snapshot["device"],
        android,
        {},
        {},
    )
except ValueError as error:
    assert "package protobuf omitted third-party package" in str(error)
else:
    raise AssertionError("partial package protobuf was accepted")

play = decoded.packages.add()
play.name = "com.example.play"
play.uid = 10124
play.installer_name = "com.android.vending"
play_permissions = play.user_permissions.add()
play_permissions.id = 0
play_permissions.granted_permissions.append("android.permission.POST_NOTIFICATIONS")
system_app = decoded.packages.add()
system_app.name = "com.example.systemapp"
system_permissions = system_app.user_permissions.add()
system_permissions.id = 0
system_permissions.granted_permissions.append("android.permission.CAMERA")
rendered_snapshot = module.normalize(
    decoded,
    {"org.example.app", "com.example.play"},
    {"org.example.app", "com.example.play", "com.example.systemapp"},
    snapshot["device"],
    android,
    permission_details,
    app_ops,
)
rendered, coverage = renderer.render_with_coverage(rendered_snapshot)
assert 'apps.play = [\n    "com.example.play"\n  ];' in rendered
assert 'apps.attended = [\n    "org.example.app"\n  ];' in rendered
assert rendered.index('"com.example.play"') < rendered.index('"org.example.app"')
assert "android.darkMode = true;" in rendered
assert 'android.privateDns = "dns.example.com";' in rendered
assert 'android.defaultApps.browser = "org.example.app";' in rendered
assert 'android.packages.disabled = [\n    "org.example.app"\n  ];' in rendered
assert (
    'android.permissions."com.example.play".grant = [\n'
    '    "android.permission.POST_NOTIFICATIONS"\n'
    "  ];"
) in rendered
assert (
    'android.permissions."org.example.app".flags."android.permission.CAMERA" = [\n'
    '    "user-fixed"\n'
    '    "user-set"\n'
    "  ];"
) in rendered
assert (
    'android.permissions."org.example.app".flags."android.permission.POST_NOTIFICATIONS" = [];'
    in rendered
)
assert 'android.appOps."org.example.app"."RUN_IN_BACKGROUND" = "ignore";' in rendered
assert 'android.packages.suspended = [\n    "org.example.app"\n  ];' in rendered
assert 'android.locales."org.example.app" = [\n    "en-US"\n    "fr-FR"\n  ];' in rendered
assert 'android.inputMethod.enabled = [\n    "com.android.inputmethod.latin/.LatinIME"\n  ];' in rendered
assert 'android.inputMethod.default = "com.android.inputmethod.latin/.LatinIME";' in rendered
assert "android.dataSaver.enabled = true;" in rendered
assert 'android.dataSaver.packages."com.example.play"' not in rendered
assert "2 per-UID Data Saver override(s)" in rendered
assert 'android.appLinks."org.example.app" = {' in rendered
assert "    allowed = false;" in rendered
assert '      "example.com"' in rendered
assert 'android.batteryOptimization.exempt = [\n    "org.example.app"\n  ];' in rendered
assert "com.example.system" not in rendered
assert "1 DeviceIdle row(s) were unparsed and omitted" in rendered
assert "1 app-link row(s) were unparsed" in rendered
assert "1 disabled system package(s)" in rendered
assert "1 non-runtime granted-permission entries" in rendered
assert "1 granted runtime-permission entries for system packages" in rendered
assert "1 system-owned DeviceIdle row(s)" in rendered
assert "1 user-added DeviceIdle row(s) for packages outside managed user 0" in rendered
assert 'android.permission.INTERNET' not in rendered
assert '"android.permission.READ_SMS"' not in rendered
assert "1 restricted runtime-permission grant(s)" in rendered
assert coverage["schemaVersion"] == 1
assert coverage["snapshotSchemaVersion"] == 2
assert set(coverage["summary"]) == {
    "declarable",
    "observed-only",
    "ambiguous",
    "unreachable",
}
assert coverage["summary"]["declarable"] > 0
assert coverage["summary"]["observed-only"] > 0
assert coverage["summary"]["ambiguous"] > 0
assert coverage["summary"]["unreachable"] == 4
assert coverage["facts"] == sorted(
    coverage["facts"],
    key=lambda item: (item["surface"], item["status"], item["reason"]),
)
assert not any("serial" in key.lower() for key in coverage["device"])

# An unparsed restriction row that names its permission scopes the omission to
# that permission: CAMERA's grant and flags disappear, other grants stay.
incomplete_restrictions = copy.deepcopy(rendered_snapshot)
incomplete_restrictions["android"]["unparsedPermissionRestrictionRows"] = [
    "Permission [android.permission.CAMERA] (changed grammar):"
]
incomplete_rendered, incomplete_coverage = renderer.render_with_coverage(
    incomplete_restrictions
)
assert '"android.permission.CAMERA"' not in incomplete_rendered
assert (
    'android.permissions."org.example.app".grant = [\n'
    '    "android.permission.POST_NOTIFICATIONS"\n'
    "  ];"
) in incomplete_rendered
assert "restriction evidence was incomplete" in incomplete_rendered
# CAMERA (granted, grant omitted) plus the denied CAR_FUEL row.
assert (
    "2 permission-flag row(s) were preserved and omitted because the declaration does not reproduce the row's grant state"
    in incomplete_rendered
)
assert any(
    fact["surface"] == "android.permissions.unknownRestrictionGrants"
    and fact["status"] == "ambiguous"
    for fact in incomplete_coverage["facts"]
)
assert any(
    fact["surface"] == "android.permissions.flagsForOmittedGrants"
    and fact["status"] == "ambiguous"
    and fact["itemCount"] == 2
    for fact in incomplete_coverage["facts"]
)

# A row that cannot be attributed to one permission keeps the conservative
# global omission of every third-party grant.
global_incomplete = copy.deepcopy(rendered_snapshot)
global_incomplete["android"]["unparsedPermissionRestrictionRows"] = [
    "garbled restriction output"
]
global_rendered, _global_coverage = renderer.render_with_coverage(global_incomplete)
assert 'android.permissions."org.example.app".grant' not in global_rendered
assert 'android.permissions."com.example.play".grant' not in global_rendered
assert "restriction evidence was incomplete" in global_rendered

auto_snapshot = copy.deepcopy(rendered_snapshot)
auto_snapshot["android"]["nightMode"] = "Night mode: auto"
auto_snapshot["android"]["roles"]["browser"].append("com.example.browser")
auto_rendered = renderer.render(auto_snapshot)
assert "android.darkMode =" not in auto_rendered
assert "android.defaultApps.browser =" not in auto_rendered
assert "public option supports yes/no only" in auto_rendered
assert "android.defaultApps.browser had 2 holders; omitted" in auto_rendered
