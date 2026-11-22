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
