"""check-webkit.sh in a throwaway checkout with a stub `swift`: exit statuses, the report, the
arguments swift gets, and Package.resolved put back. No real build, no app."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

SCRIPTS = Path(__file__).resolve().parents[2]

INDEX = [
    {"id": "navigation.load", "area": "Pages", "feature": "Page load", "chromium": "works", "webkit": "works", "note": ""},
    {"id": "tabs.popups", "area": "Tabs", "feature": "New tabs from links", "chromium": "works", "webkit": "missing", "note": ""},
]
DOC = """| Feature | Chromium | WebKit | On WebKit | ID |
|---|---|---|---|---|
| Page load | works | **works** | | `navigation.load` |
| New tabs from links | works | **missing** | | `tabs.popups` |
"""
TESTS = """final class WebKitEngineSmokeTests: XCTestCase {
    // parity: navigation.load
    func testAPageLoads() async throws {}
}
"""

# Records each call and its Chromium variables; `swift test` drops Package.resolved's pin as the real one does.
FAKE_SWIFT = r"""#!/bin/bash
echo "$* | out=${REARC_CHROMIUM_OUT-unset} include=${REARC_ENGINE_INCLUDE-unset}" >> "$STUB_CALLS"
package=""
args=("$@")
for ((i = 0; i < ${#args[@]}; i++)); do [[ ${args[i]} == --package-path ]] && package="${args[i+1]}"; done
case "$1" in
  build)
    if [[ -n ${STUB_BUILD_FAILS:-} ]]; then echo "Sources/ReArc/X.swift:1:1: error: nope"; exit 1; fi
    echo "Build complete!" ;;
  test)
    echo '{"pins": []}' > "$package/Package.resolved"
    echo "Test Case '-[ReArcTests.WebKitEngineSmokeTests testAPageLoads]' ${STUB_RESULT:-passed} (0.1 seconds)."
    if [[ -n ${STUB_OTHER_FAILS:-} ]]; then echo "✘ Test syncWaits() recorded an issue"; exit 1; fi
    [[ ${STUB_RESULT:-passed} == passed ]] || exit 1 ;;
esac
"""


class CheckWebKitTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="rearc-webkit-check-")
        self.addCleanup(self.temp.cleanup)
        self.repo = Path(self.temp.name) / "repo"
        shell = self.repo / "shell"
        (shell / "scripts" / "release").mkdir(parents=True)
        (shell / "Tests" / "ReArcTests" / "WebKitEngine").mkdir(parents=True)
        (self.repo / "docs").mkdir()
        shutil.copy(SCRIPTS / "check-webkit.sh", shell / "scripts" / "check-webkit.sh")
        shutil.copy(SCRIPTS / "release" / "webkit-parity-report.py", shell / "scripts" / "release" / "webkit-parity-report.py")
        (self.repo / "docs" / "engine-parity.json").write_text(json.dumps(INDEX), encoding="utf-8")
        (self.repo / "docs" / "ENGINE-PARITY.md").write_text(DOC, encoding="utf-8")
        (shell / "Tests" / "ReArcTests" / "WebKitEngine" / "WebKitEngineSmokeTests.swift").write_text(TESTS, encoding="utf-8")
        self.resolved = shell / "Package.resolved"
        self.resolved.write_text('{"pins": ["sparkle"]}\n', encoding="utf-8")
        tools = Path(self.temp.name) / "bin"
        tools.mkdir()
        (tools / "swift").write_text(FAKE_SWIFT)
        (tools / "swift").chmod(0o755)
        self.calls = Path(self.temp.name) / "calls.txt"
        self.calls.write_text("")
        self.env = {**os.environ, "PATH": f"{tools}:{os.environ['PATH']}", "STUB_CALLS": str(self.calls),
                    "REARC_CHROMIUM_OUT": "/engine/out", "REARC_ENGINE_INCLUDE": "/engine/include"}
        for command in (["init", "-q"], ["add", "-A"],
                        ["-c", "user.name=t", "-c", "user.email=t@example.invalid", "commit", "-q", "-m", "fixture"]):
            subprocess.run(["git", "-C", str(self.repo), *command], check=True, capture_output=True)
        self.report = Path(self.temp.name) / "report"

    def run_check(self, *arguments, **env):
        return subprocess.run([str(self.repo / "shell" / "scripts" / "check-webkit.sh"), "--report", str(self.report), *arguments],
                              capture_output=True, text=True, env={**self.env, **env})

    def swift_calls(self):
        return self.calls.read_text().splitlines()

    def made(self):
        return json.loads((self.report / "webkit-parity-report.json").read_text(encoding="utf-8"))

    def test_a_passing_build_writes_the_report_and_restores_package_resolved(self):
        result = self.run_check()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.made()["result"], "pass")
        self.assertIn("Darni", self.made()["build"])
        self.assertTrue((self.report / "webkit-parity-report.md").exists())
        self.assertEqual(self.resolved.read_text(), '{"pins": ["sparkle"]}\n', "swift test's change is undone")
        calls = self.swift_calls()
        self.assertEqual(len(calls), 2)
        self.assertTrue(calls[0].startswith("build "))
        self.assertIn("--filter ReArcTests\\.WebKitEngine", calls[1])

    def test_swift_never_sees_the_chromium_variables(self):
        self.run_check()
        for call in self.swift_calls():
            self.assertTrue(call.endswith("out=unset include=unset"), call)

    def test_full_runs_the_whole_suite(self):
        self.assertEqual(self.run_check("--full").returncode, 0)
        self.assertNotIn("--filter", self.swift_calls()[1])

    def test_scratch_path_and_label_are_passed_on(self):
        result = self.run_check("--scratch-path", "/tmp/scratch-here", "--label", "Darni 2026.1122.9999")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(all("--scratch-path /tmp/scratch-here" in call for call in self.swift_calls()))
        self.assertEqual(self.made()["build"], "Darni 2026.1122.9999")

    def test_a_failing_webkit_test_fails_the_pass(self):
        result = self.run_check(STUB_RESULT="failed")
        self.assertEqual(result.returncode, 1)
        self.assertEqual(self.made()["failedRows"], ["navigation.load"])
        self.assertIn("FAILED navigation.load", result.stderr)

    def test_a_build_failure_fails_the_pass_without_running_tests(self):
        result = self.run_check(STUB_BUILD_FAILS="1")
        self.assertEqual(result.returncode, 1)
        self.assertEqual(len(self.swift_calls()), 1)
        self.assertFalse(self.made()["buildOK"])
        self.assertIn("error: nope", result.stderr)

    def test_a_failure_outside_the_webkit_tests_fails_the_pass_but_not_the_report(self):
        result = self.run_check("--full", STUB_OTHER_FAILS="1")
        self.assertEqual(result.returncode, 1)
        self.assertEqual(self.made()["result"], "pass")
        self.assertIn("outside the WebKit engine tests", result.stderr)
        self.assertIn("syncWaits", result.stderr)

    def test_a_document_that_disagrees_with_the_index_stops_before_any_build(self):
        (self.repo / "docs" / "ENGINE-PARITY.md").write_text(DOC.replace("**missing**", "**works**"), encoding="utf-8")
        result = self.run_check()
        self.assertEqual(result.returncode, 2)
        self.assertEqual(self.swift_calls(), [])
        self.assertIn("tabs.popups says works/works, the index says works/missing", result.stderr)

    def test_package_resolved_with_changes_of_its_own_is_left_alone(self):
        self.resolved.write_text('{"pins": ["mine"]}\n', encoding="utf-8")
        self.assertEqual(self.run_check().returncode, 0)
        self.assertEqual(self.resolved.read_text(), '{"pins": []}\n', "not reverted to the committed file")

    def test_an_unknown_option_is_refused(self):
        result = self.run_check("--screen")
        self.assertEqual(result.returncode, 64)
        self.assertEqual(self.swift_calls(), [])


if __name__ == "__main__":
    unittest.main()
