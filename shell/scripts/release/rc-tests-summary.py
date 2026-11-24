#!/usr/bin/env python3
"""The summary of one full `swift test` run for a release candidate: reads the log
rc-tests.sh saved and writes docs/releases/<build>/tests/SUMMARY.md, the record every review
reads instead of running the suite again.

It counts what the log says, line by line (`--xunit-output` does not work with this toolchain):

  XCTest          Test Case '-[Module.Suite test]' passed|failed|skipped (0.1 seconds).
  Swift Testing   ✔ Test name() passed after 0.1 seconds.
                  ✘ Test name() failed after 0.1 seconds with 1 issue.
                  ✔ Test name(of:) with 11 test cases passed after 0.1 seconds.   (one test)

A test that started and has no result did not finish (a crash or a hang), and counts as failed.
A test that ran twice and failed once failed. The tests tagged `// parity: <row id>` in
shell/Tests (the rows of docs/ENGINE-PARITY.md) are listed with their result in this run.

The result is PASS when `swift test` ended with status 0, at least one test ran, none failed
and none was left unfinished. Anything else is FAIL; a FAIL is recorded too.

Usage: rc-tests-summary.py --log FILE --build N --commit SHA --out SUMMARY.md
                           [--tests DIR] [--exit-status N] [--started EPOCH] [--ended EPOCH]
                           [--version TEXT] [--log-name TEXT]
Exit status: 0 PASS; 1 FAIL; 2 the log cannot be read.
"""
import argparse
import datetime
from pathlib import Path
import re
import sys

XCTEST = re.compile(r"^Test Case '-\[(?P<name>[\w.]+ \w+)\]' (?P<result>started|passed|failed|skipped)")
XCTEST_ERROR = re.compile(r"^(?P<where>\S+?:\d+): error: -\[(?P<name>[\w.]+ \w+)\] : (?P<message>.*)$")
# The first character is the runner's mark (✔ ✘ ◇ ➜, or an SF Symbol in a terminal).
# A test with arguments ends "… with 11 test cases passed after"; its cases have lines of their own ("Test case passing …").
SWIFT_TESTING = re.compile(r"^\S+\s+Test (?P<name>(?!run |case ).+?)(?: with \d+ test cases?)? (?P<result>started\.$|passed after |failed after |skipped)")
SWIFT_TESTING_ISSUE = re.compile(r"^\S+\s+Test (?P<name>(?!run |case ).+?) recorded an issue(?: with \d+ arguments?.*?)? at (?P<where>[^ ]+?:\d+):\d+: (?P<message>.*)$")
COMPILE_ERROR = re.compile(r"\berror: ")
PARITY = re.compile(r"^\s*//\s*parity:\s*(.+?)\s*$")
FUNC = re.compile(r"^\s*(?:@\w+(?:\([^)]*\))?\s+)*(?:\w+\s+)*func\s+(\w+)\s*\(")
XCTEST_CLASS = re.compile(r"^\s*(?:final\s+)?class\s+(\w+)\s*:\s*XCTestCase")
OTHER_TYPE = re.compile(r"^(?:@\w+(?:\([^)]*\))?\s+)*(?:final\s+)?(?:struct|class|enum|actor|extension)\s+(\w+)")


def xctest_name(raw):
    """'ReArcTests.TabTests testTitle' -> 'ReArcTests.TabTests.testTitle'."""
    return raw.replace(" ", ".")


def parse_log(text):
    """What a `swift test` log says. XCTest tests are named Module.Suite.test and counted once
    each; Swift Testing's lines name only the function, so they are counted line by line."""
    xctest, started = {}, []
    swift = {"passed": 0, "failed": 0, "skipped": 0}
    swift_open, swift_failed, details, errors = {}, [], {}, []
    for line in text.splitlines():
        match = XCTEST.match(line)
        if match:
            name, result = xctest_name(match["name"]), match["result"]
            if result == "started":
                if name not in xctest:
                    xctest[name] = "unfinished"
                    started.append(name)
            elif xctest.get(name) != "failed":
                xctest[name] = result
            continue
        match = XCTEST_ERROR.match(line)
        if match:
            details.setdefault(xctest_name(match["name"]), f"{match['message']} ({short_path(match['where'])})")
            continue
        match = SWIFT_TESTING_ISSUE.match(line)
        if match:
            details.setdefault(match["name"], f"{match['message']} ({short_path(match['where'])})")
            continue
        match = SWIFT_TESTING.match(line)
        if match:
            name, result = match["name"], match["result"].split()[0].rstrip(".")
            if result == "started":
                swift_open[name] = swift_open.get(name, 0) + 1
                continue
            swift[result] += 1
            if swift_open.get(name):
                swift_open[name] -= 1
            if result == "failed" and name not in swift_failed:
                swift_failed.append(name)
            continue
        if COMPILE_ERROR.search(line) and len(errors) < 10:
            errors.append(line.strip())
    counts = {"passed": 0, "failed": 0, "skipped": 0, "unfinished": 0}
    for result in xctest.values():
        counts[result] += 1
    swift_unfinished = sorted(name for name, left in swift_open.items() if left > 0)
    return {
        "xctest": xctest,
        "xctestCounts": counts,
        "swiftTestingCounts": {**swift, "unfinished": len(swift_unfinished)},
        "swiftTestingResults": swift_results(text),
        "failed": sorted(name for name, result in xctest.items() if result == "failed") + swift_failed,
        "unfinished": [name for name in started if xctest[name] == "unfinished"] + swift_unfinished,
        "details": details,
        "errors": errors,
    }


def swift_results(text):
    """Swift Testing function name -> result, for matching a tagged test (failed wins)."""
    results = {}
    for line in text.splitlines():
        match = SWIFT_TESTING.match(line)
        if not match:
            continue
        result = match["result"].split()[0].rstrip(".")
        function = match["name"].split("(")[0]
        if result == "started":
            results.setdefault(function, "unfinished")
        elif results.get(function) != "failed":
            results[function] = result
    return results


def short_path(where):
    """A source position without the checkout it was built in."""
    for marker in ("/shell/Tests/", "/shell/Sources/"):
        if marker in where:
            return "shell/" + where.split("/shell/", 1)[1]
    return where


def parity_tests(tests_dir):
    """The tests under `// parity:` comments: [{suite, test, rows, file, xctest}], in file order."""
    found = []
    root = Path(tests_dir)
    sources = {path: path.read_text(encoding="utf-8", errors="replace").splitlines() for path in sorted(root.rglob("*.swift"))}
    xctest_classes = {match[1] for lines in sources.values() for match in map(XCTEST_CLASS.match, lines) if match}
    for path, lines in sources.items():
        suite, is_xctest, pending = None, False, None
        for line in lines:
            match = XCTEST_CLASS.match(line)
            if match:
                suite, is_xctest = match[1], True
                continue
            match = OTHER_TYPE.match(line)
            if match:   # an extension of a test class is still that class
                suite, is_xctest = match[1], match[1] in xctest_classes
                continue
            match = PARITY.match(line)
            if match:
                pending = [row.strip() for row in re.split(r"[,\s]+", match[1]) if row.strip()]
                continue
            match = FUNC.match(line)
            if match and pending is not None:
                found.append({"suite": suite or "", "test": match[1], "rows": pending,
                              "file": path.relative_to(root).as_posix(), "xctest": is_xctest})
                pending = None
    return found


def parity_results(tagged, parsed):
    """Each tagged test with its result in this run: passed, failed, skipped, unfinished or not run."""
    by_suite = {}
    for name, result in parsed["xctest"].items():
        _module, suite, test = name.rsplit(".", 2) if name.count(".") >= 2 else ("", *name.rsplit(".", 1))
        key = f"{suite}.{test}"
        if by_suite.get(key) != "failed":
            by_suite[key] = result
    rows = []
    for item in tagged:
        if item["xctest"]:
            result = by_suite.get(f"{item['suite']}.{item['test']}", "not run")
        else:
            result = parsed["swiftTestingResults"].get(item["test"], "not run")
        rows.append({**item, "result": result})
    return rows


def verdict(parsed, exit_status):
    """("PASS" | "FAIL", why)."""
    counts, swift = parsed["xctestCounts"], parsed["swiftTestingCounts"]
    ran = sum(counts.values()) + sum(swift.values())
    failed = counts["failed"] + swift["failed"]
    unfinished = counts["unfinished"] + swift["unfinished"]
    if ran == 0:
        return "FAIL", "no test ran: the build failed, or the run did not start"
    if failed or unfinished:
        parts = []
        if failed:
            parts.append(f"{failed} failed")
        if unfinished:
            parts.append(f"{unfinished} did not finish")
        return "FAIL", " and ".join(parts)
    if exit_status not in (0, None):
        return "FAIL", f"`swift test` ended with status {exit_status} though no test in the log failed: the run itself failed"
    return "PASS", ""


def duration(seconds):
    minutes, rest = divmod(max(0, int(seconds)), 60)
    hours, minutes = divmod(minutes, 60)
    if hours:
        return f"{hours} h {minutes} min"
    return f"{minutes} min {rest} s" if minutes else f"{rest} s"


def summary(parsed, parity, build, commit, exit_status=None, started="", ended="", took=None, version="", log_name=""):
    """SUMMARY.md as text."""
    result, why = verdict(parsed, exit_status)
    counts, swift = parsed["xctestCounts"], parsed["swiftTestingCounts"]
    total = {key: counts[key] + swift[key] for key in counts}
    ran = sum(total.values())
    lines = [f"# Tests at build {build}", ""]
    lines.append(f"- Commit `{commit}`" + (f", Darni {version}." if version else "."))
    if started and ended:
        lines.append(f"- Started {started}, ended {ended}" + (f" ({duration(took)})." if took is not None else "."))
    tally = f"{ran} tests: {total['passed']} passed, {total['failed']} failed, {total['skipped']} skipped"
    if total["unfinished"]:
        tally += f", {total['unfinished']} did not finish"
    # The tally already says how many failed; a reason is added only when it is something else.
    said = bool(total["failed"] or total["unfinished"])
    lines.append(f"- **Result: {result}.** {tally}." + (f" {why[0].upper()}{why[1:]}." if why and not said else ""))
    if exit_status is not None:
        lines.append(f"- `swift test` ended with status {exit_status}.")
    lines.append("- The whole `swift test` suite, run once for this release candidate by "
                 "`shell/scripts/release/rc-tests.sh`. Reviews read this record; they do not run the suite again.")
    if log_name:
        lines.append(f"- Full log: `{log_name}` (not in git).")
    lines += ["", "## Counts", "", "| Runner | Passed | Failed | Skipped | Did not finish |", "|---|---|---|---|---|"]
    for label, row in (("XCTest", counts), ("Swift Testing", swift), ("All", total)):
        lines.append(f"| {label} | {row['passed']} | {row['failed']} | {row['skipped']} | {row['unfinished']} |")
    lines += ["", "## Failed tests", ""]
    if not parsed["failed"] and not parsed["unfinished"]:
        lines.append("None.")
    for name in parsed["failed"]:
        detail = parsed["details"].get(name)
        lines.append(f"- `{name}`" + (f": {detail}" if detail else ""))
    for name in parsed["unfinished"]:
        lines.append(f"- `{name}`: started and did not finish (a crash or a hang; see the log)")
    if ran == 0 or (result == "FAIL" and not parsed["failed"] and not parsed["unfinished"]):
        if parsed["errors"]:
            lines += ["", "Errors in the log:", ""] + [f"- `{short_path_in(error)}`" for error in parsed["errors"]]
    lines += ["", "## Parity tests", ""]
    if not parity:
        lines.append("No test in `shell/Tests` is tagged `// parity:`.")
    else:
        tally = {}
        for item in parity:
            tally[item["result"]] = tally.get(item["result"], 0) + 1
        order = ["passed", "failed", "unfinished", "skipped", "not run"]
        said = ", ".join(f"{tally[key]} {key.replace('unfinished', 'did not finish')}" for key in order if key in tally)
        lines.append(f"The tests tagged `// parity:` (rows of `docs/ENGINE-PARITY.md`): {len(parity)} tests, {said}.")
        lines += ["", "| Result | Test | Rows | File |", "|---|---|---|---|"]
        for item in sorted(parity, key=lambda entry: (order.index(entry["result"]) if entry["result"] != "passed" else len(order), entry["file"])):
            name = f"{item['suite']}.{item['test']}" if item["suite"] else item["test"]
            shown = item["result"].replace("unfinished", "did not finish")
            lines.append(f"| {shown} | `{name}` | {', '.join(item['rows'])} | `{item['file']}` |")
    return "\n".join(lines) + "\n"


def short_path_in(line):
    """An error line with the checkout's path cut from its start."""
    head, _, rest = line.partition(": error: ")
    return f"{short_path(head)}: error: {rest}" if rest else line


def clock(epoch):
    return datetime.datetime.fromtimestamp(epoch).astimezone().strftime("%Y-%m-%d %H:%M:%S %z")


def main():
    parser = argparse.ArgumentParser(description="Write the tests summary of a release candidate from its swift test log.")
    parser.add_argument("--log", required=True, help="the saved `swift test` output")
    parser.add_argument("--build", required=True, help="the release's build number")
    parser.add_argument("--commit", required=True, help="the commit the suite ran on")
    parser.add_argument("--out", required=True, help="SUMMARY.md to write")
    parser.add_argument("--tests", help="shell/Tests of that commit, searched for // parity: comments")
    parser.add_argument("--exit-status", type=int, help="what `swift test` ended with")
    parser.add_argument("--started", type=int, help="when the run started, seconds since 1970")
    parser.add_argument("--ended", type=int, help="when it ended")
    parser.add_argument("--version", default="", help="the release's display version")
    parser.add_argument("--log-name", default="", help="where the log is kept, as the summary should name it")
    args = parser.parse_args()
    try:
        text = Path(args.log).read_text(encoding="utf-8", errors="replace")
    except OSError as error:
        print(f"rc-tests-summary: cannot read the log: {error}", file=sys.stderr)
        return 2
    parsed = parse_log(text)
    parity = parity_results(parity_tests(args.tests), parsed) if args.tests else []
    timed = args.started is not None and args.ended is not None
    out = Path(args.out)
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(summary(parsed, parity, args.build, args.commit, args.exit_status,
                           clock(args.started) if timed else "", clock(args.ended) if timed else "",
                           args.ended - args.started if timed else None, args.version, args.log_name), encoding="utf-8")
    result, why = verdict(parsed, args.exit_status)
    counts, swift = parsed["xctestCounts"], parsed["swiftTestingCounts"]
    print(f"rc-tests: {result}: {counts['passed'] + swift['passed']} passed, {counts['failed'] + swift['failed']} failed, "
          f"{counts['skipped'] + swift['skipped']} skipped, {counts['unfinished'] + swift['unfinished']} did not finish"
          + (f" ({why})" if why else "") + f"; summary in {out}")
    return 0 if result == "PASS" else 1


if __name__ == "__main__":
    sys.exit(main())
