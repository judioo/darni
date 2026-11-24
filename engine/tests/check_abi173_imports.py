#!/usr/bin/env python3
"""ABI 1.73 (dark mode for websites: the host says which pages are dark, tab/105): preserve the ABI 1.71 struct layouts and typecheck gated Swift adoption.

The checkout carries tab/104 (ABI 1.72's functions) on top of this patch, so the header that is
checked is the one of this patch's own overlay commit, read with `git show`. REARC_TEST_ABI_HEADER_DIR
names another directory with the patched headers and module map (a patch not applied yet)."""
import os
import subprocess
import tempfile
from pathlib import Path

SRC = Path(__file__).resolve().parents[1] / "chromium/src"
BASE = "a3b96b217d"
# a3b96b217d: the overlay through tab/103 on 156.0.8078.114 (ABI 1.71, bridge 0.83.0).
OVERLAY = "30c30a1c8d"
# 30c30a1c8d: tab/105 on it (ABI 1.73, bridge 0.85.0). 1.72 is tab/104's, which landed after.
if "REARC_TEST_ABI_HEADER_DIR" not in os.environ:
    headers = Path(tempfile.mkdtemp(prefix="rearc-abi173-headers-"))
    for name in ("rearc_engine_abi.h", "rearc_engine_entry_mac.h", "module.modulemap"):
        (headers / name).write_bytes(subprocess.check_output(
            ["git", "-C", str(SRC), "show", f"{OVERLAY}:chrome/browser/rearc_bridge/{name}"]))
    os.environ["REARC_TEST_ABI_HEADER_DIR"] = str(headers)

from abi_import_check import check  # noqa: E402 (after the header directory is chosen)

# Scalars and JSON, no callback: a host reaches the calls by symbol lookup, so no type is added.
check(base_commit=BASE, base_minor=71, minor=73,
      added=["ReArcProfileSetWebsiteDarkMode", "ReArcTabGetWebsiteDarkMode"], swift='''import Foundation
import ReArcEngine
func configureABI173(profile: UInt64, tab: UInt64) -> ReArcStatus {
    guard ReArcEngineABIMinorVersion() >= 73, ReArcEngineHasFeature("website_dark_mode") else { return ReArcStatus(REARC_UNSUPPORTED) }
    var status = ReArcProfileSetWebsiteDarkMode(profile, true, "[\\"news.example\\"]", "[\\"bank.example\\"]")
    status = ReArcProfileSetWebsiteDarkMode(profile, false, nil, nil)
    var dark = false
    status = ReArcTabGetWebsiteDarkMode(tab, &dark)
    return dark ? status : ReArcStatus(REARC_OK)
}
''')
print("ABI 1.73: two functions, no struct and no callback type added PASS")
