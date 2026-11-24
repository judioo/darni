"""The heavy-job lock in perf-check.sh, release.sh and build-engine-release.sh: each script runs
in a throwaway checkout where every tool it calls is a stub that notes whether the lock was held
when it ran. No build, no measurement, no app, no signing; the lock is a temporary path.
(check-webkit.sh's part is in test_check_webkit.py.)"""
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import unittest

SCRIPTS = Path(__file__).resolve().parents[2]

# A stub's first lines: "<what> held=<the nesting variable> owner=<who has the lock>".
NOTE = '''echo "{what} held=${{DARNI_HEAVY_JOB_HELD-none}} owner=$(sed -n 's/^name=//p' "$DARNI_HEAVY_JOB_LOCK/owner" 2>/dev/null)" >> "$STUB_CALLS"\n'''


def stub(path, what, body=""):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("#!/bin/bash\n" + NOTE.format(what=what) + body)
    path.chmod(0o755)


class Wiring(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="darni-heavy-wiring-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.repo = self.root / "repo"
        self.scripts = self.repo / "shell" / "scripts"
        self.scripts.mkdir(parents=True)
        shutil.copy(SCRIPTS / "heavy-job.sh", self.scripts / "heavy-job.sh")
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.calls = self.root / "calls.txt"
        self.calls.write_text("")
        self.lock = self.root / "heavy.lock"
        (self.root / "tmp").mkdir()
        self.env = {**os.environ, "PATH": f"{self.bin}:{os.environ['PATH']}", "STUB_CALLS": str(self.calls),
                    "DARNI_HEAVY_JOB_LOCK": str(self.lock), "DARNI_HEAVY_JOB_POLL": "0.05", "TMPDIR": str(self.root / "tmp")}
        self.env.pop("DARNI_HEAVY_JOB_HELD", None)

    def git(self, *arguments, cwd=None):
        subprocess.run(["git", "-C", str(cwd or self.repo), "-c", "user.name=t", "-c", "user.email=t@example.invalid", *arguments],
                       check=True, capture_output=True)

    def seen(self):
        return self.calls.read_text().splitlines()

    def seen_by(self, what):
        return [line.split(" ", 1)[1] for line in self.seen() if line.split(" ", 1)[0] == what]

    def heavy(self, *arguments):
        return subprocess.run([str(self.scripts / "heavy-job.sh"), *arguments], capture_output=True, text=True, env=self.env, timeout=20)


FAKE_PERF = '''import os, sys
from pathlib import Path
what = sys.argv[1]
owner = ""
try:
    for line in Path(os.environ["DARNI_HEAVY_JOB_LOCK"], "owner").read_text().splitlines():
        if line.startswith("name="):
            owner = line[5:]
except OSError:
    pass
with open(os.environ["STUB_CALLS"], "a") as calls:
    calls.write(f"{what} held={os.environ.get('DARNI_HEAVY_JOB_HELD', 'none')} owner={owner}\\n")
if what == "measure":
    if os.environ.get("STUB_MEASURE_FAILS"):
        sys.exit(3)
    Path(sys.argv[sys.argv.index("--out") + 1]).write_text("{}")
if what == "gate":
    print("gate: PASS")
'''


class PerfCheckTests(Wiring):
    """perf-check.sh --weekly: the probe build and the measurement hold the lock; the gate after them does not."""

    def setUp(self):
        super().setUp()
        shutil.copy(SCRIPTS / "perf-check.sh", self.scripts / "perf-check.sh")
        package = self.repo / "perf" / "darni_perf"
        package.mkdir(parents=True)
        (package / "__init__.py").write_text("HARNESS = 2\n")
        (package / "__main__.py").write_text(FAKE_PERF)
        (self.repo / "shell" / "Package.resolved").write_text('{"pins": []}\n')
        qa = self.repo / "shell" / "dist" / "perf-7" / "Darni.app" / "Contents"
        qa.mkdir(parents=True)
        (qa / "Info.plist").write_bytes(plistlib.dumps({"ReArcReleaseVerification": True}))
        stub(self.bin / "swift", "swift")
        self.git("init", "-q")
        self.git("commit", "-q", "--allow-empty", "-m", "fixture")
        self.git("tag", "v0.1.0-7")
        home = self.root / "home"
        (home / "Library" / "Caches").mkdir(parents=True)
        (home / "Library" / "Caches" / "rearc-input-allowed").touch()   # the screen, lent
        self.env["HOME"] = str(home)
        self.data = self.root / "data"

    def perf(self, *arguments, **env):
        return subprocess.run([str(self.scripts / "perf-check.sh"), *arguments, "--no-rotation", "--no-commit", "--no-guards",
                               "--data", str(self.data)], capture_output=True, text=True, env={**self.env, **env}, timeout=60)

    def test_the_weekly_measurement_holds_the_lock_and_the_gate_does_not(self):
        result = self.perf("--weekly")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.seen_by("swift"), ["held=perf owner=perf"], "the probe build")
        self.assertEqual(self.seen_by("measure"), ["held=perf owner=perf"])
        self.assertEqual(self.seen_by("gate"), ["held=none owner="])
        self.assertEqual(self.seen_by("chart"), ["held=none owner="])
        self.assertFalse(self.lock.exists())

    def test_a_measurement_that_fails_frees_the_lock(self):
        result = self.perf("--weekly", STUB_MEASURE_FAILS="1")
        self.assertEqual(result.returncode, 3)
        self.assertEqual(self.seen_by("measure"), ["held=perf owner=perf"])
        self.assertEqual(self.seen_by("gate"), [])
        self.assertFalse(self.lock.exists())

    def test_a_build_measured_by_number_takes_no_lock(self):
        result = self.perf("--build", "7")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.seen_by("measure"), ["held=none owner="])

    def test_the_weekly_measurement_runs_inside_a_perf_hold(self):
        self.assertEqual(self.heavy("--hold", "perf", "60").returncode, 0)
        self.addCleanup(self.heavy, "--release", "perf")
        result = self.perf("--weekly")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.seen_by("measure"), ["held=perf owner=perf"])
        self.assertTrue(self.heavy("--status").stdout.startswith("held by perf (a hold"), "the window stays open")

    def test_what_is_due_is_answered_without_the_lock(self):
        self.assertEqual(self.heavy("--hold", "engine-build", "60").returncode, 0)
        self.addCleanup(self.heavy, "--release", "engine-build")
        result = self.perf("--weekly", "--check-due")
        self.assertEqual(result.returncode, 10, result.stdout + result.stderr)
        self.assertEqual(self.seen_by("measure"), [])


BUNDLE = '''dist=""
while [[ $# -gt 0 ]]; do [[ $1 == --dist ]] && dist="$2"; shift; done
app="$dist/Darni.app/Contents"
mkdir -p "$app/MacOS" "$app/Resources/Blocklists"
plutil -create xml1 "$app/Info.plist"
cat > "$app/MacOS/ReArc" <<'APP'
#!/bin/bash
''' + NOTE.format(what="selftest") + '''echo "[selftest] passed"
APP
chmod +x "$app/MacOS/ReArc"
'''


class ReleaseTests(Wiring):
    """release.sh: the lock from the bundle build to the end of the checks, not for what follows."""

    def setUp(self):
        super().setUp()
        shutil.copy(SCRIPTS / "release.sh", self.scripts / "release.sh")
        (self.scripts / "release").mkdir()
        shutil.copy(SCRIPTS / "release" / "version.py", self.scripts / "release" / "version.py")
        (self.scripts / "release" / "signing-env.sh").write_text('load_signing_env() { :; }\nrelease_identity() { printf "Test Identity"; }\n')
        stub(self.scripts / "bundle-chromium.sh", "bundle", BUNDLE)
        stub(self.scripts / "release" / "check-rename.sh", "rename-gate")
        stub(self.scripts / "sign-release.sh", "sign")
        stub(self.scripts / "check-launch.sh", "launch-check", '[[ -z ${STUB_LAUNCH_FAILS:-} ]] || exit 1\n')
        blocklists = self.scripts / "blocklists" / "build-blocklists.py"
        blocklists.parent.mkdir()
        blocklists.write_text('print("packed")\n')
        stub(self.bin / "swift", "swift", 'echo "/nowhere"\n')
        (self.repo / "engine" / "chromium" / "src").mkdir(parents=True)
        (self.repo / "engine" / "chromium" / "src" / "keep").touch()
        self.git("init", "-q")
        self.git("add", "-A")
        self.git("commit", "-q", "-m", "fixture")
        self.engine = self.root / "engine-out"
        (self.engine / "Chromium.app" / "Contents").mkdir(parents=True)
        (self.engine / "Chromium.app" / "Contents" / "Info.plist").write_bytes(plistlib.dumps({"CFBundleShortVersionString": "156.0.1.2"}))
        self.dist = self.root / "dist"

    def release(self, **env):
        return subprocess.run([str(self.scripts / "release.sh"), "--worktree", "--engine-out", str(self.engine), "--dist", str(self.dist)],
                              capture_output=True, text=True, env={**self.env, **env}, timeout=120)

    def test_the_build_and_the_checks_hold_the_lock_and_the_shipped_signing_does_not(self):
        result = self.release()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        held, free = "held=release owner=release", "held=none owner="
        self.assertEqual(self.seen_by("bundle"), [held])
        self.assertEqual(self.seen_by("launch-check"), [held])
        self.assertEqual(self.seen_by("selftest"), [held])
        self.assertEqual(self.seen_by("sign"), [held, free], "the bundle the checks run on, then the one that ships")
        self.assertEqual(self.seen_by("rename-gate"), [held, free])
        self.assertFalse(self.lock.exists())

    def test_a_failed_check_frees_the_lock(self):
        result = self.release(STUB_LAUNCH_FAILS="1")
        self.assertEqual(result.returncode, 1)
        self.assertIn("launch check failed", result.stderr)
        self.assertEqual(self.seen_by("launch-check"), ["held=release owner=release"])
        self.assertEqual(self.seen_by("selftest"), [])
        self.assertFalse(self.lock.exists())

    def test_inside_a_heavy_job_the_release_does_not_wait_for_itself(self):
        self.assertEqual(self.heavy("--hold", "nightly", "60").returncode, 0)
        self.addCleanup(self.heavy, "--release", "nightly")
        result = self.release(DARNI_HEAVY_JOB_HELD="nightly")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.seen_by("bundle"), ["held=nightly owner=nightly"])
        self.assertTrue(self.heavy("--status").stdout.startswith("held by nightly"), "the outer job's lock stays")


SUBPROJECTS = '''subproject_entries() { printf 'sub\\tfix.patch\\n'; }
subproject_excludes() { echo ':(exclude)sub'; }
subproject_checkouts() { echo sub; }
subproject_verify() { return 0; }
'''
AUTONINJA = '''[[ -z ${STUB_BUILD_FAILS:-} ]] || exit 1
mkdir -p "$2/Chromium Framework.framework/Versions/1.2.3.4/Helpers"
'''


class EngineBuildTests(Wiring):
    """build-engine-release.sh: the build itself holds the lock; the checks and gn before it do not."""

    def setUp(self):
        super().setUp()
        shutil.copy(SCRIPTS / "build-engine-release.sh", self.scripts / "build-engine-release.sh")
        (self.scripts / "release").mkdir()
        (self.scripts / "release" / "BRANDING").write_text("MAC_BUNDLE_ID=test.bundle\n")
        engine = self.repo / "engine"
        (engine / "scripts").mkdir(parents=True)
        (engine / "scripts" / "subprojects.sh").write_text(SUBPROJECTS)
        (engine / "scripts" / "google-api-keys.py").write_text("")
        (engine / "CHROMIUM_PIN").write_text("1.2.3.4\n")
        src = engine / "chromium" / "src"
        for path, text in (("chrome/VERSION", "MAJOR=1\nMINOR=2\nBUILD=3\nPATCH=4\n"),
                           ("chrome/app/theme/chromium/BRANDING", "MAC_BUNDLE_ID=test.bundle\n"),
                           ("chrome/browser/rearc_bridge/rearc_engine_abi.h", "\n"),
                           ("chrome/browser/rearc_bridge/rearc_engine_entry_mac.h", "\n"),
                           ("sub/file", "\n"), (".gitignore", "out/\n")):
            (src / path).parent.mkdir(parents=True, exist_ok=True)
            (src / path).write_text(text)
        self.git("init", "-q", cwd=src)
        self.git("add", "-A", cwd=src)
        self.git("commit", "-q", "-m", "pin", cwd=src)
        self.git("tag", "1.2.3.4", cwd=src)
        base = subprocess.run(["git", "-C", str(src), "rev-parse", "HEAD"], capture_output=True, text=True).stdout.strip()
        (engine / "chromium" / ".rearc-hooks-complete").write_text(base + "\n")
        for tool in ("xcodebuild", "xcrun", "nm"):
            stub(self.bin / tool, tool)
        stub(self.bin / "gn", "gn")
        stub(self.bin / "autoninja", "autoninja", AUTONINJA)
        self.env.update(REARC_DEPOT_TOOLS=str(self.bin), REARC_TEAM_ID="ABCDE12345")
        self.env.pop("REARC_RELEASE_OUT", None)

    def build(self, *arguments, **env):
        return subprocess.run([str(self.scripts / "build-engine-release.sh"), *arguments], capture_output=True, text=True,
                              env={**self.env, **env}, timeout=60)

    def test_the_build_holds_the_lock_and_gn_does_not(self):
        result = self.build()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("Release engine built", result.stdout)
        self.assertEqual(self.seen_by("gn"), ["held=none owner="])
        self.assertEqual(self.seen_by("autoninja"), ["held=engine-build owner=engine-build"])
        self.assertFalse(self.lock.exists())

    def test_gen_only_takes_no_lock(self):
        self.assertEqual(self.heavy("--hold", "perf", "60").returncode, 0)
        self.addCleanup(self.heavy, "--release", "perf")
        result = self.build("--gen-only")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.seen_by("gn"), ["held=none owner=perf"], "it ran beside the holder")
        self.assertEqual(self.seen_by("autoninja"), [])

    def test_a_failed_build_frees_the_lock_and_fails(self):
        result = self.build(STUB_BUILD_FAILS="1")
        self.assertEqual(result.returncode, 1)
        self.assertNotIn("Release engine built", result.stdout)
        self.assertEqual(self.seen_by("autoninja"), ["held=engine-build owner=engine-build"])
        self.assertFalse(self.lock.exists())

    def test_the_job_count_reaches_the_build(self):
        stub(self.bin / "autoninja", "autoninja", 'echo "args $*" >> "$STUB_CALLS"\n' + AUTONINJA.replace("$2", "$4"))
        result = self.build("--jobs=3")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertTrue(any(line.startswith("args -j 3 -C out/ReArc-release-") and line.endswith(" chrome_framework chrome")
                            for line in self.seen()), self.seen())


if __name__ == "__main__":
    unittest.main()
