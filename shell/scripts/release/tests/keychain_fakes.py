"""Fake bundles and fake `codesign` / `security` for the keychain access group tests. Nothing
here signs, reads a keychain, or starts an app: a "signature" is a property list in a folder.

    FakeSigning(root)          makes root/bin with the fake tools and root/signed for the store
    .env()                     an environment whose PATH finds the fakes first
    .app(name, build, ...)     a bundle directory with an Info.plist and a main executable
    .sign(path, entitlements)  records entitlements for a code object, as codesign would
    .profile(app, grants)      writes app/Contents/embedded.provisionprofile (a plain plist;
                               the fake `security cms -D -i` prints it)
"""
import os
import plistlib
from pathlib import Path

TEAM = "TEAM123456"
BUNDLE_ID = "com.rearc.browser"
OWN = f"{TEAM}.{BUNDLE_ID}"
WEBAUTHN = f"{OWN}.webauthn"

CODESIGN = r'''#!/usr/bin/env python3
"""Fake codesign: `--sign` stores the entitlements file for the path; `-d --entitlements`
prints what was stored; `-dvv` prints a team, a timestamp and the runtime flag; `--verify`
passes unless TEST_CODESIGN_VERIFY_FAILS names the path."""
import os, shutil, sys
store = os.environ["TEST_SIGNED"]
args = sys.argv[1:]
with open(os.environ["TEST_LOG"], "a") as log:
    log.write("codesign:" + " ".join(args) + "\n")
key = lambda path: os.path.join(store, os.path.realpath(path).strip("/").replace("/", "%"))
def lookup(path):
    path = os.path.realpath(path)
    if os.path.exists(key(path)):
        return key(path)
    marker = ".app/Contents/MacOS/"
    if marker in path and os.path.exists(key(path.split(marker)[0] + ".app")):
        return key(path.split(marker)[0] + ".app")
    return None
target = args[-1]
if "--verify" in args:
    sys.exit(1 if os.environ.get("TEST_CODESIGN_VERIFY_FAILS") == target else 0)
if "--sign" in args:
    if "--entitlements" in args:
        shutil.copyfile(args[args.index("--entitlements") + 1], key(target))
    else:
        open(key(target), "w").close()
    sys.exit(0)
if "--entitlements" in args:  # -d --entitlements - --xml PATH
    found = lookup(target)
    if found is None:
        sys.stderr.write(target + ": code object is not signed at all\n")
        sys.exit(1)
    sys.stdout.write(open(found).read())
    sys.exit(0)
if any(a.startswith("-d") for a in args):  # -dv, -dvv
    team = os.environ.get("TEST_TEAM_OF_" + os.path.basename(target).replace(".", "_").replace(" ", "_"), os.environ.get("TEST_TEAM", ""))
    sys.stderr.write("Executable=" + target + "\nTeamIdentifier=" + (team or "not set") + "\nTimestamp=now\nCodeDirectory v=20500 flags=0x10000(runtime)\n")
    sys.exit(0)
sys.exit(0)
'''

SECURITY = r'''#!/bin/bash
# Fake security: `cms -D -i FILE` prints FILE (the tests' profiles are plain plists);
# `find-identity` lists the test identity. Anything else fails, so no test reaches a keychain.
printf 'security:%s\n' "$*" >> "$TEST_LOG"
case "$1" in
  cms) [[ $2 == -D && $3 == -i && -f $4 ]] && cat "$4" ;;
  find-identity) echo "  1) 0000 \"$TEST_IDENTITY\"" ;;
  *) exit 1 ;;
esac
'''

QUIET = '#!/bin/bash\nprintf \'%s:%s\\n\' "$(basename "$0")" "$*" >> "$TEST_LOG"\n'

INFO = """<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>%s</string>
<key>CFBundleVersion</key><string>%s</string>
<key>SUFeedURL</key><string>https://example.invalid/updates/appcast.xml</string>
%s</dict></plist>
"""
RELEASE = "<key>ReArcRelease</key><true/>"
VERIFICATION = "<key>ReArcReleaseVerification</key><true/>"


class FakeSigning:
    def __init__(self, root):
        self.root = Path(root)
        self.bin = self.root / "bin"
        self.signed = self.root / "signed"
        self.log = self.root / "calls"
        for directory in (self.bin, self.signed, self.root / "tmp"):
            directory.mkdir(parents=True, exist_ok=True)
        self.log.touch()
        for name, text in (("codesign", CODESIGN), ("security", SECURITY), ("spctl", QUIET), ("xattr", QUIET), ("otool", QUIET)):
            (self.bin / name).write_text(text)
            (self.bin / name).chmod(0o755)

    def env(self, **extra):
        env = {key: value for key, value in os.environ.items()
               if not key.startswith(("REARC_", "TEST_"))}
        env.update(PATH=f"{self.bin}:{os.environ['PATH']}", TEST_SIGNED=str(self.signed), TEST_LOG=str(self.log),
                   TEST_TEAM=TEAM, TEST_IDENTITY=f"Developer ID Application: Test ({TEAM})", TMPDIR=str(self.root / "tmp"))
        env.update(extra)
        return env

    def app(self, name, build="1400", keys=RELEASE, bundle="Darni.app", bundle_id=BUNDLE_ID):
        app = self.root / name / bundle
        (app / "Contents/MacOS").mkdir(parents=True)
        (app / "Contents/MacOS/ReArc").write_text("#!/bin/bash\n")
        (app / "Contents/MacOS/ReArc").chmod(0o755)
        (app / "Contents/Info.plist").write_text(INFO % (bundle_id, build, keys))
        return app

    def helper(self, app, name="Chromium Helper.app"):
        helper = app / "Contents/Frameworks/Chromium Framework.framework/Versions/1.0/Helpers" / name
        (helper / "Contents/MacOS").mkdir(parents=True)
        (helper / "Contents/MacOS" / name[:-4]).write_text("#!/bin/bash\n")
        (helper / "Contents/MacOS" / name[:-4]).chmod(0o755)
        self.sign(helper, {})
        framework = app / "Contents/Frameworks/Chromium Framework.framework"
        if not (self.signed / os.path.realpath(framework).strip("/").replace("/", "%")).exists():
            self.sign(framework, {})
        return helper

    def sign(self, path, entitlements):
        target = self.signed / os.path.realpath(path).strip("/").replace("/", "%")
        if entitlements:
            target.write_bytes(plistlib.dumps(entitlements))
        else:
            target.write_text("")

    def signed_entitlements(self, path):
        target = self.signed / os.path.realpath(path).strip("/").replace("/", "%")
        data = target.read_bytes()
        return plistlib.loads(data) if data.strip() else {}

    def profile(self, app, grants):
        path = Path(app) / "Contents/embedded.provisionprofile"
        path.write_bytes(plistlib.dumps({"Entitlements": grants, "Name": "test"}))
        return path


def app_entitlements(groups=None, team=TEAM, **extra):
    """What a main executable is signed with: the team, the identifier, and the groups."""
    found = {"com.apple.developer.team-identifier": team, "com.apple.application-identifier": f"{team}.{BUNDLE_ID}",
             "com.apple.security.device.camera": True}
    if groups is not None:
        found["keychain-access-groups"] = list(groups)
    found.update(extra)
    return found


def profile_grants(groups=(f"{TEAM}.*",), **extra):
    grants = {"com.apple.application-identifier": OWN, "com.apple.developer.team-identifier": TEAM,
              "com.apple.developer.icloud-container-identifiers": ["iCloud.com.rearc.browser"],
              "com.apple.developer.icloud-services": "*",
              "com.apple.developer.icloud-container-environment": ["Production"],
              "keychain-access-groups": list(groups)}
    grants.update(extra)
    return grants
