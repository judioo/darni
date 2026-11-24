#!/usr/bin/env python3
"""One view of a release candidate: which reviews have reported, what each concluded, and
which review branches hold commits that are not on main yet.

  Reviews   The records in docs/releases/<build>/ (docs/releases/README.md): tests,
            engine-parity, security, consistency. A review has reported when its folder holds
            a record. Its verdict is the first line of REPORT.md, SUMMARY.md or another .md
            there that states one: a bold phrase with PASS, FAIL, BLOCK, HOLD or SHIP in
            capitals, or a line that starts "Verdict:" or "Result:".
            performance is weekly and never blocks a release; it is shown for information.
  Branches  security/patches, security/batch-*, consistency/review and every webkit/* that is
            ahead of main, and each t3/* branch ahead of main whose newest commit is less than
            seven days old: how many commits, and the date of the newest. (A branch once sat
            unmerged for two days.)

Reads the release folder and git refs; changes nothing unless --write.

Usage: release-status.py <build> [--write] [--repo DIR] [--main BRANCH]
  --write        also write it to docs/releases/<build>/STATUS.md
  --repo DIR     the checkout to look at (default: the one this script is in)
  --main BRANCH  the trunk the branches are compared with (default: main)
Exit status: 0; 2 the checkout or its trunk cannot be read.
"""
import argparse
import datetime
from pathlib import Path
import re
import subprocess
import sys

REVIEWS = (("tests", "Tests"), ("engine-parity", "Engine parity"), ("security", "Security"), ("consistency", "Consistency"))
INFORMATION = (("performance", "Performance"),)
PREFERRED = ("REPORT.md", "SUMMARY.md")
FAILING = ("FAIL", "FAILED", "BLOCK", "BLOCKED", "BLOCKS", "HOLD", "NO-GO")
PASSING = ("PASS", "PASSED", "SHIP", "GO", "CLEAR")
WORD = re.compile(r"(?<![\w-])(" + "|".join(sorted(FAILING + PASSING, key=len, reverse=True)) + r")(?![\w-])")
BOLD = re.compile(r"\*\*([^*\n]+)\*\*")
LABELLED = re.compile(r"^(?:[-*>#\s]*)(?:\*\*)?(?:verdict|result)\s*:", re.IGNORECASE)
ALWAYS = ("security/patches", "consistency/review")
ALWAYS_PREFIXES = ("security/batch-", "webkit/")
RECENT_PREFIX = "t3/"
RECENT_DAYS = 7


def verdict_in(text):
    """(line, "pass" | "fail") for the first line of a record that states a verdict, or None."""
    for line in text.splitlines():
        words = [word for phrase in BOLD.findall(line) for word in WORD.findall(phrase)]
        if not words and LABELLED.match(line):
            words = WORD.findall(line)
        if words:
            shown = re.sub(r"^\s*(?:[-*+]\s+|>\s*|#+\s*)", "", line).strip()   # the list or heading mark
            return shown, "fail" if any(word in FAILING for word in words) else "pass"
    return None


def review(folder):
    """What a review's folder says: {reported, file, verdict, state}."""
    files = sorted(path for path in folder.glob("*.md") if path.is_file()) if folder.is_dir() else []
    any_file = folder.is_dir() and any(path.is_file() for path in folder.iterdir())
    if not any_file:
        return {"reported": False, "file": None, "verdict": None, "state": None}
    files.sort(key=lambda path: (PREFERRED.index(path.name) if path.name in PREFERRED else len(PREFERRED), path.name))
    for path in files:
        found = verdict_in(path.read_text(encoding="utf-8", errors="replace"))
        if found:
            return {"reported": True, "file": path.name, "verdict": found[0], "state": found[1]}
    return {"reported": True, "file": files[0].name if files else None, "verdict": None, "state": None}


def git(repo, *arguments):
    return subprocess.run(["git", "-C", str(repo), *arguments], capture_output=True, text=True, check=True).stdout


def watched(name):
    """"always" for a review branch, "recent" for a t3 branch, None for the rest."""
    if name in ALWAYS or name.startswith(ALWAYS_PREFIXES):
        return "always"
    return "recent" if name.startswith(RECENT_PREFIX) else None


def branches_ahead(repo, main, now):
    """The watched branches with commits main lacks: [{name, ahead, date, kind}], review branches
    first, then t3 branches, newest first."""
    listing = git(repo, "for-each-ref", "--format=%(refname:short)%09%(committerdate:unix)%09%(committerdate:short)", "refs/heads/")
    found = []
    for line in listing.splitlines():
        name, stamp, date = line.split("\t")
        kind = watched(name)
        if kind is None or name == main:
            continue
        if kind == "recent" and now - int(stamp) >= RECENT_DAYS * 86400:
            continue
        ahead = int(git(repo, "rev-list", "--count", f"{main}..{name}").strip())
        if ahead:
            found.append({"name": name, "ahead": ahead, "date": date, "stamp": int(stamp), "kind": kind})
    found.sort(key=lambda branch: (branch["kind"] != "always", branch["name"] if branch["kind"] == "always" else "", -branch["stamp"], branch["name"]))
    return found


def cell(text, limit=200):
    text = " ".join(text.split()).replace("|", "\\|")
    return text if len(text) <= limit else text[: limit - 1].rstrip() + "…"


def status(build, releases, repo, main, now):
    """STATUS.md as text."""
    folder = releases / str(build)
    head = git(repo, "rev-parse", "--short=8", f"{main}^{{commit}}").strip()
    when = datetime.datetime.fromtimestamp(now).astimezone().strftime("%Y-%m-%d %H:%M %z")
    lines = [f"# Release {build}: status", "", f"As of {when}, `{main}` at `{head}`. Made by `shell/scripts/release/release-status.py {build}`.",
             "", "## Reviews", "", "| Review | State | Verdict |", "|---|---|---|"]
    waiting, failed = [], []
    for kind, label in REVIEWS:
        found = review(folder / kind)
        if not found["reported"]:
            waiting.append(label.lower())
            lines.append(f"| {label} | not reported | |")
            continue
        if found["state"] == "fail":
            failed.append(label.lower())
        said = f"{cell(found['verdict'])} (`{kind}/{found['file']}`)" if found["verdict"] else f"no verdict line found in `{kind}/`; read the record"
        lines.append(f"| {label} | reported | {said} |")
    lines.append("")
    reported = len(REVIEWS) - len(waiting)
    lines.append(f"Reported: {reported} of {len(REVIEWS)}." + (f" Waiting for: {', '.join(waiting)}." if waiting else "")
                 + (f" Failed: {', '.join(failed)}." if failed else ""))
    for kind, label in INFORMATION:
        found = review(folder / kind)
        if not found["reported"]:
            said = "no record for this release"
        elif found["verdict"]:
            said = f"{found['verdict']} (`{kind}/{found['file']}`)"
        else:
            said = f"a record is in `{kind}/`" + (f" (`{found['file']}`)" if found["file"] else "")
        lines += ["", f"{label} (weekly; for information, it never blocks a release): {said}."]
    others = sorted(path.name for path in folder.iterdir() if path.is_dir() and path.name not in dict(REVIEWS + INFORMATION)) if folder.is_dir() else []
    if others:
        lines += ["", f"Other records in the folder: {', '.join(f'`{name}/`' for name in others)}."]
    lines += ["", f"## Branches ahead of {main}", ""]
    ahead = branches_ahead(repo, main, now)
    if not ahead:
        lines.append(f"None: no review branch, and no `t3/` branch from the last {RECENT_DAYS} days, has a commit that `{main}` lacks.")
    else:
        lines += ["| Branch | Commits ahead | Newest commit |", "|---|---|---|"]
        lines += [f"| `{branch['name']}` | {branch['ahead']} | {branch['date']} |" for branch in ahead]
        lines += ["", f"Review branches are listed whatever their age; `t3/` branches only when their newest commit is less than {RECENT_DAYS} days old."]
    return "\n".join(lines) + "\n"


def main():
    parser = argparse.ArgumentParser(description="Show which reviews of a release candidate have reported and which review branches are not merged.")
    parser.add_argument("build", help="the release's build number, the folder under docs/releases")
    parser.add_argument("--write", action="store_true", help="also write docs/releases/<build>/STATUS.md")
    parser.add_argument("--repo", default=str(Path(__file__).resolve().parents[3]), help="the checkout to look at")
    parser.add_argument("--main", default="main", help="the trunk the branches are compared with")
    args = parser.parse_args()
    if not re.fullmatch(r"[1-9][0-9]*", args.build):
        parser.error(f"the build is a number, not '{args.build}'")
    repo = Path(args.repo)
    releases = repo / "docs" / "releases"
    try:
        text = status(args.build, releases, repo, args.main, int(datetime.datetime.now().timestamp()))
    except (subprocess.CalledProcessError, OSError) as error:
        detail = (getattr(error, "stderr", "") or str(error)).strip()
        print(f"release-status: cannot read {repo} or its branch {args.main}: {detail}", file=sys.stderr)
        return 2
    sys.stdout.write(text)
    if args.write:
        out = releases / args.build / "STATUS.md"
        out.parent.mkdir(parents=True, exist_ok=True)
        out.write_text(text, encoding="utf-8")
        print(f"\nrelease-status: written to {out}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
