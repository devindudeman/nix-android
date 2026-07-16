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
permissions = package.user_permissions.add()
permissions.id = 0
permissions.granted_permissions.extend(
    [
        "android.permission.POST_NOTIFICATIONS",
        "android.permission.CAMERA",
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
        "permission:invalid permission name",
    ],
)
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
]
assert snapshot["android"]["installedPackagesForManagedUser"] == [
    "com.example.omittedsystem",
    "org.example.app",
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
]

framework_dump = module.package_dump_class()()
framework_dump.packages.add().name = "android"
framework_snapshot = module.normalize(
    framework_dump, set(), {"android"}, snapshot["device"], android
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
    )
except ValueError as error:
    assert "package protobuf omitted third-party package" in str(error)
else:
    raise AssertionError("partial package protobuf was accepted")

play = decoded.packages.add()
play.name = "com.example.play"
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
assert 'android.batteryOptimization.exempt = [\n    "org.example.app"\n  ];' in rendered
assert "com.example.system" not in rendered
assert "1 DeviceIdle row(s) were unparsed and omitted" in rendered
assert "1 disabled system package(s)" in rendered
assert "1 non-runtime granted-permission entries" in rendered
assert "1 granted runtime-permission entries for system packages" in rendered
assert "1 system-owned DeviceIdle row(s)" in rendered
assert "1 user-added DeviceIdle row(s) for packages outside managed user 0" in rendered
assert 'android.permission.INTERNET' not in rendered
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

auto_snapshot = copy.deepcopy(rendered_snapshot)
auto_snapshot["android"]["nightMode"] = "Night mode: auto"
auto_snapshot["android"]["roles"]["browser"].append("com.example.browser")
auto_rendered = renderer.render(auto_snapshot)
assert "android.darkMode =" not in auto_rendered
assert "android.defaultApps.browser =" not in auto_rendered
assert "public option supports yes/no only" in auto_rendered
assert "android.defaultApps.browser had 2 holders; omitted" in auto_rendered
