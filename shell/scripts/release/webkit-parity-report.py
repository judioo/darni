#!/usr/bin/env python3
"""The WebKit parity report for one build (docs/ENGINE-PARITY.md, section 5).

Joins three things:
  - the index, docs/engine-parity.json: one row per feature with its verdict on each engine;
  - the WebKit tests' `// parity: <row id>` comments (the comment sits above the test it tags);
  - a `swift test` log, for which of those tests passed.

Writes webkit-parity-report.md and webkit-parity-report.json into --out. With --check it only
checks that the index, the document and the tests agree, and writes nothing.

With --record-release it also keeps the release's record for people to read later, in
<releases>/<build>/engine-parity/ (docs/releases/README.md):
  REPORT.md         every feature's verdict and test result in that release, and what changed
                    since the release before
  report.json       the same, for tools
  NOTES.md          written by hand: what the release changed on each engine, and what was
                    concluded. A template is made when there is none; it is never overwritten
  ENGINE-PARITY.md  the full document as it stood, copied for the first release and whenever a
                    verdict changed
and rewrites <releases>/ENGINE-PARITY-HISTORY.md, one line per release, newest first.
--history RELEASES rewrites only that file (after a release's notes are written).

Coverage (docs/ENGINE-PARITY.md, section 5): every commit that changes Darni's code should have a
WebKit parity test or a reason it needs none. docs/engine-parity-changes.json says which rows each
commit touched (or that it is Chromium-only, or no feature at all). --coverage A..B lists the
commits in a range and flags those with neither a tagged WebKit test nor a reason; a release record
lists the commits since the record before. Flags never change the exit status.

Exit status: 0 pass; 1 a WebKit test failed or did not run, or the build failed; 2 the index,
the document or a test's row ID is wrong (fix those first: the report would mislead).
"""
import argparse
import json
from pathlib import Path
import re
import subprocess
import sys

VERDICTS = ("works", "partial", "missing", "impossible")
PARITY = re.compile(r"^\s*//\s*parity:\s*(.+?)\s*$")
TEST_FUNC = re.compile(r"^\s*(?:@\w+(?:\([^)]*\))?\s+)*func\s+(test\w*)\s*\(")
SUITE = re.compile(r"^\s*(?:final\s+)?class\s+(\w+)\s*:\s*XCTestCase")
CASE = re.compile(r"^Test Case '-\[(?P<module>\w+)\.(?P<suite>\w+) (?P<test>\w+)\]' (?P<result>passed|failed)")
# XCTExpectFailure that matched: the test states behaviour WebKit does not have yet, and passes.
EXPECTED = re.compile(r"Expected failure in -\[(?P<module>\w+)\.(?P<suite>\w+) (?P<test>\w+)\]")
# Darni's own code. A commit touching only tests, docs, scripts, benches or the perf tools is no feature.
PRODUCT_PATHS = ("shell/Sources/ReArc/", "shell/Sources/SidebarModel/", "shell/Sources/Onboarding/",
                 "shell/Resources/", "engine/patches/")
ROW_REASONS = ("chromiumOnly", "screenOnly")
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
        for reason in ROW_REASONS:
            if reason in row and not (isinstance(row[reason], str) and row[reason].strip()):
                problems.append(f"index: row {row_id} has an empty \"{reason}\"; give the reason or leave it out")
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
    """Suite.test -> "passed" | "failed" | "gap confirmed" from a `swift test` log. A test that ran twice
    and failed once failed. "gap confirmed": it passed on an expected failure (XCTExpectFailure), so the
    behaviour it states is still missing on WebKit."""
    results, expected = {}, set()
    for line in Path(log_path).read_text(encoding="utf-8", errors="replace").splitlines():
        if match := EXPECTED.search(line):
            expected.add(f"{match['suite']}.{match['test']}")
        if match := CASE.match(line.strip()):
            name = f"{match['suite']}.{match['test']}"
            if results.get(name) != "failed":
                results[name] = match["result"]
    for name in expected:
        if results.get(name) == "passed":
            results[name] = "gap confirmed"
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
        elif any(t["result"] == "gap confirmed" for t in tests):
            state = "passed, gap confirmed"
        elif tests:
            state = "passed"
        else:
            state = "no test"
        report_rows.append({**row, "tests": tests, "webkitTests": state})
    counts = {verdict: sum(1 for row in rows if row["webkit"] == verdict) for verdict in VERDICTS}
    covered = sum(1 for row in report_rows if row["webkitTests"].startswith("passed"))
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


def range_commits(repo, rev_range):
    """The commits of `rev_range` (merges left out), oldest first: [{"commit", "subject", "files"}]."""
    out = subprocess.run(["git", "-C", str(repo), "log", "--reverse", "--no-merges", "--format=@@%H%x09%s", "--name-only", rev_range],
                         capture_output=True, text=True, check=True).stdout
    commits = []
    for line in out.splitlines():
        if line.startswith("@@"):
            sha, _, subject = line[2:].partition("\t")
            commits.append({"commit": sha, "subject": subject, "files": []})
        elif line.strip() and commits:
            commits[-1]["files"].append(line.strip())
    return commits


def load_ledger(path):
    """docs/engine-parity-changes.json: commit (an abbreviated SHA) -> what it touched."""
    if not path or not Path(path).exists():
        return {}
    return json.loads(Path(path).read_text(encoding="utf-8")).get("changes", {})


def coverage(commits, ledger, rows, tags):
    """Each commit that changes Darni's code, covered or flagged, and how many changed none of it."""
    by_id = {row["id"]: row for row in rows}
    tested = {row_id for ids in tags.values() for row_id in ids}
    entries, skipped = [], 0
    for commit in commits:
        if not any(f.startswith(PRODUCT_PATHS) for f in commit["files"]):
            skipped += 1
            continue
        key = next((k for k in ledger if len(k) >= 7 and commit["commit"].startswith(k)), None)
        entry = ledger.get(key) if key else None
        item = {"commit": commit["commit"][:8], "subject": commit["subject"], "rows": [], "flags": [], "reasons": []}
        if entry is None:
            item["flags"].append("no entry in docs/engine-parity-changes.json")
        elif entry.get("chromiumOnly"):
            item["reasons"].append(f"Chromium-only: {entry['chromiumOnly']}")
        elif entry.get("notAFeature"):
            item["reasons"].append(f"no feature: {entry['notAFeature']}")
        elif not entry.get("rows"):
            item["flags"].append("its entry names no row and gives no reason")
        by_reason = entry is not None and bool(entry.get("chromiumOnly") or entry.get("notAFeature"))
        for row_id in [] if entry is None or by_reason else entry.get("rows", []):
            item["rows"].append(row_id)
            row = by_id.get(row_id)
            if row is None:
                item["flags"].append(f"{row_id}: not a row of the index")
            elif row_id in tested:
                item["reasons"].append(f"{row_id}: WebKit test")
            elif row.get("chromiumOnly"):
                item["reasons"].append(f"{row_id}: Chromium-only: {row['chromiumOnly']}")
            elif row.get("screenOnly"):
                item["flags"].append(f"{row_id}: no WebKit test; needs the screen: {row['screenOnly']}")
            else:
                item["flags"].append(f"{row_id}: no WebKit test and no Chromium-only reason")
        item["state"] = "flagged" if item["flags"] else "covered"
        entries.append(item)
    return {"changes": entries, "notProductCode": skipped,
            "flagged": [e["commit"] for e in entries if e["state"] == "flagged"]}


def plural(count, one, many, bare=False):
    """"1 commit changes", "2 commits change"; with `bare`, "1 has", "2 have"."""
    return f"{count} {one if count == 1 else many}"


def coverage_markdown(result, rev_range, heading="##"):
    lines = [f"{heading} Changes in `{rev_range}` and their WebKit tests", ""]
    changes = result["changes"]
    if not changes:
        lines.append("No commit in the range changes Darni's code.")
    else:
        flagged = [e for e in changes if e["state"] == "flagged"]
        lines.append(f"{plural(len(changes), 'commit changes', 'commits change')} Darni's code; "
                     f"{plural(len(flagged), 'has', 'have', bare=True)} neither a WebKit test nor a reason it needs none."
                     " This flags and does not block.")
        lines += ["", "| Commit | Change | Rows | Coverage |", "|---|---|---|---|"]
        for e in changes:
            what = "; ".join(e["flags"] + e["reasons"]) or ""
            mark = "**flagged**: " if e["flags"] else ""
            subject = e["subject"].replace("|", "\\|")
            lines.append(f"| `{e['commit']}` | {subject} | {', '.join(e['rows']) or '-'} | {mark}{what} |")
    lines += ["", f"{plural(result['notProductCode'], 'more commit changes', 'more commits change')} no Darni code (tests, docs, scripts, benches)."]
    return "\n".join(lines)


NOTES_PENDING = "<!-- engine-parity notes: not written yet -->"
RECORD = "engine-parity"


def recorded_releases(releases):
    """(build, folder) of every release with a record, oldest first."""
    found = []
    for folder in Path(releases).glob(f"*/{RECORD}"):
        if folder.parent.name.isdigit() and (folder / "report.json").exists():
            found.append((int(folder.parent.name), folder))
    return sorted(found)


def verdict_changes(previous_matrix, rows):
    """What differs from the release before: verdicts that moved, rows that came or went."""
    before = {row["id"]: row for row in previous_matrix}
    changes = []
    for row in rows:
        old = before.pop(row["id"], None)
        if old is None:
            changes.append({"id": row["id"], "feature": row["feature"], "from": None, "to": row["webkit"]})
        elif (old["webkit"], old["chromium"]) != (row["webkit"], row["chromium"]):
            change = {"id": row["id"], "feature": row["feature"], "from": old["webkit"], "to": row["webkit"]}
            if old["chromium"] != row["chromium"]:
                change["chromiumFrom"], change["chromiumTo"] = old["chromium"], row["chromium"]
            changes.append(change)
    for old in before.values():
        changes.append({"id": old["id"], "feature": old["feature"], "from": old["webkit"], "to": None})
    return changes


def describe_change(change):
    if change["from"] is None:
        return f"new row, {change['to']} on WebKit"
    if change["to"] is None:
        return f"row removed (was {change['from']} on WebKit)"
    text = f"{change['from']} → {change['to']} on WebKit" if change["from"] != change["to"] else f"{change['to']} on WebKit, as before"
    if "chromiumFrom" in change:
        text += f"; {change['chromiumFrom']} → {change['chromiumTo']} on Chromium"
    return text


def notes_template(release, previous, cover=None):
    since = f"since {previous}" if previous else "in this release"
    flagged = [e for e in (cover or {}).get("changes", []) if e["state"] == "flagged"]
    gaps = ["## Changes without a WebKit test or a Chromium-only reason", ""]
    if cover is None:
        gaps.append("No coverage check: no earlier record to start the range from.")
    elif not flagged:
        gaps.append("None.")
    else:
        gaps += [f"- `{e['commit']}` {e['subject']}: {'; '.join(e['flags'])}" for e in flagged]
    return "\n".join([
        f"# Engine parity notes: Darni {release['version']}",
        "",
        NOTES_PENDING,
        "",
        "Written by hand for each release. Delete the line above when this is filled in.",
        "",
        f"## What changed {since}, by engine",
        "",
        "| New or fixed | On WebKit | Why |",
        "|---|---|---|",
        "",
        "## What the WebKit pass found",
        "",
        *gaps,
        "",
        "## Conclusions and open questions",
        "",
    ])


def release_markdown(report):
    release, previous = report["release"], report["previous"]
    lines = [f"# Engine parity at Darni {release['version']}", ""]
    lines += [
        f"- Release build {release['build']}, `main` at `{release['commit']}`, {release['date']}.",
        f"- **WebKit pass: {'PASS' if report['result'] == 'pass' else 'FAIL'}.** "
        + ("Darni ships Chromium; this is the state of the WebKit path in this release."),
        "- [NOTES.md](NOTES.md): what this release changed on each engine, and what was concluded.",
    ]
    snapshot = report["documentSnapshot"]
    where = "ENGINE-PARITY.md" if snapshot == release["build"] else f"../../{snapshot}/{RECORD}/ENGINE-PARITY.md"
    same = "as it stood at this release" if snapshot == release["build"] else f"as it stood at build {snapshot}; no verdict has changed since"
    lines.append(f"- [ENGINE-PARITY.md]({where}): the full document, with the evidence for each verdict, {same}.")
    lines += ["", f"## Changed since {'build ' + str(previous) if previous else 'the release before'}", ""]
    if previous is None:
        lines.append("This is the first release with a record.")
    elif not report["changes"]:
        lines.append("No verdict changed.")
    else:
        lines += ["| Feature | Change | ID |", "|---|---|---|"]
        lines += [f"| {c['feature']} | {describe_change(c)} | `{c['id']}` |" for c in report["changes"]]
    if report.get("coverage") is not None:
        lines += ["", coverage_markdown(report["coverage"], report["coverageRange"])]
    lines += ["", "## The pass", ""]
    return "\n".join(lines) + "\n" + "\n".join(markdown(report).splitlines()[2:])


def history_markdown(releases):
    lines = [
        "# Engine parity, release by release",
        "",
        "Made by `shell/scripts/check-webkit.sh --record`; do not edit. One line per release, newest first.",
        "Each release's folder has its report, its notes and the full document as it stood (README.md).",
        "",
        "| Release | Date | Commit | WebKit pass | Works | Partly | Missing | Impossible | Covered by a WebKit test | Failed | Verdict changes | Changes without a WebKit test | Notes |",
        "|---|---|---|---|---|---|---|---|---|---|---|---|---|",
    ]
    for build, folder in reversed(recorded_releases(releases)):
        report = json.loads((folder / "report.json").read_text(encoding="utf-8"))
        release, counts = report["release"], report["counts"]
        notes = folder / "NOTES.md"
        written = notes.exists() and NOTES_PENDING not in notes.read_text(encoding="utf-8")
        changes = "first record" if report["previous"] is None else (str(len(report["changes"])) if report["changes"] else "none")
        lines.append(
            f"| [{release['version']}]({build}/{RECORD}/REPORT.md) | {release['date']} | `{release['commit']}` "
            f"| {'pass' if report['result'] == 'pass' else '**fail**'} | {counts['works']} | {counts['partial']} | {counts['missing']} "
            f"| {counts['impossible']} | {report['rowsWithAPassingWebKitTest']} of {report['rows']} "
            f"| {', '.join(report['failedRows'] + report['notRunRows']) or 'none'} | {changes} "
            f"| {'not checked' if report.get('coverage') is None else (len(report['coverage']['flagged']) or 'none')} "
            f"| {f'[notes]({build}/{RECORD}/NOTES.md)' if written else 'not written yet'} |")
    return "\n".join(lines) + "\n"


def record_release(report, rows, doc, releases, release, repo=None, ledger=None, tags=None):
    """Keeps this release's record and rewrites the history. Returns the release's folder. With `repo`,
    the commits since the record before are checked for WebKit tests (`coverage`)."""
    releases = Path(releases)
    folder = releases / str(release["build"]) / RECORD
    earlier = [(build, path) for build, path in recorded_releases(releases) if build < release["build"]]
    previous, changes, snapshot = None, [], release["build"]
    if earlier:
        previous, previous_folder = earlier[-1]
        before = json.loads((previous_folder / "report.json").read_text(encoding="utf-8"))
        changes = verdict_changes(before["matrix"], rows)
        if not changes:
            snapshot = before["documentSnapshot"]
    cover, cover_range = None, None
    if repo and earlier:
        cover_range = f"{before['release']['commit']}..{release['commit']}"
        cover = coverage(range_commits(repo, cover_range), load_ledger(ledger), rows, tags or {})
    record = {**report, "release": release, "previous": previous, "changes": changes, "documentSnapshot": snapshot,
              "coverage": cover, "coverageRange": cover_range}
    folder.mkdir(parents=True, exist_ok=True)
    (folder / "report.json").write_text(json.dumps(record, indent=1, ensure_ascii=False) + "\n", encoding="utf-8")
    (folder / "REPORT.md").write_text(release_markdown(record) + "\n", encoding="utf-8")
    copy = folder / "ENGINE-PARITY.md"
    if snapshot == release["build"]:
        header = (f"> A copy of docs/ENGINE-PARITY.md as it stood at Darni {release['version']} (`{release['commit']}`). "
                  "The document that is kept up to date is docs/ENGINE-PARITY.md.\n\n")
        copy.write_text(header + Path(doc).read_text(encoding="utf-8"), encoding="utf-8")
    elif copy.exists():
        copy.unlink()
    notes = folder / "NOTES.md"
    if not notes.exists():
        notes.write_text(notes_template(release, previous, cover), encoding="utf-8")
    (releases / "ENGINE-PARITY-HISTORY.md").write_text(history_markdown(releases), encoding="utf-8")
    return folder


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
    parser.add_argument("--index", help="docs/engine-parity.json")
    parser.add_argument("--doc", help="docs/ENGINE-PARITY.md")
    parser.add_argument("--tests", help="the WebKit tests' directory (searched for // parity: comments)")
    parser.add_argument("--log", help="a swift test log")
    parser.add_argument("--build-failed", action="store_true", help="the build or the test run itself failed")
    parser.add_argument("--label", default="unlabelled build")
    parser.add_argument("--out", help="directory for webkit-parity-report.md and .json")
    parser.add_argument("--check", action="store_true", help="only check that index, document and tests agree")
    parser.add_argument("--record-release", metavar="VERSION", help="keep this release's record (2026.1122.1231); needs --releases, --commit and --date")
    parser.add_argument("--releases", help="docs/releases")
    parser.add_argument("--commit", help="the release's commit")
    parser.add_argument("--date", help="the release's date, YYYY-MM-DD")
    parser.add_argument("--repo", help="the repository, for --coverage and a release record's coverage")
    parser.add_argument("--ledger", help="docs/engine-parity-changes.json")
    parser.add_argument("--coverage", metavar="A..B", help="only list the range's commits and their WebKit tests (prints markdown)")
    parser.add_argument("--history", metavar="RELEASES", help="only rewrite RELEASES/ENGINE-PARITY-HISTORY.md (after a release's notes are written)")
    args = parser.parse_args(argv)
    if args.history:
        Path(args.history, "ENGINE-PARITY-HISTORY.md").write_text(history_markdown(args.history), encoding="utf-8")
        count = len(recorded_releases(args.history))
        print(f"webkit-parity-report: history of {count} release{'' if count == 1 else 's'} in {args.history}")
        return 0
    if not (args.index and args.doc and args.tests):
        parser.error("--index, --doc and --tests are needed")
    release = None
    if args.record_release:
        build = args.record_release.rsplit(".", 1)[-1]
        if not (args.releases and args.commit and args.date and args.log) or not build.isdigit():
            parser.error("--record-release needs a version that ends in the build number, and --releases, --commit, --date and --log")
        release = {"version": args.record_release, "build": int(build), "commit": args.commit, "date": args.date}

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
    if args.coverage:
        if not args.repo:
            parser.error("--coverage needs --repo")
        result = coverage(range_commits(args.repo, args.coverage), load_ledger(args.ledger), rows, tags)
        print(coverage_markdown(result, args.coverage, heading="#"))
        return 0
    if args.check:
        print(f"webkit-parity-report: {len(rows)} rows, {len(tags)} tagged tests; index, document and tests agree")
        return 0
    if not args.log or not (args.out or release):
        parser.error("--log and --out are needed for a report (or pass --check)")
    where = []
    if args.out:
        out = Path(args.out)
        out.mkdir(parents=True, exist_ok=True)
        (out / "webkit-parity-report.json").write_text(json.dumps(report, indent=1, ensure_ascii=False) + "\n", encoding="utf-8")
        (out / "webkit-parity-report.md").write_text(markdown(report) + "\n", encoding="utf-8")
        where.append(f"report in {out}")
    if release:
        folder = record_release(report, rows, args.doc, args.releases, release, repo=args.repo, ledger=args.ledger, tags=tags)
        where.append(f"release record in {folder}")
        recorded = json.loads((folder / "report.json").read_text(encoding="utf-8"))
        for commit in (recorded.get("coverage") or {}).get("flagged", []):
            print(f"webkit-parity-report: NO WEBKIT TEST for {commit} (flagged, not blocking)", file=sys.stderr)
    print(f"webkit-parity-report: {report['result'].upper()}: {report['rowsWithAPassingWebKitTest']} of {report['rows']} "
          f"features covered by a passing WebKit test; {'; '.join(where)}")
    for row_id in report["failedRows"]:
        print(f"webkit-parity-report: FAILED {row_id}", file=sys.stderr)
    for row_id in report["notRunRows"]:
        print(f"webkit-parity-report: NOT RUN {row_id}", file=sys.stderr)
    return 0 if report["result"] == "pass" else 1


if __name__ == "__main__":
    sys.exit(main())
