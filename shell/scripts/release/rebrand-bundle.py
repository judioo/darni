#!/usr/bin/env python3
"""Puts Darni's name and icon where the engine build leaves Chromium's or ReArc's in the app.

The engine keeps PRODUCT_FULLNAME=Chromium (patch chrome/002 keeps Chromium's bundle file
names), so Chromium's localized strings still name Chromium:

- The alerts helpers ("Chromium Helper (Alerts).app" and the Aperitif one) send web
  notifications. macOS names them by their localized CFBundleDisplayName, "Chromium", and
  shows their AppIcon, Chromium's. On first launch macOS shows a "Chromium Notifications"
  banner beside the app's, and Notification settings list a "Chromium" app (bug report,
  2026-11-17). Chrome sets that name to "Google Chrome", so the helper reads as the browser.
- The app's own <locale>.lproj/InfoPlist.strings override Info.plist's camera, microphone,
  location and Bluetooth reasons with "Once Chromium has access, ...".
- The app's name as Finder, the Dock and Spotlight show it: each app InfoPlist.strings gets
  CFBundleDisplayName = Darni, over the Info.plist's ReArc (bundle-chromium.sh says why).
- Every helper's CFBundleName is "ReArc Helper ...": the engine build writes it from
  PRODUCT_SHORTNAME, which stays ReArc because the Safe Storage Keychain item is named from
  it too (check-safe-storage-name.py). The name is display only (the helpers are found by
  their file names and bundle ids, which stay), so it is rewritten here to "Darni Helper ...".

Usage: rebrand-bundle.py <Darni.app> <ReArc.icns>. Runs before signing; it prints the
helper bundles it changed, one per line, so the caller can re-sign them.
"""
import plistlib
import re
import shutil
import sys
from pathlib import Path

NAME = "Darni"
# PRODUCT_SHORTNAME in scripts/release/BRANDING: what the engine build names the helpers with.
ENGINE_SHORT_NAME = "ReArc"
# The engine's name as its translations write it. Hindi spells it in Devanagari; the other
# translations keep the Latin word (the 57 locales of the 156.0.8078.100 engine; the en_XA
# test locale accents it and is left).
ENGINE_NAMES = ("Chromium", "क्रोमियम")
HELPERS = "Contents/Frameworks/Chromium Framework.framework/Versions/Current/Helpers"
ALERT_HELPERS = ("Chromium Helper (Alerts).app", "Chromium Helper (Aperitif Alerts).app")
# Only the strings people read as the app's name; "The Chromium Authors" in the copyright
# and the "Chromium Shortcut" file type stay as they are.
NAMED_KEY = re.compile(r"^(CFBundleDisplayName|CFBundleName|NS\w+UsageDescription)$")
LINE = re.compile(r'^(\s*"?([A-Za-z0-9_ ]+?)"?\s*=\s*")(.*)(";\s*)$')


def renamed(value: str) -> str:
    for name in ENGINE_NAMES:
        value = value.replace(name, NAME)
    return value


def rebrand_strings_text(text: str) -> str:
    """Old-style .strings text: replaces Chromium with the app's name in the named keys' values."""
    out = []
    for line in text.splitlines(keepends=True):
        m = LINE.match(line)
        if m and NAMED_KEY.match(m.group(2)):
            line = m.group(1) + renamed(m.group(3)) + m.group(4)
        out.append(line)
    return "".join(out)


def plist_format(raw: bytes):
    """The form a property list file is in, to write it back the same."""
    return plistlib.FMT_BINARY if raw.startswith(b"bplist") else plistlib.FMT_XML


def edit_strings_file(path: Path, edit_plist, edit_text) -> bool:
    """Rewrites an InfoPlist.strings in the form it has; True when it changed.

    The engine writes these files in more than one form, so every change to one is given
    twice: `edit_plist` changes the dictionary of a binary or XML property list in place,
    and `edit_text` returns the new text of an old-style .strings file (UTF-8 or UTF-16).
    The one place that reads, tells the forms apart and writes."""
    raw = path.read_bytes()
    if raw.startswith(b"bplist") or raw.lstrip().startswith(b"<?xml"):
        data = plistlib.loads(raw)
        before = dict(data)
        edit_plist(data)
        if data == before:
            return False
        path.write_bytes(plistlib.dumps(data, fmt=plist_format(raw)))
        return True
    encoding = "utf-16" if raw[:2] in (b"\xff\xfe", b"\xfe\xff") else "utf-8"
    text = raw.decode(encoding)
    new = edit_text(text)
    if new == text:
        return False
    path.write_bytes(new.encode(encoding))
    return True


def rebrand_plist(data: dict) -> None:
    for key, value in data.items():
        if NAMED_KEY.match(key) and isinstance(value, str):
            data[key] = renamed(value)


def rebrand_strings_file(path: Path) -> bool:
    return edit_strings_file(path, rebrand_plist, rebrand_strings_text)


def set_display_name_text(text: str) -> str:
    """Old-style .strings text with the one line CFBundleDisplayName = Darni, at its end."""
    lines = [line for line in text.splitlines(keepends=True)
             if not ((m := LINE.match(line)) and m.group(2) == "CFBundleDisplayName")]
    new = "".join(lines)
    if new and not new.endswith("\n"):
        new += "\n"
    return new + f'"CFBundleDisplayName" = "{NAME}";\n'


def set_display_name(path: Path) -> bool:
    """The app's localized CFBundleDisplayName is Darni in this locale (bundle-chromium.sh: the
    Info.plist's own is ReArc, the file name of every updated copy, so macOS shows this one)."""
    return edit_strings_file(path, lambda data: data.update(CFBundleDisplayName=NAME), set_display_name_text)


def rebrand_alert_helper(helper: Path, icns: Path) -> None:
    resources = helper / "Contents/Resources"
    for strings in resources.glob("*.lproj/InfoPlist.strings"):
        rebrand_strings_file(strings)
    # The icon: app.icns is replaced, and CFBundleIconName goes so the AppIcon in
    # Assets.car (Chromium's) doesn't win over it, as for the app itself.
    shutil.copyfile(icns, resources / "app.icns")
    info_path = helper / "Contents/Info.plist"
    raw = info_path.read_bytes()
    info = plistlib.loads(raw)
    info.pop("CFBundleIconName", None)
    info["CFBundleIconFile"] = "app.icns"
    info_path.write_bytes(plistlib.dumps(info, fmt=plist_format(raw)))


def rename_helper(helper: Path) -> bool:
    """CFBundleName "ReArc Helper (GPU)" becomes "Darni Helper (GPU)"; nothing else changes."""
    info_path = helper / "Contents/Info.plist"
    raw = info_path.read_bytes()
    info = plistlib.loads(raw)
    name = info.get("CFBundleName")
    if not isinstance(name, str) or not name.startswith(ENGINE_SHORT_NAME + " "):
        return False
    info["CFBundleName"] = NAME + name[len(ENGINE_SHORT_NAME):]
    info_path.write_bytes(plistlib.dumps(info, fmt=plist_format(raw)))
    return True


def main(argv: list[str]) -> int:
    if len(argv) != 3:
        print("usage: rebrand-bundle.py <Darni.app> <ReArc.icns>", file=sys.stderr)
        return 2
    app, icns = Path(argv[1]), Path(argv[2])
    if not icns.is_file():
        print(f"rebrand-bundle: no icon at {icns}", file=sys.stderr)
        return 1
    app_strings = sorted((app / "Contents/Resources").glob("*.lproj/InfoPlist.strings"))
    if not app_strings:
        print(f"rebrand-bundle: no <locale>.lproj/InfoPlist.strings in {app}: macOS would show ReArc",
              file=sys.stderr)
        return 1
    for strings in app_strings:
        rebrand_strings_file(strings)
        set_display_name(strings)
    for name in ALERT_HELPERS:
        helper = app / HELPERS / name
        if not helper.is_dir():
            print(f"rebrand-bundle: missing {helper}", file=sys.stderr)
            return 1
        rebrand_alert_helper(helper, icns)
    changed = {app / HELPERS / name for name in ALERT_HELPERS}
    for helper in sorted((app / HELPERS).glob("*.app")):
        if rename_helper(helper):
            changed.add(helper)
    for helper in sorted(changed):
        print(helper)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
