#!/usr/bin/env python3
"""The WebKit parity report for one build (docs/ENGINE-PARITY.md, section 5).

Joins three things:
  - the index, docs/engine-parity.json: one row per feature with its verdict on each engine;
  - the WebKit tests' `// parity: <row id>` comments (the comment sits above the test it tags);
  - a `swift test` log, for which of those tests passed.

Writes webkit-parity-report.md and webkit-parity-report.json into --out. With --check it only
checks that the index, the document and the tests agree, and writes nothing.

Exit status: 0 pass; 1 a WebKit test failed or did not run, or the build failed; 2 the index,
the document or a test's row ID is wrong (fix those first: the report would mislead).
"""
import argparse
import json
from pathlib import Path
import re
import sys

VERDICTS = ("works", "partial", "missing", "impossible")
PARITY = re.compile(r"^\s*//\s*parity:\s*(.+?)\s*$")
TEST_FUNC = re.compile(r"^\s*(?:@\w+(?:\([^)]*\))?\s+)*func\s+(test\w*)\s*\(")
SUITE = re.compile(r"^\s*(?:final\s+)?class\s+(\w+)\s*:\s*XCTestCase")
CASE = re.compile(r"^Test Case '-\[(?P<module>\w+)\.(?P<suite>\w+) (?P<test>\w+)\]' (?P<result>passed|failed)")
DOC_ROW = re.compile(r"^\|.*\|\s*(?P<chromium>\w+)\s*\|\s*\*\*(?P<webkit>\w+)\*\*[^|]*\|.*\|\s*`(?P<id>[a-z0-9.-]+)`\s*\|\s*$")


def load_index(path):
    """The rows, and what is wrong with them."""
    problems = []
    rows = json.loads(Path(path).read_text(encoding="utf-8"))
    seen = set()
    for row in rows:
        row_id = row.get("id", "")
        for key in ("id", "area", "feature", "chromium", "webkit", "note"):
            if key not in row:
                problems.append(f"index: row {row_id or '?'} has no \"{key}\"")
        if row_id in seen:
            problems.append(f"index: row {row_id} is there twice")
        seen.add(row_id)
        if row.get("webkit") not in VERDICTS:
            problems.append(f"index: row {row_id} has the WebKit verdict \"{row.get('webkit')}\"; use one of {', '.join(VERDICTS)}")
    return rows, problems


def doc_rows(path):
    """The matrix rows of ENGINE-PARITY.md: id -> (chromium, webkit)."""
    found = {}
    for line in Path(path).read_text(encoding="utf-8").splitlines():
        match = DOC_ROW.match(line)
        if match:
            found[match["id"]] = (match["chromium"], match["webkit"])
    return found


def check_doc(rows, path):
    problems = []
    in_doc = doc_rows(path)
    for row in rows:
        if row["id"] not in in_doc:
            problems.append(f"document: no matrix row for {row['id']}")
        elif in_doc[row["id"]] != (row["chromium"], row["webkit"]):
            chromium, webkit = in_doc[row["id"]]
            problems.append(f"document: {row['id']} says {chromium}/{webkit}, the index says {row['chromium']}/{row['webkit']}")
    known = {row["id"] for row in rows}
    for row_id in sorted(set(in_doc) - known):
        problems.append(f"document: matrix row {row_id} is not in the index")
    return problems


def tagged_tests(tests_dir):
    """Suite.test -> row IDs, from `// parity:` comments above XCTest methods."""
    tags = {}
    for path in sorted(Path(tests_dir).rglob("*.swift")):
        suite, pending = None, []
        for line in path.read_text(encoding="utf-8").splitlines():
            if match := SUITE.match(line):
                suite, pending = match[1], []
            elif match := PARITY.match(line):
                pending += [part.strip() for part in match[1].split(",") if part.strip()]
            elif match := TEST_FUNC.match(line):
                if pending and suite:
                    tags[f"{suite}.{match[1]}"] = pending
                pending = []
            elif line.strip() and not line.strip().startswith(("//", "@")):
                pending = []
    return tags


def test_results(log_path):
    """Suite.test -> "passed" | "failed" from a `swift test` log. A test that ran twice and failed once failed."""
    results = {}
    for line in Path(log_path).read_text(encoding="utf-8", errors="replace").splitlines():
        if match := CASE.match(line.strip()):
            name = f"{match['suite']}.{match['test']}"
            if results.get(name) != "failed":
                results[name] = match["result"]
    return results


def build_report(rows, tags, results, build_ok, label):
    known = {row["id"] for row in rows}
    problems = []
    by_row = {}
    for test, ids in sorted(tags.items()):
        for row_id in ids:
            if row_id not in known:
                problems.append(f"tests: {test} names the row {row_id}, which is not in the index")
            by_row.setdefault(row_id, []).append(test)
    report_rows, failed, not_run = [], [], []
    for row in rows:
        tests = [{"name": test, "result": results.get(test, "not run")} for test in by_row.get(row["id"], [])]
        if any(t["result"] == "failed" for t in tests):
            state = "failed"
            failed.append(row["id"])
        elif any(t["result"] == "not run" for t in tests):
            state = "not run"
            not_run.append(row["id"])
        elif tests:
            state = "passed"
        else:
            state = "no test"
        report_rows.append({**row, "tests": tests, "webkitTests": state})
    counts = {verdict: sum(1 for row in rows if row["webkit"] == verdict) for verdict in VERDICTS}
    covered = sum(1 for row in report_rows if row["webkitTests"] == "passed")
    untested_working = [row["id"] for row in report_rows if row["webkit"] == "works" and row["webkitTests"] == "no test"]
    passed = build_ok and not failed and not not_run
    return {
        "build": label,
        "result": "pass" if passed else "fail",
        "buildOK": build_ok,
        "counts": counts,
        "rows": len(rows),
        "rowsWithAPassingWebKitTest": covered,
        "failedRows": failed,
        "notRunRows": not_run,
        "workingRowsWithoutAWebKitTest": untested_working,
        "matrix": report_rows,
    }, problems


def markdown(report):
    lines = [f"# WebKit parity report: {report['build']}", ""]
    lines.append(f"**Result: {'PASS' if report['result'] == 'pass' else 'FAIL'}.**")
    if not report["buildOK"]:
        lines.append("The WebKit shell did not build, or its tests did not run.")
    counts = report["counts"]
    lines += [
        "",
        f"- {report['rows']} features: {counts['works']} work on WebKit, {counts['partial']} partly, "
        f"{counts['missing']} are missing, {counts['impossible']} are impossible there.",
        f"- {report['rowsWithAPassingWebKitTest']} features have a WebKit engine test that passed in this build.",
    ]
    if report["failedRows"]:
        lines.append(f"- **Failed:** {', '.join(report['failedRows'])}.")
    if report["notRunRows"]:
        lines.append(f"- **Tests that did not run:** {', '.join(report['notRunRows'])}.")
    without = report["workingRowsWithoutAWebKitTest"]
    lines.append(f"- {len(without)} features marked as working have no WebKit engine test yet"
                 + (f": {', '.join(without)}." if without else "."))
    lines += ["", "The verdicts and their evidence are in docs/ENGINE-PARITY.md."]
    area = None
    for row in report["matrix"]:
        if row["area"] != area:
            area = row["area"]
            lines += ["", f"## {area}", "", "| Feature | Chromium | WebKit | WebKit tests in this build |", "|---|---|---|---|"]
        tests = row["webkitTests"]
        if row["tests"]:
            tests += " (" + ", ".join(t["name"].split(".")[-1] for t in row["tests"]) + ")"
        lines.append(f"| {row['feature']} | {row['chromium']} | {row['webkit']} | {tests} |")
    return "\n".join(lines)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--index", required=True, help="docs/engine-parity.json")
    parser.add_argument("--doc", required=True, help="docs/ENGINE-PARITY.md")
    parser.add_argument("--tests", required=True, help="the WebKit tests' directory (searched for // parity: comments)")
    parser.add_argument("--log", help="a swift test log")
    parser.add_argument("--build-failed", action="store_true", help="the build or the test run itself failed")
    parser.add_argument("--label", default="unlabelled build")
    parser.add_argument("--out", help="directory for webkit-parity-report.md and .json")
    parser.add_argument("--check", action="store_true", help="only check that index, document and tests agree")
    args = parser.parse_args(argv)

    rows, problems = load_index(args.index)
    if not problems:
        problems += check_doc(rows, args.doc)
    tags = tagged_tests(args.tests)
    results = test_results(args.log) if args.log else {}
    report, tag_problems = build_report(rows, tags, results, not args.build_failed, args.label)
    problems += tag_problems
    if problems:
        for problem in problems:
            print(f"webkit-parity-report: {problem}", file=sys.stderr)
        return 2
    if args.check:
        print(f"webkit-parity-report: {len(rows)} rows, {len(tags)} tagged tests; index, document and tests agree")
        return 0
    if not args.out or not args.log:
        parser.error("--out and --log are needed for a report (or pass --check)")
    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    (out / "webkit-parity-report.json").write_text(json.dumps(report, indent=1, ensure_ascii=False) + "\n", encoding="utf-8")
    (out / "webkit-parity-report.md").write_text(markdown(report) + "\n", encoding="utf-8")
    print(f"webkit-parity-report: {report['result'].upper()}: {report['rowsWithAPassingWebKitTest']} of {report['rows']} "
          f"features covered by a passing WebKit test; report in {out}")
    for row_id in report["failedRows"]:
        print(f"webkit-parity-report: FAILED {row_id}", file=sys.stderr)
    for row_id in report["notRunRows"]:
        print(f"webkit-parity-report: NOT RUN {row_id}", file=sys.stderr)
    return 0 if report["result"] == "pass" else 1


if __name__ == "__main__":
    sys.exit(main())
