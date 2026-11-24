"""heavy-job.sh on a lock in a temporary directory (DARNI_HEAVY_JOB_LOCK): the real lock in
~/Library/Caches is never touched. The jobs are `sh` one-liners; nothing heavy runs."""
import os
from pathlib import Path
import signal
import subprocess
import tempfile
import time
import unittest

HEAVY_JOB = Path(__file__).resolve().parents[2] / "heavy-job.sh"


def started(pid):
    """What heavy-job.sh records beside a pid: when that process started."""
    return subprocess.run(["ps", "-o", "lstart=", "-p", str(pid)], capture_output=True, text=True,
                          env={**os.environ, "LC_ALL": "C"}).stdout.strip()


class HeavyJobTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="darni-heavy-job-")
        self.addCleanup(self.temp.cleanup)
        self.dir = Path(self.temp.name)
        self.lock = self.dir / "heavy.lock"
        self.env = {**os.environ, "DARNI_HEAVY_JOB_LOCK": str(self.lock), "DARNI_HEAVY_JOB_POLL": "0.05"}
        self.env.pop("DARNI_HEAVY_JOB_HELD", None)
        self.processes = []
        self.addCleanup(self.stop_processes)

    def stop_processes(self):
        # SIGTERM first: heavy-job.sh passes it on, so no command is left behind holding a pipe.
        for process in self.processes:
            if process.poll() is None:
                process.terminate()
        for process in self.processes:
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
            for pipe in (process.stdout, process.stderr):
                if pipe:
                    pipe.close()
        owner = self.lock / "owner"
        if owner.exists():  # a hold's keeper outlives the command that made it
            for line in owner.read_text().splitlines():
                if line.startswith("pid=") and "kind=hold" in owner.read_text():
                    try:
                        os.kill(int(line[4:]), signal.SIGKILL)
                    except (ProcessLookupError, ValueError):
                        pass

    def heavy(self, *arguments, timeout=20, **env):
        return subprocess.run([str(HEAVY_JOB), *arguments], capture_output=True, text=True, timeout=timeout,
                              env={**self.env, **env})

    def start(self, *arguments, **env):
        process = subprocess.Popen([str(HEAVY_JOB), *arguments], stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                   text=True, env={**self.env, **env})
        self.processes.append(process)
        return process

    def status(self):
        return self.heavy("--status").stdout.strip()

    def wait_for(self, condition, what, seconds=10):
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            if condition():
                return
            time.sleep(0.02)
        self.fail(f"timed out waiting for {what}")

    def hold_open(self, name="first"):
        """A job that holds the lock until the file `go` appears."""
        go = self.dir / f"go-{name}"
        process = self.start(name, "--", "sh", "-c", f'echo {name} >> "$0"; while [ ! -e "$1" ]; do sleep 0.05; done; echo {name}-end >> "$0"',
                             str(self.dir / "order.txt"), str(go))
        self.wait_for(lambda: self.status().startswith(f"held by {name} "), f"{name} to take the lock")
        return process, go

    def order(self):
        path = self.dir / "order.txt"
        return path.read_text().split() if path.exists() else []

    def stale_lock(self, pid, name="gone", pstart=None, kind="run"):
        self.lock.mkdir()
        lines = [f"pid={pid}", f"name={name}", f"kind={kind}", "started=2026-11-01 10:00:00", "until=", "token=old", "command=swift test"]
        if pstart is not None:
            lines.insert(1, f"pstart={pstart}")
        (self.lock / "owner").write_text("\n".join(lines) + "\n")

    def dead_pid(self):
        process = subprocess.Popen(["true"])
        process.wait()
        return process.pid

    # Running a command

    def test_the_command_runs_with_the_lock_and_frees_it(self):
        result = self.heavy("build", "--", "sh", "-c", 'cat "$DARNI_HEAVY_JOB_LOCK/owner"; echo "held=$DARNI_HEAVY_JOB_HELD"')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("name=build\n", result.stdout)
        self.assertIn("kind=run\n", result.stdout)
        self.assertRegex(result.stdout, r"pid=\d+\n")
        self.assertRegex(result.stdout, r"started=\d{4}-\d\d-\d\d \d\d:\d\d:\d\d\n")
        self.assertIn("command=sh -c cat", result.stdout)
        self.assertIn("held=build", result.stdout)
        self.assertFalse(self.lock.exists())
        self.assertEqual(self.status(), "free")

    def test_the_commands_exit_status_and_input_pass_through(self):
        self.assertEqual(self.heavy("build", "--", "sh", "-c", "exit 7").returncode, 7)
        result = subprocess.run([str(HEAVY_JOB), "build", "--", "cat"], input="from stdin\n", capture_output=True, text=True, env=self.env)
        self.assertEqual(result.stdout, "from stdin\n")
        self.assertFalse(self.lock.exists())

    def test_two_contenders_run_one_after_the_other(self):
        first, go = self.hold_open("first")
        second = self.start("second", "--", "sh", "-c", 'echo second >> "$0"', str(self.dir / "order.txt"), DARNI_HEAVY_JOB_REPORT="1")
        time.sleep(1.3)
        self.assertIsNone(second.poll(), "the second job waits")
        self.assertEqual(self.order(), ["first"])
        go.touch()
        self.assertEqual(first.wait(timeout=10), 0)
        self.assertEqual(second.wait(timeout=10), 0)
        self.assertEqual(self.order(), ["first", "first-end", "second"])
        waiting = [line for line in second.stderr.read().splitlines() if "second is waiting for first (pid" in line]
        self.assertGreaterEqual(len(waiting), 2, "the holder is printed at once and then at every report interval")
        self.assertIn("sh -c echo first", waiting[0])
        self.assertEqual(self.status(), "free")

    def test_status_names_the_holder(self):
        first, go = self.hold_open("first")
        self.assertRegex(self.status(), rf"^held by first \(pid {first.pid}\) since \d{{4}}-\d\d-\d\d \d\d:\d\d:\d\d: sh -c ")
        go.touch()
        first.wait(timeout=10)
        self.assertEqual(self.status(), "free")

    # Not waiting

    def test_try_exits_75_when_the_lock_is_taken(self):
        first, go = self.hold_open("first")
        result = self.heavy("--try", "second", "--", "sh", "-c", 'echo second >> "$0"', str(self.dir / "order.txt"))
        self.assertEqual(result.returncode, 75)
        self.assertIn("taken by first (pid", result.stderr)
        self.assertEqual(self.order(), ["first"], "the command did not run")
        self.assertTrue(self.status().startswith("held by first "), "the holder keeps the lock")
        go.touch()
        first.wait(timeout=10)

    def test_try_runs_when_the_lock_is_free(self):
        self.assertEqual(self.heavy("--try", "second", "--", "true").returncode, 0)

    def test_timeout_gives_up_with_75(self):
        first, go = self.hold_open("first")
        began = time.monotonic()
        result = self.heavy("--timeout", "1", "second", "--", "sh", "-c", 'echo second >> "$0"', str(self.dir / "order.txt"))
        self.assertEqual(result.returncode, 75)
        self.assertGreaterEqual(time.monotonic() - began, 0.9)
        self.assertIn("after 1s; giving up (--timeout)", result.stderr)
        self.assertEqual(self.order(), ["first"])
        go.touch()
        first.wait(timeout=10)

    def test_timeout_is_not_reached_when_the_lock_frees_in_time(self):
        first, go = self.hold_open("first")
        second = self.start("--timeout", "15", "second", "--", "sh", "-c", 'echo second >> "$0"', str(self.dir / "order.txt"))
        time.sleep(0.3)
        go.touch()
        self.assertEqual(second.wait(timeout=10), 0)
        self.assertEqual(self.order(), ["first", "first-end", "second"])

    # Stale locks

    def test_a_lock_whose_pid_is_dead_is_taken_over_with_a_note(self):
        pid = self.dead_pid()
        self.stale_lock(pid, name="gone")
        self.assertIn("free (a stale lock is left: gone", self.status())
        result = self.heavy("next", "--", "sh", "-c", 'cat "$DARNI_HEAVY_JOB_LOCK/owner"')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(f"took over a stale lock: gone (pid {pid}, since 2026-11-01 10:00:00) is gone", result.stderr)
        self.assertIn("name=next\n", result.stdout)
        self.assertFalse(self.lock.exists())

    def test_a_pid_reused_by_another_process_is_stale_too(self):
        self.stale_lock(os.getpid(), pstart="Thu Jan  1 00:00:00 1970")
        result = self.heavy("--try", "next", "--", "true")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("took over a stale lock", result.stderr)

    def test_a_lock_whose_pid_is_alive_is_not_taken_over(self):
        self.stale_lock(os.getpid(), name="alive", pstart=started(os.getpid()))
        result = self.heavy("--try", "next", "--", "true")
        self.assertEqual(result.returncode, 75)
        self.assertTrue((self.lock / "owner").read_text().startswith(f"pid={os.getpid()}\n"))

    def test_a_lock_without_an_owner_is_busy_at_first_and_stale_after_ten_seconds(self):
        self.lock.mkdir()
        self.assertEqual(self.heavy("--try", "next", "--", "true").returncode, 75, "it may be mid-take")
        old = time.time() - 60
        os.utime(self.lock, (old, old))
        result = self.heavy("--try", "next", "--", "true")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("took over a stale lock that named no owner", result.stderr)

    def test_two_waiters_on_a_stale_lock_do_not_both_take_it(self):
        self.stale_lock(self.dead_pid())
        log = self.dir / "overlap.txt"
        job = 'echo start >> "$0"; sleep 0.3; echo end >> "$0"'
        contenders = [self.start(f"job{n}", "--", "sh", "-c", job, str(log)) for n in range(4)]
        for contender in contenders:
            self.assertEqual(contender.wait(timeout=20), 0)
        self.assertEqual(log.read_text().split(), ["start", "end"] * 4, "no two ran at once")

    # Nesting

    def test_inside_a_heavy_job_the_command_runs_directly(self):
        self.stale_lock(os.getpid(), name="outer", pstart=started(os.getpid()))  # taken, and never freed here
        result = self.heavy("inner", "--", "sh", "-c", "echo ran as $DARNI_HEAVY_JOB_HELD", DARNI_HEAVY_JOB_HELD="outer")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "ran as outer\n")
        self.assertIn("name=outer\n", (self.lock / "owner").read_text(), "the outer job's lock is untouched")

    def test_a_job_that_calls_another_job_does_not_deadlock(self):
        result = self.heavy("outer", "--", str(HEAVY_JOB), "inner", "--", "sh", "-c", 'sed -n "s/^name=//p" "$DARNI_HEAVY_JOB_LOCK/owner"', timeout=15)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "outer\n")
        self.assertEqual(self.status(), "free")

    # Signals

    def test_sigterm_stops_the_command_and_frees_the_lock(self):
        pid_file = self.dir / "child.pid"
        job = self.start("build", "--", "sh", "-c", 'echo $$ > "$0"; exec sleep 60', str(pid_file))
        self.wait_for(pid_file.exists, "the command to start")
        self.wait_for(lambda: pid_file.read_text().strip() != "", "the command's pid")
        child = int(pid_file.read_text())
        self.assertTrue(self.status().startswith("held by build "))
        job.send_signal(signal.SIGTERM)
        self.assertEqual(job.wait(timeout=10), 128 + signal.SIGTERM)
        self.assertEqual(self.status(), "free")
        self.assertFalse(self.lock.exists())
        self.wait_for(lambda: started(child) == "", "the command to be gone")

    def test_a_killed_holder_leaves_a_lock_the_next_job_takes_over(self):
        pid_file = self.dir / "child.pid"
        job = self.start("build", "--", "sh", "-c", 'echo $$ > "$0"; exec sleep 60', str(pid_file))
        self.wait_for(lambda: pid_file.exists() and pid_file.read_text().strip() != "", "the command to start")
        job.kill()
        job.wait(timeout=10)
        os.kill(int(pid_file.read_text()), signal.SIGKILL)
        result = self.heavy("next", "--", "true")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("took over a stale lock: build", result.stderr)

    # Holds

    def test_hold_keeps_the_lock_until_released_by_the_same_name(self):
        result = self.heavy("--hold", "perf", "60")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("perf holds the lock until", result.stdout)
        self.assertRegex(self.status(), r"^held by perf \(a hold, pid \d+\) since .*, until \d{4}-")
        self.assertEqual(self.heavy("--try", "build", "--", "true").returncode, 75)
        refused = self.heavy("--release", "build")
        self.assertEqual(refused.returncode, 1)
        self.assertIn("only --release perf ends it", refused.stderr)
        self.assertTrue(self.status().startswith("held by perf "), "another name cannot release it")
        released = self.heavy("--release", "perf")
        self.assertEqual(released.returncode, 0, released.stderr)
        self.assertEqual(released.stdout, "released perf\n")
        self.assertEqual(self.status(), "free")
        self.assertEqual(self.heavy("--try", "build", "--", "true").returncode, 0)

    def test_hold_ends_when_its_time_runs_out(self):
        self.assertEqual(self.heavy("--hold", "perf", "1").returncode, 0)
        self.assertTrue(self.status().startswith("held by perf "))
        self.wait_for(lambda: self.status() == "free", "the hold to run out", seconds=6)

    def test_hold_waits_for_a_running_job_and_try_does_not(self):
        first, go = self.hold_open("first")
        self.assertEqual(self.heavy("--try", "--hold", "perf", "60").returncode, 75)
        self.assertEqual(self.heavy("--timeout", "0", "--hold", "perf", "60").returncode, 75)
        waiting = self.start("--hold", "perf", "60")
        time.sleep(0.3)
        self.assertIsNone(waiting.poll())
        go.touch()
        self.assertEqual(waiting.wait(timeout=10), 0)
        self.assertTrue(self.status().startswith("held by perf (a hold"))
        self.heavy("--release", "perf")

    def test_a_hold_from_inside_a_heavy_job_is_refused(self):
        result = self.heavy("outer", "--", str(HEAVY_JOB), "--hold", "perf", "60")
        self.assertEqual(result.returncode, 64)
        self.assertIn("cannot be taken from inside the heavy job outer", result.stderr)
        self.assertEqual(self.status(), "free")

    def test_a_command_of_the_same_name_runs_inside_the_hold(self):
        self.heavy("--hold", "perf", "60")
        result = self.heavy("perf", "--", "sh", "-c", "echo measured as $DARNI_HEAVY_JOB_HELD", timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "measured as perf\n")
        self.assertTrue(self.status().startswith("held by perf (a hold"), "the hold outlives the command")
        self.assertEqual(list(self.lock.glob("join.*")), [])
        self.heavy("--release", "perf")

    def test_a_hold_does_not_end_while_a_command_inside_it_runs(self):
        self.heavy("--hold", "perf", "1")
        inside = self.start("perf", "--", "sleep", "3")
        time.sleep(2.2)
        self.assertIsNone(inside.poll())
        self.assertTrue(self.status().startswith("held by perf (a hold"), "past its time, kept for the running command")
        self.assertEqual(self.heavy("--try", "build", "--", "true").returncode, 75)
        self.assertEqual(inside.wait(timeout=10), 0)
        self.wait_for(lambda: self.status() == "free", "the hold to end after the command", seconds=6)

    def test_release_refuses_a_running_job_and_says_free_when_free(self):
        self.assertEqual(self.heavy("--release", "perf").stdout, "free\n")
        first, go = self.hold_open("perf")
        refused = self.heavy("--release", "perf")
        self.assertEqual(refused.returncode, 1)
        self.assertIn("a running job", refused.stderr)
        self.assertTrue(self.status().startswith("held by perf (pid"))
        go.touch()
        first.wait(timeout=10)

    def test_a_hold_whose_keeper_died_is_stale(self):
        self.heavy("--hold", "perf", "60")
        keeper = int([line for line in (self.lock / "owner").read_text().splitlines() if line.startswith("pid=")][0][4:])
        os.kill(keeper, signal.SIGKILL)
        self.wait_for(lambda: started(keeper) == "", "the keeper to be gone")
        result = self.heavy("--try", "build", "--", "true")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("took over a stale lock: perf", result.stderr)

    # From a script that sources it

    def script(self, body, **env):
        path = self.dir / "caller.sh"
        path.write_text(f'#!/usr/bin/env bash\nset -euo pipefail\nsource "{HEAVY_JOB}"\n{body}\n')
        path.chmod(0o755)
        return subprocess.run([str(path)], capture_output=True, text=True, timeout=20, env={**self.env, **env})

    def test_a_sourcing_script_holds_the_lock_between_begin_and_end(self):
        result = self.script(f'''echo "before: $("{HEAVY_JOB}" --status)"
heavy_job_begin release
echo "pid: $$ $(sed -n 's/^pid=//p' "$DARNI_HEAVY_JOB_LOCK/owner")"
echo "inside: $("{HEAVY_JOB}" --status) held=$DARNI_HEAVY_JOB_HELD"
"{HEAVY_JOB}" inner -- echo "inner ran"
heavy_job_end
echo "after: $("{HEAVY_JOB}" --status) held=${{DARNI_HEAVY_JOB_HELD-unset}}"''')
        self.assertEqual(result.returncode, 0, result.stderr)
        lines = result.stdout.splitlines()
        self.assertEqual(lines[0], "before: free")
        pid, owner = lines[1].split()[1:]
        self.assertEqual(pid, owner, "the script's own pid owns the lock")
        self.assertRegex(lines[2], r"^inside: held by release \(pid \d+\) since .* held=release$")
        self.assertEqual(lines[3], "inner ran")
        self.assertEqual(lines[4], "after: free held=unset")

    def test_a_sourcing_script_that_dies_frees_the_lock_at_exit(self):
        result = self.script("heavy_job_begin release\nfalse\necho not reached")
        self.assertEqual(result.returncode, 1)
        self.assertNotIn("not reached", result.stdout)
        self.assertFalse(self.lock.exists())

    def test_a_sourcing_scripts_own_exit_trap_is_kept(self):
        result = self.script("trap 'echo mine' EXIT\nheavy_job_begin release\nheavy_job_end")
        self.assertEqual(result.stdout, "mine\n")
        self.assertFalse(self.lock.exists())

    def test_begin_inside_a_heavy_job_takes_nothing(self):
        self.stale_lock(os.getpid(), name="outer", pstart=started(os.getpid()))
        result = self.script("heavy_job_begin release\necho ran\nheavy_job_end\necho held=$DARNI_HEAVY_JOB_HELD", DARNI_HEAVY_JOB_HELD="outer")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "ran\nheld=outer\n", "the outer job's mark stays")
        self.assertIn("name=outer\n", (self.lock / "owner").read_text())

    def test_begin_waits_for_the_holder(self):
        first, go = self.hold_open("first")
        path = self.dir / "waiter.sh"
        path.write_text(f'#!/usr/bin/env bash\nset -euo pipefail\nsource "{HEAVY_JOB}"\nheavy_job_begin second\necho second >> "{self.dir / "order.txt"}"\nheavy_job_end\n')
        path.chmod(0o755)
        waiter = subprocess.Popen([str(path)], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, env=self.env)
        self.processes.append(waiter)
        time.sleep(0.3)
        self.assertIsNone(waiter.poll())
        go.touch()
        self.assertEqual(waiter.wait(timeout=10), 0)
        self.assertEqual(self.order(), ["first", "first-end", "second"])

    # Usage

    def test_wrong_usage_is_64_and_runs_nothing(self):
        for arguments in (["build"], ["--", "true"], ["build", "true"], ["--hold", "perf"], ["--hold", "perf", "soon"],
                          ["--timeout", "x", "build", "--", "true"], ["--frob"], ["bad name", "--", "true"], ["--release"]):
            result = self.heavy(*arguments)
            self.assertEqual(result.returncode, 64, arguments)
            self.assertFalse(self.lock.exists(), arguments)

    def test_help_prints_the_usage(self):
        result = self.heavy("--help")
        self.assertEqual(result.returncode, 0)
        self.assertIn("Usage: scripts/heavy-job.sh", result.stdout)
        self.assertIn("Exit status:", result.stdout)
        self.assertNotIn("_hj_lock", result.stdout)

    def test_the_default_lock_is_in_the_users_caches(self):
        text = HEAVY_JOB.read_text()
        self.assertIn('${DARNI_HEAVY_JOB_LOCK:-$HOME/Library/Caches/darni-heavy-job.lock}', text)


if __name__ == "__main__":
    unittest.main()
