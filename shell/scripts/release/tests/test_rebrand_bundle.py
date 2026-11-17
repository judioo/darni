"""rebrand-bundle.py on a fake ReArc.app: the alerts helpers macOS shows as the notifying app
say ReArc and carry ReArc's icon, and the permission reasons name ReArc. No app, no signing."""
import plistlib
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

RELEASE = Path(__file__).resolve().parents[1]
SCRIPT = RELEASE / "rebrand-bundle.py"
HELPERS = "Contents/Frameworks/Chromium Framework.framework/Versions/Current/Helpers"
ALERTS = ("Chromium Helper (Alerts).app", "Chromium Helper (Aperitif Alerts).app")

APP_STRINGS = (
    '"Chromium Shortcut" = "Chromium のショートカット";\n'
    'CFBundleGetInfoString = "Chromium 156.0.8078.100, Copyright 2026 The Chromium Authors.";\n'
    'NSCameraUsageDescription = "Chromium にアクセスを許可すると、ウェブサイトからアクセスをリクエストできるようになります。";\n'
    'NSHumanReadableCopyright = "Copyright 2026 The Chromium Authors. All rights reserved.";\n'
)
# Hindi spells the engine's name out (the 156.0.8078.100 engine's hi.lproj).
HINDI_STRINGS = (
    '"Chromium Shortcut" = "Chromium का शॉर्टकट";\n'
    'NSCameraUsageDescription = "क्रोमियम को ऐक्सेस मिलने के बाद, वेबसाइटें आपसे ऐक्सेस मांग सकेंगी.";\n'
)


class RebrandBundleTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        root = Path(self.tmp.name)
        self.app = root / "ReArc.app"
        self.icns = root / "ReArc.icns"
        self.icns.write_bytes(b"rearc-icon")
        ja = self.app / "Contents/Resources/ja.lproj"
        ja.mkdir(parents=True)
        (ja / "InfoPlist.strings").write_text(APP_STRINGS, encoding="utf-8")
        hi = self.app / "Contents/Resources/hi.lproj"
        hi.mkdir()
        (hi / "InfoPlist.strings").write_text(HINDI_STRINGS, encoding="utf-8")
        for name in ALERTS:
            res = self.app / HELPERS / name / "Contents/Resources"
            (res / "base.lproj").mkdir(parents=True)
            (res / "base.lproj/InfoPlist.strings").write_bytes(
                plistlib.dumps({"CFBundleDisplayName": "Chromium"}, fmt=plistlib.FMT_BINARY))
            (res / "app.icns").write_bytes(b"chromium-icon")
            (self.app / HELPERS / name / "Contents/Info.plist").write_bytes(plistlib.dumps({
                "CFBundleIdentifier": "com.rearc.browser.framework.AlertNotificationService",
                "CFBundleIconFile": "app.icns", "CFBundleIconName": "AppIcon",
            }))

    def tearDown(self):
        self.tmp.cleanup()

    def run_script(self, *args):
        return subprocess.run([sys.executable, "-I", str(SCRIPT), *args],
                              capture_output=True, text=True)

    def test_alert_helpers_say_rearc_with_rearc_icon(self):
        result = self.run_script(str(self.app), str(self.icns))
        self.assertEqual(result.returncode, 0, result.stderr)
        printed = result.stdout.splitlines()
        for name in ALERTS:
            helper = self.app / HELPERS / name
            self.assertIn(str(helper), printed, "the caller re-signs every changed helper")
            strings = plistlib.loads((helper / "Contents/Resources/base.lproj/InfoPlist.strings").read_bytes())
            self.assertEqual(strings["CFBundleDisplayName"], "ReArc")
            self.assertEqual((helper / "Contents/Resources/app.icns").read_bytes(), b"rearc-icon")
            info = plistlib.loads((helper / "Contents/Info.plist").read_bytes())
            self.assertNotIn("CFBundleIconName", info, "Assets.car's Chromium AppIcon would win")

    def test_permission_reasons_name_rearc_and_the_rest_stays(self):
        self.assertEqual(self.run_script(str(self.app), str(self.icns)).returncode, 0)
        text = (self.app / "Contents/Resources/ja.lproj/InfoPlist.strings").read_text(encoding="utf-8")
        self.assertIn('NSCameraUsageDescription = "ReArc にアクセスを許可すると', text)
        self.assertIn('"Chromium Shortcut" = "Chromium のショートカット";', text)
        self.assertIn("Copyright 2026 The Chromium Authors. All rights reserved.", text)
        self.assertIn('CFBundleGetInfoString = "Chromium 156', text)

    def test_a_translated_engine_name_becomes_rearc_too(self):
        self.assertEqual(self.run_script(str(self.app), str(self.icns)).returncode, 0)
        text = (self.app / "Contents/Resources/hi.lproj/InfoPlist.strings").read_text(encoding="utf-8")
        self.assertIn('NSCameraUsageDescription = "ReArc को ऐक्सेस मिलने के बाद', text)
        self.assertIn('"Chromium Shortcut" = "Chromium का शॉर्टकट";', text)

    def test_a_missing_helper_fails(self):
        shutil.rmtree(self.app / HELPERS / ALERTS[0])
        result = self.run_script(str(self.app), str(self.icns))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("missing", result.stderr)


if __name__ == "__main__":
    unittest.main()
