"""release-status.py on a temporary git repository and fixture release folders: which reviews
it shows as reported, the verdict line it finds, and the branches it lists as ahead of main."""
import importlib.util
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / "release-status.py"
spec = importlib.util.spec_from_file_location("release_status", SCRIPT)
release_status = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release_status)

DAY = 86400
TESTS_SUMMARY = "# Tests at build 1255\n\n- Commit `a9ed9926`.\n- **Result: PASS.** 1548 tests: 1542 passed, 0 failed, 6 skipped.\n"
PARITY_REPORT = "# Engine parity at Darni 2026.1123.1255\n\n- Release build 1255.\n- **WebKit pass: FAIL.** Darni ships Chromium.\n\n**Result: FAIL.**\n"


class VerdictLineTests(unittest.TestCase):
    def test_a_bold_phrase_with_a_verdict_word_is_the_verdict(self):
        self.assertEqual(release_status.verdict_in(TESTS_SUMMARY), ("**Result: PASS.** 1548 tests: 1542 passed, 0 failed, 6 skipped.", "pass"))
        self.assertEqual(release_status.verdict_in(PARITY_REPORT), ("**WebKit pass: FAIL.** Darni ships Chromium.", "fail"))

    def test_a_labelled_line_is_a_verdict_without_bold(self):
        self.assertEqual(release_status.verdict_in("# Review\n\nVerdict: SHIP, with two notes.\n"), ("Verdict: SHIP, with two notes.", "pass"))
        self.assertEqual(release_status.verdict_in("## Result: BLOCK\n"), ("Result: BLOCK", "fail"))

    def test_a_line_that_names_both_fails(self):
        self.assertEqual(release_status.verdict_in("**PASS with one FAIL left open**\n")[1], "fail")

    def test_prose_is_not_a_verdict(self):
        self.assertIsNone(release_status.verdict_in("The tests pass. Nothing failed.\nA **bold** word. We cannot SHIP this yet, see below.\n"))
        self.assertIsNone(release_status.verdict_in("**PASSWORD** rules and **GOOGLE** keys.\n"))
        self.assertIsNone(release_status.verdict_in("The verdict: unclear.\n"))

    def test_the_first_verdict_line_wins(self):
        self.assertEqual(release_status.verdict_in("**Result: HOLD.**\n\nLater: **PASS**\n"), ("**Result: HOLD.**", "fail"))


class ReviewFolderTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="darni-release-status-")
        self.addCleanup(self.temp.cleanup)
        self.folder = Path(self.temp.name) / "security"

    def test_a_missing_or_empty_folder_has_not_reported(self):
        self.assertFalse(release_status.review(self.folder)["reported"])
        self.folder.mkdir()
        self.assertFalse(release_status.review(self.folder)["reported"])

    def test_report_md_is_read_before_summary_and_notes(self):
        self.folder.mkdir()
        (self.folder / "NOTES.md").write_text("**Result: PASS.**\n")
        (self.folder / "SUMMARY.md").write_text("**Result: PASS.**\n")
        (self.folder / "REPORT.md").write_text("**Verdict: BLOCK.** One finding.\n")
        found = release_status.review(self.folder)
        self.assertEqual((found["file"], found["state"], found["verdict"]), ("REPORT.md", "fail", "**Verdict: BLOCK.** One finding."))

    def test_another_file_gives_the_verdict_when_the_report_has_none(self):
        self.folder.mkdir()
        (self.folder / "REPORT.md").write_text("# Report\n\nNo conclusion here.\n")
        (self.folder / "RC-1255.md").write_text("Verdict: PASS\n")
        self.assertEqual(release_status.review(self.folder)["file"], "RC-1255.md")

    def test_a_record_without_a_verdict_line_has_still_reported(self):
        self.folder.mkdir()
        (self.folder / "NOTES.md").write_text("# Notes\n\nNumbers only.\n")
        found = release_status.review(self.folder)
        self.assertEqual((found["reported"], found["verdict"], found["file"]), (True, None, "NOTES.md"))


class RepoFixture(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="darni-release-status-")
        self.addCleanup(self.temp.cleanup)
        self.repo = Path(self.temp.name) / "repo"
        self.repo.mkdir()
        self.now = int(time.time())
        self.git("init", "-q")
        self.commit("the release", age_days=10)
        self.git("branch", "-M", "main")
        self.releases = self.repo / "docs" / "releases"

    def git(self, *arguments, env=None):
        return subprocess.run(["git", "-C", str(self.repo), "-c", "user.name=t", "-c", "user.email=t@example.invalid", *arguments],
                              check=True, capture_output=True, text=True, env={**os.environ, **(env or {})}).stdout

    def commit(self, message, age_days=0.0):
        when = f"{self.now - int(age_days * DAY)} +0000"
        self.git("commit", "-q", "--allow-empty", "-m", message, env={"GIT_AUTHOR_DATE": when, "GIT_COMMITTER_DATE": when})

    def branch(self, name, commits=1, age_days=0.0, start="main"):
        """A branch with `commits` commits main lacks, the newest `age_days` old; main is checked out again after."""
        self.git("checkout", "-q", "-b", name, start)
        for number in range(commits):
            self.commit(f"{name} {number}", age_days=age_days + (commits - 1 - number))
        self.git("checkout", "-q", "main")

    def record(self, build, kind, name, text):
        folder = self.releases / str(build) / kind
        folder.mkdir(parents=True, exist_ok=True)
        (folder / name).write_text(text, encoding="utf-8")

    def day(self, age_days):
        return time.strftime("%Y-%m-%d", time.gmtime(self.now - int(age_days * DAY)))

    def status(self, build=1255):
        return release_status.status(build, self.releases, self.repo, "main", self.now)


class BranchTests(RepoFixture):
    def names(self):
        return [branch["name"] for branch in release_status.branches_ahead(self.repo, "main", self.now)]

    def test_review_branches_ahead_of_main_are_listed_with_count_and_newest_date(self):
        self.branch("security/patches", commits=3, age_days=2)
        self.branch("consistency/review", commits=1, age_days=0)
        found = {branch["name"]: branch for branch in release_status.branches_ahead(self.repo, "main", self.now)}
        self.assertEqual(found["security/patches"]["ahead"], 3)
        self.assertEqual(found["security/patches"]["date"], self.day(2), "the newest of its commits")
        self.assertEqual(found["consistency/review"]["ahead"], 1)

    def test_every_batch_and_webkit_branch_is_watched(self):
        self.branch("security/batch-7", age_days=1)
        self.branch("security/batch-8", age_days=1)
        self.branch("webkit/parity-history", age_days=1)
        self.branch("webkit/fix/zoom", age_days=1)
        self.assertEqual(self.names(), ["security/batch-7", "security/batch-8", "webkit/fix/zoom", "webkit/parity-history"])

    def test_a_merged_branch_is_not_listed(self):
        self.branch("security/patches", commits=2)
        self.branch("webkit/done")
        self.git("merge", "-q", "--no-ff", "-m", "merge", "webkit/done")
        self.assertEqual(self.names(), ["security/patches"])

    def test_a_branch_at_main_is_not_listed(self):
        self.git("branch", "consistency/review", "main")
        self.assertEqual(self.names(), [])

    def test_an_old_review_branch_is_still_listed(self):
        self.branch("security/patches", age_days=40)
        self.assertEqual(self.names(), ["security/patches"])

    def test_t3_branches_are_listed_only_when_newer_than_seven_days(self):
        self.branch("t3/fresh", commits=2, age_days=1)
        self.branch("t3/almost-old", age_days=6.9)
        self.branch("t3/old", age_days=7.1)
        self.assertEqual(self.names(), ["t3/fresh", "t3/almost-old"], "newest first")

    def test_a_merged_t3_branch_is_not_listed(self):
        self.branch("t3/landed", age_days=1)
        self.git("merge", "-q", "--no-ff", "-m", "merge", "t3/landed")
        self.assertEqual(self.names(), [])

    def test_other_branches_are_ignored(self):
        self.branch("fix/menus", age_days=1)
        self.branch("security/rc-500", age_days=1)
        self.branch("drm/widevine", age_days=1)
        self.assertEqual(self.names(), [])

    def test_review_branches_come_before_t3_branches(self):
        self.branch("t3/fresh", age_days=0)
        self.branch("webkit/tests", age_days=3)
        self.branch("consistency/review", age_days=5)
        self.assertEqual(self.names(), ["consistency/review", "webkit/tests", "t3/fresh"])


class StatusTextTests(RepoFixture):
    def test_nothing_reported(self):
        text = self.status()
        self.assertTrue(text.startswith("# Release 1255: status\n"))
        head = self.git("rev-parse", "--short=8", "main").strip()
        self.assertRegex(text, rf"As of \d{{4}}-\d\d-\d\d \d\d:\d\d [+-]\d{{4}}, `main` at `{head}`\.")
        for label in ("Tests", "Engine parity", "Security", "Consistency"):
            self.assertIn(f"| {label} | not reported | |", text)
        self.assertIn("Reported: 0 of 4. Waiting for: tests, engine parity, security, consistency.", text)
        self.assertIn("Performance (weekly; for information, it never blocks a release): no record for this release.", text)
        self.assertIn("## Branches ahead of main\n\nNone:", text)

    def test_reported_reviews_show_their_verdict_line_and_file(self):
        self.record(1255, "tests", "SUMMARY.md", TESTS_SUMMARY)
        self.record(1255, "engine-parity", "REPORT.md", PARITY_REPORT)
        self.record(1255, "engine-parity", "NOTES.md", "# Notes\n")
        text = self.status()
        self.assertIn("| Tests | reported | **Result: PASS.** 1548 tests: 1542 passed, 0 failed, 6 skipped. (`tests/SUMMARY.md`) |", text)
        self.assertIn("| Engine parity | reported | **WebKit pass: FAIL.** Darni ships Chromium. (`engine-parity/REPORT.md`) |", text)
        self.assertIn("| Security | not reported | |", text)
        self.assertIn("Reported: 2 of 4. Waiting for: security, consistency. Failed: engine parity.", text)

    def test_all_reported_and_passing(self):
        for kind in ("tests", "engine-parity", "security", "consistency"):
            self.record(1255, kind, "REPORT.md", "**Result: PASS.**\n")
        text = self.status()
        self.assertIn("\nReported: 4 of 4.\n", text)
        self.assertNotIn("Waiting for", text)
        self.assertNotIn("Failed", text)

    def test_a_record_without_a_verdict_says_so(self):
        self.record(1255, "security", "RC-1255.md", "# Review\n\nFindings follow.\n")
        self.assertIn("| Security | reported | no verdict line found in `security/`; read the record |", self.status())

    def test_performance_is_information_and_never_counted(self):
        self.record(1255, "performance", "NOTES.md", "# Idle CPU\n\nNumbers.\n")
        text = self.status()
        self.assertIn("Performance (weekly; for information, it never blocks a release): a record is in `performance/` (`NOTES.md`).", text)
        self.assertIn("Reported: 0 of 4.", text)
        self.assertNotIn("| Performance |", text)

    def test_a_failed_performance_gate_is_shown_but_does_not_count_as_failed(self):
        self.record(1255, "performance", "REPORT.md", "**Gate: FAIL.** Idle CPU up 12 %.\n")
        text = self.status()
        self.assertIn("never blocks a release): **Gate: FAIL.** Idle CPU up 12 %. (`performance/REPORT.md`).", text)
        self.assertNotIn("Failed:", text)

    def test_only_this_releases_folder_is_read(self):
        self.record(1231, "tests", "SUMMARY.md", TESTS_SUMMARY)
        self.assertIn("| Tests | not reported | |", self.status(1255))

    def test_other_folders_are_named(self):
        self.record(1255, "videos", "NOTES.md", "# Clips\n")
        self.assertIn("Other records in the folder: `videos/`.", self.status())

    def test_branches_are_in_the_table(self):
        self.branch("security/patches", commits=3, age_days=2)
        self.branch("t3/fresh", age_days=1)
        text = self.status()
        self.assertIn("| Branch | Commits ahead | Newest commit |", text)
        self.assertIn(f"| `security/patches` | 3 | {self.day(2)} |", text)
        self.assertIn(f"| `t3/fresh` | 1 | {self.day(1)} |", text)

    def test_a_table_cell_is_one_line_without_bars(self):
        self.record(1255, "security", "REPORT.md", "**Verdict: PASS** | with a bar " + "x" * 400 + "\n")
        row = [line for line in self.status().splitlines() if line.startswith("| Security")][0]
        self.assertIn("\\|", row)
        self.assertLess(len(row), 300)
        self.assertIn("…", row)


class CommandTests(RepoFixture):
    def run_status(self, *arguments):
        return subprocess.run([sys.executable, "-I", str(SCRIPT), *arguments, "--repo", str(self.repo)], capture_output=True, text=True)

    def test_it_prints_the_status_and_writes_nothing(self):
        self.record(1255, "tests", "SUMMARY.md", TESTS_SUMMARY)
        self.branch("consistency/review", commits=2, age_days=1)
        result = self.run_status("1255")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("# Release 1255: status", result.stdout)
        self.assertIn("| Tests | reported | **Result: PASS.**", result.stdout)
        self.assertIn("| `consistency/review` | 2 |", result.stdout)
        self.assertFalse((self.releases / "1255" / "STATUS.md").exists())

    def test_write_keeps_it_in_the_release_folder(self):
        self.record(1255, "tests", "SUMMARY.md", TESTS_SUMMARY)
        result = self.run_status("1255", "--write")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.releases / "1255" / "STATUS.md").read_text(encoding="utf-8"), result.stdout)

    def test_write_makes_the_folder_of_a_release_with_no_record_yet(self):
        result = self.run_status("1300", "--write")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Reported: 0 of 4.", (self.releases / "1300" / "STATUS.md").read_text(encoding="utf-8"))

    def test_status_md_is_not_taken_for_a_review(self):
        self.run_status("1255", "--write")
        self.assertIn("Reported: 0 of 4.", self.run_status("1255").stdout)

    def test_another_trunk_can_be_named(self):
        self.git("branch", "trunk", "main")
        self.branch("webkit/tests", age_days=1)
        result = self.run_status("1255", "--main", "trunk")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("## Branches ahead of trunk", result.stdout)
        self.assertIn("| `webkit/tests` | 1 |", result.stdout)

    def test_a_missing_trunk_or_repository_is_2(self):
        result = self.run_status("1255", "--main", "nowhere")
        self.assertEqual(result.returncode, 2)
        self.assertIn("release-status: cannot read", result.stderr)
        outside = subprocess.run([sys.executable, "-I", str(SCRIPT), "1255", "--repo", self.temp.name], capture_output=True, text=True)
        self.assertEqual(outside.returncode, 2)

    def test_a_build_that_is_not_a_number_is_refused(self):
        result = self.run_status("latest")
        self.assertEqual(result.returncode, 2)
        self.assertIn("the build is a number", result.stderr)


if __name__ == "__main__":
    unittest.main()
