#!/usr/bin/env python3
"""Release gate: the bundle must read its Safe Storage key from "ReArc Safe Storage".

Saved passwords, cookies and cards are encrypted with the key in the Keychain item with
service "ReArc Safe Storage" and account "ReArc". The engine compiles both names in from
PRODUCT_SHORTNAME in the BRANDING file it was built with (engine patch chrome/002,
engine/docs/PACKAGING-MAC.md). ReArc was renamed Darni, and the item keeps its name: an
engine built to look for any other item finds none, makes a new key, and every existing
profile loses its sign-ins and saved passwords. Nothing migrates the old item.

Checks, all of which must hold:
  1. shell/scripts/release/BRANDING (the engine build's input, next to this script) says
     PRODUCT_SHORTNAME=ReArc.
  2. The engine binary in APP holds "ReArc Safe Storage", and every other "... Safe Storage"
     name in it is one Chromium uses for something else (OTHER_ITEMS).
  3. With --engine-out DIR: the header the engine build generated there names the service
     "ReArc Safe Storage" and the account "ReArc".

Usage: check-safe-storage-name.py APP [--engine-out DIR] [--branding FILE]
Reads files only: no Keychain access, no launch, no network.
"""
import argparse
import re
import sys
from pathlib import Path

SHORT_NAME = "ReArc"
SERVICE = f"{SHORT_NAME} Safe Storage"
# Other Keychain items Chromium names this way; they hold nothing of a profile's saved data.
OTHER_ITEMS = (b"Endpoint Verification Safe Storage",)
ENGINE = "Contents/Frameworks/Chromium Framework.framework/Versions/Current/Chromium Framework"
HEADER = "gen/components/os_crypt/common/keychain_branding.h"
SUFFIX = b" Safe Storage"
# The longest run of name characters before the suffix, read backwards from it.
NAME_BYTES = re.compile(rb"[A-Za-z0-9 ._-]*\Z")


class GateError(Exception):
    pass


def branding_short_name(path):
    try:
        text = Path(path).read_text(encoding="utf-8")
    except OSError as error:
        raise GateError(f"cannot read the BRANDING file {path}: {error}")
    names = re.findall(r"^PRODUCT_SHORTNAME=(.*)$", text, flags=re.MULTILINE)
    if len(names) != 1:
        raise GateError(f"{path} has {len(names)} PRODUCT_SHORTNAME lines, expected one")
    return names[0].strip()


def check_branding(path):
    name = branding_short_name(path)
    if name != SHORT_NAME:
        raise GateError(f"{path} says PRODUCT_SHORTNAME={name}: an engine built from it reads "
                        f"\"{name} Safe Storage\", not \"{SERVICE}\". Keep PRODUCT_SHORTNAME={SHORT_NAME}; "
                        "the name people see is set in bundle-chromium.sh and rebrand-bundle.py")


def storage_names(data):
    """Every "<name> Safe Storage" in the binary, as the bytes before the suffix name it."""
    found = set()
    at = data.find(SUFFIX)
    while at >= 0:
        before = NAME_BYTES.search(data, max(0, at - 64), at).group(0)
        found.add(before + SUFFIX)
        at = data.find(SUFFIX, at + 1)
    return found


def check_binary(path):
    try:
        data = Path(path).read_bytes()
    except OSError as error:
        raise GateError(f"cannot read the engine binary {path}: {error}")
    service = SERVICE.encode()
    names = storage_names(data)
    # A name can run on from the constant stored before it ("saltysalt" at this pin), so the
    # service is matched at the end of the run; the other items must match whole.
    ours = {name for name in names if name.endswith(service)}
    wrong = sorted(name.decode("ascii", "replace") for name in names - ours if name not in OTHER_ITEMS)
    if wrong:
        raise GateError(f"{path} names another Safe Storage item: {', '.join(repr(name) for name in wrong)}. "
                        f"Existing profiles are encrypted with the key in \"{SERVICE}\"; rebuild the engine "
                        f"with PRODUCT_SHORTNAME={SHORT_NAME}")
    if not ours:
        raise GateError(f"{path} does not hold \"{SERVICE}\": this engine would not read the key existing "
                        f"profiles are encrypted with (is it a component build, or built from another BRANDING?)")


def check_header(out):
    path = Path(out) / HEADER
    try:
        text = path.read_text(encoding="utf-8")
    except OSError as error:
        raise GateError(f"cannot read {path}: {error}")
    defines = dict(re.findall(r'^#define (OS_CRYPT_BRANDED_\w+) "([^"]*)"$', text, flags=re.MULTILINE))
    expected = {"OS_CRYPT_BRANDED_SERVICE_NAME": SERVICE, "OS_CRYPT_BRANDED_ACCOUNT_NAME": SHORT_NAME}
    if defines != expected:
        raise GateError(f"{path} defines {defines}, expected {expected}")


def main(argv):
    parser = argparse.ArgumentParser(description="The Safe Storage keychain item keeps its name")
    parser.add_argument("app")
    parser.add_argument("--engine-out")
    parser.add_argument("--branding", default=str(Path(__file__).resolve().with_name("BRANDING")))
    args = parser.parse_args(argv)
    try:
        check_branding(args.branding)
        check_binary(Path(args.app) / ENGINE)
        if args.engine_out:
            check_header(args.engine_out)
    except GateError as error:
        print(f"check-safe-storage-name: FAIL: {error}", file=sys.stderr)
        return 1
    checked = "BRANDING, the engine binary" + (" and the generated header" if args.engine_out else "")
    print(f"check-safe-storage-name: PASS: \"{SERVICE}\" / account \"{SHORT_NAME}\" ({checked})")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
