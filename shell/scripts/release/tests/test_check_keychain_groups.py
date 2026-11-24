"""check-keychain-groups.py, the release gate of security review PK-01: once a keychain access
group has shipped, no release may lose it, and no copy made for tests may carry one. Fake
bundles and a fake codesign (keychain_fakes.py): nothing is signed and no keychain is read."""
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parent))
from keychain_fakes import (BUNDLE_ID, OWN, RELEASE, TEAM, VERIFICATION, WEBAUTHN, FakeSigning,  # noqa: E402
                            app_entitlements, profile_grants)

RELEASE_DIR = Path(__file__).resolve().parents[1]
SCRIPT = RELEASE_DIR / "check-keychain-groups.py"
RECORD = RELEASE_DIR / "shipped-keychain-groups.txt"
REPO = RELEASE_DIR.parents[2]
LINE = "<team>.com.rearc.browser.webauthn 1400\n"


class Case(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory(prefix="rearc-keychain-groups-test-")
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name)
        self.fakes = FakeSigning(self.root)

    def record(self, text=""):
        self.records = getattr(self, "records", 0) + 1
        path = self.root / f"record-{self.records}" / "shipped-keychain-groups.txt"
        path.parent.mkdir()
        path.write_text("# a comment\n\n" + text)
        return path

    def run_script(self, *args, **env):
        return subprocess.run([sys.executable, "-I", str(SCRIPT), *map(str, args)], capture_output=True, text=True,
                              env=self.fakes.env(**env))

    def shipped(self, name="new", build="1400", groups=(OWN, WEBAUTHN)):
        app = self.fakes.app(name, build)
        self.fakes.sign(app, app_entitlements(groups))
        self.fakes.helper(app)
        return app

    def assertFails(self, result, *words):
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        for word in words:
            self.assertIn(word, result.stderr)

    def assertPasses(self, result, *words):
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        for word in words:
            self.assertIn(word, result.stdout)


class GateTests(Case):
    def test_nothing_shipped_and_nothing_carried_passes(self):
        self.assertPasses(self.run_script("gate", self.shipped(groups=None), "--record", self.record()), "PASS", "no group")

    def test_the_recorded_group_carried_passes(self):
        result = self.run_script("gate", self.shipped(), "--record", self.record(LINE), "--build", "1400")
        self.assertPasses(result, "PASS", "<team>.com.rearc.browser.webauthn")
        self.assertNotIn(TEAM, RECORD.read_text(), "the record never holds a team identifier")

    def test_a_recorded_group_that_is_missing_fails(self):
        for groups in (None, (OWN,)):
            with self.subTest(groups=groups):
                result = self.run_script("gate", self.shipped(f"new-{bool(groups)}", groups=groups), "--record", self.record(LINE))
                self.assertFails(result, "lacks <team>.com.rearc.browser.webauthn", "the record", "lose")

    def test_a_group_of_the_previous_release_that_is_missing_fails(self):
        # The record is empty (edited by mistake, or never written): the previous app still says so.
        previous = self.shipped("previous", "1390")
        result = self.run_script("gate", self.shipped(groups=None), "--record", self.record(), "--previous-app", previous)
        self.assertFails(result, "lacks <team>.com.rearc.browser.webauthn", "the previous release (build 1390")

    def test_both_sources_are_checked_as_a_union(self):
        other = f"{OWN}.other"
        previous = self.shipped("previous", "1390", groups=(OWN, other))
        record = self.record(LINE + "<team>.com.rearc.browser.other 1300\n")
        # Only the recorded one: the previous release's is lost.
        result = self.run_script("gate", self.shipped("a"), "--record", self.record(LINE), "--previous-app", previous)
        self.assertFails(result, "lacks <team>.com.rearc.browser.other", "the previous release")
        # Only the previous release's: the recorded one is lost.
        result = self.run_script("gate", self.shipped("b", groups=(OWN, other)), "--record", record, "--previous-app", previous)
        self.assertFails(result, "lacks <team>.com.rearc.browser.webauthn", "the record")
        # Both: passes.
        result = self.run_script("gate", self.shipped("c", groups=(OWN, WEBAUTHN, other)), "--record", record, "--previous-app", previous)
        self.assertPasses(result, "the record and the previous release")

    def test_the_previous_release_is_read_as_shipped_and_its_own_identifier_is_no_shipped_group(self):
        previous = self.shipped("previous", "1390", groups=(OWN,))
        self.assertPasses(self.run_script("gate", self.shipped(groups=None), "--record", self.record(), "--previous-app", previous))

    def test_a_previous_release_of_another_team_fails(self):
        previous = self.fakes.app("previous", "1390")
        self.fakes.sign(previous, app_entitlements((f"OTHERTEAM1.{BUNDLE_ID}",), team="OTHERTEAM1"))
        result = self.run_script("gate", self.shipped(), "--record", self.record(LINE), "--previous-app", previous)
        self.assertFails(result, "team OTHERTEAM1")

    def test_a_group_the_record_does_not_name_fails(self):
        result = self.run_script("gate", self.shipped(), "--record", self.record())
        self.assertFails(result, "which the record does not name", "append")

    def test_a_group_before_its_first_build_fails(self):
        result = self.run_script("gate", self.shipped(build="1399"), "--record", self.record(LINE), "--build", "1399")
        self.assertFails(result, "build 1399", "build 1400 and later")

    def test_the_apps_own_identifier_must_be_first(self):
        result = self.run_script("gate", self.shipped(groups=(WEBAUTHN, OWN)), "--record", self.record(LINE))
        self.assertFails(result, "the first keychain access group", "default group would move")

    def test_a_helper_with_a_group_fails(self):
        app = self.shipped()
        helper = self.fakes.helper(app, "Chromium Helper (Renderer).app")
        self.fakes.sign(helper, {"keychain-access-groups": [WEBAUTHN]})
        result = self.run_script("gate", app, "--record", self.record(LINE))
        self.assertFails(result, "nested code carries a keychain access group", "Chromium Helper (Renderer).app")

    def test_an_unsigned_app_fails(self):
        app = self.fakes.app("unsigned")
        self.assertFails(self.run_script("gate", app, "--record", self.record()), "cannot read the signature")

    def test_dropping_a_group_takes_its_name_and_a_reason(self):
        app, record = self.shipped(groups=None), self.record(LINE)
        name = "<team>.com.rearc.browser.webauthn"
        # The name alone: refused.
        result = self.run_script("gate", app, "--record", record, REARC_DROP_KEYCHAIN_GROUP=name)
        self.assertFails(result, "REARC_DROP_KEYCHAIN_GROUP_REASON", "written reason")
        # A reason alone drops nothing.
        result = self.run_script("gate", app, "--record", record, REARC_DROP_KEYCHAIN_GROUP_REASON="because")
        self.assertFails(result, "lacks <team>.com.rearc.browser.webauthn")
        # Both: passes, and the reason is in the output, so it is in the release log.
        result = self.run_script("gate", app, "--record", record, REARC_DROP_KEYCHAIN_GROUP=name,
                                 REARC_DROP_KEYCHAIN_GROUP_REASON="the owner retired this Mac passkeys on 2027-01-01")
        self.assertPasses(result, f"DROPPED {name}", "the owner retired this Mac passkeys on 2027-01-01")

    def test_a_drop_variable_left_in_the_environment_does_not_pass_by_accident(self):
        record = self.record(LINE)
        # It names something that never shipped (a typo, another release's variable).
        result = self.run_script("gate", self.shipped("a", groups=None), "--record", record,
                                 REARC_DROP_KEYCHAIN_GROUP="<team>.com.rearc.browser.webauth", REARC_DROP_KEYCHAIN_GROUP_REASON="x")
        self.assertFails(result, "is no shipped group")
        # It names a group the app still carries: nothing is being dropped.
        result = self.run_script("gate", self.shipped("b"), "--record", record,
                                 REARC_DROP_KEYCHAIN_GROUP="<team>.com.rearc.browser.webauthn", REARC_DROP_KEYCHAIN_GROUP_REASON="x")
        self.assertFails(result, "still carries it")

    def test_a_drop_also_covers_a_group_only_the_previous_release_names(self):
        previous = self.shipped("previous", "1390")
        result = self.run_script("gate", self.shipped(groups=None), "--record", self.record(), "--previous-app", previous,
                                 REARC_DROP_KEYCHAIN_GROUP="<team>.com.rearc.browser.webauthn", REARC_DROP_KEYCHAIN_GROUP_REASON="tested")
        self.assertPasses(result, "DROPPED", "tested")


class NoneTests(Case):
    """A copy for tests is signed by the same team: with a group it could reach real passkeys."""

    def copy(self, groups=None):
        app = self.fakes.app("copy", keys=RELEASE + VERIFICATION)
        self.fakes.sign(app, app_entitlements(groups))
        self.fakes.helper(app)
        return app

    def test_a_copy_without_a_group_passes(self):
        self.assertPasses(self.run_script("none", self.copy()), "no keychain access group")

    def test_a_copy_with_the_group_fails(self):
        self.assertFails(self.run_script("none", self.copy((OWN, WEBAUTHN))), "copy for tests", "real passkeys")

    def test_a_copy_with_only_its_own_identifier_as_a_group_fails_too(self):
        self.assertFails(self.run_script("none", self.copy((OWN,))), "copy for tests")

    def test_a_copy_whose_helper_has_a_group_fails(self):
        app = self.copy()
        self.fakes.sign(self.fakes.helper(app, "Chromium Helper (GPU).app"), {"keychain-access-groups": [WEBAUTHN]})
        self.assertFails(self.run_script("none", app), "nested code")


class ProfileTests(Case):
    def app(self, groups=(OWN, WEBAUTHN), grants=None, **signed):
        self.apps = getattr(self, "apps", 0) + 1
        app = self.fakes.app(f"app-{self.apps}")
        self.fakes.sign(app, app_entitlements(groups, **signed))
        if grants is not None:
            self.fakes.profile(app, grants)
        return app

    def test_a_wildcard_profile_covers_both_groups(self):
        self.assertPasses(self.run_script("profile", self.app(grants=profile_grants())), "PASS", "keychain-access-groups")

    def test_a_profile_with_both_groups_by_name_covers_them(self):
        self.assertPasses(self.run_script("profile", self.app(grants=profile_grants((OWN, WEBAUTHN)))))

    def test_a_profile_with_only_the_passkey_group_does_not_cover_two(self):
        # icloud-signing.sh once accepted this profile and then signed in two groups.
        result = self.run_script("profile", self.app(grants=profile_grants((WEBAUTHN,))))
        self.assertFails(result, "outrun", OWN, "kill it at launch")

    def test_a_profile_without_the_key_fails(self):
        grants = profile_grants()
        del grants["keychain-access-groups"]
        self.assertFails(self.run_script("profile", self.app(grants=grants)), "keychain-access-groups is signed in and the profile does not have it")

    def test_icloud_values_are_compared_too(self):
        signed = {"com.apple.developer.icloud-container-environment": "Development",
                  "com.apple.developer.icloud-services": ["CloudKit"],
                  "com.apple.developer.icloud-container-identifiers": ["iCloud.com.rearc.browser"]}
        result = self.run_script("profile", self.app(grants=profile_grants(), **signed))
        self.assertFails(result, "icloud-container-environment: Development", "Production")
        signed["com.apple.developer.icloud-container-environment"] = "Production"
        # "*" for the services covers CloudKit; an array of one covers the string.
        self.assertPasses(self.run_script("profile", self.app(grants=profile_grants(), **signed)))

    def test_another_apps_identifier_fails(self):
        grants = profile_grants(**{"com.apple.application-identifier": f"{TEAM}.com.example.other"})
        self.assertFails(self.run_script("profile", self.app(grants=grants)), "com.apple.application-identifier")

    def test_no_profile_and_no_restricted_entitlement_passes(self):
        app = self.fakes.app("plain")
        self.fakes.sign(app, {"com.apple.security.device.camera": True})
        self.assertPasses(self.run_script("profile", app), "no provisioning profile")

    def test_no_profile_and_a_group_fails(self):
        self.assertFails(self.run_script("profile", self.app()), "no embedded provisioning profile", "refuse to start")


class RecordTests(Case):
    def git(self, repo, *args):
        return subprocess.run(["git", "-C", str(repo), "-c", "user.name=test", "-c", "user.email=test@localhost",
                               "-c", "commit.gpgsign=false", *args], capture_output=True, text=True, check=True).stdout

    def history(self, *versions):
        """A repository whose record went through `versions`; the last one is only on disk."""
        repo = self.root / "repo"
        repo.mkdir()
        self.git(repo, "init", "-q")
        path = repo / "shipped.txt"
        for index, text in enumerate(versions):
            path.write_text(text)
            if index < len(versions) - 1:
                self.git(repo, "add", "shipped.txt")
                self.git(repo, "commit", "-q", "-m", f"record {index}")
        return repo, path

    A, B, C = "<team>.com.rearc.browser.webauthn 1400\n", "<team>.com.rearc.browser.second 1500\n", "<team>.com.rearc.browser.third 1600\n"

    def test_the_committed_record_is_well_formed_and_append_only_in_this_repository(self):
        # THE test of the record: it fails when a line of any earlier version is gone or changed.
        result = self.run_script("record", RECORD, "--repo", REPO)
        self.assertPasses(result, "append-only")

    def test_appending_passes(self):
        repo, path = self.history("# empty\n", self.A, self.A + self.B, "# reworded\n" + self.A + self.B + self.C)
        self.assertPasses(self.run_script("record", path, "--repo", repo), "append-only over 3 commit(s)", "3 group(s)")

    def test_a_line_that_disappears_fails(self):
        repo, path = self.history(self.A + self.B, self.B)
        self.assertFails(self.run_script("record", path, "--repo", repo), "append-only", "<team>.com.rearc.browser.webauthn 1400")

    def test_an_emptied_record_fails(self):
        repo, path = self.history(self.A, "# nothing\n")
        self.assertFails(self.run_script("record", path, "--repo", repo), "append-only")

    def test_a_changed_first_build_fails(self):
        repo, path = self.history(self.A, self.A.replace("1400", "1500"))
        self.assertFails(self.run_script("record", path, "--repo", repo), "gone or changed")

    def test_a_renamed_group_fails(self):
        repo, path = self.history(self.A, self.A.replace("webauthn", "passkeys"))
        self.assertFails(self.run_script("record", path, "--repo", repo), "gone or changed")

    def test_reordered_lines_fail(self):
        repo, path = self.history(self.A + self.B, self.B + self.A)
        self.assertFails(self.run_script("record", path, "--repo", repo), "order changed")

    def test_a_line_removed_long_ago_and_put_back_changed_fails(self):
        repo, path = self.history(self.A, self.A + self.B, self.A + self.B.replace("1500", "1501"))
        self.assertFails(self.run_script("record", path, "--repo", repo), "append-only")

    def test_malformed_lines_fail(self):
        for text in (f"{TEAM}.com.rearc.browser.webauthn 1400\n",  # a team identifier written out
                     "<team>.com.rearc.browser.webauthn\n", "<team>.com.rearc.browser.webauthn first\n",
                     "<team>.com.rearc.browser.webauthn 1400 extra\n", "com.rearc.browser.webauthn 1400\n",
                     self.A + self.A):
            with self.subTest(text=text):
                self.assertFails(self.run_script("record", self.record(text)), "line")

    def test_the_gate_refuses_a_malformed_record(self):
        result = self.run_script("gate", self.shipped(), "--record", self.record("webauthn\n"))
        self.assertFails(result, "expected `<team>.<group> <first build>`")


class ListTests(Case):
    def test_list_prints_the_groups(self):
        result = self.run_script("list", self.shipped())
        self.assertEqual(result.stdout.split(), [OWN, WEBAUTHN])


if __name__ == "__main__":
    unittest.main()
