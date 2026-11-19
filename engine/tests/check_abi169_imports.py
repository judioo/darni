#!/usr/bin/env python3
"""ABI 1.69 (the sites behind a tab's blocked count and the site of a host, tab/098): preserve the ABI 1.68 struct layouts and typecheck gated Swift adoption.

REARC_TEST_ABI_HEADER_DIR names a directory with the patched headers and module map when the
patch is not applied to the checkout yet."""
from abi_import_check import check

# 17641fac0a: the overlay through tab/097 on 156.0.8078.109 (ABI 1.68, bridge 0.78.0).
# JSON in a malloc'd string: a host reaches the calls by symbol lookup, so no struct and no
# callback type may be added.
check(base_commit="17641fac0a", base_minor=68, minor=69, added=["ReArcTabCopyBlockedHosts", "ReArcEngineCopySiteOfHost"], swift='''import Foundation
import ReArcEngine
func siteOfHostABI169(_ host: String) -> String? {
    guard ReArcEngineABIMinorVersion() >= 69, ReArcEngineHasFeature("host_sites") else { return nil }
    var json: UnsafeMutablePointer<CChar>?
    let status = host.withCString { ReArcEngineCopySiteOfHost($0, &json) }
    defer { if let json { ReArcBufferFree(json) } }
    guard status == ReArcStatus(REARC_OK), let json else { return nil }
    return String(cString: json)
}
func blockedHostsABI169(tab: UInt64) -> String? {
    guard ReArcEngineABIMinorVersion() >= 69, ReArcEngineHasFeature("content_blocking_hosts") else { return nil }
    var json: UnsafeMutablePointer<CChar>?
    let status = ReArcTabCopyBlockedHosts(tab, &json)
    defer { if let json { ReArcBufferFree(json) } }
    guard status == ReArcStatus(REARC_OK), let json else { return nil }
    return String(cString: json)
}
''')
