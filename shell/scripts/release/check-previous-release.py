#!/usr/bin/env python3
"""The previous release a new one is compared with is the build people actually have.

release.sh compares a candidate with --previous-app: a profile made by it must open
(check-upgrade.sh), and the candidate must keep its keychain access groups
(check-keychain-groups.py). Both say nothing when the app given is not the published one, so:

  check-previous-release.py PREVIOUS_APP [--team TEAM] [--feed FEED [--live URL | --no-live]]

  1. PREVIOUS_APP is a local bundle whose signature verifies (codesign --verify --deep; not
     --strict, which refuses the Finder attributes an installed app collects) and which is a
     release as shipped (ReArcRelease, no ReArcReleaseVerification). With --team, the
     signature must also be a Developer ID one of that team. It is never downloaded: a
     release does not depend on the network.
  2. With --feed: FEED, the last signed feed in the tree (the appcast.xml of release.sh's
     --appcast directory), verifies against the update key (verify-appcast.sh), and its newest
     item is PREVIOUS_APP's build.
  3. The live feed (--live, default: PREVIOUS_APP's SUFeedURL) is fetched and compared with
     FEED byte for byte. A difference fails: the tree is behind or ahead of what is published.
     A feed that cannot be reached is a note, not a failure. --no-live skips the fetch.

The fetch sends nothing but the request for the public feed.
REARC_VERIFY_APPCAST: another verifier for FEED (tests).
"""
import argparse
import os
import plistlib
import re
import subprocess
import sys
import tempfile
from pathlib import Path

NAME = "check-previous-release"
HERE = Path(__file__).resolve().parent


def fail(text):
    print(f"{NAME}: FAIL: {text}", file=sys.stderr)
    sys.exit(1)


def say(text):
    print(f"{NAME}: {text}")


def feed_builds(data):
    """Every item's build (sparkle:version, as an element or on the enclosure)."""
    text = data.decode("utf-8", errors="replace")
    found = re.findall(r"<sparkle:version>\s*([0-9]+)\s*</sparkle:version>", text)
    found += re.findall(r"<enclosure\b[^>]*\bsparkle:version=\"([0-9]+)\"", text)
    return sorted({int(build) for build in found})


def main():
    parser = argparse.ArgumentParser(prog=NAME, description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("previous_app")
    parser.add_argument("--team")
    parser.add_argument("--feed")
    parser.add_argument("--live")
    parser.add_argument("--no-live", action="store_true")
    args = parser.parse_args()

    app = Path(args.previous_app)
    try:
        with open(app / "Contents/Info.plist", "rb") as handle:
            info = plistlib.load(handle)
    except Exception as error:
        fail(f"cannot read {app}/Contents/Info.plist: {error}")
    build = str(info.get("CFBundleVersion", ""))
    if not re.fullmatch(r"[1-9][0-9]{0,8}", build):
        fail(f"{app} has no build number (CFBundleVersion {build!r})")
    if info.get("ReArcRelease") is not True or info.get("ReArcReleaseVerification") is True:
        fail(f"{app} (build {build}) is not a release as shipped (ReArcRelease without ReArcReleaseVerification): "
             f"the previous release is the app people have, not a test copy of it")
    verify = ["codesign", "--verify", "--deep"]
    if args.team:
        if not re.fullmatch(r"[A-Z0-9]{10}", args.team):
            fail(f"--team is not a team identifier: {args.team!r}")
        # Apple's Developer ID requirement, for this team.
        verify.append("-R=anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists and "
                      f"certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = \"{args.team}\"")
    verified = subprocess.run([*verify, str(app)], capture_output=True, text=True)
    if verified.returncode != 0:
        fail(f"the signature of {app} does not verify{' as a Developer ID signature of the team' if args.team else ''}: "
             f"{(verified.stderr or verified.stdout).strip()}")
    say(f"{app} is build {build}, a release as shipped, and its signature verifies"
        + (" (Developer ID, the release team)" if args.team else ""))
    if not args.feed:
        say("NOTE: no feed given, so the build was not compared with the newest published one")
        return 0

    feed = Path(args.feed)
    if not feed.is_file():
        fail(f"no feed at {feed}")
    verifier = os.environ.get("REARC_VERIFY_APPCAST") or str(HERE / "verify-appcast.sh")
    checked = subprocess.run([verifier, str(feed)], capture_output=True, text=True)
    if checked.returncode != 0:
        fail(f"{feed} is not a signed feed: {(checked.stderr or checked.stdout).strip()}")
    local = feed.read_bytes()
    builds = feed_builds(local)
    if not builds:
        fail(f"{feed} names no build")
    if builds[-1] != int(build):
        fail(f"the newest build of {feed} is {builds[-1]}, and --previous-app is build {build}: compare with the build "
             f"people have (the app of build {builds[-1]}), or bring the feed in the tree up to date")
    say(f"build {build} is the newest of the signed feed {feed}")

    if args.no_live:
        say("NOTE: the live feed was not fetched (--no-live)")
        return 0
    url = args.live or str(info.get("SUFeedURL", ""))
    if not url.startswith("https://"):
        say(f"NOTE: no https address for the live feed ({url!r}); not compared")
        return 0
    with tempfile.TemporaryDirectory(prefix="rearc-live-feed-") as work:
        target = Path(work) / "appcast.xml"
        fetched = subprocess.run(["curl", "-fsS", "--max-time", "20", "-A", "darni-release-check", "-o", str(target), url],
                                 capture_output=True, text=True)
        if fetched.returncode != 0 or not target.is_file():
            say(f"NOTE: the live feed {url} could not be reached (curl status {fetched.returncode}); not compared, and not an error")
            return 0
        live = target.read_bytes()
    if live != local:
        live_builds = feed_builds(live)
        fail(f"the live feed {url} differs from {feed} (live newest build: {live_builds[-1] if live_builds else 'none'}; "
             f"in the tree: {builds[-1]}). The tree is behind or ahead of what is published: settle that first")
    say(f"the live feed {url} is the same {len(local)} bytes")
    return 0


if __name__ == "__main__":
    sys.exit(main())
