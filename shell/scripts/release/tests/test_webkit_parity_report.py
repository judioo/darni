"""webkit-parity-report.py: the report for one build, and the checks that keep docs/engine-parity.json,
docs/ENGINE-PARITY.md and the WebKit tests' `// parity:` comments in step. No build, no app."""
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

RELEASE = Path(__file__).resolve().parents[1]
SCRIPT = RELEASE / "webkit-parity-report.py"
REPO = RELEASE.parents[2]

spec = importlib.util.spec_from_file_location("webkit_parity_report", SCRIPT)
report = importlib.util.module_from_spec(spec)
spec.loader.exec_module(report)

INDEX = [
    {"id": "navigation.load", "area": "Pages", "feature": "Page load", "chromium": "works", "webkit": "works", "note": ""},
    {"id": "tabs.popups", "area": "Tabs", "feature": "New tabs from links", "chromium": "works", "webkit": "missing", "note": "", "priority": "P0"},
    {"id": "find.count", "area": "Pages", "feature": "Find", "chromium": "works", "webkit": "works", "note": ""},
]
DOC = """# Engine parity

| Feature | Chromium | WebKit | On WebKit | ID |
|---|---|---|---|---|
| Page load | works | **works** | fine | `navigation.load` |
| New tabs from links | works | **missing** (P0) | nothing happens | `tabs.popups` |
| Find | works | **works** | | `find.count` |
"""
TESTS = """import XCTest

@MainActor
final class WebKitEngineSmokeTests: XCTestCase {
    private func helper() {}

    // parity: navigation.load
    func testAPageLoads() async throws {}

    // parity: find.count, navigation.load
    @MainActor
    func testFindCounts() async throws {}

    // An ordinary comment.
    func testUntagged() {}
}
"""
LOG = """Build complete!
Test Case '-[ReArcTests.WebKitEngineSmokeTests testAPageLoads]' started.
Test Case '-[ReArcTests.WebKitEngineSmokeTests testAPageLoads]' passed (0.191 seconds).
Test Case '-[ReArcTests.WebKitEngineSmokeTests testFindCounts]' passed (0.269 seconds).
Test Case '-[ReArcTests.WebKitEngineSmokeTests testUntagged]' passed (0.001 seconds).
"""


class Fixture:
    def __init__(self, case, index=INDEX, doc=DOC, tests=TESTS, log=LOG):
        self.dir = tempfile.TemporaryDirectory()
        case.addCleanup(self.dir.cleanup)
        root = Path(self.dir.name)
        (root / "tests").mkdir()
        self.index = root / "engine-parity.json"
        self.doc = root / "ENGINE-PARITY.md"
        self.log = root / "swift-test.log"
        self.out = root / "out"
        self.index.write_text(json.dumps(index), encoding="utf-8")
        self.doc.write_text(doc, encoding="utf-8")
        (root / "tests" / "WebKitEngineSmokeTests.swift").write_text(tests, encoding="utf-8")
        self.log.write_text(log, encoding="utf-8")
        self.tests = root / "tests"

    def run(self, *extra):
        return subprocess.run(
            [sys.executable, "-I", str(SCRIPT), "--index", str(self.index), "--doc", str(self.doc), "--tests", str(self.tests),
             "--log", str(self.log), "--out", str(self.out), "--label", "Darni test build", *extra],
            capture_output=True, text=True)

    def report(self):
        return json.loads((self.out / "webkit-parity-report.json").read_text(encoding="utf-8"))


class ReportTests(unittest.TestCase):
    def test_a_passing_build_reports_each_row_with_its_tests(self):
        fixture = Fixture(self)
        result = fixture.run()
        self.assertEqual(result.returncode, 0, result.stderr)
        made = fixture.report()
        self.assertEqual(made["result"], "pass")
        self.assertEqual(made["counts"], {"works": 2, "partial": 0, "missing": 1, "impossible": 0})
        by_id = {row["id"]: row for row in made["matrix"]}
        self.assertEqual(by_id["navigation.load"]["webkitTests"], "passed")
        self.assertEqual([t["name"] for t in by_id["navigation.load"]["tests"]],
                         ["WebKitEngineSmokeTests.testAPageLoads", "WebKitEngineSmokeTests.testFindCounts"])
        self.assertEqual(by_id["tabs.popups"]["webkitTests"], "no test")
        self.assertEqual(made["rowsWithAPassingWebKitTest"], 2)
        text = (fixture.out / "webkit-parity-report.md").read_text(encoding="utf-8")
        self.assertIn("# WebKit parity report: Darni test build", text)
        self.assertIn("**Result: PASS.**", text)
        self.assertIn("| New tabs from links | works | missing | no test |", text)
        self.assertIn("| Find | works | works | passed (testFindCounts) |", text)

    def test_a_failed_webkit_test_fails_the_report_and_names_the_row(self):
        fixture = Fixture(self, log=LOG.replace("testFindCounts]' passed", "testFindCounts]' failed"))
        result = fixture.run()
        self.assertEqual(result.returncode, 1)
        self.assertIn("FAILED find.count", result.stderr)
        made = fixture.report()
        self.assertEqual(made["result"], "fail")
        self.assertEqual(made["failedRows"], ["navigation.load", "find.count"])

    def test_a_tagged_test_that_did_not_run_fails_the_report(self):
        fixture = Fixture(self, log="Build complete!\n")
        result = fixture.run()
        self.assertEqual(result.returncode, 1)
        self.assertIn("NOT RUN navigation.load", result.stderr)

    def test_a_failed_build_fails_the_report_even_when_the_log_has_passes(self):
        fixture = Fixture(self)
        result = fixture.run("--build-failed")
        self.assertEqual(result.returncode, 1)
        self.assertIn("did not build", (fixture.out / "webkit-parity-report.md").read_text(encoding="utf-8"))

    def test_a_working_row_without_a_test_is_listed_not_failed(self):
        index = INDEX + [{"id": "zoom.page", "area": "Pages", "feature": "Zoom", "chromium": "works", "webkit": "works", "note": ""}]
        doc = DOC + "| Zoom | works | **works** | | `zoom.page` |\n"
        fixture = Fixture(self, index=index, doc=doc)
        self.assertEqual(fixture.run().returncode, 0)
        self.assertEqual(fixture.report()["workingRowsWithoutAWebKitTest"], ["zoom.page"])


class ConsistencyTests(unittest.TestCase):
    def assert_refused(self, fixture, message):
        result = fixture.run()
        self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
        self.assertIn(message, result.stderr)
        self.assertFalse(fixture.out.exists(), "a report that would mislead is not written")

    def test_a_test_that_names_an_unknown_row_is_refused(self):
        self.assert_refused(Fixture(self, tests=TESTS.replace("// parity: navigation.load\n", "// parity: navigation.lod\n")),
                            "names the row navigation.lod")

    def test_a_row_missing_from_the_document_is_refused(self):
        self.assert_refused(Fixture(self, doc=DOC.replace("| Find | works | **works** | | `find.count` |\n", "")),
                            "no matrix row for find.count")

    def test_a_verdict_that_differs_between_document_and_index_is_refused(self):
        self.assert_refused(Fixture(self, doc=DOC.replace("**missing** (P0)", "**partial** (P0)")),
                            "tabs.popups says works/partial, the index says works/missing")

    def test_a_document_row_missing_from_the_index_is_refused(self):
        self.assert_refused(Fixture(self, doc=DOC + "| Zoom | works | **partial** | | `zoom.page` |\n"), "zoom.page is not in the index")

    def test_an_unknown_verdict_and_a_duplicate_row_are_refused(self):
        bad = [dict(INDEX[0], webkit="fine"), INDEX[1], INDEX[1]]
        fixture = Fixture(self, index=bad)
        result = fixture.run()
        self.assertEqual(result.returncode, 2)
        self.assertIn("WebKit verdict \"fine\"", result.stderr)
        self.assertIn("tabs.popups is there twice", result.stderr)

    def test_check_writes_nothing(self):
        fixture = Fixture(self)
        result = fixture.run("--check")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("3 rows, 2 tagged tests", result.stdout)
        self.assertFalse(fixture.out.exists())


class ReleaseRecordTests(unittest.TestCase):
    """--record-release: a folder per release that people can read later, and the history."""

    def setUp(self):
        self.fixture = Fixture(self)
        self.releases = Path(self.fixture.dir.name) / "releases"

    def record(self, version, commit="abc12345", date="2026-11-22", index=None, doc=None, log=None):
        if index is not None:
            self.fixture.index.write_text(json.dumps(index), encoding="utf-8")
        if doc is not None:
            self.fixture.doc.write_text(doc, encoding="utf-8")
        if log is not None:
            self.fixture.log.write_text(log, encoding="utf-8")
        return self.fixture.run("--record-release", version, "--releases", str(self.releases), "--commit", commit, "--date", date)

    def folder(self, build):
        return self.releases / str(build) / "engine-parity"

    def text(self, build, name):
        return (self.folder(build) / name).read_text(encoding="utf-8")

    def history(self):
        return (self.releases / "ENGINE-PARITY-HISTORY.md").read_text(encoding="utf-8")

    def test_the_first_record_has_the_report_the_notes_to_write_and_the_document_as_it_stood(self):
        result = self.record("2026.1122.1231")
        self.assertEqual(result.returncode, 0, result.stderr)
        report_text = self.text(1231, "REPORT.md")
        self.assertIn("# Engine parity at Darni 2026.1122.1231", report_text)
        self.assertIn("Release build 1231, `main` at `abc12345`, 2026-11-22.", report_text)
        self.assertIn("**WebKit pass: PASS.**", report_text)
        self.assertIn("This is the first release with a record.", report_text)
        self.assertIn("| New tabs from links | works | missing | no test |", report_text)
        self.assertIn("[ENGINE-PARITY.md](ENGINE-PARITY.md)", report_text)
        copy = self.text(1231, "ENGINE-PARITY.md")
        self.assertTrue(copy.startswith("> A copy of docs/ENGINE-PARITY.md as it stood at Darni 2026.1122.1231 (`abc12345`)."))
        self.assertTrue(copy.endswith(DOC))
        self.assertIn(report.NOTES_PENDING, self.text(1231, "NOTES.md"))
        made = json.loads(self.text(1231, "report.json"))
        self.assertEqual(made["release"], {"version": "2026.1122.1231", "build": 1231, "commit": "abc12345", "date": "2026-11-22"})
        self.assertEqual((made["previous"], made["changes"], made["documentSnapshot"]), (None, [], 1231))
        line = self.history().splitlines()[-1]
        self.assertEqual(line, "| [2026.1122.1231](1231/engine-parity/REPORT.md) | 2026-11-22 | `abc12345` | pass | 2 | 0 | 1 | 0 "
                               "| 2 of 3 | none | first record | not checked | not written yet |")

    def test_a_release_with_no_verdict_change_points_at_the_document_it_already_has(self):
        self.record("2026.1122.1231")
        result = self.record("2026.1125.1260", commit="def67890", date="2026-11-25")
        self.assertEqual(result.returncode, 0, result.stderr)
        report_text = self.text(1260, "REPORT.md")
        self.assertIn("## Changed since build 1231", report_text)
        self.assertIn("No verdict changed.", report_text)
        self.assertIn("[ENGINE-PARITY.md](../../1231/engine-parity/ENGINE-PARITY.md)", report_text)
        self.assertIn("as it stood at build 1231; no verdict has changed since", report_text)
        self.assertFalse((self.folder(1260) / "ENGINE-PARITY.md").exists())
        self.assertIn("What changed since 1231, by engine", self.text(1260, "NOTES.md"))
        rows = [line for line in self.history().splitlines() if line.startswith("| [")]
        self.assertEqual([row.split("]")[0] for row in rows], ["| [2026.1125.1260", "| [2026.1122.1231"], "newest first")
        self.assertIn("| none | none | not checked | not written yet |", rows[0], "no --repo: coverage not checked")

    def test_changed_added_and_removed_rows_are_listed_and_the_document_is_copied_again(self):
        self.record("2026.1122.1231")
        index = [INDEX[0], dict(INDEX[1], webkit="works"),
                 {"id": "zoom.page", "area": "Pages", "feature": "Zoom", "chromium": "works", "webkit": "partial", "note": ""}]
        doc = DOC.replace("**missing** (P0)", "**works**").replace("| Find | works | **works** | | `find.count` |\n", "") \
            + "| Zoom | works | **partial** | | `zoom.page` |\n"
        tests = TESTS.replace("// parity: find.count, navigation.load", "// parity: navigation.load")
        (self.fixture.tests / "WebKitEngineSmokeTests.swift").write_text(tests, encoding="utf-8")
        result = self.record("2026.1125.1260", index=index, doc=doc)
        self.assertEqual(result.returncode, 0, result.stderr)
        report_text = self.text(1260, "REPORT.md")
        self.assertIn("| New tabs from links | missing → works on WebKit | `tabs.popups` |", report_text)
        self.assertIn("| Zoom | new row, partial on WebKit | `zoom.page` |", report_text)
        self.assertIn("| Find | row removed (was works on WebKit) | `find.count` |", report_text)
        self.assertTrue((self.folder(1260) / "ENGINE-PARITY.md").exists())
        made = json.loads(self.text(1260, "report.json"))
        self.assertEqual(made["documentSnapshot"], 1260)
        self.assertEqual([c["id"] for c in made["changes"]], ["tabs.popups", "zoom.page", "find.count"])
        self.assertIn("| none | 3 | not checked | not written yet |", self.history())

    def test_a_chromium_verdict_change_is_a_change_too(self):
        self.record("2026.1122.1231")
        self.record("2026.1125.1260", index=[dict(INDEX[0], chromium="partial"), INDEX[1], INDEX[2]],
                    doc=DOC.replace("| Page load | works |", "| Page load | partial |"))
        self.assertIn("| Page load | works on WebKit, as before; works → partial on Chromium | `navigation.load` |", self.text(1260, "REPORT.md"))

    def test_notes_are_never_overwritten_and_the_history_shows_them_once_written(self):
        self.record("2026.1122.1231")
        notes = self.folder(1231) / "NOTES.md"
        notes.write_text("# Notes\n\nWebKit has no extensions.\n", encoding="utf-8")
        self.record("2026.1122.1231")
        self.assertEqual(notes.read_text(encoding="utf-8"), "# Notes\n\nWebKit has no extensions.\n")
        self.assertIn("| first record | not checked | [notes](1231/engine-parity/NOTES.md) |", self.history())

    def test_history_alone_rewrites_the_table(self):
        self.record("2026.1122.1231")
        (self.folder(1231) / "NOTES.md").write_text("written\n", encoding="utf-8")
        result = subprocess.run([sys.executable, "-I", str(SCRIPT), "--history", str(self.releases)], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("history of 1 release in", result.stdout)
        self.assertIn("[notes](1231/engine-parity/NOTES.md)", self.history())

    def test_a_failed_pass_is_recorded_as_failed(self):
        result = self.record("2026.1122.1231", log=LOG.replace("testFindCounts]' passed", "testFindCounts]' failed"))
        self.assertEqual(result.returncode, 1)
        self.assertIn("**WebKit pass: FAIL.**", self.text(1231, "REPORT.md"))
        self.assertIn("| **fail** | 2 | 0 | 1 | 0 | 0 of 3 | navigation.load, find.count | first record |", self.history())

    def test_a_record_needs_its_commit_date_and_a_version_that_ends_in_the_build(self):
        result = self.fixture.run("--record-release", "2026.1122.1231", "--releases", str(self.releases))
        self.assertEqual(result.returncode, 2)
        self.assertIn("--record-release needs", result.stderr)
        result = self.fixture.run("--record-release", "nightly", "--releases", str(self.releases), "--commit", "abc", "--date", "2026-11-22")
        self.assertEqual(result.returncode, 2)
        self.assertFalse(self.releases.exists())

    def test_an_inconsistent_index_records_nothing(self):
        result = self.record("2026.1122.1231", doc=DOC.replace("**missing** (P0)", "**partial** (P0)"))
        self.assertEqual(result.returncode, 2)
        self.assertFalse(self.releases.exists())


def git(repo, *arguments):
    return subprocess.run(["git", "-C", str(repo), *arguments], check=True, capture_output=True, text=True).stdout.strip()


class CoverageTests(unittest.TestCase):
    """--coverage and a record's coverage: each commit that changes Darni's code has a WebKit test or a reason."""

    def setUp(self):
        self.fixture = Fixture(self)
        self.repo = Path(self.fixture.dir.name) / "repo"
        self.repo.mkdir()
        git(self.repo, "init", "-q")
        self.commits = {}
        self.commit("base", {"README.md": "base"})

    def commit(self, name, files):
        for path, text in files.items():
            target = self.repo / path
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text(text, encoding="utf-8")
        git(self.repo, "add", "-A")
        git(self.repo, "-c", "user.name=t", "-c", "user.email=t@example.invalid", "commit", "-q", "-m", name)
        self.commits[name] = git(self.repo, "rev-parse", "HEAD")
        return self.commits[name]

    def ledger(self, entries):
        path = Path(self.fixture.dir.name) / "engine-parity-changes.json"
        path.write_text(json.dumps({"changes": {self.commits[name][:8]: entry for name, entry in entries.items()}}), encoding="utf-8")
        return path

    def index_with(self, **extra):
        rows = [dict(row) for row in INDEX]
        for row in rows:
            row.update(extra.get(row["id"].replace(".", "_"), {}))
        self.fixture.index.write_text(json.dumps(rows), encoding="utf-8")

    def run_coverage(self, ledger, rev_range=None):
        return subprocess.run(
            [sys.executable, "-I", str(SCRIPT), "--index", str(self.fixture.index), "--doc", str(self.fixture.doc),
             "--tests", str(self.fixture.tests), "--repo", str(self.repo), "--ledger", str(ledger),
             "--coverage", rev_range or f"{self.commits['base']}..HEAD"], capture_output=True, text=True)

    def test_each_kind_of_commit_is_covered_or_flagged_with_its_reason(self):
        self.commit("tested feature", {"shell/Sources/ReArc/Page.swift": "1"})
        self.commit("untested feature", {"shell/Sources/SidebarModel/Popups.swift": "1"})
        self.commit("engine switch", {"engine/patches/launch.patch": "1"})
        self.commit("pin bump", {"engine/CHROMIUM_PIN": "156.0.8078.114"})
        self.commit("refactor", {"shell/Sources/ReArc/Helpers.swift": "1"})
        self.commit("forgotten", {"shell/Sources/Onboarding/Act.swift": "1"})
        self.commit("tests only", {"shell/Tests/ReArcTests/X.swift": "1"})
        self.commit("bench only", {"shell/Sources/ArcBench/Probe.swift": "1", "perf/x.md": "1"})
        ledger = self.ledger({
            "tested feature": {"rows": ["navigation.load"]},
            "untested feature": {"rows": ["tabs.popups"]},
            "engine switch": {"chromiumOnly": "a Chromium launch switch"},
            "pin bump": {"chromiumOnly": "the engine pin"},
            "refactor": {"notAFeature": "one helper for two call sites"},
        })
        result = self.run_coverage(ledger)
        self.assertEqual(result.returncode, 0, result.stderr)
        out = result.stdout
        self.assertIn("6 commits change Darni's code; 2 have neither a WebKit test nor a reason it needs none.", out)
        self.assertIn(f"| `{self.commits['tested feature'][:8]}` | tested feature | navigation.load | navigation.load: WebKit test |", out)
        self.assertIn(f"| `{self.commits['untested feature'][:8]}` | untested feature | tabs.popups | **flagged**: "
                      "tabs.popups: no WebKit test and no Chromium-only reason |", out)
        self.assertIn("| engine switch | - | Chromium-only: a Chromium launch switch |", out)
        self.assertIn("| refactor | - | no feature: one helper for two call sites |", out)
        self.assertIn("| pin bump | - | Chromium-only: the engine pin |", out, "the engine pin is Darni's code")
        self.assertIn("| forgotten | - | **flagged**: no entry in docs/engine-parity-changes.json |", out)
        self.assertIn("2 more commits change no Darni code", out)

    def test_a_row_with_a_chromium_only_reason_needs_no_test(self):
        self.index_with(tabs_popups={"chromiumOnly": "nothing to test until WebKit opens tabs"})
        self.commit("feature", {"shell/Sources/ReArc/Popups.swift": "1"})
        result = self.run_coverage(self.ledger({"feature": {"rows": ["tabs.popups"]}}))
        self.assertIn("tabs.popups: Chromium-only: nothing to test until WebKit opens tabs |", result.stdout)
        self.assertIn("1 commit changes Darni's code; 0 have neither", result.stdout)

    def test_a_row_that_needs_the_screen_is_flagged_with_that_reason(self):
        self.index_with(tabs_popups={"screenOnly": "SwiftUI places the window"})
        self.commit("feature", {"shell/Sources/ReArc/Little.swift": "1"})
        result = self.run_coverage(self.ledger({"feature": {"rows": ["tabs.popups"]}}))
        self.assertIn("**flagged**: tabs.popups: no WebKit test; needs the screen: SwiftUI places the window |", result.stdout)

    def test_an_entry_naming_an_unknown_row_or_nothing_is_flagged(self):
        self.commit("typo", {"shell/Sources/ReArc/A.swift": "1"})
        self.commit("empty", {"shell/Sources/ReArc/B.swift": "1"})
        result = self.run_coverage(self.ledger({"typo": {"rows": ["tabs.popup"]}, "empty": {}}))
        self.assertIn("**flagged**: tabs.popup: not a row of the index |", result.stdout)
        self.assertIn("**flagged**: its entry names no row and gives no reason |", result.stdout)

    def test_merges_are_left_out_and_a_range_with_no_code_says_so(self):
        self.commit("docs", {"docs/x.md": "1"})
        result = self.run_coverage(self.ledger({}))
        self.assertIn("No commit in the range changes Darni's code.", result.stdout)
        self.assertIn("1 more commit changes no Darni code", result.stdout)

    def test_an_empty_reason_in_the_index_is_refused(self):
        self.index_with(tabs_popups={"chromiumOnly": " "})
        result = self.run_coverage(self.ledger({}))
        self.assertEqual(result.returncode, 2)
        self.assertIn("row tabs.popups has an empty \"chromiumOnly\"", result.stderr)

    def test_a_record_lists_the_commits_since_the_record_before_without_failing_the_pass(self):
        releases = Path(self.fixture.dir.name) / "releases"
        first = self.commits["base"]
        record = lambda version, commit: self.fixture.run(
            "--record-release", version, "--releases", str(releases), "--commit", commit[:8], "--date", "2026-11-24",
            "--repo", str(self.repo), "--ledger", str(ledger))
        ledger = self.ledger({})
        self.assertEqual(record("2026.1123.1255", first).returncode, 0)
        self.assertIn("| not checked |", (releases / "ENGINE-PARITY-HISTORY.md").read_text(encoding="utf-8"), "no record before the first")
        self.commit("tested feature", {"shell/Sources/ReArc/Page.swift": "1"})
        latest = self.commit("untested feature", {"shell/Sources/SidebarModel/Popups.swift": "1"})
        ledger = self.ledger({"tested feature": {"rows": ["navigation.load"]}})
        result = record("2026.1124.1270", latest)
        self.assertEqual(result.returncode, 0, "a flag never fails the pass: " + result.stderr)
        self.assertIn(f"NO WEBKIT TEST for {latest[:8]} (flagged, not blocking)", result.stderr)
        folder = releases / "1270" / "engine-parity"
        report_text = (folder / "REPORT.md").read_text(encoding="utf-8")
        self.assertIn(f"## Changes in `{first[:8]}..{latest[:8]}` and their WebKit tests", report_text)
        self.assertIn("2 commits change Darni's code; 1 has neither", report_text)
        notes = (folder / "NOTES.md").read_text(encoding="utf-8")
        self.assertIn("## Changes without a WebKit test or a Chromium-only reason", notes)
        self.assertIn(f"- `{latest[:8]}` untested feature: no entry in docs/engine-parity-changes.json", notes)
        made = json.loads((folder / "report.json").read_text(encoding="utf-8"))
        self.assertEqual(made["coverage"]["flagged"], [latest[:8]])
        history = (releases / "ENGINE-PARITY-HISTORY.md").read_text(encoding="utf-8")
        self.assertIn("| none | 1 | not written yet |", history.splitlines()[-2])


class ExpectedFailureTests(unittest.TestCase):
    """A test on a missing row passes on an expected failure; the report says the gap is confirmed."""

    TESTS = TESTS.replace("// An ordinary comment.\n    func testUntagged() {}", "// parity: tabs.popups\n    func testNewTabsOpen() {}")

    def test_an_expected_failure_confirms_the_gap_and_passes(self):
        log = LOG + ("Popups.swift:9: Expected failure in -[ReArcTests.WebKitEngineSmokeTests testNewTabsOpen]: XCTAssertEqual failed\n"
                     "Test Case '-[ReArcTests.WebKitEngineSmokeTests testNewTabsOpen]' passed (1.0 seconds).\n")
        fixture = Fixture(self, tests=self.TESTS, log=log)
        result = fixture.run()
        self.assertEqual(result.returncode, 0, result.stderr)
        made = fixture.report()
        row = next(r for r in made["matrix"] if r["id"] == "tabs.popups")
        self.assertEqual(row["webkitTests"], "passed, gap confirmed")
        self.assertEqual(row["tests"][0]["result"], "gap confirmed")
        self.assertEqual(made["rowsWithAPassingWebKitTest"], 3)
        self.assertIn("| New tabs from links | works | missing | passed, gap confirmed (testNewTabsOpen) |",
                      (fixture.out / "webkit-parity-report.md").read_text(encoding="utf-8"))

    def test_a_gap_that_closed_fails_the_row(self):
        log = LOG + ("Popups.swift:9: error: -[ReArcTests.WebKitEngineSmokeTests testNewTabsOpen] : Expected failure 'gap' but none recorded\n"
                     "Test Case '-[ReArcTests.WebKitEngineSmokeTests testNewTabsOpen]' failed (1.0 seconds).\n")
        fixture = Fixture(self, tests=self.TESTS, log=log)
        result = fixture.run()
        self.assertEqual(result.returncode, 1)
        self.assertIn("FAILED tabs.popups", result.stderr)


class ParsingTests(unittest.TestCase):
    def test_a_test_that_failed_once_stays_failed(self):
        with tempfile.TemporaryDirectory() as folder:
            log = Path(folder) / "log"
            log.write_text("Test Case '-[ReArcTests.S testA]' failed (1.0 seconds).\n"
                           "Test Case '-[ReArcTests.S testA]' passed (1.0 seconds).\n", encoding="utf-8")
            self.assertEqual(report.test_results(log), {"S.testA": "failed"})

    def test_a_parity_comment_does_not_reach_past_other_code(self):
        with tempfile.TemporaryDirectory() as folder:
            (Path(folder) / "T.swift").write_text(
                "final class T: XCTestCase {\n    // parity: a.b\n    let x = 1\n    func testOne() {}\n}\n", encoding="utf-8")
            self.assertEqual(report.tagged_tests(folder), {})


class RepositoryTests(unittest.TestCase):
    """The real index, document and tests agree."""

    def test_the_repository_is_consistent(self):
        result = subprocess.run(
            [sys.executable, "-I", str(SCRIPT), "--check", "--index", str(REPO / "docs/engine-parity.json"),
             "--doc", str(REPO / "docs/ENGINE-PARITY.md"), "--tests", str(REPO / "shell/Tests/ReArcTests/WebKitEngine")],
            capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)


if __name__ == "__main__":
    unittest.main()
