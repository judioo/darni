#!/usr/bin/env python3
"""The keychain access groups of a signed app: the release gate of security review PK-01.

A passkey made on "this Mac" is a Secure Enclave key in the keychain access group
<team>.com.rearc.browser.webauthn. Only an app signed with that group reaches it, so once one
release has carried a group, every later release must carry it too, or people lose the
passkeys they made (docs/FEATURE-SPECS/PASSKEYS-AND-SITE-PERMISSIONS.md, 1.4).

  gate APP --record FILE [--previous-app APP] [--build N]
      APP is a bundle as it ships. Fails when its main executable lacks a group that has
      shipped. Two sources say which have, and both are checked: the committed record FILE
      and the signed entitlements of the previous release (--previous-app, as it was shipped,
      never a copy signed again). Also fails when
        - the app carries a group the record does not name (a group ships only once it is
          recorded), or one the record gives to a later build than --build;
        - the app's own identifier is not the first group (it is the default group, and what
          the app keeps elsewhere must not move);
        - any nested code (helpers, frameworks, the updater) carries a group at all.
      Dropping a shipped group takes two variables, both: REARC_DROP_KEYCHAIN_GROUP names the
      group (as the record writes it; several with commas) and REARC_DROP_KEYCHAIN_GROUP_REASON
      says why. The reason is printed, so it is in the release log. A name that is not a
      shipped group, or a group the app still carries, fails: a variable left in the
      environment drops nothing by accident.
  none APP
      APP is a copy for tests (release verification mode: release.sh's gate bundle, a --qa
      bundle, the upgrade checks' copies of a previous release). It is signed by the same team
      and may run on a copy of a person's profile, so it must carry no group at all: fails
      when the main executable or any nested code has one.
  profile APP
      The signed entitlements are all allowed by the embedded provisioning profile. macOS
      kills an app at launch whose entitlements outrun its profile. Without a profile the app
      must carry no restricted entitlement.
  record FILE [--repo DIR [--path PATH] [--revision REV]]
      FILE is well formed. With --repo: it is also append-only in git. Every version of PATH
      (default: FILE's path in the repository) in the history of REV (default HEAD) must be
      the beginning of FILE, line for line. A line that disappears, changes or moves fails.
  list APP
      Prints the main executable's groups, one a line.

The record: one line per group, `<team>.<rest> <first build>`. `<team>` is written as it
stands here (the team identifier is not committed) and means the signing team. The first build
is the lowest build number that may carry the group. `#` starts a comment.

REARC_TEAM_ID: the signing team, when the app names none (neither in its entitlements nor in
its signature).

Reads signatures with `codesign -d --entitlements - --xml` and profiles with `security cms -D`;
launches nothing and reads no keychain. No network.
"""
import argparse
import os
import plistlib
import re
import subprocess
import sys
from pathlib import Path

NAME = "check-keychain-groups"
GROUPS = "keychain-access-groups"
TEAM = "com.apple.developer.team-identifier"
APP_ID = "com.apple.application-identifier"
PLACEHOLDER = "<team>"
ENTRY = re.compile(r"<team>\.[A-Za-z0-9][A-Za-z0-9.-]*")
BUILD = re.compile(r"[1-9][0-9]{0,8}")
EXECUTABLE = "Contents/MacOS/ReArc"
DROP = "REARC_DROP_KEYCHAIN_GROUP"
DROP_REASON = "REARC_DROP_KEYCHAIN_GROUP_REASON"


class Failure(Exception):
    pass


def say(text):
    print(f"{NAME}: {text}")


def entitlements(path):
    """The signed entitlements of a code object; {} when it has none."""
    result = subprocess.run(["codesign", "-d", "--entitlements", "-", "--xml", str(path)], capture_output=True)
    if result.returncode != 0:
        raise Failure(f"cannot read the signature of {path}: {result.stderr.decode(errors='replace').strip()}")
    data = result.stdout.strip()
    if not data:
        return {}
    try:
        value = plistlib.loads(data)
    except Exception as error:
        raise Failure(f"the entitlements of {path} are not a property list: {error}")
    if not isinstance(value, dict):
        raise Failure(f"the entitlements of {path} are not a dictionary")
    return value


def groups_of(found, path):
    value = found.get(GROUPS, [])
    if not isinstance(value, list) or not all(isinstance(item, str) for item in value):
        raise Failure(f"{GROUPS} of {path} is not a list of names")
    return value


def main_executable(app):
    path = Path(app) / EXECUTABLE
    if not path.is_file():
        raise Failure(f"no app bundle (Contents/MacOS/ReArc) at {app}")
    return path


def info(app):
    try:
        with open(Path(app) / "Contents/Info.plist", "rb") as handle:
            return plistlib.load(handle)
    except Exception as error:
        raise Failure(f"cannot read {app}/Contents/Info.plist: {error}")


def nested_code(app):
    """Every code object in the bundle but the main executable: bundles by their directory,
    bare executables and libraries by their file."""
    app = Path(app)
    found = []
    for root, dirs, files in os.walk(app / "Contents"):
        root = Path(root)
        for name in list(dirs):
            if name.endswith((".app", ".xpc", ".framework")):
                found.append(root / name)
        for name in files:
            path = root / name
            if path == app / EXECUTABLE or path.is_symlink():
                continue
            in_code_dir = root.name in ("Helpers", "MacOS", "Libraries", "XPCServices") or name == "Autoupdate"
            if in_code_dir and (os.access(path, os.X_OK) or name.endswith(".dylib")):
                found.append(path)
    return sorted(set(found))


def check_nested(app):
    carrying = []
    for path in nested_code(app):
        if GROUPS in entitlements(path):
            carrying.append(str(path.relative_to(app)))
    if carrying:
        raise Failure("nested code carries a keychain access group, which only the app itself may: " + ", ".join(carrying))


def read_record(text, name="the record"):
    """[(group with <team>, first build)], in the file's order."""
    entries = []
    for number, line in enumerate(text.splitlines(), 1):
        line = line.split("#", 1)[0].strip()
        if not line:
            continue
        parts = line.split()
        if len(parts) != 2 or not ENTRY.fullmatch(parts[0]) or not BUILD.fullmatch(parts[1]):
            raise Failure(f"{name}, line {number}: expected `<team>.<group> <first build>`, found {line!r}")
        if any(parts[0] == group for group, _ in entries):
            raise Failure(f"{name}, line {number}: {parts[0]} is listed twice")
        entries.append((parts[0], int(parts[1])))
    return entries


def team_of(found, path):
    team = found.get(TEAM)
    if isinstance(team, str) and team:
        return team
    result = subprocess.run(["codesign", "-dvv", str(path)], capture_output=True, text=True)
    match = re.search(r"^TeamIdentifier=(\S+)$", result.stdout + result.stderr, re.M)
    if match and match.group(1) != "not":
        return match.group(1)
    return os.environ.get("REARC_TEAM_ID", "")


def dropped_groups(required):
    """{record name: reason} for the groups the environment drops; fails on a half-said drop."""
    names = [name.strip() for name in os.environ.get(DROP, "").split(",") if name.strip()]
    reason = os.environ.get(DROP_REASON, "").strip()
    if not names:
        return {}
    if not reason:
        raise Failure(f"{DROP} names {', '.join(names)} without {DROP_REASON}: dropping a shipped group needs a written reason")
    for name in names:
        if name not in required:
            raise Failure(f"{DROP} names {name}, which is no shipped group (the shipped ones: {', '.join(sorted(required)) or 'none'})")
    return {name: reason for name in names}


def gate(args):
    app = Path(args.app)
    executable = main_executable(app)
    signed = entitlements(executable)
    carried = groups_of(signed, executable)
    team = team_of(signed, executable)
    bundle_id = info(app).get("CFBundleIdentifier", "")
    written = lambda group: PLACEHOLDER + group[len(team):] if team and group.startswith(team + ".") else group

    record = read_record(Path(args.record).read_text(encoding="utf-8"), Path(args.record).name)
    required = {group: f"the record ({Path(args.record).name}, from build {build})" for group, build in record}
    if args.previous_app:
        previous = Path(args.previous_app)
        previous_executable = main_executable(previous)
        previous_signed = entitlements(previous_executable)
        previous_team = team_of(previous_signed, previous_executable)
        previous_build = info(previous).get("CFBundleVersion", "?")
        if team and previous_team and previous_team != team:
            raise Failure(f"the previous release is signed by team {previous_team}, this build by {team}")
        own = f"{previous_team}.{info(previous).get('CFBundleIdentifier', '')}"
        for group in groups_of(previous_signed, previous_executable):
            if group == own:
                continue  # The app's identifier: the default group, with or without the key.
            name = PLACEHOLDER + group[len(previous_team):] if previous_team and group.startswith(previous_team + ".") else group
            source = f"the previous release (build {previous_build}, {previous})"
            required[name] = required[name] + " and " + source if name in required else source

    problems = []
    dropped = dropped_groups(required)
    carried_names = [written(group) for group in carried]
    own = PLACEHOLDER + "." + bundle_id
    for name, source in sorted(required.items()):
        if name in dropped:
            if name in carried_names:
                problems.append(f"{DROP} names {name}, and the app still carries it")
            else:
                say(f"DROPPED {name} (shipped by {source}). Reason given: {dropped[name]}")
            continue
        if name not in carried_names:
            problems.append(f"the app lacks {name}, which has shipped: {source}. People who made passkeys on this Mac "
                            f"would lose them. Sign with the group, or drop it on purpose with {DROP} and {DROP_REASON}")
    recorded = dict(record)
    for name in carried_names:
        if name == own:
            continue
        if name not in recorded:
            problems.append(f"the app carries {name}, which the record does not name. A group ships only once it is "
                            f"recorded: append `{name} <first build>` to {Path(args.record).name} in the commit that turns it on")
        elif args.build is not None and args.build < recorded[name]:
            problems.append(f"the app (build {args.build}) carries {name}, which the record gives to build {recorded[name]} and later")
    if carried and carried_names[0] != own:
        problems.append(f"the first keychain access group is {carried_names[0]}, not the app's own identifier {own}: "
                        f"the default group would move, and with it what the app already keeps")
    try:
        check_nested(app)
    except Failure as failure:
        problems.append(str(failure))
    if problems:
        raise Failure("; ".join(problems))
    sources = "the record" + (" and the previous release" if args.previous_app else "")
    say(f"PASS: {app.name} carries {', '.join(carried_names) or 'no group'}; shipped groups by {sources}: "
        f"{', '.join(sorted(required)) or 'none'}; nested code carries none")


def none(args):
    app = Path(args.app)
    executable = main_executable(app)
    carried = groups_of(entitlements(executable), executable)
    if carried:
        raise Failure(f"{app.name} is a copy for tests and carries {', '.join(carried)}: with the group it could use, list "
                      f"and delete the real passkeys of whoever runs it. Sign it without the group")
    check_nested(app)
    say(f"PASS: {app.name} carries no keychain access group (a copy for tests never reaches a real passkey)")


def allowed(value, grants):
    """One signed value against the profile's: equal, or under a grant that ends in `*`."""
    for grant in grants:
        if value == grant or (isinstance(grant, str) and isinstance(value, str) and grant.endswith("*") and value.startswith(grant[:-1])):
            return True
    return False


def restricted(key):
    return key in (GROUPS, APP_ID) or key.startswith("com.apple.developer.")


def profile(args):
    app = Path(args.app)
    executable = main_executable(app)
    signed = entitlements(executable)
    wanted = {key: value for key, value in signed.items() if restricted(key)}
    embedded = app / "Contents/embedded.provisionprofile"
    if not embedded.is_file():
        if wanted:
            raise Failure(f"{app.name} has no embedded provisioning profile and is signed with {', '.join(sorted(wanted))}: "
                          f"macOS would refuse to start it")
        return say(f"PASS: {app.name} has no provisioning profile and no entitlement that needs one")
    decoded = subprocess.run(["security", "cms", "-D", "-i", str(embedded)], capture_output=True)
    if decoded.returncode != 0:
        raise Failure(f"cannot decode {embedded}")
    try:
        grants = plistlib.loads(decoded.stdout).get("Entitlements", {})
    except Exception as error:
        raise Failure(f"{embedded} does not decode to a property list: {error}")
    listed = lambda value: value if isinstance(value, list) else [value]
    problems = []
    for key, value in sorted(wanted.items()):
        if key not in grants:
            problems.append(f"{key} is signed in and the profile does not have it")
            continue
        outside = [item for item in listed(value) if not allowed(item, listed(grants[key]))]
        if outside:
            problems.append(f"{key}: {', '.join(map(str, outside))} is signed in and the profile allows only "
                            f"{', '.join(map(str, listed(grants[key])))}")
    if problems:
        raise Failure(f"{app.name}'s entitlements outrun its provisioning profile, so macOS would kill it at launch: " + "; ".join(problems))
    say(f"PASS: the profile allows every restricted entitlement of {app.name} ({', '.join(sorted(wanted)) or 'none'})")


def record(args):
    path = Path(args.file)
    current = read_record(path.read_text(encoding="utf-8"), path.name)
    if not args.repo:
        return say(f"PASS: {path.name} is well formed ({len(current)} group(s))")
    repo = Path(args.repo)
    in_repo = args.path or str(path.resolve().relative_to(repo.resolve()))
    git = lambda *command: subprocess.run(["git", "-C", str(repo), *command], capture_output=True, text=True)
    log = git("log", "--format=%H", args.revision, "--", in_repo)
    if log.returncode != 0:
        raise Failure(f"cannot read the history of {in_repo}: {log.stderr.strip()}")
    commits = log.stdout.split()
    for commit in commits:
        shown = git("show", f"{commit}:{in_repo}")
        if shown.returncode != 0:
            continue  # The commit that deleted it, if one ever does: the next older one still counts.
        earlier = read_record(shown.stdout, f"{in_repo} at {commit[:10]}")
        if current[:len(earlier)] != earlier:
            gone = [f"{group} {build}" for group, build in earlier if (group, build) not in current]
            raise Failure(f"{path.name} is append-only, and it no longer begins with its lines of {commit[:10]}"
                          + (f" (gone or changed: {', '.join(gone)})" if gone else " (their order changed)")
                          + f". A shipped group is dropped with {DROP}, never by editing the record")
    say(f"PASS: {path.name} is well formed and append-only over {len(commits)} commit(s) ({len(current)} group(s))")


def listing(args):
    executable = main_executable(args.app)
    for group in groups_of(entitlements(executable), executable):
        print(group)


def main():
    parser = argparse.ArgumentParser(prog=NAME, description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    commands = parser.add_subparsers(dest="command", required=True)
    command = commands.add_parser("gate")
    command.add_argument("app")
    command.add_argument("--record", required=True)
    command.add_argument("--previous-app")
    command.add_argument("--build", type=int)
    command.set_defaults(run=gate)
    for name, run in (("none", none), ("profile", profile), ("list", listing)):
        command = commands.add_parser(name)
        command.add_argument("app")
        command.set_defaults(run=run)
    command = commands.add_parser("record")
    command.add_argument("file")
    command.add_argument("--repo")
    command.add_argument("--path")
    command.add_argument("--revision", default="HEAD")
    command.set_defaults(run=record)
    args = parser.parse_args()
    try:
        args.run(args)
    except Failure as failure:
        print(f"{NAME}: FAIL: {failure}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
