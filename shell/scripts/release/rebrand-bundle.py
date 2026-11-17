#!/usr/bin/env python3
"""Puts ReArc's name and icon where the engine build leaves Chromium's in a ReArc.app.

The engine keeps PRODUCT_FULLNAME=Chromium (patch chrome/002 keeps Chromium's bundle file
names), so Chromium's localized strings still name Chromium:

- The alerts helpers ("Chromium Helper (Alerts).app" and the Aperitif one) send web
  notifications. macOS names them by their localized CFBundleDisplayName, "Chromium", and
  shows their AppIcon, Chromium's. On first launch macOS shows a "Chromium Notifications"
  banner beside ReArc's, and Notification settings list a "Chromium" app (bug report,
  2026-11-17). Chrome sets that name to "Google Chrome", so the helper reads as the browser.
- The app's own <locale>.lproj/InfoPlist.strings override Info.plist's camera, microphone,
  location and Bluetooth reasons with "Once Chromium has access, ...".

Usage: rebrand-bundle.py <ReArc.app> <ReArc.icns>. Runs before signing; it prints the
helper bundles it changed, one per line, so the caller can re-sign them.
"""
import plistlib
import re
import shutil
import sys
from pathlib import Path

NAME = "ReArc"
HELPERS = "Contents/Frameworks/Chromium Framework.framework/Versions/Current/Helpers"
ALERT_HELPERS = ("Chromium Helper (Alerts).app", "Chromium Helper (Aperitif Alerts).app")
# Only the strings people read as the app's name; "The Chromium Authors" in the copyright
# and the "Chromium Shortcut" file type stay as they are.
NAMED_KEY = re.compile(r"^(CFBundleDisplayName|CFBundleName|NS\w+UsageDescription)$")
LINE = re.compile(r'^(\s*"?([A-Za-z0-9_ ]+?)"?\s*=\s*")(.*)(";\s*)$')


def rebrand_strings_text(text: str) -> str:
    """Old-style .strings text: replaces Chromium with ReArc in the named keys' values."""
    out = []
    for line in text.splitlines(keepends=True):
        m = LINE.match(line)
        if m and NAMED_KEY.match(m.group(2)):
            line = m.group(1) + m.group(3).replace("Chromium", NAME) + m.group(4)
        out.append(line)
    return "".join(out)


def rebrand_strings_file(path: Path) -> bool:
    raw = path.read_bytes()
    if raw.startswith(b"bplist") or raw.lstrip().startswith(b"<?xml"):
        fmt = plistlib.FMT_BINARY if raw.startswith(b"bplist") else plistlib.FMT_XML
        data = plistlib.loads(raw)
        changed = {k: v.replace("Chromium", NAME) for k, v in data.items()
                   if NAMED_KEY.match(k) and isinstance(v, str) and "Chromium" in v}
        if not changed:
            return False
        data.update(changed)
        path.write_bytes(plistlib.dumps(data, fmt=fmt))
        return True
    encoding = "utf-16" if raw[:2] in (b"\xff\xfe", b"\xfe\xff") else "utf-8"
    text = raw.decode(encoding)
    new = rebrand_strings_text(text)
    if new == text:
        return False
    path.write_bytes(new.encode(encoding))
    return True


def rebrand_alert_helper(helper: Path, icns: Path) -> None:
    resources = helper / "Contents/Resources"
    for strings in resources.glob("*.lproj/InfoPlist.strings"):
        rebrand_strings_file(strings)
    # The icon: app.icns is replaced, and CFBundleIconName goes so the AppIcon in
    # Assets.car (Chromium's) doesn't win over it, as for the app itself.
    shutil.copyfile(icns, resources / "app.icns")
    info_path = helper / "Contents/Info.plist"
    raw = info_path.read_bytes()
    fmt = plistlib.FMT_BINARY if raw.startswith(b"bplist") else plistlib.FMT_XML
    info = plistlib.loads(raw)
    info.pop("CFBundleIconName", None)
    info["CFBundleIconFile"] = "app.icns"
    info_path.write_bytes(plistlib.dumps(info, fmt=fmt))


def main(argv: list[str]) -> int:
    if len(argv) != 3:
        print("usage: rebrand-bundle.py <ReArc.app> <ReArc.icns>", file=sys.stderr)
        return 2
    app, icns = Path(argv[1]), Path(argv[2])
    if not icns.is_file():
        print(f"rebrand-bundle: no icon at {icns}", file=sys.stderr)
        return 1
    for strings in (app / "Contents/Resources").glob("*.lproj/InfoPlist.strings"):
        rebrand_strings_file(strings)
    for name in ALERT_HELPERS:
        helper = app / HELPERS / name
        if not helper.is_dir():
            print(f"rebrand-bundle: missing {helper}", file=sys.stderr)
            return 1
        rebrand_alert_helper(helper, icns)
        print(helper)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
