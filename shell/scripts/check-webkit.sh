#!/usr/bin/env bash
# The WebKit pass for a build (docs/ENGINE-PARITY.md, section 5). Darni ships Chromium; this
# checks that the WebKit shell still builds and that its engine still does what the parity
# matrix says, and writes the parity report for the build.
#
#   1. The index (docs/engine-parity.json), the document and the tests' row IDs must agree.
#   2. Plain `swift build`: the WebKit shell, no Chromium.
#   3. The WebKit engine tests (Tests/ReArcTests/WebKitEngine): real WKWebViews load pages from
#      a loopback server inside `swift test`.
#   4. webkit-parity-report.md and .json: every feature, its verdict on each engine, and
#      whether a WebKit test covers it and passed in this build.
#
# No app is launched, no window opens and no input is posted, so it needs no screen token.
# It builds, so mind the Mac's load (not during a performance slot).
#
# Usage: scripts/check-webkit.sh [--report DIR] [--full] [--record REV] [--label TEXT] [--scratch-path DIR]
#   --report DIR        where the report and logs go (default dist/webkit-check)
#   --full              run the whole `swift test` suite, not only the WebKit engine tests
#   --record REV        for a release: also keep its record in docs/releases/<build>/engine-parity
#                       (REPORT.md, report.json, a NOTES.md to fill in, the document as it stood)
#                       and add its line to docs/releases/ENGINE-PARITY-HISTORY.md. REV is the
#                       release's commit, with its RELEASES.md entry; shell/Sources here must be
#                       that commit's. Commit the folder afterwards. A failed pass is recorded too.
#   --label TEXT        the build's name in the report (default: the commit's version)
#   --scratch-path DIR  SwiftPM's build directory (default: the package's own .build)
# Exit status: 0 pass; 1 the build or a test failed; 2 the index, the document or a test's
# row ID is wrong; 64 a wrong option, or --record on sources that are not the release's.
set -euo pipefail

SHELL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
REPO="$(cd "$SHELL_DIR/.." && pwd)"
REPORT="$SHELL_DIR/dist/webkit-check"
FULL=0
LABEL=""
RECORD=""
SCRATCH=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --report) REPORT="${2:?--report needs a directory}"; shift ;;
    --full) FULL=1 ;;
    --record) RECORD="${2:?--record needs a release commit}"; shift ;;
    --label) LABEL="${2:?--label needs text}"; shift ;;
    --scratch-path) SCRATCH=(--scratch-path "${2:?--scratch-path needs a directory}"); shift ;;
    -h|--help) sed -n '2,28p' "$0"; exit 0 ;;
    *) echo "check-webkit: unknown option: $1" >&2; exit 64 ;;
  esac
  shift
done

REPORTER=(python3 -I "$SHELL_DIR/scripts/release/webkit-parity-report.py"
  --index "$REPO/docs/engine-parity.json" --doc "$REPO/docs/ENGINE-PARITY.md"
  --tests "$SHELL_DIR/Tests/ReArcTests/WebKitEngine")

echo "==> index, document and tests"
"${REPORTER[@]}" --check || exit 2

RECORD_FLAGS=()
if [[ -n $RECORD ]]; then
  if ! stamp="$(python3 -I "$SHELL_DIR/scripts/release/version.py" release --repo "$REPO" --revision "$RECORD" 2>&1)"; then
    echo "check-webkit: $RECORD is not a release commit: $stamp" >&2
    exit 64
  fi
  read -r release_version release_build <<<"$stamp"
  release_commit="$(git -C "$REPO" rev-parse --short=8 "$RECORD^{commit}")"
  if ! git -C "$REPO" diff --quiet "$RECORD" -- shell/Sources; then
    echo "check-webkit: shell/Sources here is not $release_commit's, so this would not be Darni $release_version's pass." >&2
    echo "check-webkit: check the release out (its tests and scripts may be newer), then record." >&2
    exit 64
  fi
  release_date="${release_version:0:4}-${release_version:5:2}-${release_version:7:2}"
  RECORD_FLAGS=(--record-release "$release_version" --releases "$REPO/docs/releases" --commit "$release_commit" --date "$release_date")
  if [[ -z $LABEL ]]; then LABEL="Darni $release_version (main $release_commit), WebKit shell"; fi
fi

if [[ -z $LABEL ]]; then
  LABEL="Darni (WebKit shell)"
  if stamp="$(python3 -I "$SHELL_DIR/scripts/release/version.py" commit --repo "$REPO" 2>/dev/null)"; then
    read -r version build <<<"$stamp"
    LABEL="Darni $version (build $build), WebKit shell"
  fi
  if commit="$(git -C "$REPO" rev-parse --short HEAD 2>/dev/null)"; then LABEL="$LABEL at $commit"; fi
fi

mkdir -p "$REPORT"
REPORT="$(cd "$REPORT" && pwd)"
BUILD_LOG="$REPORT/webkit-build.log"
TEST_LOG="$REPORT/webkit-swift-test.log"
: >"$TEST_LOG"

# `swift test` rewrites Package.resolved without the Sparkle pin (only the Chromium build has
# that dependency). Put it back afterwards, unless it already had changes of its own.
resolved_was_clean=0
if git -C "$SHELL_DIR" diff --quiet -- Package.resolved 2>/dev/null; then resolved_was_clean=1; fi
restore_resolved() {
  if [[ $resolved_was_clean == 1 ]] && ! git -C "$SHELL_DIR" diff --quiet -- Package.resolved 2>/dev/null; then
    git -C "$SHELL_DIR" checkout -- Package.resolved
  fi
}
trap restore_resolved EXIT

# Without the Chromium variables the manifest builds the WebKit shell, whatever the caller exported.
unset REARC_CHROMIUM_OUT REARC_ENGINE_INCLUDE

start=$SECONDS
echo "==> swift build (WebKit shell; log: $BUILD_LOG)"
build_failed=0
swift build --package-path "$SHELL_DIR" ${SCRATCH[@]+"${SCRATCH[@]}"} >"$BUILD_LOG" 2>&1 || build_failed=1

tests_failed=0
if [[ $build_failed == 0 ]]; then
  if [[ $FULL == 1 ]]; then
    echo "==> swift test, the whole suite (log: $TEST_LOG)"
    swift test --package-path "$SHELL_DIR" ${SCRATCH[@]+"${SCRATCH[@]}"} >"$TEST_LOG" 2>&1 || tests_failed=1
  else
    echo "==> swift test, the WebKit engine tests (log: $TEST_LOG)"
    swift test --package-path "$SHELL_DIR" ${SCRATCH[@]+"${SCRATCH[@]}"} --filter 'ReArcTests\.WebKitEngine' >"$TEST_LOG" 2>&1 || tests_failed=1
  fi
else
  echo "check-webkit: the WebKit shell did not build:" >&2
  grep -E "error:" "$BUILD_LOG" | head -n 10 >&2 || true
fi

flags=()
if [[ $build_failed == 1 ]]; then flags+=(--build-failed); fi
report_status=0
"${REPORTER[@]}" --log "$TEST_LOG" --out "$REPORT" --label "$LABEL" ${flags[@]+"${flags[@]}"} \
  ${RECORD_FLAGS[@]+"${RECORD_FLAGS[@]}"} || report_status=$?
echo "==> $((SECONDS - start))s"

if [[ $report_status != 0 ]]; then exit "$report_status"; fi
if [[ $tests_failed == 1 ]]; then
  # The WebKit engine tests passed, so the failure is in another suite (--full) or in the run itself.
  echo "check-webkit: swift test failed outside the WebKit engine tests:" >&2
  grep -E "^✘ Test |error: -\[|: error: " "$TEST_LOG" | head -n 10 >&2 || true
  exit 1
fi
exit 0
