"""Who is signed with the keychain access group of "this Mac" passkeys, and who never is
(security review PK-01 and the advance read of 2026-11-24).

- icloud-signing.sh decides: asked for, the caller's default, and never a bundle in release
  verification mode. A wanted group the profile does not cover stops the build.
- sign-release.sh, run for real on a fake bundle with a fake codesign: a verification copy
  comes out without the group whatever is asked; a bundle that ships must carry every group
  of the record; the signed entitlements must fit the embedded profile.
- The copies upgrade-bundles.sh, check-rename-update.sh and release.sh --qa make are all
  verification bundles signed by sign-release.sh, so none of them can reach a real passkey.

Nothing is signed, no keychain is read and no app starts (keychain_fakes.py)."""
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parent))
from keychain_fakes import (OWN, RELEASE, TEAM, VERIFICATION, WEBAUTHN, FakeSigning,  # noqa: E402
                            app_entitlements, profile_grants)

SCRIPTS = Path(__file__).resolve().parents[2]
RELEASE_DIR = SCRIPTS / "release"
CONTAINER = "iCloud.com.rearc.browser"
RECORD_LINE = "<team>.com.rearc.browser.webauthn 1400\n"


class Case(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory(prefix="rearc-webauthn-signing-test-")
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name)
        self.fakes = FakeSigning(self.root)

    def profile_file(self, groups=(f"{TEAM}.*",)):
        path = self.root / f"profile-{len(list(self.root.glob('profile-*')))}.provisionprofile"
        path.write_bytes(plistlib.dumps({"Entitlements": profile_grants(groups), "Name": "test"}))
        return path


class PrepareTests(Case):
    """icloud_prepare, sourced as the bundle scripts source it."""

    def prepare(self, app, profile, **env):
        out = self.root / f"out-{len(list(self.root.glob('out-*')))}.entitlements"
        script = f'''set -euo pipefail
die() {{ echo "die: $*" >&2; exit 1; }}
source "{SCRIPTS}/icloud-signing.sh"
SIGN_IDENTITY=test TEAM_ID={TEAM} REARC_ICLOUD_CONTAINER={CONTAINER}
icloud_prepare "{app}" com.rearc.browser "{profile}" "{RELEASE_DIR}/entitlements/app.entitlements" "{out}"
'''
        result = subprocess.run(["bash", "-c", script], capture_output=True, text=True, env=self.fakes.env(**env))
        groups = None
        if result.returncode == 0:
            groups = plistlib.loads(out.read_bytes()).get("keychain-access-groups")
        return result, groups

    def test_nothing_asked_means_no_group(self):
        result, groups = self.prepare(self.fakes.app("a"), self.profile_file())
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIsNone(groups)
        self.assertIn("no keychain access group", result.stdout)

    def test_asked_for_the_group_is_signed_after_the_apps_own_identifier(self):
        result, groups = self.prepare(self.fakes.app("a"), self.profile_file(), REARC_WEBAUTHN_KEYCHAIN_GROUP="1")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(groups, [OWN, WEBAUTHN])

    def test_the_callers_default_decides_when_nothing_is_asked(self):
        _, groups = self.prepare(self.fakes.app("a"), self.profile_file(), REARC_WEBAUTHN_GROUP_DEFAULT="1")
        self.assertEqual(groups, [OWN, WEBAUTHN])
        _, groups = self.prepare(self.fakes.app("b"), self.profile_file(), REARC_WEBAUTHN_GROUP_DEFAULT="1", REARC_WEBAUTHN_KEYCHAIN_GROUP="0")
        self.assertIsNone(groups, "an explicit 0 wins over the default")

    def test_a_verification_bundle_never_gets_the_group(self):
        for env in ({"REARC_WEBAUTHN_KEYCHAIN_GROUP": "1"}, {"REARC_WEBAUTHN_GROUP_DEFAULT": "1"},
                    {"REARC_WEBAUTHN_KEYCHAIN_GROUP": "1", "REARC_WEBAUTHN_GROUP_DEFAULT": "1"}):
            with self.subTest(env=env):
                app = self.fakes.app(f"copy-{len(env)}-{list(env)[0][-7:]}", keys=RELEASE + VERIFICATION)
                result, groups = self.prepare(app, self.profile_file(), **env)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIsNone(groups)
                self.assertIn("release verification mode never gets it", result.stdout)

    def test_a_profile_must_cover_both_groups_the_script_adds(self):
        # The old condition took a profile with the passkey group alone, and then added two.
        for groups in ((WEBAUTHN,), (OWN,), ()):
            with self.subTest(groups=groups):
                result, _ = self.prepare(self.fakes.app(f"a{len(groups)}{groups[:1]}"), self.profile_file(groups), REARC_WEBAUTHN_KEYCHAIN_GROUP="1")
                self.assertEqual(result.returncode, 1, result.stdout)
                self.assertIn("the profile does not allow", result.stderr)
        result, groups = self.prepare(self.fakes.app("both"), self.profile_file((OWN, WEBAUTHN)), REARC_WEBAUTHN_KEYCHAIN_GROUP="1")
        self.assertEqual(groups, [OWN, WEBAUTHN], result.stderr)

    def test_a_wanted_group_is_never_left_out_quietly(self):
        result, _ = self.prepare(self.fakes.app("a"), self.profile_file(("OTHERTEAM1.*",)), REARC_WEBAUTHN_GROUP_DEFAULT="1")
        self.assertEqual(result.returncode, 1)
        self.assertNotIn("no keychain access group", result.stdout)

    def test_a_setting_that_is_neither_0_nor_1_stops_the_build(self):
        result, _ = self.prepare(self.fakes.app("a"), self.profile_file(), REARC_WEBAUTHN_KEYCHAIN_GROUP="yes")
        self.assertEqual(result.returncode, 1)
        self.assertIn("must be 0 or 1", result.stderr)


class SignReleaseTests(Case):
    """sign-release.sh itself, on a fake bundle: what it signs in, and what it then refuses."""

    def setUp(self):
        super().setUp()
        # A copy of the scripts, so a test can give it another record and another default.
        self.scripts = self.root / "shell/scripts"
        (self.scripts / "release").mkdir(parents=True)
        for name in ("sign-release.sh", "icloud-signing.sh"):
            shutil.copy(SCRIPTS / name, self.scripts / name)
        for name in ("signing-env.sh", "check-keychain-groups.py", "shipped-keychain-groups.txt"):
            shutil.copy(RELEASE_DIR / name, self.scripts / "release" / name)
        shutil.copytree(RELEASE_DIR / "entitlements", self.scripts / "release/entitlements")
        self.record = self.scripts / "release/shipped-keychain-groups.txt"

    def set_default(self, value):
        path = self.scripts / "sign-release.sh"
        text = path.read_text()
        self.assertEqual(text.count("export REARC_WEBAUTHN_GROUP_DEFAULT="), 1)
        import re
        path.write_text(re.sub(r"export REARC_WEBAUTHN_GROUP_DEFAULT=\d", f"export REARC_WEBAUTHN_GROUP_DEFAULT={value}", text))

    def bundle(self, name, keys=RELEASE):
        app = self.fakes.app(name, keys=keys)
        framework = app / "Contents/Frameworks/Chromium Framework.framework"
        version = framework / "Versions/1.0"
        (version / "Helpers").mkdir(parents=True)
        (version / "Chromium Framework").write_text("framework\n")
        (framework / "Versions/Current").symlink_to("1.0")
        for helper in ("Chromium Helper (Renderer).app", "Chromium Helper (GPU).app", "Chromium Helper.app"):
            (version / "Helpers" / helper / "Contents/MacOS").mkdir(parents=True)
            (version / "Helpers" / helper / "Contents/MacOS" / helper[:-4]).write_text("helper\n")
        return app

    def sign(self, app, profile=None, container=CONTAINER, **env):
        settings = dict(REARC_RELEASE_IDENTITY=f"Developer ID Application: Test ({TEAM})", REARC_TEAM_ID=TEAM)
        if container:
            settings.update(REARC_ICLOUD_CONTAINER=container, REARC_RELEASE_PROVISIONING_PROFILE=str(profile or self.profile_file()))
        settings.update(env)
        result = subprocess.run(["bash", str(self.scripts / "sign-release.sh"), str(app)], capture_output=True, text=True,
                                env=self.fakes.env(**settings), timeout=120)
        return result

    def groups(self, app):
        return self.fakes.signed_entitlements(app).get("keychain-access-groups")

    def test_the_default_is_off_until_the_switch(self):
        text = (SCRIPTS / "sign-release.sh").read_text()
        self.assertIn("export REARC_WEBAUTHN_GROUP_DEFAULT=0\n", text)
        self.assertNotIn("webauthn", "".join(line for line in (RELEASE_DIR / "shipped-keychain-groups.txt").read_text().splitlines(True)
                                            if not line.startswith("#")),
                         "the record names the group only from the commit that turns its signing on")

    def test_a_release_without_the_group_signs_and_passes_while_nothing_has_shipped(self):
        app = self.bundle("plain")
        result = self.sign(app)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIsNone(self.groups(app))
        self.assertIn("check-keychain-groups: PASS: the profile allows", result.stdout)
        self.assertIn("carries no group", result.stdout)

    def test_a_group_signed_in_before_it_is_recorded_is_refused(self):
        result = self.sign(self.bundle("early"), REARC_WEBAUTHN_KEYCHAIN_GROUP="1")
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn("which the record does not name", result.stderr)

    def test_with_the_switch_on_a_release_carries_the_group_and_its_helpers_none(self):
        self.set_default(1)
        self.record.write_text(RECORD_LINE)
        app = self.bundle("shipping")
        result = self.sign(app)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.groups(app), [OWN, WEBAUTHN])
        helpers = app / "Contents/Frameworks/Chromium Framework.framework/Versions/1.0/Helpers"
        for helper in helpers.iterdir():
            self.assertNotIn("keychain-access-groups", self.fakes.signed_entitlements(helper), helper.name)
        self.assertIn("passkeys: keychain access group", result.stdout)

    def test_a_release_that_would_lose_a_shipped_group_fails(self):
        self.set_default(1)
        self.record.write_text(RECORD_LINE)
        # Each way PK-01 names: the variable left at 0, no iCloud container, a renewed profile.
        result = self.sign(self.bundle("zero"), REARC_WEBAUTHN_KEYCHAIN_GROUP="0")
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn("lacks <team>.com.rearc.browser.webauthn, which has shipped", result.stderr)
        result = self.sign(self.bundle("no-container"), container="")
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn("without REARC_ICLOUD_CONTAINER there is no provisioning profile", result.stderr)
        result = self.sign(self.bundle("renewed"), profile=self.profile_file((OWN,)))
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn("the profile does not allow", result.stderr)

    def test_a_shipped_group_is_dropped_only_with_its_name_and_a_reason(self):
        self.set_default(1)
        self.record.write_text(RECORD_LINE)
        drop = dict(REARC_WEBAUTHN_KEYCHAIN_GROUP="0", REARC_DROP_KEYCHAIN_GROUP="<team>.com.rearc.browser.webauthn")
        result = self.sign(self.bundle("half"), **drop)
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn("REARC_DROP_KEYCHAIN_GROUP_REASON", result.stderr)
        result = self.sign(self.bundle("said"), REARC_DROP_KEYCHAIN_GROUP_REASON="owner decision 2027-01-01, issue 99", **drop)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("DROPPED <team>.com.rearc.browser.webauthn", result.stdout)
        self.assertIn("owner decision 2027-01-01, issue 99", result.stdout, "the reason is in the signing log")

    def test_a_verification_copy_is_signed_without_the_group_whatever_is_asked(self):
        # release.sh's gate bundle, a --qa bundle, upgrade-bundles.sh's and
        # check-rename-update.sh's copies of a previous release: all of them are this.
        self.set_default(1)
        self.record.write_text(RECORD_LINE)
        for env in ({}, {"REARC_WEBAUTHN_KEYCHAIN_GROUP": "1"}):
            with self.subTest(env=env):
                app = self.bundle(f"copy-{len(env)}", keys=RELEASE + VERIFICATION)
                result = self.sign(app, **env)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertIsNone(self.groups(app))
                self.assertIn("a copy for tests never reaches a real passkey", result.stdout)
                self.assertNotIn("lacks", result.stderr, "a verification copy is not held to the record")

    def test_a_verification_copy_that_came_out_with_a_group_is_refused(self):
        # If the decision in icloud-signing.sh ever breaks, the read-back still stops the copy.
        signing = self.scripts / "icloud-signing.sh"
        text = signing.read_text()
        marker = 'echo "a bundle in release verification mode never gets it"\n    return 1'
        self.assertEqual(text.count(marker), 1)
        signing.write_text(text.replace(marker, "return 0"))
        result = self.sign(self.bundle("broken", keys=RELEASE + VERIFICATION), REARC_WEBAUTHN_KEYCHAIN_GROUP="1")
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn("copy for tests", result.stderr)

    def test_entitlements_that_outrun_the_profile_fail_after_signing(self):
        # Signing succeeds; macOS would kill the app at launch. The read-back catches it.
        app = self.bundle("outrun")
        base = self.scripts / "release/entitlements/app.entitlements"
        entitlements = plistlib.loads(base.read_bytes())
        entitlements["com.apple.developer.web-browser.public-key-credential"] = True
        base.write_bytes(plistlib.dumps(entitlements))
        result = self.sign(app)
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn("com.apple.developer.web-browser.public-key-credential is signed in and the profile does not have it", result.stderr)


class WiringTests(unittest.TestCase):
    """Every script that signs a copy of a release with the release identity makes it a
    verification bundle first and signs it with sign-release.sh, which gives such a bundle no
    group and refuses one that has it."""

    def test_the_upgrade_checks_copy_is_a_verification_bundle_signed_by_sign_release(self):
        text = (RELEASE_DIR / "upgrade-bundles.sh").read_text()
        insert = text.index('plutil -insert ReArcReleaseVerification -bool true "$copy/Contents/Info.plist"')
        sign = text.index('"$sign" "$copy"')
        self.assertLess(insert, sign, "the key is in the Info.plist before the copy is signed")
        self.assertIn("sign-release.sh}", text)

    def test_the_rename_update_copies_are_verification_bundles_signed_by_sign_release(self):
        text = (RELEASE_DIR / "check-rename-update.sh").read_text()
        stamp = text[text.index("# stamp APP"):]
        self.assertLess(stamp.index("ReArcReleaseVerification"), stamp.index('"$SIGN" "$app"'))
        self.assertIn('SIGN="${REARC_UPGRADE_SIGN:-$SHELL_DIR/scripts/sign-release.sh}"', text)

    def test_the_performance_checks_copy_is_a_verification_bundle_signed_by_sign_release(self):
        text = (SCRIPTS / "perf-check.sh").read_text()
        self.assertLess(text.index('plutil -insert ReArcReleaseVerification -bool true "$QA/Contents/Info.plist"'),
                        text.index('"$SHELL_DIR/scripts/sign-release.sh" "$QA"'))

    def test_only_these_scripts_sign_with_the_release_identity(self):
        # A new script that signs a copy has to be added here, and to the tests above.
        signers = sorted(str(path.relative_to(SCRIPTS)) for path in SCRIPTS.rglob("*") if path.is_file()
                         and "tests" not in path.parts and path.suffix in (".sh", ".py")
                         and "sign-release.sh" in path.read_text(errors="replace") and path.name != "sign-release.sh"
                         and any("sign-release.sh" in line and not line.lstrip().startswith("#") and "die " not in line
                                 for line in path.read_text(errors="replace").splitlines()))
        self.assertEqual(signers, ["perf-check.sh", "release.sh", "release/check-rename-update.sh", "release/upgrade-bundles.sh"])

    def test_release_sh_signs_the_gate_bundle_and_a_qa_bundle_in_verification_mode(self):
        text = (SCRIPTS / "release.sh").read_text()
        key = text.index("plutil -insert ReArcReleaseVerification -bool true")
        first_sign = text.index('"$SHELL_DIR/scripts/sign-release.sh" "$APP" 2>&1 | tee "$DIST/sign-release.log"')
        self.assertLess(key, first_sign)
        self.assertIn("if [[ $VERIFY == 1 || $DMG == 1 || $QA == 1 ]]; then\n  plutil -insert ReArcReleaseVerification", text)
        # The bundle as it ships is checked after the key is removed and it is signed again.
        shipped = text.index('sign-release-shipped.log')
        groups = text.index("check-upgrade.sh\" --keychain-groups \"$APP\" \"$PREVIOUS_APP\"")
        self.assertLess(shipped, groups)
        self.assertLess(groups, text.index("# 6. Optional notarization"), "before anything is notarized or packed")

    def test_sign_release_reads_back_what_it_signed(self):
        text = (SCRIPTS / "sign-release.sh").read_text()
        final_sign = text.index('sign "$APP" --options "$FULL"')
        for check in ('"${GROUPS_CHECK[@]}" profile "$APP"', '"${GROUPS_CHECK[@]}" none "$APP"', '"${GROUPS_CHECK[@]}" gate "$APP"'):
            self.assertLess(final_sign, text.index(check), check)
        self.assertIn('--record "$RELEASE_DIR/shipped-keychain-groups.txt"', text)

    def test_the_webkit_development_bundle_never_asks_for_the_group(self):
        text = (SCRIPTS / "bundle-webkit-dev.sh").read_text()
        self.assertIn("REARC_WEBAUTHN_KEYCHAIN_GROUP=0 icloud_prepare", text)

    def test_release_sh_checks_the_record_and_the_previous_release_before_it_builds(self):
        text = (SCRIPTS / "release.sh").read_text()
        build = text.index("heavy_job_begin release")
        self.assertLess(text.index('check-keychain-groups.py" record'), build)
        self.assertLess(text.index("check-previous-release.py"), build)
        self.assertIn('previous_check+=(--feed "$APPCAST/appcast.xml")', text)


class UpgradeHalfTests(Case):
    """check-upgrade.sh --keychain-groups: the candidate as it ships against the previous
    release as it was shipped."""

    SCRIPT = RELEASE_DIR / "check-upgrade.sh"

    def run_check(self, new, previous):
        return subprocess.run(["bash", str(self.SCRIPT), "--keychain-groups", str(new), str(previous)], capture_output=True, text=True,
                              env=self.fakes.env(), timeout=120)

    def release(self, name, build, groups):
        app = self.fakes.app(name, build)
        self.fakes.sign(app, app_entitlements(groups))
        return app

    def test_a_candidate_that_loses_the_previous_releases_group_fails(self):
        result = self.run_check(self.release("new", "1410", None), self.release("old", "1400", (OWN, WEBAUTHN)))
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn("lacks <team>.com.rearc.browser.webauthn", result.stderr)
        self.assertIn("the previous release (build 1400", result.stderr)
        self.assertIn("would lose a keychain access group", result.stderr)

    def test_no_groups_on_either_side_passes(self):
        result = self.run_check(self.release("new", "1410", None), self.release("old", "1400", None))
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("keeps every keychain access group", result.stdout)

    def test_a_verification_bundle_is_not_what_ships(self):
        new = self.fakes.app("new", "1410", keys=RELEASE + VERIFICATION)
        self.fakes.sign(new, app_entitlements(None))
        result = self.run_check(new, self.release("old", "1400", None))
        self.assertEqual(result.returncode, 1)
        self.assertIn("verification bundle", result.stderr)

    def test_nothing_is_launched_or_signed(self):
        self.run_check(self.release("new", "1410", None), self.release("old", "1400", None))
        calls = self.fakes.log.read_text()
        self.assertNotIn("--sign", calls)
        self.assertTrue(all(line.startswith(("codesign:-d", "security:")) for line in calls.splitlines()), calls)


if __name__ == "__main__":
    unittest.main()
