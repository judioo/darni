"""rc-tests-summary.py on fixture logs: what it counts in a `swift test` log, how it matches the
`// parity:` tests, the verdict, and the SUMMARY.md it writes. No test suite runs here."""
import importlib.util
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / "rc-tests-summary.py"
spec = importlib.util.spec_from_file_location("rc_tests_summary", SCRIPT)
summary = importlib.util.module_from_spec(spec)
spec.loader.exec_module(summary)

# The shape of a real log: build noise, XCTest bundles, then Swift Testing runs.
PASSING = """[1/1] Compiling plugin GenerateManual
Build complete! (12.34s)
Test Suite 'All tests' started at 2026-11-24 10:00:00.000.
Test Suite 'TabTests' started at 2026-11-24 10:00:00.001.
Test Case '-[ReArcTests.TabTests testTitle]' started.
Test Case '-[ReArcTests.TabTests testTitle]' passed (0.001 seconds).
Test Case '-[ReArcTests.TabTests testClose]' started.
Test Case '-[ReArcTests.TabTests testClose]' passed (0.002 seconds).
Test Case '-[SidebarModelTests.LookFixture testWrite]' started.
/work/shell/Tests/SidebarModelTests/LookFixture.swift:29: -[SidebarModelTests.LookFixture testWrite] : Test skipped - set REARC_LOOK_FIXTURE
Test Case '-[SidebarModelTests.LookFixture testWrite]' skipped (0.001 seconds).
Test Suite 'TabTests' passed at 2026-11-24 10:00:00.010.
\t Executed 3 tests, with 1 test skipped and 0 failures (0 unexpected) in 0.004 (0.004) seconds
◇ Test run started.
↳ Testing Library Version: 2403
◇ Suite FrameDiffTests started.
◇ Test spacesInSidebarOrder() started.
✔ Test spacesInSidebarOrder() passed after 0.001 seconds.
◇ Test domains(pair:) started.
◇ Test case passing 1 argument pair → ("a", "b", true) to domains(pair:) started.
✔ Test case passing 1 argument pair → ("a", "b", true) to domains(pair:) passed after 0.001 seconds.
✔ Test domains(pair:) with 11 test cases passed after 0.010 seconds.
◇ Test "A title in quotes" started.
✔ Test "A title in quotes" passed after 0.001 seconds.
✔ Suite FrameDiffTests passed after 0.004 seconds.
✔ Test run with 3 tests in 1 suites passed after 0.027 seconds.
"""

FAILING = PASSING + """Test Case '-[ReArcTests.SyncTests testMerge]' started.
/work/rc/worktree/shell/Tests/ReArcTests/SyncTests.swift:41: error: -[ReArcTests.SyncTests testMerge] : XCTAssertEqual failed: ("1") is not equal to ("2")
/work/rc/worktree/shell/Tests/ReArcTests/SyncTests.swift:44: error: -[ReArcTests.SyncTests testMerge] : a second failure
Test Case '-[ReArcTests.SyncTests testMerge]' failed (0.004 seconds).
◇ Test syncWaits() started.
✘ Test syncWaits() recorded an issue at SyncWaitTests.swift:12:5: Expectation failed: (waited → 3) == 2
✘ Test syncWaits() failed after 0.020 seconds with 1 issue.
◇ Test regions(text:) started.
✘ Test regions(text:) recorded an issue with 1 argument text → "x" at RegionTests.swift:7:9: Expectation failed: parsed
✘ Test regions(text:) with 4 test cases failed after 0.020 seconds with 1 issue.
➜ Test needsTheScreen() skipped: "no screen here"
✘ Test run with 3 tests in 1 suites failed after 0.050 seconds with 2 issues.
"""

CRASHED = """Test Case '-[ReArcTests.TabTests testTitle]' started.
Test Case '-[ReArcTests.TabTests testTitle]' passed (0.001 seconds).
Test Case '-[ReArcTests.CrashTests testBoom]' started.
error: Exited with unexpected signal code 11
◇ Test neverComesBack() started.
"""

BUILD_FAILED = """[3/40] Compiling ReArc BrowserViewModel.swift
/work/rc/worktree/shell/Sources/ReArc/BrowserViewModel.swift:10:5: error: cannot find 'nope' in scope
error: fatalError
"""

TAGGED = {
    "ReArcTests/WebKitEngine/SmokeTests.swift": """import XCTest

final class SmokeTests: XCTestCase {
    // parity: navigation.load
    func testAPageLoads() async throws {}

    // parity: tabs.title, tabs.session
    @MainActor
    func testTheTitleFollows() {}

    func testUntagged() {}

    // parity: find.count
    func testFindCounts() {}
}

extension SmokeTests {
    // parity: zoom.page
    func testZoom() {}
}
""",
    "ReArcTests/RegionTests.swift": """import Testing

struct RegionTests {
    // parity: capture.page
    @Test func regionsParse() {}

    // parity: print.pdf
    @Test(arguments: ["a", "b"]) func regions(text: String) {}

    @Test func untagged() {}
}
""",
}

PARITY_LOG = """Test Case '-[ReArcTests.SmokeTests testAPageLoads]' passed (0.1 seconds).
Test Case '-[ReArcTests.SmokeTests testTheTitleFollows]' failed (0.1 seconds).
Test Case '-[ReArcTests.SmokeTests testZoom]' skipped (0.1 seconds).
✔ Test regionsParse() passed after 0.001 seconds.
✘ Test regions(text:) with 2 test cases failed after 0.020 seconds with 1 issue.
"""


class ParseLogTests(unittest.TestCase):
    def test_a_passing_log_is_counted_by_runner(self):
        parsed = summary.parse_log(PASSING)
        self.assertEqual(parsed["xctestCounts"], {"passed": 2, "failed": 0, "skipped": 1, "unfinished": 0})
        self.assertEqual(parsed["swiftTestingCounts"], {"passed": 3, "failed": 0, "skipped": 0, "unfinished": 0},
                         "a test with arguments is one test; its cases and the run's own line are not tests")
        self.assertEqual(parsed["failed"], [])
        self.assertEqual(parsed["unfinished"], [])
        self.assertEqual(parsed["xctest"]["ReArcTests.TabTests.testTitle"], "passed")
        self.assertEqual(parsed["xctest"]["SidebarModelTests.LookFixture.testWrite"], "skipped")

    def test_failed_tests_are_named_with_their_first_message(self):
        parsed = summary.parse_log(FAILING)
        self.assertEqual(parsed["xctestCounts"], {"passed": 2, "failed": 1, "skipped": 1, "unfinished": 0})
        self.assertEqual(parsed["swiftTestingCounts"], {"passed": 3, "failed": 2, "skipped": 1, "unfinished": 0})
        self.assertEqual(parsed["failed"], ["ReArcTests.SyncTests.testMerge", "syncWaits()", "regions(text:)"])
        self.assertEqual(parsed["details"]["ReArcTests.SyncTests.testMerge"],
                         'XCTAssertEqual failed: ("1") is not equal to ("2") (shell/Tests/ReArcTests/SyncTests.swift:41)',
                         "the first message, and the path without the checkout")
        self.assertEqual(parsed["details"]["syncWaits()"], "Expectation failed: (waited → 3) == 2 (SyncWaitTests.swift:12)")
        self.assertEqual(parsed["details"]["regions(text:)"], "Expectation failed: parsed (RegionTests.swift:7)")

    def test_a_test_that_ran_twice_and_failed_once_failed(self):
        log = ("Test Case '-[A.B testC]' passed (0.1 seconds).\n" "Test Case '-[A.B testC]' failed (0.1 seconds).\n"
               "Test Case '-[A.B testC]' passed (0.1 seconds).\n")
        parsed = summary.parse_log(log)
        self.assertEqual(parsed["xctestCounts"]["failed"], 1)
        self.assertEqual(parsed["xctestCounts"]["passed"], 0)
        self.assertEqual(parsed["failed"], ["A.B.testC"])

    def test_a_test_that_started_and_has_no_result_did_not_finish(self):
        parsed = summary.parse_log(CRASHED)
        self.assertEqual(parsed["xctestCounts"], {"passed": 1, "failed": 0, "skipped": 0, "unfinished": 1})
        self.assertEqual(parsed["swiftTestingCounts"]["unfinished"], 1)
        self.assertEqual(parsed["unfinished"], ["ReArcTests.CrashTests.testBoom", "neverComesBack()"])

    def test_a_build_failure_has_no_tests_and_keeps_its_errors(self):
        parsed = summary.parse_log(BUILD_FAILED)
        self.assertEqual(sum(parsed["xctestCounts"].values()) + sum(parsed["swiftTestingCounts"].values()), 0)
        self.assertEqual(len(parsed["errors"]), 2)
        self.assertIn("cannot find 'nope' in scope", parsed["errors"][0])

    def test_sf_symbol_marks_are_read_like_the_plain_ones(self):
        parsed = summary.parse_log("\U00100000  Test alpha() passed after 0.001 seconds.\n\U00100001  Test beta() failed after 0.001 seconds with 1 issue.\n")
        self.assertEqual(parsed["swiftTestingCounts"]["passed"], 1)
        self.assertEqual(parsed["failed"], ["beta()"])

    def test_two_swift_testing_tests_of_one_name_are_both_counted(self):
        parsed = summary.parse_log("✔ Test loads() passed after 0.001 seconds.\n✔ Test loads() passed after 0.002 seconds.\n")
        self.assertEqual(parsed["swiftTestingCounts"]["passed"], 2)


class VerdictTests(unittest.TestCase):
    def test_pass_needs_status_zero_tests_and_no_failure(self):
        self.assertEqual(summary.verdict(summary.parse_log(PASSING), 0), ("PASS", ""))
        self.assertEqual(summary.verdict(summary.parse_log(PASSING), None), ("PASS", ""))

    def test_a_failed_test_fails_it(self):
        self.assertEqual(summary.verdict(summary.parse_log(FAILING), 1), ("FAIL", "3 failed"))

    def test_an_unfinished_test_fails_it_even_with_status_zero(self):
        self.assertEqual(summary.verdict(summary.parse_log(CRASHED), 0), ("FAIL", "2 did not finish"))

    def test_no_tests_fails_it(self):
        result, why = summary.verdict(summary.parse_log(BUILD_FAILED), 1)
        self.assertEqual(result, "FAIL")
        self.assertIn("no test ran", why)

    def test_a_nonzero_status_without_a_failed_test_fails_it(self):
        result, why = summary.verdict(summary.parse_log(PASSING), 1)
        self.assertEqual(result, "FAIL")
        self.assertIn("ended with status 1", why)


class ParityTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="darni-rc-tests-")
        self.addCleanup(self.temp.cleanup)
        self.tests = Path(self.temp.name) / "Tests"
        for name, text in TAGGED.items():
            (self.tests / name).parent.mkdir(parents=True, exist_ok=True)
            (self.tests / name).write_text(text, encoding="utf-8")

    def test_tagged_tests_are_found_with_their_rows(self):
        tagged = {(item["suite"], item["test"]): item for item in summary.parity_tests(self.tests)}
        self.assertEqual(sorted(tagged), [("RegionTests", "regions"), ("RegionTests", "regionsParse"), ("SmokeTests", "testAPageLoads"),
                                          ("SmokeTests", "testFindCounts"), ("SmokeTests", "testTheTitleFollows"), ("SmokeTests", "testZoom")])
        self.assertEqual(tagged[("SmokeTests", "testTheTitleFollows")]["rows"], ["tabs.title", "tabs.session"])
        self.assertEqual(tagged[("SmokeTests", "testAPageLoads")]["file"], "ReArcTests/WebKitEngine/SmokeTests.swift")
        self.assertTrue(tagged[("SmokeTests", "testZoom")]["xctest"], "an extension of a test class")
        self.assertFalse(tagged[("RegionTests", "regionsParse")]["xctest"])

    def test_each_tagged_test_gets_its_result_from_the_log(self):
        rows = summary.parity_results(summary.parity_tests(self.tests), summary.parse_log(PARITY_LOG))
        self.assertEqual({item["test"]: item["result"] for item in rows},
                         {"testAPageLoads": "passed", "testTheTitleFollows": "failed", "testFindCounts": "not run",
                          "testZoom": "skipped", "regionsParse": "passed", "regions": "failed"})

    def test_a_tests_folder_without_tags_gives_none(self):
        empty = Path(self.temp.name) / "Empty"
        empty.mkdir()
        self.assertEqual(summary.parity_tests(empty), [])


class SummaryTextTests(unittest.TestCase):
    def text(self, log, exit_status, parity=()):
        return summary.summary(summary.parse_log(log), list(parity), "1255", "a9ed9926aaaa", exit_status,
                               "2026-11-24 10:00:05 +0400", "2026-11-24 10:07:41 +0400", 456, "2026.1123.1255",
                               "shell/dist/rc-1255/swift-test.log")

    def test_a_passing_summary(self):
        text = self.text(PASSING, 0)
        self.assertTrue(text.startswith("# Tests at build 1255\n"))
        self.assertIn("- Commit `a9ed9926aaaa`, Darni 2026.1123.1255.", text)
        self.assertIn("- Started 2026-11-24 10:00:05 +0400, ended 2026-11-24 10:07:41 +0400 (7 min 36 s).", text)
        self.assertIn("- **Result: PASS.** 6 tests: 5 passed, 0 failed, 1 skipped.", text)
        self.assertIn("- `swift test` ended with status 0.", text)
        self.assertIn("- Full log: `shell/dist/rc-1255/swift-test.log` (not in git).", text)
        self.assertIn("| XCTest | 2 | 0 | 1 | 0 |", text)
        self.assertIn("| Swift Testing | 3 | 0 | 0 | 0 |", text)
        self.assertIn("| All | 5 | 0 | 1 | 0 |", text)
        self.assertIn("## Failed tests\n\nNone.\n", text)
        self.assertIn("No test in `shell/Tests` is tagged `// parity:`.", text)

    def test_a_failing_summary_names_the_failed_tests(self):
        text = self.text(FAILING, 1)
        self.assertIn("- **Result: FAIL.** 10 tests: 5 passed, 3 failed, 2 skipped.\n", text)
        self.assertIn('- `ReArcTests.SyncTests.testMerge`: XCTAssertEqual failed: ("1") is not equal to ("2") (shell/Tests/ReArcTests/SyncTests.swift:41)', text)
        self.assertIn("- `syncWaits()`: Expectation failed: (waited → 3) == 2 (SyncWaitTests.swift:12)", text)
        self.assertNotIn("None.", text)

    def test_unfinished_tests_are_listed_as_such(self):
        text = self.text(CRASHED, 1)
        self.assertIn("- **Result: FAIL.** 3 tests: 1 passed, 0 failed, 0 skipped, 2 did not finish.\n", text)
        self.assertIn("- `ReArcTests.CrashTests.testBoom`: started and did not finish (a crash or a hang; see the log)", text)

    def test_a_build_failure_shows_the_errors_without_the_checkouts_path(self):
        text = self.text(BUILD_FAILED, 1)
        self.assertIn("- **Result: FAIL.** 0 tests: 0 passed, 0 failed, 0 skipped. No test ran: the build failed, or the run did not start.", text)
        self.assertIn("Errors in the log:", text)
        self.assertIn("- `shell/Sources/ReArc/BrowserViewModel.swift:10:5: error: cannot find 'nope' in scope`", text)

    def test_parity_tests_are_listed_by_result_with_the_failed_first(self):
        parity = [
            {"suite": "SmokeTests", "test": "testAPageLoads", "rows": ["navigation.load"], "file": "A.swift", "xctest": True, "result": "passed"},
            {"suite": "SmokeTests", "test": "testFind", "rows": ["find.count"], "file": "A.swift", "xctest": True, "result": "not run"},
            {"suite": "SmokeTests", "test": "testTitle", "rows": ["tabs.title", "tabs.session"], "file": "A.swift", "xctest": True, "result": "failed"},
        ]
        text = self.text(PASSING, 0, parity)
        self.assertIn("3 tests, 1 passed, 1 failed, 1 not run.", text)
        table = [line for line in text.splitlines() if line.startswith("| ") and "SmokeTests" in line]
        self.assertEqual(table, ["| failed | `SmokeTests.testTitle` | tabs.title, tabs.session | `A.swift` |",
                                 "| not run | `SmokeTests.testFind` | find.count | `A.swift` |",
                                 "| passed | `SmokeTests.testAPageLoads` | navigation.load | `A.swift` |"])

    def test_a_run_that_failed_without_a_failed_test_says_so(self):
        text = self.text(PASSING, 1)
        self.assertIn("- **Result: FAIL.** 6 tests: 5 passed, 0 failed, 1 skipped. `swift test` ended with status 1 though no test in the log failed: the run itself failed.", text)

    def test_durations_read_like_a_clock(self):
        self.assertEqual(summary.duration(42), "42 s")
        self.assertEqual(summary.duration(456), "7 min 36 s")
        self.assertEqual(summary.duration(3725), "1 h 2 min")


class CommandTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="darni-rc-tests-")
        self.addCleanup(self.temp.cleanup)
        self.dir = Path(self.temp.name)
        self.out = self.dir / "docs" / "releases" / "1255" / "tests" / "SUMMARY.md"

    def run_summary(self, log_text, *extra):
        log = self.dir / "swift-test.log"
        log.write_text(log_text, encoding="utf-8")
        return subprocess.run([sys.executable, "-I", str(SCRIPT), "--log", str(log), "--build", "1255", "--commit", "a9ed9926",
                               "--out", str(self.out), *extra], capture_output=True, text=True)

    def test_it_writes_the_summary_and_exits_0_on_pass(self):
        result = self.run_summary(PASSING, "--exit-status", "0", "--started", "1795500000", "--ended", "1795500456")
        self.assertEqual(result.returncode, 0, result.stderr)
        text = self.out.read_text(encoding="utf-8")
        self.assertIn("**Result: PASS.**", text)
        self.assertNotIn("ended with status 0 though", text)
        self.assertRegex(text, r"- Started \d{4}-\d\d-\d\d \d\d:\d\d:\d\d [+-]\d{4}, ended .* \(7 min 36 s\)\.")
        self.assertIn("rc-tests: PASS: 5 passed, 0 failed, 1 skipped, 0 did not finish", result.stdout)

    def test_it_writes_the_summary_and_exits_1_on_fail(self):
        result = self.run_summary(FAILING, "--exit-status", "1")
        self.assertEqual(result.returncode, 1)
        self.assertIn("**Result: FAIL.**", self.out.read_text(encoding="utf-8"))
        self.assertIn("rc-tests: FAIL", result.stdout)

    def test_the_parity_tests_come_from_the_tests_folder(self):
        tests = self.dir / "Tests"
        tests.mkdir()
        (tests / "SmokeTests.swift").write_text(TAGGED["ReArcTests/WebKitEngine/SmokeTests.swift"], encoding="utf-8")
        self.run_summary(PARITY_LOG, "--tests", str(tests))
        text = self.out.read_text(encoding="utf-8")
        self.assertIn("| failed | `SmokeTests.testTheTitleFollows` | tabs.title, tabs.session | `SmokeTests.swift` |", text)
        self.assertIn("| passed | `SmokeTests.testAPageLoads` | navigation.load | `SmokeTests.swift` |", text)

    def test_a_log_that_cannot_be_read_is_2_and_writes_nothing(self):
        result = subprocess.run([sys.executable, "-I", str(SCRIPT), "--log", str(self.dir / "none.log"), "--build", "1", "--commit", "a",
                                 "--out", str(self.out)], capture_output=True, text=True)
        self.assertEqual(result.returncode, 2)
        self.assertFalse(self.out.exists())


if __name__ == "__main__":
    unittest.main()
