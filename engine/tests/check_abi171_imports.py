#!/usr/bin/env python3
"""ABI 1.71 (tab freezing: a hidden tab is frozen before it is unloaded, tab/103): preserve the ABI 1.70 struct layouts and typecheck gated Swift adoption.

REARC_TEST_ABI_HEADER_DIR names a directory with the patched headers and module map when the
patch is not applied to the checkout yet, or when a later minor has been stacked on it (the
check holds its own minor: against a tree at 1.72 or later it no longer passes, as 1.70's does
not after this one). The headers of 1.71 are those of overlay commit a3b96b217d:
    git -C engine/chromium/src archive a3b96b217d chrome/browser/rearc_bridge | tar -x -C <dir>"""
from abi_import_check import check

BASE = "86afa51467"
# 86afa51467: the overlay through tab/102 on 156.0.8078.114 (ABI 1.70, bridge 0.82.0).
# Scalars only: a host reaches the three calls by symbol lookup, so the minor adds no struct
# and no callback type.
check(base_commit=BASE, base_minor=70, minor=71,
      added=["ReArcTabFreeze", "ReArcTabUnfreeze", "ReArcTabGetFreezeState"], swift='''import Foundation
import ReArcEngine
func configureABI171(tab: UInt64) -> (ReArcStatus, Bool, Bool) {
    guard ReArcEngineABIMinorVersion() >= 71, ReArcEngineHasFeature("tab_freeze") else { return (ReArcStatus(REARC_UNSUPPORTED), false, false) }
    var requested = false
    var frozen = false
    var status = ReArcTabFreeze(tab)
    status = ReArcTabGetFreezeState(tab, &requested, &frozen)
    status = ReArcTabUnfreeze(tab)
    return (status, requested, frozen)
}
''')
