#!/usr/bin/env bash
# The weekly performance check (docs/PERFORMANCE-CHIP.md §7). Owner, 2026-11-22: the
# performance metric is collated once a week and is not part of the release cycle; a release
# never waits for it. (The /compare feature comparison is a different thing and still runs
# with every release, from the monorepo's own scripts.)
#
# Usage: scripts/perf-check.sh --weekly [--remeasure] [options]
#        scripts/perf-check.sh --build NNNN [--released] [options]
#   options: [--compare [--browsers LIST]] [--halt RULES] [--confirm FILE] [--runs N] [--no-speedometer]
#            [--arc-quit-allowed] [--quit-owner-darni] [--data DIR] [--no-commit] [--no-guards] [--gate-only FILE]
#
#   --weekly         measures the newest released build: the highest v0.1.0-NNNN tag. If that
#                    build is already in the data folder (no release since the last weekly run),
#                    it says so and measures nothing, unless --remeasure (a second session of the
#                    same build, for calibration; the earlier file stays in git history)
#                    Every week it also measures the rotation: the five /compare browsers measured
#                    longest ago (python3 -m darni_perf rotation), as a comparison session that
#                    feeds comparison/latest.json; --no-rotation skips it
#   --check-due      with --weekly: only say what a run would do and exit (0 nothing due, 10 due);
#                    touches nothing, needs no screen. The weekly scheduled task uses it.
#   --arc-baseline   the one-off Arc run: Arc alone, saved as baselines/arc.json for good (needs
#                    --arc-quit-allowed and a fair Arc profile: docs/PERFORMANCE-CHIP.md §5)
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
#   --quit-other-browsers  the owner allowed (2026-11-23) quitting their other browsers gracefully for
#                    the run: noted, quit (a "quit with N tabs?" prompt is cancelled and the run
#                    refused), relaunched after with their windows checked
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
BUILD="" WEEKLY=0 REMEASURE=0 CHECK_DUE=0 ROTATE=1 ARC_BASELINE=0 RELEASED=0 COMPARE=0 BROWSERS="" HALT="" CONFIRM="" RUNS=5 SPEEDOMETER=1 ARC=0 COMMIT=1 GUARDS=1 GATE_ONLY="" OWNER_DARNI=0 OTHERS=0
die() { echo "perf-check: $*" >&2; exit 2; }
refuse() { echo "perf-check: refusing to run: $*" >&2; exit 75; }
while [[ $# -gt 0 ]]; do
  case "$1" in
    --build) BUILD="$2"; shift ;;
    --weekly) WEEKLY=1 ;;
    --remeasure) REMEASURE=1 ;;
    --check-due) CHECK_DUE=1 ;;
    --no-rotation) ROTATE=0 ;;
    --arc-baseline) ARC_BASELINE=1 ;;
    --released) RELEASED=1 ;;
    --compare) COMPARE=1 ;;
    --browsers) BROWSERS="$2"; shift ;;
    --halt) HALT="$2"; shift ;;
    --confirm) CONFIRM="$2"; shift ;;
    --runs) RUNS="$2"; shift ;;
    --no-speedometer) SPEEDOMETER=0 ;;
    --arc-quit-allowed) ARC=1 ;;
    --quit-owner-darni) OWNER_DARNI=1 ;;
    --quit-other-browsers) OTHERS=1 ;;
    --data) DATA="$2"; shift ;;
    --no-commit) COMMIT=0 ;;
    --no-guards) GUARDS=0 ;;
    --gate-only) GATE_ONLY="$2"; shift ;;
    -h|--help) sed -n '2,47p' "$0"; exit 0 ;;
    *) die "unknown option $1" ;;
  esac
  shift
done
[[ -d $DATA || $COMMIT == 0 ]] || die "no data folder $DATA (make the perf-data worktree, or pass --data)"
py() { (cd "$PERF" && python3 -m darni_perf "$@"); }
DO_DARNI=1 DO_ROTATION=0
if [[ $WEEKLY == 1 ]]; then
  [[ -z $BUILD ]] || die "--weekly picks the build itself; drop --build"
  TAG="$(git -C "$REPO" tag --list 'v0.1.0-*' --sort=-v:refname | head -n 1)"
  BUILD="${TAG#v0.1.0-}"
  [[ $BUILD =~ ^[0-9]+$ ]] || die "no released build: no v0.1.0-NNNN tag"
  RELEASED=1
  HARNESS_NOW="$(cd "$PERF" && python3 -c 'import darni_perf; print(darni_perf.HARNESS)')"
  HARNESS_THEN=""
  [[ ! -f $DATA/builds/$BUILD.json ]] || HARNESS_THEN="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["method"]["harness"])' "$DATA/builds/$BUILD.json")"
  if [[ -f $DATA/builds/$BUILD.json && $HARNESS_THEN != "$HARNESS_NOW" ]]; then
    echo "perf-check: Darni $BUILD was measured with harness $HARNESS_THEN; the harness is now $HARNESS_NOW, so it is measured again"
  elif [[ -f $DATA/builds/$BUILD.json && $REMEASURE == 0 ]]; then
    DO_DARNI=0
    echo "perf-check: Darni $BUILD ($TAG), the newest release, is already measured ($(sed -n 's/.*"measured_at": "\([^"]*\)".*/\1/p' "$DATA/builds/$BUILD.json" | head -n 1)); no release since."
  else
    echo "perf-check: due: Darni $BUILD ($TAG), the newest release"
  fi
  if [[ $ROTATE == 1 ]]; then
    WEEK="$(py rotation --data "$DATA" --json | python3 -c 'import json,sys; print(",".join(json.load(sys.stdin)["week"]))')"
    [[ -z $WEEK ]] || { DO_ROTATION=1; echo "perf-check: due: this week's rotation: $WEEK"; py rotation --data "$DATA" | tail -n 2; }
  fi
  if [[ $DO_DARNI == 0 && $DO_ROTATION == 0 ]]; then
    echo "perf-check: nothing to measure this week (--remeasure to measure Darni $BUILD again)"
    exit 0
  fi
  [[ $CHECK_DUE == 0 ]] || exit 10
fi
[[ $CHECK_DUE == 0 ]] || die "--check-due goes with --weekly"
if [[ $ARC_BASELINE == 1 ]]; then
  [[ $ARC == 1 ]] || die "--arc-baseline needs --arc-quit-allowed (the owner's leave to quit and relaunch Arc)"
  DO_DARNI=0
  BUILD="${BUILD:-arc}"
fi
[[ $BUILD =~ ^[0-9]+$ || $ARC_BASELINE == 1 ]] || die "--build NNNN, --weekly or --arc-baseline is required"
mkdir -p "$DATA"
STAMP="$(date -u +%Y-%m-%dT%H-%M-%SZ)"
OUT="$SHELL_DIR/bench/results/perf/$STAMP-$BUILD"   # git-ignored
mkdir -p "$OUT"
VERDICT=0 RESULT=""

if [[ -z $GATE_ONLY ]]; then
  MEASURE=(--runs "$RUNS" --data "$DATA")
  if [[ $DO_DARNI == 1 ]]; then
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
    MEASURE+=(--darni-app "$QA")
  fi

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

  [[ $SPEEDOMETER == 1 ]] || MEASURE+=(--no-speedometer --speedometer-reason "${DARNI_PERF_SPEEDOMETER_REASON:-Speedometer was not run in this session}")
  [[ $ARC == 0 ]] || MEASURE+=(--arc-quit-allowed)
  [[ $OWNER_DARNI == 0 ]] || MEASURE+=(--quit-owner-darni)
  [[ $OTHERS == 0 ]] || MEASURE+=(--quit-other-browsers)
  if [[ $DO_DARNI == 1 ]]; then
    RELEASE_FLAG=()
    [[ $RELEASED == 0 ]] || RELEASE_FLAG=(--released)
    RESULT="$OUT/build-$BUILD.json"
    set +e
    py measure --kind build --id "$BUILD" --browsers darni ${RELEASE_FLAG[@]+"${RELEASE_FLAG[@]}"} "${MEASURE[@]}" --out "$RESULT"
    STATUS=$?
    set -e
    [[ $STATUS == 0 ]] || { echo "perf-check: the measurement ended with $STATUS; nothing gated or committed" >&2; exit "$STATUS"; }
  fi
  SESSION="" SESSION_ID=""
  if [[ $ARC_BASELINE == 1 ]]; then
    # Arc on the owner's real profile (owner, 2026-11-23): darni_perf/arc.py has the rules.
    MEASURE+=(--arc-owner-profile)
    SESSION="arc" SESSION_ID="arc-baseline-$(date +%Y-%m-%d)"
  elif [[ $DO_ROTATION == 1 ]]; then
    SESSION="rotation" SESSION_ID="$(date +%Y-%m-%d)-rotation"
  elif [[ $COMPARE == 1 ]]; then
    SESSION="${BROWSERS:-$COMPARE_BROWSERS}" SESSION_ID="$(date +%Y-%m-%d)-$BUILD"
  fi
  if [[ -n $SESSION ]]; then
    set +e
    py measure --kind comparison --id "$SESSION_ID" --browsers "$SESSION" "${MEASURE[@]}" --out "$OUT/comparison.json"
    CSTATUS=$?
    set -e
    [[ $CSTATUS == 0 ]] || echo "perf-check: the comparison session ended with $CSTATUS" >&2
  fi
else
  RESULT="$GATE_ONLY"
  [[ -f $RESULT ]] || die "no result $RESULT"
fi

if [[ -n $RESULT ]]; then
  GATE_ARGS=(--data "$DATA" --result "$RESULT")
  [[ ! -f $DATA/thresholds.json ]] || GATE_ARGS+=(--thresholds "$DATA/thresholds.json")
  [[ -z $HALT ]] || GATE_ARGS+=(--halt "$HALT")
  [[ -z $CONFIRM ]] || GATE_ARGS+=(--confirm "$CONFIRM")
  set +e
  py gate "${GATE_ARGS[@]}" | tee "$OUT/gate.txt"
  VERDICT=${PIPESTATUS[0]}
  set -e
  [[ $VERDICT != 2 ]] || exit 2
fi
WHAT=()
[[ -z $RESULT ]] || WHAT+=("Darni $BUILD measured, gate $(sed -n '1s/^gate: \([A-Z_]*\).*/\1/p' "$OUT/gate.txt" | tr 'A-Z' 'a-z')")
if [[ -f $OUT/comparison.json ]]; then
  if [[ $ARC_BASELINE == 1 ]]; then
    py baseline --data "$DATA" --result "$OUT/comparison.json"
    WHAT+=("the Arc baseline")
  else
    py compare --data "$DATA" --result "$OUT/comparison.json" | tee "$OUT/comparison.txt"
    WHAT+=("comparison $SESSION_ID")
  fi
fi
py index --data "$DATA" >/dev/null
[[ ! -f $DATA/baselines/arc.json ]] || py score --data "$DATA" | tee "$OUT/score.txt" || true
py chart --data "$DATA" --out "$OUT/chart.html"

if [[ $COMMIT == 1 && ${#WHAT[@]} -gt 0 ]]; then
  WORKTREE="$(git -C "$DATA" rev-parse --show-toplevel)"
  [[ "$(git -C "$WORKTREE" branch --show-current)" == perf-data ]] || die "$WORKTREE is not on perf-data: not committed"
  git -C "$WORKTREE" add -- "$DATA"
  if ! git -C "$WORKTREE" diff --cached --quiet; then
    git -C "$WORKTREE" commit -q -m "performance: $(IFS=';'; echo "${WHAT[*]}" | sed 's/;/; /g')" \
      -m "Generated by shell/scripts/perf-check.sh in the Darni repo." -m "Co-Authored-By: ${DARNI_PERF_COAUTHOR:-Claude Fable 5.2 <noreply@anthropic.com>}"
    echo "perf-check: committed on perf-data in $WORKTREE (not pushed)"
  fi
fi
echo "perf-check: results and chart in $OUT"
exit "$VERDICT"
