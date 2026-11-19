"""The rename from ReArc to Darni, as Sparkle 2.10.1 sees it. No app runs and no network.

An installed copy is /Applications/ReArc.app. From build 1054 the update holds Darni.app with
the same bundle id. Two things must hold for every installed copy to follow:

1. Sparkle finds the new app inside the extracted update. Ported from Sparkle 2.10.1,
   Autoupdate/SUInstaller.m, +installSourcePathInUpdateFolder:forHost:isPackage:isGuided:
   it walks the update folder and takes the first entry whose file name is the host's file
   name, or the host's name (CFBundleDisplayName, else CFBundleName; Sparkle/SUHost.m -name)
   plus the host's extension, or else whose bundle id is the host's. Symbolic links are
   skipped. It then installs at the host's own path (SPARKLE_NORMALIZE_INSTALLED_APPLICATION_NAME
   is off in Sparkle's releases), so an updated copy keeps the file name ReArc.app.
2. The feed and the deltas come out right from a folder that holds archives of both names.
   This part runs Sparkle's own generate_appcast and BinaryDelta (the pinned 2.10.1 tools in
   .build-chromium/artifacts, or REARC_SPARKLE_TOOLS) on two tiny bundles with a throwaway
   key, and is skipped when the tools or OpenSSL 3 are not there. A delta is applied the way
   Autoupdate/SUBinaryDeltaUnarchiver.m does it: onto the host, into a folder named after the
   host's file name.

The live check (a 1027 copy updating itself from a feed on 127.0.0.1) launches the app and
is scripts/release/check-rename-update.sh.
"""
import base64
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import unittest
import xml.etree.ElementTree as ET

SHELL = Path(__file__).resolve().parents[3]
TOOLS = Path(os.environ.get("REARC_SPARKLE_TOOLS") or SHELL / ".build-chromium/artifacts/sparkle/Sparkle/bin")
BUNDLE_ID = "com.rearc.browser"
SPARKLE = "http://www.andymatuschak.org/xml-namespaces/sparkle"


def bundle_identifier(path):
    """NSBundle's identifier for a path: a directory with an Info.plist that names one."""
    for info in (path / "Contents/Info.plist", path / "Info.plist"):
        if info.is_file():
            try:
                return plistlib.loads(info.read_bytes()).get("CFBundleIdentifier")
            except Exception:
                return None
    return None


def find_app(update_folder, host_file_name, host_name, host_bundle_id):
    """SUInstaller.m, installSourcePathInUpdateFolder: the path Sparkle would install, or None."""
    alternate = host_name + Path(host_file_name).suffix
    for root, dirs, files in os.walk(update_folder):
        dirs.sort()
        for name in sorted(dirs + files):
            path = Path(root) / name
            if path.is_symlink():
                # "Ignore all symbolic links and aliases"; the enumerator does not descend either.
                if name in dirs:
                    dirs.remove(name)
                continue
            if name == host_file_name or name == alternate:
                return path
            if path.is_dir() and bundle_identifier(path) == host_bundle_id:
                return path
    return None


def make_app(path, name, build, display, bundle_id=BUNDLE_ID, public_key=None, payload="page"):
    (path / "Contents/MacOS").mkdir(parents=True)
    (path / "Contents/Resources").mkdir()
    info = {"CFBundleIdentifier": bundle_id, "CFBundleName": name, "CFBundleDisplayName": name,
            "CFBundleExecutable": "ReArc", "CFBundlePackageType": "APPL", "CFBundleVersion": str(build),
            "CFBundleShortVersionString": display, "LSMinimumSystemVersion": "14.0.0",
            "SUFeedURL": "https://rearc.imara.ae/updates/appcast.xml"}
    if public_key:
        info["SUPublicEDKey"] = public_key
    (path / "Contents/Info.plist").write_bytes(plistlib.dumps(info))
    executable = path / "Contents/MacOS/ReArc"
    executable.write_text(f"#!/bin/sh\necho {build}\n")
    executable.chmod(0o755)
    (path / "Contents/Resources/shared.txt").write_text("the same in every build\n" * 200)
    (path / "Contents/Resources/changed.txt").write_text(f"{payload} of build {build}\n" * 200)
    return path


class FindingTheAppTests(unittest.TestCase):
    """Part 1: the lookup, on the layouts a DMG and a delta leave in the update folder."""

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="rearc-sparkle-rename-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)

    def dmg_folder(self, app_name, name, bundle_id=BUNDLE_ID):
        """What make-dmg.sh puts on the volume: the app, the Applications link and Finder's files."""
        folder = self.root / f"update-{app_name}-{bundle_id}"
        make_app(folder / app_name, name, 1060, "2026.1120.1060", bundle_id)
        (folder / " ").symlink_to("/Applications")
        (folder / ".background").mkdir()
        (folder / ".background/background.tiff").write_bytes(b"tiff")
        (folder / ".DS_Store").write_bytes(b"store")
        (folder / ".VolumeIcon.icns").write_bytes(b"icns")
        return folder

    def test_a_rearc_install_finds_darni_by_its_bundle_id(self):
        # Builds up to 1053: ReArc.app on disk, named ReArc. The bridge DMG holds Darni.app.
        folder = self.dmg_folder("Darni.app", "Darni")
        found = find_app(folder, "ReArc.app", "ReArc", BUNDLE_ID)
        self.assertEqual(found, folder / "Darni.app", "no name matches, the bundle id does")

    def test_an_updated_install_finds_the_next_darni_by_its_name(self):
        # After the bridge: still ReArc.app on disk, but its CFBundleName is Darni.
        folder = self.dmg_folder("Darni.app", "Darni")
        self.assertEqual(find_app(folder, "ReArc.app", "Darni", BUNDLE_ID), folder / "Darni.app")
        # Even if a later build's id lookup were lost, the name alone finds it.
        self.assertEqual(find_app(folder, "ReArc.app", "Darni", "another.id"), folder / "Darni.app")

    def test_a_new_download_finds_the_next_darni_by_its_file_name(self):
        folder = self.dmg_folder("Darni.app", "Darni")
        self.assertEqual(find_app(folder, "Darni.app", "Darni", BUNDLE_ID), folder / "Darni.app")

    def test_a_copy_the_person_renamed_is_found_too(self):
        folder = self.dmg_folder("Darni.app", "Darni")
        self.assertEqual(find_app(folder, "My Browser.app", "Darni", BUNDLE_ID), folder / "Darni.app")
        self.assertEqual(find_app(folder, "My Browser.app", "ReArc", BUNDLE_ID), folder / "Darni.app")

    def test_a_delta_is_extracted_under_the_hosts_own_name(self):
        # SUBinaryDeltaUnarchiver: target = extraction directory + the host bundle's file name.
        folder = self.root / "delta"
        make_app(folder / "ReArc.app", "Darni", 1060, "2026.1120.1060")
        self.assertEqual(find_app(folder, "ReArc.app", "ReArc", BUNDLE_ID), folder / "ReArc.app")

    def test_a_new_name_with_a_new_bundle_id_is_never_found(self):
        """Why the bundle id stays: a ReArc install would refuse this update, for good."""
        folder = self.dmg_folder("Darni.app", "Darni", bundle_id="ae.imara.darni")
        self.assertIsNone(find_app(folder, "ReArc.app", "ReArc", BUNDLE_ID))

    def test_the_applications_link_is_not_searched(self):
        folder = self.dmg_folder("Darni.app", "Darni", bundle_id="ae.imara.darni")
        # /Applications may well hold a ReArc.app; the link to it must not count as the update.
        self.assertIsNone(find_app(folder, "ReArc.app", "ReArc", BUNDLE_ID))
        self.assertTrue((folder / " ").is_symlink())

    def test_the_helpers_are_not_mistaken_for_the_app(self):
        folder = self.dmg_folder("Darni.app", "Darni")
        helper = folder / "Darni.app/Contents/Frameworks/Chromium Helper.app"
        make_app(helper, "Darni Helper", 1060, "156.0", bundle_id=BUNDLE_ID + ".helper")
        self.assertEqual(find_app(folder, "ReArc.app", "ReArc", BUNDLE_ID), folder / "Darni.app")


def openssl():
    for candidate in (os.environ.get("REARC_OPENSSL"), "/opt/homebrew/bin/openssl", "/usr/local/bin/openssl", shutil.which("openssl")):
        if candidate and os.access(candidate, os.X_OK):
            version = subprocess.run([candidate, "version"], capture_output=True, text=True).stdout
            if version.startswith("OpenSSL ") and int(version.split()[1].split(".")[0]) >= 3:
                return candidate
    return None


@unittest.skipUnless((TOOLS / "generate_appcast").is_file() and (TOOLS / "BinaryDelta").is_file(), f"no Sparkle tools in {TOOLS}")
@unittest.skipUnless(openssl(), "needs OpenSSL 3 or later for a throwaway Ed25519 key")
class SparkleToolsTests(unittest.TestCase):
    """Part 2: Sparkle's own tools on archives of both names. A throwaway key, never the real one."""

    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory(prefix="rearc-sparkle-rename-tools-")
        cls.addClassCleanup(cls.temp.cleanup)
        cls.root = Path(cls.temp.name)
        ssl = openssl()
        der = subprocess.run([ssl, "genpkey", "-algorithm", "ed25519", "-outform", "DER"], capture_output=True, check=True).stdout
        public = subprocess.run([ssl, "pkey", "-inform", "DER", "-pubout", "-outform", "DER"], input=der, capture_output=True, check=True).stdout
        # The 32-byte seed and the 32-byte public key are the last bytes of each DER form.
        cls.key_file = cls.root / "throwaway-ed25519.key"
        cls.key_file.write_text(base64.b64encode(der[-32:]).decode())
        cls.public_key = base64.b64encode(public[-32:]).decode()
        cls.apps = cls.root / "apps"
        cls.archives = cls.root / "archives"
        cls.archives.mkdir()
        cls.old = make_app(cls.apps / "1053/ReArc.app", "ReArc", 1053, "2026.1119.1053", public_key=cls.public_key)
        cls.bridge = make_app(cls.apps / "1060/Darni.app", "Darni", 1060, "2026.1120.1060", public_key=cls.public_key)
        # As in production: the feed exists, made when every archive was a ReArc.app.
        cls.zip(cls.old, "ReArc-2026.1119.1053.zip")
        cls.before = cls.generate()
        cls.title_before = ET.fromstring((cls.archives / "appcast.xml").read_text(encoding="utf-8")).find("channel").findtext("title")
        cls.zip(cls.bridge, "Darni-2026.1120.1060.zip")
        cls.first = cls.generate()

    @classmethod
    def zip(cls, app, name):
        subprocess.run(["ditto", "-c", "-k", "--keepParent", str(app), str(cls.archives / name)], check=True)

    @classmethod
    def generate(cls):
        return subprocess.run([str(TOOLS / "generate_appcast"), "--ed-key-file", str(cls.key_file),
                               "--download-url-prefix", "https://rearc.imara.ae/updates/", str(cls.archives)],
                              capture_output=True, text=True, timeout=300)

    def feed(self):
        return ET.fromstring((self.archives / "appcast.xml").read_text(encoding="utf-8"))

    def item(self, build):
        for item in self.feed().iter("item"):
            if item.findtext(f"{{{SPARKLE}}}version") == str(build):
                return item
        self.fail(f"no item for build {build}")

    def apply(self, host, delta, name):
        """As SUBinaryDeltaUnarchiver: the result is named after the host."""
        out = self.root / name / host.name
        out.parent.mkdir()
        result = subprocess.run([str(TOOLS / "BinaryDelta"), "apply", str(host), str(out), str(delta)], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return out

    def assert_same_tree(self, a, b):
        result = subprocess.run(["diff", "-r", str(a), str(b)], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stdout[:2000])

    def test_one_feed_holds_both_names(self):
        self.assertEqual(self.before.returncode, 0, self.before.stdout + self.before.stderr)
        self.assertEqual(self.first.returncode, 0, self.first.stdout + self.first.stderr)
        self.assertEqual(self.title_before, "ReArc")
        self.assertEqual(self.item(1053).find("enclosure").get("url"), "https://rearc.imara.ae/updates/ReArc-2026.1119.1053.zip")
        self.assertEqual(self.item(1060).find("enclosure").get("url"), "https://rearc.imara.ae/updates/Darni-2026.1120.1060.zip")
        self.assertEqual(self.item(1060).findtext("title"), "2026.1120.1060", "an item's title is its version, with no name in it")
        self.assertEqual(self.item(1060).findtext(f"{{{SPARKLE}}}shortVersionString"), "2026.1120.1060")

    def test_the_delta_is_named_after_the_new_apps_file_name(self):
        delta = self.archives / "Darni1060-1053.delta"
        self.assertTrue(delta.is_file(), sorted(p.name for p in self.archives.iterdir()))
        self.assertFalse((self.archives / "ReArc1060-1053.delta").exists())
        urls = [e.get("url") for e in self.item(1060).iter("enclosure")]
        self.assertIn("https://rearc.imara.ae/updates/Darni1060-1053.delta", urls)

    def test_the_delta_updates_a_rearc_install_in_place(self):
        delta = self.archives / "Darni1060-1053.delta"
        host = self.root / "Applications/ReArc.app"
        shutil.copytree(self.old, host, symlinks=True)
        updated = self.apply(host, delta, "extracted-rearc")
        self.assertEqual(updated.name, "ReArc.app", "the file name on disk stays")
        self.assert_same_tree(updated, self.bridge)
        info = plistlib.loads((updated / "Contents/Info.plist").read_bytes())
        self.assertEqual((info["CFBundleName"], info["CFBundleIdentifier"], info["CFBundleVersion"]), ("Darni", BUNDLE_ID, "1060"))
        self.assertEqual(find_app(updated.parent, "ReArc.app", "ReArc", BUNDLE_ID), updated)

    def test_the_delta_does_not_care_what_the_host_is_called(self):
        host = self.root / "Renamed/Darni.app"
        shutil.copytree(self.old, host, symlinks=True)
        self.assert_same_tree(self.apply(host, self.archives / "Darni1060-1053.delta", "extracted-renamed"), self.bridge)

    def test_the_update_after_the_bridge(self):
        """Darni to Darni: the next build's delta applies to ReArc.app and Darni.app on disk alike."""
        following = make_app(self.apps / "1070/Darni.app", "Darni", 1070, "2026.1121.1070", public_key=self.public_key, payload="later page")
        self.zip(following, "Darni-2026.1121.1070.zip")
        result = self.generate()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.feed().find("channel").findtext("title"), "ReArc",
                         "generate_appcast names a feed once, when it creates it; the channel title is never shown")
        for older in (1060, 1053):
            self.assertTrue((self.archives / f"Darni1070-{older}.delta").is_file(), f"a delta from {older}")
        self.assertTrue((self.archives / "Darni1060-1053.delta").is_file(), "the bridge's own delta stays for its item")
        for n, on_disk in enumerate(("ReArc.app", "Darni.app")):
            host = self.root / f"hop2-{n}" / on_disk
            shutil.copytree(self.bridge, host, symlinks=True)
            updated = self.apply(host, self.archives / "Darni1070-1060.delta", f"extracted-hop2-{n}")
            self.assertEqual(updated.name, on_disk)
            self.assert_same_tree(updated, following)
            self.assertEqual(find_app(updated.parent, on_disk, "Darni", BUNDLE_ID), updated)


if __name__ == "__main__":
    unittest.main()
