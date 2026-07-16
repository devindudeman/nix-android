#!/usr/bin/env python3
"""Small regression check for the package-protobuf snapshot normalizer."""

import importlib.util
from pathlib import Path


path = Path(__file__).with_name("package-snapshot.py")
spec = importlib.util.spec_from_file_location("package_snapshot", path)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

render_path = Path(__file__).with_name("render-import.py")
render_spec = importlib.util.spec_from_file_location("render_import", render_path)
renderer = importlib.util.module_from_spec(render_spec)
render_spec.loader.exec_module(renderer)

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
    ["android.permission.POST_NOTIFICATIONS", "android.permission.CAMERA"]
)

# Exercise the wire decoder too, not just the Python object mapper.
decoded = module.package_dump_class()()
decoded.ParseFromString(dump.SerializeToString())
snapshot = module.normalize(
    decoded,
    {"org.example.app"},
    {
        "model": "Test Phone",
        "product": "test",
        "abi": "x86_64",
        "sdk": 35,
        "securityPatch": "2026-01-01",
        "managedUser": 0,
    },
)

assert snapshot["schemaVersion"] == 1
assert snapshot["packages"][0]["name"] == "org.example.app"
assert snapshot["packages"][0]["thirdPartyForManagedUser"] is True
assert snapshot["packages"][0]["users"][0]["enabledState"] == 3
assert snapshot["packages"][0]["splits"] == [{"name": "base", "revisionCode": 7}]
assert snapshot["packages"][0]["userPermissions"][0]["granted"] == [
    "android.permission.CAMERA",
    "android.permission.POST_NOTIFICATIONS",
]

framework_dump = module.package_dump_class()()
framework_dump.packages.add().name = "android"
framework_snapshot = module.normalize(framework_dump, set(), snapshot["device"])
assert framework_snapshot["packages"][0]["name"] == "android"

bad_dump = module.package_dump_class()()
bad_dump.packages.add().name = 'org.example.bad"; builtins.abort "injected"'
try:
    module.normalize(
        bad_dump, {'org.example.bad"; builtins.abort "injected"'}, snapshot["device"]
    )
except ValueError:
    pass
else:
    raise AssertionError("unsafe package name was accepted")

try:
    module.normalize(decoded, {"org.example.omitted"}, snapshot["device"])
except ValueError as error:
    assert "protobuf omitted third-party package" in str(error)
else:
    raise AssertionError("partial package protobuf was accepted")

play = decoded.packages.add()
play.name = "com.example.play"
play.installer_name = "com.android.vending"
rendered_snapshot = module.normalize(
    decoded,
    {"org.example.app", "com.example.play"},
    snapshot["device"],
)
rendered = renderer.render(rendered_snapshot)
assert 'apps.play = [\n    "com.example.play"\n  ];' in rendered
assert 'apps.attended = [\n    "org.example.app"\n  ];' in rendered
assert rendered.index('"com.example.play"') < rendered.index('"org.example.app"')
