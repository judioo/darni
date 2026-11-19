"""check-rename.sh on fake bundles: the names people see are Darni and every identifier an
installed copy depends on is unchanged. No app runs, no Keychain."""
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest

RELEASE = Path(__file__).resolve().parents[1]
SCRIPT = RELEASE / "check-rename.sh"
KEY = (RELEASE / "sparkle-public-key.txt").read_text().strip()
FRAMEWORK = "Contents/Frameworks/Chromium Framework.framework/Versions/Current"
HELPERS = {
    "Chromium Helper.app": "com.rearc.browser.helper",
    "Chromium Helper (Renderer).app": "com.rearc.browser.helper.renderer",
    "Chromium Helper (Alerts).app": "com.rearc.browser.framework.AlertNotificationService",
}
INFO = {
    "CFBundleName": "Darni", "CFBundleDisplayName": "Darni", "CFBundleIdentifier": "com.rearc.browser",
    "CFBundleExecutable": "ReArc", "ReArcRelease": True, "SUPublicEDKey": KEY,
    "SUFeedURL": "https://rearc.imara.ae/updates/appcast.xml", "ReArcICloudContainer": "iCloud.com.rearc.browser",
}
EXECUTABLE = b"\xcf\xfa\xed\xfe\x00https://rearc.imara.ae/blocklists/latest.json\x00"
ENGINE = b"\xcf\xfa\xed\xfe\x00saltysaltReArc Safe Storage\x00ReArc\x00"


class CheckRenameTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="rearc-rename-test-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)

    def app(self, name="Darni.app", info=None, executable=EXECUTABLE, engine=ENGINE, helpers=None, framework_id="com.rearc.browser.framework"):
        app = self.root / name
        (app / "Contents/MacOS").mkdir(parents=True)
        (app / "Contents/Info.plist").write_bytes(plistlib.dumps({**INFO, **(info or {})}))
        exe = app / "Contents/MacOS/ReArc"
        exe.write_bytes(executable)
        exe.chmod(0o755)
        version = app / "Contents/Frameworks/Chromium Framework.framework/Versions/156.0"
        (version / "Resources").mkdir(parents=True)
        (version.parent / "Current").symlink_to("156.0")
        (version / "Chromium Framework").write_bytes(engine)
        (version / "Resources/Info.plist").write_bytes(plistlib.dumps({"CFBundleIdentifier": framework_id}))
        for helper, identifier in (HELPERS if helpers is None else helpers).items():
            (version / "Helpers" / helper / "Contents").mkdir(parents=True)
            (version / "Helpers" / helper / "Contents/Info.plist").write_bytes(plistlib.dumps({"CFBundleIdentifier": identifier}))
        return app

    def run_gate(self, app, *args):
        return subprocess.run(["bash", SCRIPT, str(app), *args], capture_output=True, text=True, timeout=60)

    def test_the_bridge_bundle_passes(self):
        result = self.run_gate(self.app())
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("check-rename: PASS", result.stdout)
        self.assertIn('"ReArc Safe Storage"', result.stdout)

    def test_each_identifier_is_checked(self):
        cases = {
            "the old visible name": (dict(name="ReArc.app"), "expected Darni.app"),
            "CFBundleName": (dict(info={"CFBundleName": "ReArc"}), "CFBundleName is 'ReArc'"),
            "CFBundleDisplayName": (dict(info={"CFBundleDisplayName": "ReArc"}), "CFBundleDisplayName is 'ReArc'"),
            "a new bundle id": (dict(info={"CFBundleIdentifier": "ae.imara.darni"}), "CFBundleIdentifier is 'ae.imara.darni'"),
            "a new executable": (dict(info={"CFBundleExecutable": "Darni"}), "CFBundleExecutable is 'Darni'"),
            "another feed": (dict(info={"SUFeedURL": "https://darni.example/appcast.xml"}), "SUFeedURL"),
            "another update key": (dict(info={"SUPublicEDKey": "AAAA"}), "SUPublicEDKey"),
            "another iCloud container": (dict(info={"ReArcICloudContainer": "iCloud.ae.imara.darni"}), "ReArcICloudContainer"),
            "another blocklists URL": (dict(executable=b"https://darni.example/blocklists/latest.json"), "blocklists/latest.json"),
            "another Safe Storage item": (dict(engine=ENGINE.replace(b"ReArc", b"Darni")), "Darni Safe Storage"),
            "a helper id": (dict(helpers={"Chromium Helper.app": "ae.imara.darni.helper"}), "ae.imara.darni.helper"),
            "the framework id": (dict(framework_id="ae.imara.darni.framework"), "ae.imara.darni.framework"),
            "no helpers": (dict(helpers={}), "no helper bundles"),
        }
        for n, (what, (changes, message)) in enumerate(cases.items()):
            with self.subTest(what):
                name = changes.pop("name", "Darni.app")
                self.root = Path(self.temp.name) / str(n)
                result = self.run_gate(self.app(name, **changes))
                self.assertEqual(result.returncode, 1, result.stdout)
                self.assertIn(message, result.stderr)

    def test_only_a_qa_bundle_may_carry_another_feed(self):
        app = self.app(info={"SUFeedURL": "http://127.0.0.1:8123/appcast.xml"})
        self.assertEqual(self.run_gate(app).returncode, 1)
        qa = self.run_gate(app, "--qa")
        self.assertEqual(qa.returncode, 0, qa.stderr)
        self.assertIn("never distribute", qa.stderr)

    def test_a_development_bundle_has_no_feed_or_container_to_check(self):
        info = {k: v for k, v in INFO.items() if k not in ("ReArcRelease", "SUFeedURL", "SUPublicEDKey", "ReArcICloudContainer")}
        app = self.app()
        (app / "Contents/Info.plist").write_bytes(plistlib.dumps(info))
        self.assertEqual(self.run_gate(app).returncode, 0)


if __name__ == "__main__":
    unittest.main()
