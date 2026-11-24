"""Every script whose --help prints its own header (`sed -n '2,Np' "$0"`) prints exactly that
header: lines 2 to N are comments, and line N+1 is code or a paragraph break of the header. A line added to the header moves N, and
PATTERNS §7 asks for that to be noticed; this test notices it (check-webkit.sh printed its
`set -euo pipefail` twice before it)."""
from pathlib import Path
import re
import unittest

SCRIPTS = Path(__file__).resolve().parents[2]
RANGE = re.compile(r"""sed -n '2,(\d+)p' "\$0\"""")


class HelpRangeTests(unittest.TestCase):
    def test_help_prints_the_whole_header_and_nothing_else(self):
        checked = 0
        for script in sorted(SCRIPTS.rglob("*.sh")):
            match = RANGE.search(script.read_text(encoding="utf-8"))
            if not match:
                continue
            checked += 1
            last = int(match.group(1))
            lines = script.read_text(encoding="utf-8").splitlines()
            name = script.relative_to(SCRIPTS)
            with self.subTest(script=str(name)):
                strays = [line for line in lines[1:last] if not line.startswith("#")]
                self.assertEqual(strays, [], f"{name}: --help prints lines that are not the header")
                # It may stop at a paragraph break of the header (an empty `#` line), as a usage
                # message that leaves out the notes under it does.
                after = lines[last] if len(lines) > last else ""
                self.assertFalse(after.startswith("#") and after.strip() != "#",
                                 f"{name}: --help stops inside a paragraph of the header (line {last + 1} is {after!r})")
        self.assertGreater(checked, 0, "no script prints its header for --help")


if __name__ == "__main__":
    unittest.main()
