#!/usr/bin/env bash
# One heavy job at a time on this Mac. A full `swift test`, an engine build, the WebKit pass,
# a release build and a performance measurement each take this lock, so they queue instead of
# running on top of each other (timing flakes at load ~50; one spoiled performance baseline).
#
# Usage: scripts/heavy-job.sh [--try] [--timeout S] <name> -- <command…>
#        scripts/heavy-job.sh --status
#        scripts/heavy-job.sh [--try] [--timeout S] --hold <name> <seconds>
#        scripts/heavy-job.sh --release <name>
#
#   <name> -- <command…>   run the command holding the lock; the lock is freed when the command
#                          ends or this script is signalled (the signal is passed on to it)
#   --try                  if the lock is taken, exit 75 instead of waiting
#   --timeout S            wait S seconds, then exit 75
#   --status               print "free", or who holds the lock, since when and with what command
#   --hold <name> <s>      take the lock for a window of <s> seconds (a performance slot) and
#                          return; it is kept until the time runs out or --release <name>. A
#                          command run as the same <name> runs inside the window, and the window
#                          does not end while such a command is still running.
#   --release <name>       end a --hold early; only the name that holds it can
#
# Waiting is the default; who holds the lock is printed at once and then once a minute.
# The lock is a directory (mkdir is atomic): ~/Library/Caches/darni-heavy-job.lock, with a file
# `owner` (pid, name, start time, command). A lock whose pid is gone is stale: the next job
# takes it over and says so.
#
# Nesting: the command runs with DARNI_HEAVY_JOB_HELD=<name>. With that variable set, this
# script runs its command directly, so a script that holds the lock can call another script
# that takes it.
#
# From a script that needs the lock for a part of its run, source this file:
#   source "$SHELL_DIR/scripts/heavy-job.sh"
#   heavy_job_begin <name>     # waits; the lock belongs to the script's own pid
#   …
#   heavy_job_end              # also run at exit, when the script has no EXIT trap of its own
#
# Environment: DARNI_HEAVY_JOB_LOCK    another lock path (tests never touch the real one)
#              DARNI_HEAVY_JOB_POLL    seconds between tries while waiting (default 1)
#              DARNI_HEAVY_JOB_REPORT  seconds between "waiting for" lines (default 60)
# Exit status: the command's own; 75 the lock was not obtained (--try, --timeout);
#              64 wrong usage; 1 --release refused.

_hj_lock() { printf '%s' "${DARNI_HEAVY_JOB_LOCK:-$HOME/Library/Caches/darni-heavy-job.lock}"; }
_hj_say() { echo "heavy-job: $*" >&2; }

# _hj_field KEY FILE: the value of KEY in an owner file (read as text, never run).
_hj_field() { sed -n "/^$1=/{s///p;q;}" "$2" 2>/dev/null || true; }

# When a pid started; empty when it is gone. Kept with the pid, so a reused pid is not the owner.
_hj_pstart() {
  local started
  started="$(LC_ALL=C ps -o lstart= -p "$1" 2>/dev/null || true)"
  started="${started#"${started%%[![:space:]]*}"}"
  printf '%s' "${started%"${started##*[![:space:]]}"}"
}

_hj_alive() {
  local pid recorded now
  pid="$(_hj_field pid "$1")"
  [[ $pid =~ ^[0-9]+$ ]] || return 1
  now="$(_hj_pstart "$pid")"
  [[ -n $now ]] || return 1
  recorded="$(_hj_field pstart "$1")"
  [[ -z $recorded || $recorded == "$now" ]]
}

_hj_age() {
  local modified
  modified="$(stat -f %m "$1" 2>/dev/null || true)"
  [[ $modified =~ ^[0-9]+$ ]] || { echo 0; return 0; }
  echo $(( $(date +%s) - modified ))
}

_hj_clock() { date -r "$1" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "$1"; }

# _hj_write_owner PID NAME KIND UNTIL TOKEN COMMAND: written beside the file, then renamed over it.
_hj_write_owner() {
  local lock new command="${6//$'\n'/ }"
  lock="$(_hj_lock)"
  new="$lock/owner.new.$$"
  {
    printf 'pid=%s\n' "$1"
    printf 'pstart=%s\n' "$(_hj_pstart "$1")"
    printf 'name=%s\n' "$2"
    printf 'kind=%s\n' "$3"
    printf 'started=%s\n' "$(date '+%Y-%m-%d %H:%M:%S')"
    printf 'until=%s\n' "$4"
    printf 'token=%s\n' "$5"
    printf 'command=%s\n' "$command"
  } >"$new" 2>/dev/null && mv -f "$new" "$lock/owner" 2>/dev/null
}

_hj_describe() {
  local owner="$1" name pid
  name="$(_hj_field name "$owner")"
  pid="$(_hj_field pid "$owner")"
  if [[ ! -f $owner ]]; then
    echo "a job that is taking or freeing the lock"
  elif [[ "$(_hj_field kind "$owner")" == hold ]]; then
    echo "$name (a hold, pid $pid) since $(_hj_field started "$owner"), until $(_hj_clock "$(_hj_field until "$owner")")"
  else
    echo "$name (pid $pid) since $(_hj_field started "$owner"): $(_hj_field command "$owner")"
  fi
}

# Commands running inside a hold leave join.<pid> in the lock; true while one of them is alive.
_hj_joined() {
  local lock file pid
  lock="$(_hj_lock)"
  for file in "$lock"/join.*; do
    [[ -e $file ]] || continue
    pid="${file##*.}"
    if [[ -n "$(_hj_pstart "$pid")" && "$(_hj_pstart "$pid")" == "$(cat "$file" 2>/dev/null || true)" ]]; then return 0; fi
    rm -f "$file"
  done
  return 1
}

# _hj_take NAME KIND UNTIL COMMAND: one try. 0 the lock is ours (_HJ_TOKEN names it); 3 we run
# inside a hold of the same name; 1 somebody else has it.
_hj_take() {
  local name="$1" kind="$2" until="$3" command="$4" lock owner token
  lock="$(_hj_lock)"
  owner="$lock/owner"
  token="$$.$RANDOM.$(date +%s)"
  mkdir -p "$(dirname "$lock")" 2>/dev/null || true
  if mkdir "$lock" 2>/dev/null; then
    _hj_write_owner "$$" "$name" "$kind" "$until" "$token" "$command" || return 1
    _HJ_TOKEN="$token"
    return 0
  fi
  if [[ -f $owner ]]; then
    if _hj_alive "$owner"; then
      [[ $kind == run && "$(_hj_field kind "$owner")" == hold && "$(_hj_field name "$owner")" == "$name" ]] || return 1
      token="$(_hj_field token "$owner")"
      _hj_pstart "$$" >"$lock/join.$$" 2>/dev/null || return 1
      # The hold may have ended between the look and the mark.
      if [[ "$(_hj_field token "$owner")" != "$token" ]]; then rm -f "$lock/join.$$"; return 1; fi
      return 3
    fi
  elif [[ "$(_hj_age "$lock")" -lt 10 ]]; then
    return 1   # no owner file yet: being taken or freed this instant
  fi
  # Stale. Only one contender takes it over; the lock directory itself is never removed here,
  # so nobody's mkdir can succeed in between.
  if ! mkdir "$lock/takeover" 2>/dev/null; then
    [[ "$(_hj_age "$lock/takeover")" -lt 30 ]] || rmdir "$lock/takeover" 2>/dev/null || true
    return 1
  fi
  if [[ -f $owner ]] && _hj_alive "$owner"; then rmdir "$lock/takeover" 2>/dev/null || true; return 1; fi
  if [[ -f $owner ]]; then
    _hj_say "took over a stale lock: $(_hj_field name "$owner") (pid $(_hj_field pid "$owner"), since $(_hj_field started "$owner")) is gone"
  else
    _hj_say "took over a stale lock that named no owner"
  fi
  rm -f "$lock"/join.* 2>/dev/null || true
  _hj_write_owner "$$" "$name" "$kind" "$until" "$token" "$command" || { rmdir "$lock/takeover" 2>/dev/null || true; return 1; }
  rmdir "$lock/takeover" 2>/dev/null || true
  _HJ_TOKEN="$token"
  return 0
}

# _hj_wait NAME KIND UNTIL COMMAND: _hj_take until it is 0 or 3; 75 on --try or --timeout.
_hj_wait() {
  local began=$SECONDS report=0 status lock
  lock="$(_hj_lock)"
  while :; do
    if _hj_take "$@"; then status=0; else status=$?; fi
    [[ $status == 1 ]] || return "$status"
    if [[ ${_HJ_TRY:-0} == 1 ]]; then
      _hj_say "the lock is taken by $(_hj_describe "$lock/owner"); not waiting (--try)"
      return 75
    fi
    # SECONDS counts whole seconds, so "more than" is what makes the wait at least that long.
    if [[ -n ${_HJ_TIMEOUT:-} ]] && (( _HJ_TIMEOUT == 0 || SECONDS - began > _HJ_TIMEOUT )); then
      _hj_say "still taken by $(_hj_describe "$lock/owner") after ${_HJ_TIMEOUT}s; giving up (--timeout)"
      return 75
    fi
    if (( SECONDS >= report )); then
      _hj_say "$1 is waiting for $(_hj_describe "$lock/owner")"
      report=$(( SECONDS + ${DARNI_HEAVY_JOB_REPORT:-60} ))
    fi
    sleep "${DARNI_HEAVY_JOB_POLL:-1}"
  done
}

# Frees the lock if it is still ours. Only the owner removes its lock, in one rename.
_hj_release() {
  local lock gone
  lock="$(_hj_lock)"
  [[ -n ${_HJ_TOKEN:-} && "$(_hj_field token "$lock/owner")" == "$_HJ_TOKEN" ]] || return 0
  gone="$lock.freed.$$"
  rm -rf "$gone"
  if mv "$lock" "$gone" 2>/dev/null; then rm -rf "$gone"; fi
  _HJ_TOKEN=""
}

# For a script that sources this file: the lock from here to heavy_job_end, held by the
# script's own pid. Inside another heavy job it does nothing.
heavy_job_begin() {
  local name="${1:?heavy_job_begin needs a name}" status
  [[ -z ${DARNI_HEAVY_JOB_HELD:-} ]] || return 0
  if _hj_wait "$name" run "" "$(ps -o command= -p "$$" 2>/dev/null || echo "$0")"; then status=0; else status=$?; fi
  case "$status" in
    0) _HJ_STATE=lock ;;
    3) _HJ_STATE=join ;;
    *) return "$status" ;;
  esac
  export DARNI_HEAVY_JOB_HELD="$name"
  [[ -n "$(trap -p EXIT)" ]] || trap heavy_job_end EXIT
}

heavy_job_end() {
  case "${_HJ_STATE:-}" in
    lock) _hj_release ;;
    join) rm -f "$(_hj_lock)/join.$$" ;;
    *) return 0 ;;
  esac
  _HJ_STATE=""
  unset DARNI_HEAVY_JOB_HELD
}

_hj_usage() { sed -n '2,41p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

_hj_run() {
  local name="$1" status child signalled=0
  shift
  if [[ -n ${DARNI_HEAVY_JOB_HELD:-} ]]; then exec "$@"; fi
  if _hj_wait "$name" run "" "$*"; then status=0; else status=$?; fi
  case "$status" in
    0) _HJ_STATE=lock ;;
    3) _HJ_STATE=join ;;
    *) exit "$status" ;;
  esac
  export DARNI_HEAVY_JOB_HELD="$name"
  trap heavy_job_end EXIT
  # The command runs in the background so that a signal reaches this script at once. A
  # background command ignores SIGINT, so every signal is passed on as SIGTERM.
  trap 'signalled=15; [[ -z ${child:-} ]] || kill -TERM "$child" 2>/dev/null' TERM
  trap 'signalled=2; [[ -z ${child:-} ]] || kill -TERM "$child" 2>/dev/null' INT
  trap 'signalled=1; [[ -z ${child:-} ]] || kill -TERM "$child" 2>/dev/null' HUP
  if { : <&0; } 2>/dev/null; then "$@" <&0 & else "$@" & fi
  child=$!
  [[ $signalled == 0 ]] || kill -TERM "$child" 2>/dev/null
  wait "$child"; status=$?
  while kill -0 "$child" 2>/dev/null; do wait "$child"; status=$?; done
  if [[ $signalled != 0 ]]; then
    wait "$child" 2>/dev/null
    exit $(( 128 + signalled ))
  fi
  exit "$status"
}

_hj_hold() {
  local name="$1" seconds="$2" until status keeper lock
  lock="$(_hj_lock)"
  until=$(( $(date +%s) + seconds ))
  if _hj_wait "$name" hold "$until" "a hold of ${seconds}s"; then status=0; else status=$?; fi
  [[ $status == 0 ]] || exit "$status"
  # A keeper process owns the lock from here: it frees it when the time is up or on --release.
  "$_HJ_SELF" --keeper "$_HJ_TOKEN" "$until" </dev/null >/dev/null 2>&1 &
  keeper=$!
  _hj_write_owner "$keeper" "$name" hold "$until" "$_HJ_TOKEN" "a hold of ${seconds}s" \
    || { kill "$keeper" 2>/dev/null; _hj_say "could not hand the lock to its keeper"; exit 1; }
  echo "heavy-job: $name holds the lock until $(_hj_clock "$until"); end it sooner with: heavy-job.sh --release $name"
}

_hj_keeper() {
  local until="$2" lock stop=0
  _HJ_TOKEN="$1"
  lock="$(_hj_lock)"
  trap '' HUP INT
  trap 'stop=1' TERM
  while [[ "$(_hj_field token "$lock/owner")" == "$_HJ_TOKEN" ]]; do
    if [[ $stop == 1 ]] || { (( $(date +%s) >= until )) && ! _hj_joined; }; then
      _hj_release
      exit 0
    fi
    sleep "${DARNI_HEAVY_JOB_POLL:-1}"
  done
}

_hj_status() {
  local lock owner
  lock="$(_hj_lock)"
  owner="$lock/owner"
  if [[ ! -d $lock ]]; then
    echo "free"
  elif [[ -f $owner ]] && ! _hj_alive "$owner"; then
    echo "free (a stale lock is left: $(_hj_field name "$owner"), pid $(_hj_field pid "$owner"), is gone; the next job takes it over)"
  else
    echo "held by $(_hj_describe "$owner")"
  fi
}

_hj_end_hold() {
  local name="$1" lock owner token tries=0
  lock="$(_hj_lock)"
  owner="$lock/owner"
  if [[ ! -d $lock ]] || { [[ -f $owner ]] && ! _hj_alive "$owner"; }; then
    echo "free"
    return 0
  fi
  if [[ "$(_hj_field kind "$owner")" != hold ]]; then
    _hj_say "not released: the lock is taken by $(_hj_describe "$owner"), a running job; it frees the lock when it ends"
    return 1
  fi
  if [[ "$(_hj_field name "$owner")" != "$name" ]]; then
    _hj_say "not released: the lock is held by $(_hj_field name "$owner"); only --release $(_hj_field name "$owner") ends it"
    return 1
  fi
  token="$(_hj_field token "$owner")"
  kill -TERM "$(_hj_field pid "$owner")" 2>/dev/null || true
  while [[ "$(_hj_field token "$owner")" == "$token" ]]; do
    tries=$(( tries + 1 ))
    if (( tries > 300 )); then _hj_say "the hold of $name did not end"; return 1; fi
    sleep 0.1
  done
  echo "released $name"
}

_hj_main() {
  set -u
  local mode=run name="" seconds=""
  _HJ_TRY=0 _HJ_TIMEOUT=""
  _HJ_SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --try) _HJ_TRY=1 ;;
      --timeout)
        _HJ_TIMEOUT="${2:-}"
        [[ $_HJ_TIMEOUT =~ ^[0-9]+$ ]] || { _hj_say "--timeout needs a number of seconds"; exit 64; }
        shift ;;
      --status) mode=status ;;
      --hold)
        mode=hold name="${2:-}" seconds="${3:-}"
        [[ $seconds =~ ^[0-9]+$ ]] || { _hj_say "--hold needs a name and a number of seconds"; exit 64; }
        shift 2 ;;
      --release) mode=release name="${2:-}"; [[ $# -ge 2 ]] && shift ;;
      --keeper) _hj_keeper "${2:-}" "${3:-0}"; exit 0 ;;
      -h|--help) _hj_usage; exit 0 ;;
      --) shift; break ;;
      -*) _hj_say "unknown option: $1"; exit 64 ;;
      *)
        [[ -z $name && $mode == run ]] || { _hj_say "unexpected argument: $1 (the command goes after --)"; exit 64; }
        name="$1" ;;
    esac
    shift
  done
  if [[ $mode == status ]]; then _hj_status; exit 0; fi
  [[ $name =~ ^[A-Za-z0-9._-]+$ ]] || { _hj_say "a job needs a name (letters, digits, . _ -); see --help"; exit 64; }
  case "$mode" in
    hold)
      # From inside a heavy job it would wait for that job, which waits for this command.
      [[ -z ${DARNI_HEAVY_JOB_HELD:-} ]] || { _hj_say "a hold cannot be taken from inside the heavy job $DARNI_HEAVY_JOB_HELD"; exit 64; }
      _hj_hold "$name" "$seconds" ;;
    release) _hj_end_hold "$name" || exit 1 ;;
    run)
      [[ $# -gt 0 ]] || { _hj_say "no command: heavy-job.sh <name> -- <command…>"; exit 64; }
      _hj_run "$name" "$@" ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then _hj_main "$@"; fi
