#!/usr/bin/env bash
# The reader view's page scripts in a real Chromium, with nothing on screen
# (docs/FEATURE-SPECS/READER-VIEW.md §10). No window, no input, no screenshot.
#
#   1. `swift test` writes the real scripts and the fixture pages to a scratch folder.
#   2. check-reader-engine.mjs serves the pages on 127.0.0.1 and runs the scripts in an
#      isolated world of each page in the engine out dir's Chromium, headless, on a scratch
#      profile that can reach loopback only.
#   3. `swift test` puts Chromium's answers through ReaderExtraction and the sanitiser.
#
# Usage: scripts/check-reader-engine.sh [--out-dir <engine out dir>] [--skip-build]
#   --out-dir   default: <main checkout>/engine/chromium/src/out/ReArc-codecs-arm64, the
#               release engine. REARC_ENGINE_OUT names another.
#   -h, --help  this text
#
# It does not replace the self-test's reader step (the shell's own engine tab, the button,
# the overlay): that one needs the screen.
set -euo pipefail

SHELL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
MAIN="$(cd "$SHELL_DIR" && git rev-parse --path-format=absolute --git-common-dir)"
MAIN="$(dirname "$MAIN")"
OUT_DIR="${REARC_ENGINE_OUT:-$MAIN/engine/chromium/src/out/ReArc-codecs-arm64}"
SKIP_BUILD=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --out-dir) OUT_DIR="$2"; shift 2 ;;
    --skip-build) SKIP_BUILD="--skip-build"; shift ;;
    -h|--help) sed -n '2,17p' "$0"; exit 0 ;;
    *) echo "check-reader-engine: unknown argument $1" >&2; exit 2 ;;
  esac
done
CHROMIUM="$OUT_DIR/Chromium.app/Contents/MacOS/Chromium"
[[ -x $CHROMIUM ]] || { echo "check-reader-engine: no Chromium in $OUT_DIR" >&2; exit 2; }
command -v node >/dev/null || { echo "check-reader-engine: node is needed" >&2; exit 2; }

# Scratch outside the repository and outside any session's temporary folder; removed on exit.
SCRATCH="$(mktemp -d "$HOME/Library/Caches/darni-reader-check.XXXXXX")"
# `swift test` rewrites Package.resolved without the Sparkle pin. Put it back on every exit,
# a failed one too, unless it already had changes of its own (check-webkit.sh's rule).
resolved_was_clean=0
if git -C "$SHELL_DIR" diff --quiet -- Package.resolved 2>/dev/null; then resolved_was_clean=1; fi
finish() {
  rm -rf "$SCRATCH"
  if [[ $resolved_was_clean == 1 ]] && ! git -C "$SHELL_DIR" diff --quiet -- Package.resolved 2>/dev/null; then
    git -C "$SHELL_DIR" checkout -- Package.resolved
  fi
}
trap finish EXIT

cd "$SHELL_DIR"
echo "==> writing the scripts and fixtures"
DARNI_READER_DUMP_DIR="$SCRATCH/fixtures" swift test $SKIP_BUILD \
  --filter 'ReaderEngineAnswerTests/testWriteTheScriptsAndFixturesForTheEngineCheck' >"$SCRATCH/dump.log" 2>&1 \
  || { tail -30 "$SCRATCH/dump.log"; exit 1; }
[[ -s $SCRATCH/fixtures/extraction.js ]] || { echo "check-reader-engine: the scripts were not written" >&2; tail -30 "$SCRATCH/dump.log"; exit 1; }

echo "==> running them in $OUT_DIR"
node "$SHELL_DIR/scripts/check-reader-engine.mjs" --chromium "$CHROMIUM" --fixtures "$SCRATCH/fixtures" \
  --profile "$SCRATCH/profile" --out "$SCRATCH/answers"

echo "==> sanitising the engine's answers"
DARNI_READER_ENGINE_ANSWERS="$SCRATCH/answers" swift test --skip-build \
  --filter 'ReaderEngineAnswerTests/testAnswersFromTheEngineGiveTheSameReader' >"$SCRATCH/answers.log" 2>&1 \
  || { grep -E "error:|failed" "$SCRATCH/answers.log" | head -20; exit 1; }
grep -E "Executed 1 test, with 0 failures" "$SCRATCH/answers.log" | head -1
echo "check-reader-engine: passed"
