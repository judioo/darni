#!/usr/bin/env python3
"""What every check_abi<minor>_imports.py checks about a header change, in one place.

A new ABI minor may add functions. It must not change the layout of a struct an older host
reads, must not drop an export, and its Swift adoption must typecheck against the header.
check_abi163, 166 and 168 each spell this out; from 1.69 on a check calls `check` with its
numbers and its Swift.

REARC_TEST_ABI_HEADER_DIR names a directory with the patched headers and module map when the
patch is not applied to the checkout yet (run_c_abi.BRIDGE)."""
from pathlib import Path
import re
import subprocess
import tempfile

from run_c_abi import BRIDGE, SRC

HEADERS = ("rearc_engine_abi.h", "rearc_engine_entry_mac.h", "module.modulemap")


def structs(header):
    return re.findall(r"typedef struct (\w+)\s*\{", header)


def exports(header):
    return set(re.findall(r"REARC_ENGINE_EXPORT\s+[\w* ]+\s+(ReArc\w+)\(", header))


def callback_types(header):
    return set(re.findall(r"typedef \w[\w* ]*\(\*(ReArc\w+)\)", header))


def check(*, base_commit, base_minor, minor, added, swift, adds_types=False):
    """`base_commit`: the overlay commit of ABI 1.<base_minor> in the checkout. `added`: the
    functions 1.<minor> adds, all of them. `swift`: gated adoption to typecheck. `adds_types`:
    the minor may add structs and callback types (a call a host reaches by symbol lookup and
    JSON must not)."""
    root = Path(tempfile.mkdtemp(prefix=f"rearc-abi1{minor}-import-"))
    old = root / f"abi-1.{base_minor}"
    old.mkdir()
    for name in HEADERS:
        (old / name).write_bytes(subprocess.check_output(
            ["git", "-C", str(SRC), "show", f"{base_commit}:chrome/browser/rearc_bridge/{name}"]))
    old_header = (old / "rearc_engine_abi.h").read_text()
    header = (BRIDGE / "rearc_engine_abi.h").read_text()

    types = structs(old_header)
    program = root / "layout.c"
    program.write_text('#include "rearc_engine_abi.h"\n#include <stdio.h>\nint main(void){\n'
                       + "".join(f'printf("{t} %zu %zu\\n",sizeof({t}),_Alignof({t}));\n' for t in types) + "}\n")
    layouts = []
    for name, include in (("old", old), ("new", BRIDGE)):
        exe = root / name
        subprocess.run(["xcrun", "clang", "-std=c11", f"-I{include}", str(program), "-o", str(exe)], check=True)
        layouts.append(subprocess.check_output([str(exe)]))
    assert layouts[0] == layouts[1], layouts
    print(f"ABI 1.{base_minor} layouts preserved PASS: {len(types)} structs")

    assert f"REARC_ABI_MINOR_VERSION = {minor}" in header
    for name in added:
        assert re.search(r"REARC_ENGINE_EXPORT\s+[\w* ]+\s+" + name + r"\(", header), name
        assert name not in old_header, name
    assert exports(header) - exports(old_header) == set(added), exports(header) - exports(old_header)
    assert not exports(old_header) - exports(header), exports(old_header) - exports(header)
    if not adds_types:
        assert set(structs(header)) == set(types), set(structs(header)) ^ set(types)
        assert callback_types(header) == callback_types(old_header)
    print(f"ABI 1.{minor} header: minor {minor}, {len(added)} function(s) added, none removed"
          + ("" if adds_types else ", no struct or callback type added") + " PASS")

    source = root / "adoption.swift"
    source.write_text(swift)
    subprocess.run(["xcrun", "swiftc", "-typecheck", f"-I{BRIDGE}", str(source)], check=True)
    print(f"Swift gated ABI 1.{minor} adoption PASS")
