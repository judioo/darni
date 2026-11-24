#!/usr/bin/env python3
"""ABI 1.72 ("this Mac" passkeys: list and delete for the host's settings, tab/104): preserve the struct layouts under it and typecheck gated Swift adoption.

The header's minor is 73, not 72: tab/105 (ABI 1.73, website dark mode) was put on the overlay
before this patch, so the order there is 103, 105, 104 and this patch leaves the number as it
is. A host asks for the feature by name ("local_passkeys"); the minor alone does not say it.

REARC_TEST_ABI_HEADER_DIR names a directory with the patched headers and module map when the
patch is not applied to the checkout yet."""
import re
import subprocess

from abi_import_check import check, structs, callback_types
from run_c_abi import BRIDGE, SRC

BASE = "577e70cef2"
# 577e70cef2: the overlay through tab/103 and tab/105 on 156.0.8078.114 (ABI 1.73, bridge 0.85.0).
# JSON over scalars with one completion, as site permissions (1.67): a host reaches the calls by
# symbol lookup, so the one type the patch may add is that callback's, and no struct.
check(base_commit=BASE, base_minor=73, minor=73, adds_types=True,
      added=["ReArcProfileGetLocalPasskeys", "ReArcProfileDeleteLocalPasskey"], swift='''import Foundation
import ReArcEngine
func configureABI172(profile: UInt64) -> ReArcStatus {
    guard ReArcEngineABIMinorVersion() >= 72, ReArcEngineHasFeature("local_passkeys") else { return ReArcStatus(REARC_UNSUPPORTED) }
    var status = ReArcProfileGetLocalPasskeys(profile, { _, status, profileID, json in
        _ = (status, profileID, json.map { String(cString: $0) })
    }, nil)
    status = ReArcProfileDeleteLocalPasskey(profile, "00ff", { _, status, profileID, json in
        _ = (status, profileID, json.map { String(cString: $0) })
    }, nil)
    return status
}
''')
old = subprocess.check_output(["git", "-C", str(SRC), "show", f"{BASE}:chrome/browser/rearc_bridge/rearc_engine_abi.h"], text=True)
new = (BRIDGE / "rearc_engine_abi.h").read_text()
assert set(structs(new)) == set(structs(old)), set(structs(new)) ^ set(structs(old))
assert callback_types(new) - callback_types(old) == {"ReArcLocalPasskeysCallback"}, callback_types(new) ^ callback_types(old)
assert not callback_types(old) - callback_types(new)
# The completion has the shape of the site permissions one: a host that mirrors one mirrors the other.
shape = lambda name: re.sub(r"\s+", " ", re.search(r"typedef void \(\*" + name + r"\)\(([^;]*)\);", new).group(1))
assert re.sub(r"\btab_id\b", "profile_id", shape("ReArcSitePermissionsCallback")) == shape("ReArcLocalPasskeysCallback"), shape("ReArcLocalPasskeysCallback")
# The patch is documented under its own number, and the feature is advertised.
assert "local_passkeys, ABI 1.72" in new
assert '"local_passkeys"' in (BRIDGE / "rearc_engine_abi.mm").read_text()
print("ABI 1.72: two functions and one callback type added (the shape of ReArcSitePermissionsCallback), no struct PASS")
