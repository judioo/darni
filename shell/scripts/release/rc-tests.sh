#!/usr/bin/env bash
# The whole `swift test` suite, once per release candidate, for every review. The security,
# consistency and WebKit reviews of a candidate each used to run it again on the same commit;
# now they read this run's record.
#
#   1. Checks <commit> out in a throwaway worktree, shell/dist/rc-<build>/worktree (git-ignored;
#      never under /tmp).
#   2. Runs `swift test` there, holding the heavy-job lock (scripts/heavy-job.sh), so no other
#      heavy job runs beside it. It waits for one that is running.
#   3. Keeps the full log: shell/dist/rc-<build>/swift-test.log.
#   4. Writes docs/releases/<build>/tests/SUMMARY.md in this checkout: the commit, start and
#      end, the pass and fail counts, the failed tests by name, and the `// parity:` tests by
#      result (scripts/release/rc-tests-summary.py). Commit that folder afterwards.
#   5. Puts the worktree's Package.resolved back (`swift test` rewrites it) and removes the
#      worktree, also when the run fails or is stopped.
#
# No app is launched and no input is posted, so it needs no screen. It builds and tests for
# several minutes at full load.
#
# Usage: scripts/release/rc-tests.sh <commit> <build> [--scratch-path DIR]
#   <commit>            the release candidate's commit
#   <build>             its build number, the folder under docs/releases
#   --scratch-path DIR  SwiftPM's build directory (default: the worktree's own .build, removed
#                       with it)
# Exit status: 0 the suite passed; 1 it failed (the summary is written all the same);
# 64 wrong usage; 75 the lock was not obtained.
set -euo pipefail

SCRIPTS="$(cd "$(dirname "$0")/.." && pwd)"
SHELL_DIR="$(cd "$SCRIPTS/.." && pwd)"
REPO="$(cd "$SHELL_DIR/.." && pwd)"
usage() { echo "rc-tests: $*; usage: rc-tests.sh <commit> <build> [--scratch-path DIR]" >&2; exit 64; }

COMMIT="" BUILD=""
SCRATCH=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --scratch-path) [[ $# -ge 2 ]] || usage "--scratch-path needs a directory"; SCRATCH=(--scratch-path "$2"); shift ;;
    -h|--help) sed -n '2,26p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) usage "unknown option $1" ;;
    *)
      if [[ -z $COMMIT ]]; then COMMIT="$1"; elif [[ -z $BUILD ]]; then BUILD="$1"; else usage "unexpected argument $1"; fi ;;
  esac
  shift
done
[[ -n $COMMIT && -n $BUILD ]] || usage "a commit and a build number are needed"
[[ $BUILD =~ ^[1-9][0-9]*$ ]] || usage "the build is a number, not '$BUILD'"
SHA="$(git -C "$REPO" rev-parse --verify --quiet "$COMMIT^{commit}")" || usage "no commit '$COMMIT'"

OUT="$SHELL_DIR/dist/rc-$BUILD"
WORKTREE="$OUT/worktree"
LOG="$OUT/swift-test.log"
SUMMARY="$REPO/docs/releases/$BUILD/tests/SUMMARY.md"
case "$WORKTREE" in
  /tmp/*|/private/tmp/*) echo "rc-tests: this checkout is under /tmp; the worktree would be too. Run it from a checkout elsewhere." >&2; exit 64 ;;
esac

# The build is the commit's count; a different number is probably another release's folder.
VERSION=""
if stamp="$(python3 -I "$SCRIPTS/release/version.py" commit --repo "$REPO" --revision "$SHA" 2>/dev/null)"; then
  read -r VERSION counted <<<"$stamp"
  if [[ $counted != "$BUILD" ]]; then
    echo "rc-tests: note: ${SHA:0:8} is build $counted by its commit count; recording it as build $BUILD, as asked" >&2
    VERSION=""
  fi
fi

remove_worktree() {
  [[ -e $WORKTREE ]] || return 0
  # `swift test` rewrites Package.resolved without the Sparkle pin; put the commit's back.
  git -C "$WORKTREE" checkout -q -- shell/Package.resolved 2>/dev/null || true
  git -C "$REPO" worktree remove --force "$WORKTREE" 2>/dev/null || rm -rf "$WORKTREE"
  git -C "$REPO" worktree prune
}
source "$SCRIPTS/heavy-job.sh"
cleanup() { heavy_job_end; remove_worktree; }
trap cleanup EXIT

mkdir -p "$OUT"
remove_worktree   # one left by a run that was killed
echo "==> ${SHA:0:8} in a throwaway worktree: $WORKTREE"
git -C "$REPO" worktree add --quiet --detach "$WORKTREE" "$SHA"

# Without the Chromium variables the manifest builds the WebKit shell, whatever the caller exported.
unset REARC_CHROMIUM_OUT REARC_ENGINE_INCLUDE

heavy_job_begin rc-tests
echo "==> swift test, the whole suite (log: $LOG)"
started="$(date +%s)"
status=0
# In the background, so that a signal stops the run at once instead of leaving it behind.
swift test --package-path "$WORKTREE/shell" ${SCRATCH[@]+"${SCRATCH[@]}"} >"$LOG" 2>&1 &
runner=$!
trap 'kill "$runner" 2>/dev/null; wait "$runner" 2>/dev/null; exit 143' TERM INT HUP
wait "$runner" || status=$?
trap - TERM INT HUP
ended="$(date +%s)"
heavy_job_end
echo "==> swift test ended with status $status after $((ended - started))s"

result=0
python3 -I "$SCRIPTS/release/rc-tests-summary.py" --log "$LOG" --build "$BUILD" --commit "$SHA" --out "$SUMMARY" \
  --tests "$WORKTREE/shell/Tests" --exit-status "$status" --started "$started" --ended "$ended" \
  --version "$VERSION" --log-name "shell/dist/rc-$BUILD/swift-test.log" || result=$?
[[ $result == 0 || $result == 1 ]] || { echo "rc-tests: the summary could not be written" >&2; exit "$result"; }
echo "==> commit docs/releases/$BUILD/tests with the release's other records"
exit "$result"
