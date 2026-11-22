#!/usr/bin/env bash
# The performance check before a release (docs/PERFORMANCE-CHIP.md §7).
#
# Usage: scripts/perf-check.sh --build NNNN [--released] [--compare [--browsers LIST]]
#          [--halt RULES] [--confirm FILE] [--runs N] [--no-speedometer] [--arc-quit-allowed] [--quit-owner-darni]
#          [--data DIR] [--no-commit] [--no-guards] [--gate-only FILE]
#
#   --build NNNN     measures shell/dist/rcNNNN/Darni.app, through a QA copy made once at
#                    shell/dist/perf-NNNN/Darni.app (ReArcReleaseVerification, re-signed), on a
#                    fresh REARC_DATA_DIR per run
#   --released       this build is published: it becomes the next build's baseline
#   --compare        also measure the other browsers (default list below) in the same
#                    session and save a comparison; --browsers overrides the list
#   --halt RULES     rules that halt for this run (regression,major,trend); the default
#                    policy is in thresholds.json (everything flags, 2026-11-22)
#   --confirm FILE   a second measurement of the same build: a regression must repeat
#   --arc-quit-allowed  the owner approved quitting and relaunching Arc for this session
#   --quit-owner-darni  the owner allowed quitting their Darni by its Quit menu item for the run;
#                    it is relaunched after and checked
#   --data DIR       the monorepo data folder (default: the perf-data worktree's
#                    data/performance); --no-commit leaves it uncommitted
#   --gate-only FILE gate, index, chart and commit an existing build result; measures nothing
#
# Needs the screen for measuring: the input gate ~/Library/Caches/rearc-input-allowed, an
# unlocked screen, and nothing else posting input (the input lock is taken for the run).
# Never pushes. Exit codes: 0 pass, 1 halt, 2 usage or not comparable, 3 flag, 75 conditions.
set -euo pipefail

SHELL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
REPO="$(cd "$SHELL_DIR/.." && pwd)"
PERF="$REPO/perf"
DATA="${DARNI_PERF_DATA:-$HOME/.t3/worktrees/rearc-monorepo/perf-data/data/performance}"
COMPARE_BROWSERS="darni,chrome,brave,helium,cra,ardia,zen,orion,arc,dia,safari"
BUILD="" RELEASED=0 COMPARE=0 BROWSERS="" HALT="" CONFIRM="" RUNS=5 SPEEDOMETER=1 ARC=0 COMMIT=1 GUARDS=1 GATE_ONLY="" OWNER_DARNI=0
die() { echo "perf-check: $*" >&2; exit 2; }
refuse() { echo "perf-check: refusing to run: $*" >&2; exit 75; }
while [[ $# -gt 0 ]]; do
  case "$1" in
    --build) BUILD="$2"; shift ;;
    --released) RELEASED=1 ;;
    --compare) COMPARE=1 ;;
    --browsers) BROWSERS="$2"; shift ;;
    --halt) HALT="$2"; shift ;;
    --confirm) CONFIRM="$2"; shift ;;
    --runs) RUNS="$2"; shift ;;
    --no-speedometer) SPEEDOMETER=0 ;;
    --arc-quit-allowed) ARC=1 ;;
    --quit-owner-darni) OWNER_DARNI=1 ;;
    --data) DATA="$2"; shift ;;
    --no-commit) COMMIT=0 ;;
    --no-guards) GUARDS=0 ;;
    --gate-only) GATE_ONLY="$2"; shift ;;
    -h|--help) sed -n '2,29p' "$0"; exit 0 ;;
    *) die "unknown option $1" ;;
  esac
  shift
done
[[ $BUILD =~ ^[0-9]+$ ]] || die "--build NNNN is required"
[[ -d $DATA || $COMMIT == 0 ]] || die "no data folder $DATA (make the perf-data worktree, or pass --data)"
mkdir -p "$DATA"
STAMP="$(date -u +%Y-%m-%dT%H-%M-%SZ)"
OUT="$SHELL_DIR/bench/results/perf/$STAMP-$BUILD"   # git-ignored
mkdir -p "$OUT"
py() { (cd "$PERF" && python3 -m darni_perf "$@"); }

if [[ -z $GATE_ONLY ]]; then
  SOURCE="$SHELL_DIR/dist/rc$BUILD/Darni.app"
  QA="$SHELL_DIR/dist/perf-$BUILD/Darni.app"
  [[ -d $SOURCE || -d $QA ]] || die "no build at $SOURCE"
  if [[ ! -d $QA ]]; then
    echo "perf-check: QA copy of $BUILD -> $QA"
    mkdir -p "$(dirname "$QA")"
    ditto "$SOURCE" "$QA"
    plutil -insert ReArcReleaseVerification -bool true "$QA/Contents/Info.plist"
    REARC_ICLOUD_ENVIRONMENT=Production "$SHELL_DIR/scripts/sign-release.sh" "$QA" >"$OUT/sign.log" 2>&1 \
      || { rm -rf "$QA"; die "signing the QA copy failed (see $OUT/sign.log)"; }
  fi
  [[ "$(/usr/libexec/PlistBuddy -c 'Print :ReArcReleaseVerification' "$QA/Contents/Info.plist" 2>/dev/null)" == true ]] \
    || die "$QA is not a QA copy (no ReArcReleaseVerification): a shipped bundle refuses REARC_DATA_DIR"

  # The probe (arc-vs-rearc probe): built from this checkout; Package.resolved is kept as it was.
  RESOLVED="$SHELL_DIR/Package.resolved"
  cp "$RESOLVED" "$OUT/Package.resolved.bak"
  swift build --package-path "$SHELL_DIR" -c release --product arc-vs-rearc >"$OUT/probe-build.log" 2>&1 \
    || { cp "$OUT/Package.resolved.bak" "$RESOLVED"; die "building the probe failed (see $OUT/probe-build.log)"; }
  cp "$OUT/Package.resolved.bak" "$RESOLVED"

  [[ -e "$HOME/Library/Caches/rearc-input-allowed" ]] || refuse "no input gate: the owner has not lent the screen"
  if [[ $GUARDS == 1 ]]; then
    # This Mac rests at 25-35 % CPU from the owner's apps: the limits perf-0 measured (PERF-BASELINE.md).
    export REARC_BENCH_MAX_LOAD1="${REARC_BENCH_MAX_LOAD1:-12}" REARC_BENCH_MAX_LOAD5="${REARC_BENCH_MAX_LOAD5:-20}" \
           REARC_BENCH_MIN_IDLE="${REARC_BENCH_MIN_IDLE:-65}"
    source "$SHELL_DIR/scripts/bench-guards.sh"
    bench_guards
  fi

  MEASURE=(--runs "$RUNS" --darni-app "$QA")
  RELEASE_FLAG=()
  [[ $RELEASED == 0 ]] || RELEASE_FLAG=(--released)
  [[ $SPEEDOMETER == 1 ]] || MEASURE+=(--no-speedometer --speedometer-reason "${DARNI_PERF_SPEEDOMETER_REASON:-Speedometer was not run in this session}")
  [[ $ARC == 0 ]] || MEASURE+=(--arc-quit-allowed)
  [[ $OWNER_DARNI == 0 ]] || MEASURE+=(--quit-owner-darni)
  RESULT="$OUT/build-$BUILD.json"
  set +e
  py measure --kind build --id "$BUILD" --browsers darni ${RELEASE_FLAG[@]+"${RELEASE_FLAG[@]}"} "${MEASURE[@]}" --out "$RESULT"
  STATUS=$?
  set -e
  [[ $STATUS == 0 ]] || { echo "perf-check: the measurement ended with $STATUS; nothing gated or committed" >&2; exit "$STATUS"; }
  if [[ $COMPARE == 1 ]]; then
    set +e
    py measure --kind comparison --id "$(date +%Y-%m-%d)-$BUILD" --browsers "${BROWSERS:-$COMPARE_BROWSERS}" "${MEASURE[@]}" \
      --out "$OUT/comparison.json"
    CSTATUS=$?
    set -e
    [[ $CSTATUS == 0 ]] || echo "perf-check: the comparison ended with $CSTATUS; the build is still gated" >&2
  fi
else
  RESULT="$GATE_ONLY"
  [[ -f $RESULT ]] || die "no result $RESULT"
fi

GATE_ARGS=(--data "$DATA" --result "$RESULT")
[[ ! -f $DATA/thresholds.json ]] || GATE_ARGS+=(--thresholds "$DATA/thresholds.json")
[[ -z $HALT ]] || GATE_ARGS+=(--halt "$HALT")
[[ -z $CONFIRM ]] || GATE_ARGS+=(--confirm "$CONFIRM")
set +e
py gate "${GATE_ARGS[@]}" | tee "$OUT/gate.txt"
VERDICT=${PIPESTATUS[0]}
set -e
[[ $VERDICT != 2 ]] || exit 2
if [[ -f $OUT/comparison.json ]]; then
  py compare --data "$DATA" --result "$OUT/comparison.json" | tee "$OUT/comparison.txt"
fi
py chart --data "$DATA" --out "$OUT/chart.html"

if [[ $COMMIT == 1 ]]; then
  WORKTREE="$(git -C "$DATA" rev-parse --show-toplevel)"
  [[ "$(git -C "$WORKTREE" branch --show-current)" == perf-data ]] || die "$WORKTREE is not on perf-data: not committed"
  git -C "$WORKTREE" add -- "$DATA"
  if ! git -C "$WORKTREE" diff --cached --quiet; then
    git -C "$WORKTREE" commit -q -m "performance: Darni $BUILD measured, gate $(sed -n '1s/^gate: \([A-Z_]*\).*/\1/p' "$OUT/gate.txt" | tr 'A-Z' 'a-z')$([[ -f $OUT/comparison.json ]] && echo ", with a comparison")" \
      -m "Generated by shell/scripts/perf-check.sh in the Darni repo." -m "Co-Authored-By: ${DARNI_PERF_COAUTHOR:-Claude Fable 5.2 <noreply@anthropic.com>}"
    echo "perf-check: committed on perf-data in $WORKTREE (not pushed)"
  fi
fi
echo "perf-check: results and chart in $OUT"
exit "$VERDICT"
