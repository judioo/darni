"""check-safe-storage-name.py on fake bundles: the engine must read "ReArc Safe Storage", the
item existing profiles are encrypted with, whatever the app is called. No app, no Keychain."""
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / "check-safe-storage-name.py"
ENGINE = "Contents/Frameworks/Chromium Framework.framework/Versions/Current/Chromium Framework"
HEADER = "gen/components/os_crypt/common/keychain_branding.h"
# As the 156 engine stores them: the salt constant runs straight into the service name.
REAL = b"\x00peanuts\x00saltysaltReArc Safe Storage\x00ReArc\x00Endpoint Verification Safe Storage\x00"


class SafeStorageNameTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="rearc-safe-storage-test-")
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)

    def app(self, binary, name="Darni.app"):
        engine = self.root / name / ENGINE
        engine.parent.mkdir(parents=True, exist_ok=True)
        engine.write_bytes(b"\xcf\xfa\xed\xfe" + b"\x00" * 64 + binary + b"\x00" * 64)
        return engine.parents[5]

    def branding(self, short="ReArc"):
        path = self.root / "BRANDING"
        path.write_text(f"PRODUCT_FULLNAME=Chromium\nPRODUCT_SHORTNAME={short}\nMAC_BUNDLE_ID=com.rearc.browser\n")
        return path

    def out(self, service="ReArc Safe Storage", account="ReArc"):
        header = self.root / "out" / HEADER
        header.parent.mkdir(parents=True, exist_ok=True)
        header.write_text(f'#define OS_CRYPT_BRANDED_SERVICE_NAME "{service}"\n#define OS_CRYPT_BRANDED_ACCOUNT_NAME "{account}"\n')
        return self.root / "out"

    def run_gate(self, app, *extra, branding=None):
        return subprocess.run([sys.executable, "-I", str(SCRIPT), str(app), "--branding", str(branding or self.branding()), *extra],
                              capture_output=True, text=True)

    def test_a_darni_bundle_with_the_rearc_item_passes(self):
        for name in ("Darni.app", "ReArc.app"):
            result = self.run_gate(self.app(REAL, name), "--engine-out", self.out())
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn('PASS: "ReArc Safe Storage" / account "ReArc"', result.stdout)

    def test_an_engine_built_as_darni_fails(self):
        result = self.run_gate(self.app(REAL.replace(b"ReArc", b"Darni")))
        self.assertEqual(result.returncode, 1)
        self.assertIn("Darni Safe Storage", result.stderr)

    def test_other_names_fail(self):
        for binary in (REAL.replace(b"ReArc Safe", b"Chromium Safe"), REAL + b"Chrome Safe Storage\x00",
                       REAL + b"Darni Safe Storage\x00", b"\x00Endpoint Verification Safe Storage\x00", b"\x00nothing\x00"):
            with self.subTest(binary=binary[-40:]):
                result = self.run_gate(self.app(binary))
                self.assertEqual(result.returncode, 1, result.stdout)
                self.assertIn("FAIL", result.stderr)

    def test_the_branding_file_must_keep_the_short_name(self):
        result = self.run_gate(self.app(REAL), branding=self.branding("Darni"))
        self.assertEqual(result.returncode, 1)
        self.assertIn("PRODUCT_SHORTNAME=Darni", result.stderr)
        self.assertIn("Keep PRODUCT_SHORTNAME=ReArc", result.stderr)

    def test_the_generated_header_must_agree(self):
        app = self.app(REAL)
        for service, account in (("Darni Safe Storage", "Darni"), ("ReArc Safe Storage", "Darni")):
            result = self.run_gate(app, "--engine-out", self.out(service, account))
            self.assertEqual(result.returncode, 1)
            self.assertIn("keychain_branding.h", result.stderr)
        self.assertEqual(self.run_gate(app, "--engine-out", self.root / "missing").returncode, 1)

    def test_a_missing_engine_fails(self):
        (self.root / "Empty.app").mkdir()
        self.assertEqual(self.run_gate(self.root / "Empty.app").returncode, 1)

    def test_the_committed_branding_file(self):
        result = subprocess.run([sys.executable, "-I", str(SCRIPT), str(self.app(REAL))], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, "shell/scripts/release/BRANDING keeps PRODUCT_SHORTNAME=ReArc: " + result.stderr)


if __name__ == "__main__":
    unittest.main()
