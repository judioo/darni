"""run_c_abi.py stops a host run whose engine dropped a test switch (security M-2)."""
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import tempfile  # noqa: E402
from run_c_abi import ignored_test_switches, refuse_offline_unsafe_host  # noqa: E402


class IgnoredTestSwitchTests(unittest.TestCase):
    def test_a_dropped_host_resolver_rule_is_found(self):
        log = ("[123:456:1124/203000.1:WARNING:chrome/browser/rearc_bridge/rearc_engine_abi.mm(1101)] "
               "ReArc engine: ignoring launch switch --host-resolver-rules\n"
               "other line\n")
        self.assertEqual(ignored_test_switches(log), ["--host-resolver-rules"])

    def test_several_are_listed_once_each(self):
        log = ("ReArc engine: ignoring launch switch --load-extension\n"
               "ReArc engine: ignoring launch switch --host-resolver-rules\n"
               "ReArc engine: ignoring launch switch --load-extension\n")
        self.assertEqual(ignored_test_switches(log), ["--host-resolver-rules", "--load-extension"])

    def test_a_never_allowed_switch_is_not_a_test_switch(self):
        log = "ReArc engine: ignoring launch switch --remote-debugging-port\n"
        self.assertEqual(ignored_test_switches(log), [])

    def test_a_clean_log_has_none(self):
        self.assertEqual(ignored_test_switches("display_capture phase=0 PASS\n"), [])


class OfflineUnsafeHostTests(unittest.TestCase):
    def out_dir(self, args):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        out = Path(temp.name)
        (out / "args.gn").write_text(args)
        return out

    def test_a_release_engine_refuses_a_host_that_does_not_ask(self):
        out = self.out_dir('is_debug=false\nis_official_build=false\n')
        with self.assertRaises(SystemExit) as raised:
            refuse_offline_unsafe_host("launch", "int main() { ReArcEngineStart(); }", out)
        self.assertIn("ReArcEngineAllowTestSwitches", str(raised.exception))

    def test_a_release_engine_runs_a_host_that_asks(self):
        out = self.out_dir("is_debug=false\n")
        refuse_offline_unsafe_host("display_capture", "assert(ReArcEngineAllowTestSwitches() == REARC_OK);", out)

    def test_a_debug_engine_keeps_the_switches(self):
        out = self.out_dir("is_debug = true\n")
        refuse_offline_unsafe_host("launch", "int main() {}", out)


if __name__ == "__main__":
    unittest.main()
