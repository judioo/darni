"""rc-tests.sh in a throwaway repository with a stub `swift`: the worktree it makes and removes,
the lock it holds, the log and summary it keeps, and what it does when the run fails or is
stopped. The real suite never runs here; the lock is a temporary path."""
import os
from pathlib import Path
import shutil
import signal
import subprocess
import tempfile
import time
import unittest

SCRIPTS = Path(__file__).resolve().parents[2]

TESTS_V1 = """final class SmokeTests: XCTestCase {
    // parity: navigation.load
    func testAPageLoads() async throws {}
}
"""

# Notes where it ran and whether the lock was held; rewrites Package.resolved as the real one does.
FAKE_SWIFT = r"""#!/bin/bash
package=""
args=("$@")
for ((i = 0; i < ${#args[@]}; i++)); do [[ ${args[i]} == --package-path ]] && package="${args[i+1]}"; done
{
  echo "args=$*"
  echo "held=${DARNI_HEAVY_JOB_HELD-none} owner=$(sed -n 's/^name=//p' "$DARNI_HEAVY_JOB_LOCK/owner" 2>/dev/null)"
  echo "chromium=${REARC_CHROMIUM_OUT-unset}"
  echo "marker=$(cat "$package/marker.txt")"
} >> "$STUB_CALLS"
echo '{"pins": []}' > "$package/Package.resolved"
if [[ -n ${STUB_HANGS:-} ]]; then echo $$ > "$STUB_HANGS"; exec sleep 60; fi
echo "Test Case '-[ReArcTests.SmokeTests testAPageLoads]' started."
echo "Test Case '-[ReArcTests.SmokeTests testAPageLoads]' ${STUB_RESULT:-passed} (0.1 seconds)."
echo "✔ Test spaces() passed after 0.001 seconds."
[[ ${STUB_RESULT:-passed} == passed ]] || exit 1
"""


class RCTestsTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="darni-rc-tests-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.repo = self.root / "repo"
        shell = self.repo / "shell"
        (shell / "scripts" / "release").mkdir(parents=True)
        for name in ("heavy-job.sh", "release/rc-tests.sh", "release/rc-tests-summary.py", "release/version.py"):
            shutil.copy(SCRIPTS / name, shell / "scripts" / name)
        (shell / "Tests" / "ReArcTests").mkdir(parents=True)
        (shell / "Tests" / "ReArcTests" / "SmokeTests.swift").write_text(TESTS_V1, encoding="utf-8")
        (shell / "Package.resolved").write_text('{"pins": ["sparkle"]}\n')
        (shell / "marker.txt").write_text("first\n")
        (shell / ".gitignore").write_text("dist/\n.build/\n")
        self.git("init", "-q")
        self.git("add", "-A")
        self.git("commit", "-q", "-m", "the candidate")
        self.candidate = self.head()
        (shell / "marker.txt").write_text("second\n")
        self.git("commit", "-q", "-am", "work after the candidate")
        tools = self.root / "bin"
        tools.mkdir()
        (tools / "swift").write_text(FAKE_SWIFT)
        (tools / "swift").chmod(0o755)
        self.calls = self.root / "calls.txt"
        self.calls.write_text("")
        self.lock = self.root / "heavy.lock"
        self.env = {**os.environ, "PATH": f"{tools}:{os.environ['PATH']}", "STUB_CALLS": str(self.calls),
                    "DARNI_HEAVY_JOB_LOCK": str(self.lock), "DARNI_HEAVY_JOB_POLL": "0.05",
                    "REARC_CHROMIUM_OUT": "/engine/out", "REARC_ENGINE_INCLUDE": "/engine/include"}
        self.env.pop("DARNI_HEAVY_JOB_HELD", None)
        self.script = shell / "scripts" / "release" / "rc-tests.sh"
        self.out = shell / "dist" / "rc-1"
        self.summary = self.repo / "docs" / "releases" / "1" / "tests" / "SUMMARY.md"

    def git(self, *arguments):
        return subprocess.run(["git", "-C", str(self.repo), "-c", "user.name=t", "-c", "user.email=t@example.invalid", *arguments],
                              check=True, capture_output=True, text=True).stdout

    def head(self):
        return self.git("rev-parse", "HEAD").strip()

    def rc_tests(self, *arguments, **env):
        return subprocess.run([str(self.script), *arguments], capture_output=True, text=True, env={**self.env, **env}, timeout=60)

    def called(self):
        return dict(line.split("=", 1) for line in self.calls.read_text().splitlines())

    def worktrees(self):
        return [line for line in self.git("worktree", "list", "--porcelain").splitlines() if line.startswith("worktree ")]

    def test_a_passing_run_keeps_the_log_and_the_summary_and_removes_the_worktree(self):
        result = self.rc_tests(self.candidate, "1")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        log = (self.out / "swift-test.log").read_text(encoding="utf-8")
        self.assertIn("Test Case '-[ReArcTests.SmokeTests testAPageLoads]' passed", log)
        text = self.summary.read_text(encoding="utf-8")
        self.assertIn("# Tests at build 1\n", text)
        self.assertIn(f"- Commit `{self.candidate}`, Darni ", text)
        self.assertRegex(text, r"- Started \d{4}-\d\d-\d\d \d\d:\d\d:\d\d [+-]\d{4}, ended \d{4}-")
        self.assertIn("- **Result: PASS.** 2 tests: 2 passed, 0 failed, 0 skipped.", text)
        self.assertIn("- Full log: `shell/dist/rc-1/swift-test.log` (not in git).", text)
        self.assertIn("| passed | `SmokeTests.testAPageLoads` | navigation.load | `ReArcTests/SmokeTests.swift` |", text)
        self.assertFalse((self.out / "worktree").exists())
        self.assertEqual(len(self.worktrees()), 1, "only the checkout itself is left")

    def test_the_suite_runs_on_the_named_commit_in_a_worktree_under_dist(self):
        self.rc_tests(self.candidate, "1")
        called = self.called()
        self.assertEqual(called["args"], f"test --package-path {self.out / 'worktree' / 'shell'}")
        self.assertEqual(called["marker"], "first", "the candidate's files, not the checkout's newer ones")
        self.assertEqual((self.repo / "shell" / "marker.txt").read_text(), "second\n")
        self.assertEqual(self.git("status", "--porcelain", "--untracked-files=no"), "", "the checkout itself is untouched")

    def test_the_run_holds_the_heavy_job_lock_and_never_sees_the_chromium_variables(self):
        self.rc_tests(self.candidate, "1")
        self.assertEqual(self.called()["held"], "rc-tests owner=rc-tests")
        self.assertEqual(self.called()["chromium"], "unset")
        self.assertFalse(self.lock.exists(), "freed afterwards")

    def test_package_resolved_is_left_as_committed(self):
        self.rc_tests(self.candidate, "1")
        self.assertEqual((self.repo / "shell" / "Package.resolved").read_text(), '{"pins": ["sparkle"]}\n')
        self.assertEqual(self.git("status", "--porcelain", "--", "shell/Package.resolved"), "")

    def test_a_failing_run_writes_the_summary_and_exits_1(self):
        result = self.rc_tests(self.candidate, "1", STUB_RESULT="failed")
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        text = self.summary.read_text(encoding="utf-8")
        self.assertIn("- **Result: FAIL.** 2 tests: 1 passed, 1 failed, 0 skipped.", text)
        self.assertIn("- `swift test` ended with status 1.", text)
        self.assertIn("- `ReArcTests.SmokeTests.testAPageLoads`", text)
        self.assertIn("| failed | `SmokeTests.testAPageLoads` |", text)
        self.assertFalse((self.out / "worktree").exists())
        self.assertFalse(self.lock.exists())

    def test_a_worktree_left_by_a_killed_run_is_replaced(self):
        self.git("worktree", "add", "--detach", str(self.out / "worktree"), "HEAD")
        (self.out / "worktree" / "shell" / "Package.resolved").write_text("{}\n")
        result = self.rc_tests(self.candidate, "1")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.called()["marker"], "first")
        self.assertEqual(len(self.worktrees()), 1)

    def test_a_stopped_run_stops_swift_removes_the_worktree_and_frees_the_lock(self):
        pid_file = self.root / "swift.pid"
        run = subprocess.Popen([str(self.script), self.candidate, "1"], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
                               env={**self.env, "STUB_HANGS": str(pid_file)})
        self.addCleanup(run.kill)
        deadline = time.monotonic() + 20
        while not (pid_file.exists() and pid_file.read_text().strip()) and time.monotonic() < deadline:
            time.sleep(0.05)
        swift = int(pid_file.read_text())
        self.assertTrue(self.lock.exists())
        run.send_signal(signal.SIGTERM)
        run.communicate(timeout=20)
        self.assertEqual(run.returncode, 143)
        self.assertFalse((self.out / "worktree").exists())
        self.assertEqual(len(self.worktrees()), 1)
        self.assertFalse(self.lock.exists())
        self.assertFalse(self.summary.exists(), "half a run is not a record")
        gone = subprocess.run(["ps", "-p", str(swift)], capture_output=True).returncode != 0
        self.assertTrue(gone, "the test run was stopped too")

    def test_it_waits_for_a_running_heavy_job(self):
        started = subprocess.run(["ps", "-o", "lstart=", "-p", str(os.getpid())], capture_output=True, text=True,
                                 env={**os.environ, "LC_ALL": "C"}).stdout.strip()
        self.lock.mkdir()
        (self.lock / "owner").write_text(f"pid={os.getpid()}\npstart={started}\nname=engine-build\nkind=run\nstarted=x\nuntil=\ntoken=o\ncommand=autoninja\n")
        run = subprocess.Popen([str(self.script), self.candidate, "1"], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, env=self.env)
        self.addCleanup(run.kill)
        time.sleep(1.0)
        self.assertIsNone(run.poll())
        self.assertEqual(self.calls.read_text(), "", "swift has not started")
        shutil.rmtree(self.lock)
        output, errors = run.communicate(timeout=30)
        self.assertEqual(run.returncode, 0, output + errors)
        self.assertIn("rc-tests is waiting for engine-build", errors)

    def test_the_scratch_path_is_passed_on(self):
        self.rc_tests(self.candidate, "1", "--scratch-path", str(self.root / "scratch"))
        self.assertTrue(self.called()["args"].endswith(f"--scratch-path {self.root / 'scratch'}"))

    def test_a_build_number_that_is_not_the_commits_count_is_noted_and_used(self):
        result = self.rc_tests(self.candidate, "77")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("is build 1 by its commit count; recording it as build 77", result.stderr)
        text = (self.repo / "docs" / "releases" / "77" / "tests" / "SUMMARY.md").read_text(encoding="utf-8")
        self.assertIn(f"- Commit `{self.candidate}`.", text, "no version is claimed for it")
        self.assertTrue((self.repo / "shell" / "dist" / "rc-77" / "swift-test.log").exists())

    def test_wrong_usage_is_64_and_runs_nothing(self):
        for arguments in ([], [self.candidate], [self.candidate, "soon"], ["no-such-commit", "1"], [self.candidate, "1", "extra"],
                          [self.candidate, "1", "--frob"]):
            result = self.rc_tests(*arguments)
            self.assertEqual(result.returncode, 64, arguments)
            self.assertEqual(self.calls.read_text(), "", arguments)
            self.assertFalse(self.out.exists(), arguments)

    def test_a_checkout_under_tmp_is_refused(self):
        # A copy of the fixture under /tmp: nothing is built there, the script refuses first.
        for base in ("/tmp", "/private/tmp"):
            with tempfile.TemporaryDirectory(prefix="darni-rc-tests-", dir=base) as place:
                copy = Path(place) / "repo"
                subprocess.run(["git", "clone", "-q", str(self.repo), str(copy)], check=True, capture_output=True)
                result = subprocess.run([str(copy / "shell" / "scripts" / "release" / "rc-tests.sh"), self.candidate, "1"],
                                        capture_output=True, text=True, env=self.env, timeout=60)
                self.assertEqual(result.returncode, 64, result.stdout + result.stderr)
                self.assertIn("this checkout is under /tmp", result.stderr)
                self.assertEqual(self.calls.read_text(), "")
                self.assertFalse((copy / "shell" / "dist").exists())
                self.assertFalse(self.lock.exists())


if __name__ == "__main__":
    unittest.main()
