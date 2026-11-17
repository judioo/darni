# Sourced by engine/scripts/fetch.sh and shell/scripts/build-engine-release.sh.
# engine/patches/series-subprojects lists patches for Chromium's sub-project checkouts
# (third_party/ffmpeg, third_party/angle, ...). Each applied patch is one local commit in
# its checkout, with a subject naming the patch, so a later step can tell it is there.

# Prints "<checkout>\t<patch>" per entry; fails on a malformed line.
subproject_entries() {
  local list="$1" line checkout rel extra
  [[ -f "$list" ]] || return 0
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%%#*}"
    checkout='' rel='' extra=''
    read -r checkout rel extra <<<"$line" || true
    [[ -n "$checkout" ]] || continue
    if [[ -z "$rel" || -n "$extra" || "$checkout" == /* || "$checkout" == *..* || "$rel" == /* || "$rel" == *..* ]]; then
      printf 'invalid series-subprojects line: %s\n' "$line" >&2
      return 1
    fi
    printf '%s\t%s\n' "$checkout" "$rel"
  done < "$list"
}

subproject_subject() { printf 'rearc subproject patch: %s' "$1"; }

# True when the checkout's history has the commit that applied the patch.
subproject_applied() {
  local dir="$1" rel="$2" subjects
  subjects="$(git -C "$dir" log --format=%s -n 200)" || return 1
  grep -Fxq "$(subproject_subject "$rel")" <<<"$subjects"
}
