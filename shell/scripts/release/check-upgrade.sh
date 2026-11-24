#!/usr/bin/env bash
# Upgrade check: a profile made by the previous release must open in the new build.
#
# Build 602 passed every other check and aborted at launch on every profile an earlier build
# had made: its engine no longer had a feature the old engine had recorded in the profile.
# The launch check and the self-test use fresh profiles, so only an upgrade shows this.
#
# Usage: scripts/release/check-upgrade.sh NEW_APP PREVIOUS_APP [PROFILE_DIR ...]
#   PREVIOUS_APP makes a profile first (launched in the background on a throwaway data
#   directory, left to settle, then quit). NEW_APP then opens a copy of that profile, and of
#   each extra PROFILE_DIR (saved data directories of older builds), and must stay up for
#   REARC_UPGRADE_SECONDS (default 45) without a new crash report of the app.
#   Either app may be named ReArc.app (up to build 1053) or Darni.app (after): the executable
#   inside is Contents/MacOS/ReArc in both, and so are the crash reports' names.
#   Pass "-" as PREVIOUS_APP to test only the PROFILE_DIRs.
# Nothing takes the keyboard focus (`open -g`). The user's own data is never opened.
#
#        scripts/release/check-upgrade.sh --keychain-groups SHIPPED_APP PREVIOUS_APP
#   The other half of an upgrade, with no launch: SHIPPED_APP, the bundle as it ships, must be
#   signed with every keychain access group PREVIOUS_APP was shipped with, and with every one
#   in shipped-keychain-groups.txt. A passkey made on "this Mac" is reachable only through
#   its group, so a release that loses one loses people their passkeys (security review
#   PK-01). PREVIOUS_APP is read as it was shipped, never a copy signed again. The launch
#   half above cannot check this: its NEW_APP and its copy of PREVIOUS_APP are verification
#   bundles, which are signed without any group on purpose (they must never reach a real
#   passkey). release.sh runs both halves.
#
# NEW_APP must be the bundle release.sh is verifying (ReArcReleaseVerification in its signed
# Info.plist): a shipped bundle refuses REARC_DATA_DIR (security RC-0.1.0-602 T-04). Shipped
# builds up to 608 honour REARC_DATA_DIR as they are; a later shipped PREVIOUS_APP is copied,
# given the verification key and signed again with the release identity (sign-release.sh, or
# REARC_UPGRADE_SIGN), and the copy makes the profile. upgrade-bundles.sh decides both.
set -euo pipefail

die() { echo "check-upgrade: $*" >&2; exit 1; }
if [[ ${1:-} == --keychain-groups ]]; then
  [[ $# == 3 ]] || die "usage: check-upgrade.sh --keychain-groups SHIPPED_APP PREVIOUS_APP"
  HERE="$(cd "$(dirname "$0")" && pwd)"
  [[ -d $2 && -d $3 ]] || die "no app bundle at $2 or at $3"
  if [[ "$(plutil -extract ReArcReleaseVerification raw "$2/Contents/Info.plist" 2>/dev/null || true)" == true ]]; then
    die "$2 is a verification bundle, which is signed without any keychain access group; compare the bundle as it ships"
  fi
  build="$(plutil -extract CFBundleVersion raw "$2/Contents/Info.plist" 2>/dev/null || true)"
  build_option=()
  [[ ! $build =~ ^[1-9][0-9]*$ ]] || build_option=(--build "$build")
  python3 -I "$HERE/check-keychain-groups.py" gate "$2" --record "$HERE/shipped-keychain-groups.txt" \
    --previous-app "$3" ${build_option[@]+"${build_option[@]}"} \
    || die "FAIL: $2 would lose a keychain access group that has shipped"
  echo "check-upgrade: PASS: $(basename "$2") keeps every keychain access group of the previous release and of the record"
  exit 0
fi
[[ $# -ge 2 ]] || die "usage: check-upgrade.sh NEW_APP PREVIOUS_APP|- [PROFILE_DIR ...] | --keychain-groups SHIPPED_APP PREVIOUS_APP"
NEW="$(cd "$1" && pwd)"; PREVIOUS="$2"; shift 2
[[ -x "$NEW/Contents/MacOS/ReArc" ]] || die "no app bundle (Contents/MacOS/ReArc) at $NEW"
SETTLE="${REARC_UPGRADE_SETTLE_SECONDS:-40}"
STAY="${REARC_UPGRADE_SECONDS:-45}"
REPORTS="$HOME/Library/Logs/DiagnosticReports"
BUNDLES="$(cd "$(dirname "$0")" && pwd)/upgrade-bundles.sh"
"$BUNDLES" new "$NEW" || exit 1
WORK="$(mktemp -d "${TMPDIR:-/tmp}/rearc-upgrade.XXXXXX")"
# The path a process runs under: launch() finds the copy of a shipped previous release by it,
# and TMPDIR ("/var/…/T/") gave "/var/…/T//rearc-upgrade…" for a process at "/private/var/…/T/rearc-upgrade…".
WORK="$(cd "$WORK" && pwd -P)"
trap 'rm -rf "$WORK"' EXIT
crashes() { ls "$REPORTS" 2>/dev/null | grep -c '^ReArc-' || true; }

# A data directory with a sidebar is an existing install: no first-run onboarding.
seed() {
  mkdir -p "$1"
  cat >"$1/sidebar.json" <<'JSON'
{"version":1,"spaces":[],"profiles":[]}
JSON
}

# Launches APP on DATA in the background and prints its pid ("" when it never appeared).
launch() {
  local app="$1" data="$2" pid="" i
  # REARC_DATA_DIR only: the release verification variable enables the self-test and launch
  # probe, which this check does not use.
  open -n -g "$app" --env REARC_DATA_DIR="$data"
  for i in $(seq 1 20); do
    pid="$(pgrep -f "$app/Contents/MacOS/ReArc" | head -1 || true)"
    [[ -n $pid ]] && break
    sleep 0.5
  done
  echo "$pid"
}

quit() {
  local pid="$1" i
  kill -TERM "$pid" 2>/dev/null || return 0
  for i in $(seq 1 20); do kill -0 "$pid" 2>/dev/null || return 0; sleep 0.5; done
  kill -KILL "$pid" 2>/dev/null || true
}

PROFILES=()
if [[ $PREVIOUS != - ]]; then
  PREVIOUS="$(cd "$PREVIOUS" && pwd)"
  [[ -x "$PREVIOUS/Contents/MacOS/ReArc" ]] || die "no app bundle (Contents/MacOS/ReArc) at $PREVIOUS"
  PREVIOUS="$("$BUNDLES" previous "$PREVIOUS" "$WORK")" || die "no launchable copy of the previous release"
  made="$WORK/previous"
  seed "$made"
  echo "check-upgrade: making a profile with $(plutil -extract CFBundleVersion raw "$PREVIOUS/Contents/Info.plist") ($PREVIOUS), ${SETTLE}s"
  pid="$(launch "$PREVIOUS" "$made")"
  [[ -n $pid ]] || die "the previous release did not start"
  sleep "$SETTLE"
  kill -0 "$pid" 2>/dev/null || die "the previous release exited while making the profile"
  quit "$pid"
  [[ -d "$made/Chromium" ]] || die "the previous release wrote no Chromium profile under $made"
  PROFILES+=("$made")
fi
for extra in "$@"; do
  [[ -d "$extra" ]] || die "no profile directory at $extra"
  PROFILES+=("$extra")
done
[[ ${#PROFILES[@]} -gt 0 ]] || die "nothing to test: give a previous app or a profile directory"

failed=0
n=0
for profile in "${PROFILES[@]}"; do
  n=$((n + 1))
  copy="$WORK/open-$n"
  cp -Rc "$profile" "$copy" 2>/dev/null || cp -R "$profile" "$copy"
  before="$(crashes)"
  pid="$(launch "$NEW" "$copy")"
  alive=0
  if [[ -n $pid ]]; then
    alive=1
    for _ in $(seq 1 "$STAY"); do
      sleep 1
      kill -0 "$pid" 2>/dev/null || { alive=0; break; }
    done
  fi
  [[ $alive == 1 ]] && quit "$pid"
  sleep 2
  after="$(crashes)"
  if [[ $alive == 1 && $after == "$before" ]]; then
    echo "check-upgrade: PASS: $profile opened and stayed up ${STAY}s"
  else
    echo "check-upgrade: FAIL: $profile (stayed up: $alive, new crash reports: $((after - before)))" >&2
    failed=1
  fi
done
exit "$failed"
