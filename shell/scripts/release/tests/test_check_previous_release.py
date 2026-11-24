"""check-previous-release.py: the app a release is compared with is the build people have
(security advance read 2026-11-24, point 3). A local bundle whose signature verifies, the
newest build of the signed feed in the tree, and that feed the same as the live one when it
can be reached. Fake codesign, curl and feed verifier: no network, nothing signed."""
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parent))
from keychain_fakes import RELEASE, VERIFICATION, FakeSigning  # noqa: E402

SCRIPT = Path(__file__).resolve().parents[1] / "check-previous-release.py"
FEED = """<?xml version="1.0"?>
<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel>
<item><sparkle:version>%s</sparkle:version><enclosure url="https://example.invalid/a.dmg"/></item>
<item><sparkle:version>1329</sparkle:version><enclosure url="https://example.invalid/b.dmg"/></item>
<item><enclosure url="https://example.invalid/c.dmg" sparkle:version="1255"/></item>
</channel></rss>
"""
# Fake curl: copies TEST_LIVE_FEED to the -o target, or fails as an unreachable host does.
CURL = '''#!/bin/bash
printf 'curl:%s\\n' "$*" >> "$TEST_LOG"
[[ -n ${TEST_LIVE_FEED:-} ]] || exit 6
while [[ $# -gt 0 ]]; do [[ $1 == -o ]] && out="$2"; shift; done
cp "$TEST_LIVE_FEED" "$out"
'''


class PreviousReleaseTests(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory(prefix="rearc-previous-release-test-")
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name)
        self.fakes = FakeSigning(self.root)
        (self.fakes.bin / "curl").write_text(CURL)
        (self.fakes.bin / "curl").chmod(0o755)
        self.verifier = self.fakes.bin / "verify"
        self.verifier.write_text('#!/bin/bash\nprintf \'verify:%s\\n\' "$*" >> "$TEST_LOG"\n[[ -z ${TEST_FEED_UNSIGNED:-} ]] || { echo "the signature does not verify" >&2; exit 1; }\n')
        self.verifier.chmod(0o755)

    def feed(self, newest="1338", name="appcast.xml"):
        path = self.root / name
        path.write_text(FEED % newest)
        return path

    def run_check(self, app, *args, **env):
        return subprocess.run([sys.executable, "-I", str(SCRIPT), str(app), *map(str, args)], capture_output=True, text=True,
                              env=self.fakes.env(REARC_VERIFY_APPCAST=str(self.verifier), **env))

    def calls(self):
        return self.fakes.log.read_text()

    def test_the_newest_build_of_the_signed_feed_passes_and_the_live_feed_is_compared(self):
        feed = self.feed()
        result = self.run_check(self.fakes.app("old", "1338"), "--feed", feed, TEST_LIVE_FEED=str(feed))
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("build 1338 is the newest of the signed feed", result.stdout)
        self.assertIn("is the same", result.stdout)
        self.assertIn(f"verify:{feed}", self.calls(), "the feed's signature is checked")
        self.assertIn("codesign:--verify --deep /", self.calls(), "the app's signature is checked")
        self.assertIn("https://example.invalid/updates/appcast.xml", self.calls(), "the live address is the app's own SUFeedURL")

    def test_an_older_build_than_the_feeds_newest_fails(self):
        result = self.run_check(self.fakes.app("old", "1329"), "--feed", self.feed(), "--no-live")
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn("the newest build of", result.stderr)
        self.assertIn("is 1338, and --previous-app is build 1329", result.stderr)

    def test_a_newer_build_than_the_feeds_newest_fails_too(self):
        result = self.run_check(self.fakes.app("old", "1400"), "--feed", self.feed(), "--no-live")
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn("is 1338, and --previous-app is build 1400", result.stderr)

    def test_the_newest_is_the_highest_build_wherever_the_feed_puts_it(self):
        feed = self.root / "appcast.xml"
        feed.write_text(FEED.replace("1255", "1390") % "1338")
        result = self.run_check(self.fakes.app("old", "1390"), "--feed", feed, "--no-live")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_a_live_feed_that_differs_fails(self):
        feed, live = self.feed(), self.feed("1345", "live.xml")
        result = self.run_check(self.fakes.app("old", "1338"), "--feed", feed, TEST_LIVE_FEED=str(live))
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn("differs from", result.stderr)
        self.assertIn("live newest build: 1345", result.stderr)

    def test_a_live_feed_that_differs_by_one_byte_fails(self):
        feed = self.feed()
        live = self.root / "live.xml"
        live.write_text(feed.read_text() + "\n")
        result = self.run_check(self.fakes.app("old", "1338"), "--feed", feed, TEST_LIVE_FEED=str(live))
        self.assertEqual(result.returncode, 1, result.stdout)

    def test_an_unreachable_live_feed_is_a_note_and_not_an_error(self):
        result = self.run_check(self.fakes.app("old", "1338"), "--feed", self.feed())
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("could not be reached", result.stdout)
        self.assertIn("not an error", result.stdout)

    def test_no_live_fetches_nothing(self):
        result = self.run_check(self.fakes.app("old", "1338"), "--feed", self.feed(), "--no-live")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertNotIn("curl:", self.calls())

    def test_the_fetch_names_nobody(self):
        feed = self.feed()
        self.run_check(self.fakes.app("old", "1338"), "--feed", feed, TEST_LIVE_FEED=str(feed))
        curl = next(line for line in self.calls().splitlines() if line.startswith("curl:"))
        self.assertIn("-A darni-release-check", curl)
        for word in (os.environ.get("USER", "\0"), str(Path.home())):
            self.assertNotIn(word, curl.replace(str(self.root), "").replace(tempfile.gettempdir(), ""))

    def test_an_unsigned_feed_fails(self):
        result = self.run_check(self.fakes.app("old", "1338"), "--feed", self.feed(), "--no-live", TEST_FEED_UNSIGNED="1")
        self.assertEqual(result.returncode, 1)
        self.assertIn("is not a signed feed", result.stderr)

    def test_an_app_whose_signature_does_not_verify_fails(self):
        app = self.fakes.app("old", "1338")
        result = self.run_check(app, "--feed", self.feed(), "--no-live", TEST_CODESIGN_VERIFY_FAILS=str(app))
        self.assertEqual(result.returncode, 1)
        self.assertIn("does not verify", result.stderr)

    def test_with_a_team_the_signature_must_be_that_teams_developer_id(self):
        app = self.fakes.app("old", "1338")
        result = self.run_check(app, "--team", "TEAM123456", "--feed", self.feed(), "--no-live")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        verify = next(line for line in self.calls().splitlines() if line.startswith("codesign:--verify"))
        self.assertIn('certificate leaf[subject.OU] = "TEAM123456"', verify)
        self.assertIn("field.1.2.840.113635.100.6.1.13", verify, "Developer ID Application")
        self.assertNotIn("--strict", verify, "an installed app has Finder attributes, which --strict refuses")
        result = self.run_check(app, "--team", "TEAM123456", "--no-live", TEST_CODESIGN_VERIFY_FAILS=str(app))
        self.assertEqual(result.returncode, 1)
        self.assertIn("as a Developer ID signature of the team", result.stderr)
        result = self.run_check(app, "--team", 'x" or anchor apple', "--no-live")
        self.assertEqual(result.returncode, 1)
        self.assertIn("not a team identifier", result.stderr)

    def test_a_test_copy_or_a_development_bundle_is_not_the_previous_release(self):
        for name, keys in (("copy", RELEASE + VERIFICATION), ("dev", "")):
            with self.subTest(name=name):
                result = self.run_check(self.fakes.app(name, "1338", keys=keys), "--feed", self.feed(), "--no-live")
                self.assertEqual(result.returncode, 1)
                self.assertIn("not a release as shipped", result.stderr)

    def test_without_a_feed_only_the_app_is_checked(self):
        result = self.run_check(self.fakes.app("old", "1338"))
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("NOTE: no feed given", result.stdout)
        self.assertNotIn("curl:", self.calls())

    def test_a_live_address_that_is_not_https_is_not_fetched(self):
        result = self.run_check(self.fakes.app("old", "1338"), "--feed", self.feed(), "--live", "http://127.0.0.1:1/appcast.xml")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertNotIn("curl:", self.calls())


if __name__ == "__main__":
    unittest.main()
