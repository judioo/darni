#!/usr/bin/env python3
"""ABI 1.70 (screen sharing: getDisplayMedia asks the host what to share, tab/101): preserve the ABI 1.69 struct layouts and typecheck gated Swift adoption.

REARC_TEST_ABI_HEADER_DIR names a directory with the patched headers and module map when the
patch is not applied to the checkout yet."""
import re

from abi_import_check import check, structs, callback_types
from run_c_abi import BRIDGE, SRC
import subprocess

BASE = "c7000854cf"
# c7000854cf: the overlay through tab/100 on 156.0.8078.109 (ABI 1.69, bridge 0.80.0).
# JSON over scalars with one callback, as WebAuthn's steps (1.68): a host reaches the calls by
# symbol lookup, so the one type the minor may add is that callback's, and no struct.
check(base_commit=BASE, base_minor=69, minor=70, adds_types=True,
      added=["ReArcEngineSetDisplayCaptureCallback", "ReArcDisplayCaptureRespond", "ReArcTabStopDisplayCapture"], swift='''import Foundation
import ReArcEngine
func configureABI170(tab: UInt64) -> ReArcStatus {
    guard ReArcEngineABIMinorVersion() >= 70, ReArcEngineHasFeature("display_capture") else { return ReArcStatus(REARC_UNSUPPORTED) }
    ReArcEngineSetDisplayCaptureCallback({ _, request, tabID, phase, json in
        _ = (request, tabID, phase, json.map { String(cString: $0) })
    }, nil)
    var status = ReArcDisplayCaptureRespond(1, 0, 0, false)
    status = ReArcDisplayCaptureRespond(1, 1, tab, true)
    status = ReArcDisplayCaptureRespond(1, 3, 0, false)
    status = ReArcTabStopDisplayCapture(tab)
    return status
}
''')
old = subprocess.check_output(["git", "-C", str(SRC), "show", f"{BASE}:chrome/browser/rearc_bridge/rearc_engine_abi.h"], text=True)
new = (BRIDGE / "rearc_engine_abi.h").read_text()
assert set(structs(new)) == set(structs(old)), set(structs(new)) ^ set(structs(old))
assert callback_types(new) - callback_types(old) == {"ReArcDisplayCaptureCallback"}, callback_types(new) ^ callback_types(old)
assert not callback_types(old) - callback_types(new)
# The callback has the shape of WebAuthn's: a host that mirrors one mirrors the other.
shape = lambda name: re.sub(r"\s+", " ", re.search(r"typedef void \(\*" + name + r"\)\(([^;]*)\);", new).group(1))
assert shape("ReArcDisplayCaptureCallback") == shape("ReArcWebAuthnCallback"), shape("ReArcDisplayCaptureCallback")
print("ABI 1.70: one callback type added (the shape of ReArcWebAuthnCallback), no struct PASS")
