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

subproject_sha() { shasum -a 256 "$1" | cut -d' ' -f1; }

# The revision chromium/src pins for a checkout (its gitlink).
subproject_pinned() { git -C "$1" rev-parse "HEAD:$2"; }

# The listed checkouts, each once, in list order.
subproject_checkouts() { cut -f1 <<<"$1" | awk 'NF && !seen[$0]++'; }

# The listed patches for one checkout, in order.
subproject_patches_for() { awk -F'\t' -v c="$2" '$1 == c {print $2}' <<<"$1"; }

# Pathspecs that leave the listed checkouts out of a chromium/src diff.
subproject_excludes() {
  local checkout
  while IFS= read -r checkout; do [[ -n "$checkout" ]] && printf ':(exclude)%s\n' "$checkout"; done < <(subproject_checkouts "$1")
}

# Commits a patch applied with --index: fixed identity and dates, so the same patch on the
# same revision gives the same commit on any Mac, and the patch file's SHA-256 in the
# message, so a changed patch under the same name is caught.
subproject_commit() {
  local dir="$1" rel="$2" patch="$3"
  GIT_AUTHOR_DATE='2000-01-01T00:00:00Z' GIT_COMMITTER_DATE='2000-01-01T00:00:00Z' \
    git -C "$dir" -c user.name='ReArc Overlay' -c user.email='rearc-overlay@localhost' \
    commit -q -m "$(subproject_subject "$rel")" -m "patch-sha256: $(subproject_sha "$patch")"
}

# True when applying the patch to the commit's parent gives exactly the commit's tree, so a
# commit amended in place (same subject and trailer, other content) is caught. Uses a
# temporary index; the checkout's own index and files are untouched.
subproject_tree_matches() {
  local dir="$1" commit="$2" patch="$3" index tree
  index="$(mktemp "${TMPDIR:-/tmp}/rearc-subproject-index.XXXXXX")" || return 1
  if GIT_INDEX_FILE="$index" git -C "$dir" read-tree "$commit^" \
     && GIT_INDEX_FILE="$index" git -C "$dir" apply --cached "$patch" 2>/dev/null; then
    tree="$(GIT_INDEX_FILE="$index" git -C "$dir" write-tree)"
  fi
  rm -f "$index"
  [[ -n "${tree:-}" && "$tree" == "$(git -C "$dir" rev-parse "$commit^{tree}")" ]]
}

# Checks one checkout: no loose changes, and its history from the pinned revision is
# exactly the given patches' commits, in order, each with the patch file's current SHA-256.
# With "prefix", a leading part of the list is enough (fetch.sh then applies the rest) and
# it prints how many are there. Prints the reason and fails otherwise.
subproject_verify() {
  local src="$1" checkout="$2" patches_dir="$3" mode="$4" entries="$5"
  local dir="$src/$checkout" pinned commits i=0 commit subject sha rel
  local -a wanted=()
  while IFS= read -r rel; do [[ -n "$rel" ]] && wanted+=("$rel"); done < <(subproject_patches_for "$entries" "$checkout")
  pinned="$(subproject_pinned "$src" "$checkout")" || { echo "src pins no revision for $checkout"; return 1; }
  git -C "$dir" diff --quiet && git -C "$dir" diff --cached --quiet || { echo "src/$checkout has uncommitted changes"; return 1; }
  git -C "$dir" merge-base --is-ancestor "$pinned" HEAD || { echo "src/$checkout does not descend from the pinned $pinned"; return 1; }
  commits="$(git -C "$dir" rev-list --reverse --first-parent "$pinned..HEAD")"
  while IFS= read -r commit; do
    [[ -n "$commit" ]] || continue
    if (( i >= ${#wanted[@]} )); then echo "src/$checkout has a commit no listed patch made: $commit"; return 1; fi
    rel="${wanted[$i]}"
    subject="$(git -C "$dir" log -1 --format=%s "$commit")"
    sha="$(git -C "$dir" log -1 --format=%b "$commit" | sed -n 's/^patch-sha256: //p')"
    [[ "$subject" == "$(subproject_subject "$rel")" ]] || { echo "src/$checkout: commit $commit is not $rel"; return 1; }
    [[ -n "$sha" ]] || { echo "src/$checkout: $rel was applied without its patch-sha256 (an older fetch.sh)"; return 1; }
    [[ "$sha" == "$(subproject_sha "$patches_dir/$rel")" ]] || { echo "src/$checkout: $rel changed since it was applied"; return 1; }
    subproject_tree_matches "$dir" "$commit" "$patches_dir/$rel" \
      || { echo "src/$checkout: commit $commit is not $rel applied to its parent (amended?)"; return 1; }
    i=$((i + 1))
  done <<<"$commits"
  if [[ "$mode" == prefix ]]; then printf '%s\n' "$i"; return 0; fi
  (( i == ${#wanted[@]} )) || { echo "src/$checkout lacks ${wanted[$i]}"; return 1; }
}

# Applies what is missing of the list (fetch.sh --apply-subprojects). Logs with `log`,
# returns 1 with the reason (and the reset that fixes it) on stdout's last line.
subproject_apply_all() {
  local src="$1" patches_dir="$2" entries="$3" checkout rel dir patch have out applied=0 i
  while IFS= read -r checkout; do
    [[ -n "$checkout" ]] || continue
    dir="$src/$checkout"
    [[ -e "$dir/.git" ]] || { echo "not a checkout: src/$checkout"; return 1; }
    out="$(subproject_verify "$src" "$checkout" "$patches_dir" prefix "$entries")" \
      || { echo "$out; reset it with: git -C src/$checkout reset --hard $(subproject_pinned "$src" "$checkout"), then rerun"; return 1; }
    have="$out" i=0
    while IFS= read -r rel; do
      [[ -n "$rel" ]] || continue
      i=$((i + 1))
      if (( i <= have )); then echo "src/$checkout already has $rel"; continue; fi
      patch="$patches_dir/$rel"
      [[ -f "$patch" ]] || { echo "missing patch: $patch"; return 1; }
      git -C "$dir" apply --index "$patch" || { echo "patch failed: $rel in src/$checkout; nothing was committed for it"; return 1; }
      subproject_commit "$dir" "$rel" "$patch"
      echo "src/$checkout: applied $rel"
      applied=$((applied + 1))
    done < <(subproject_patches_for "$entries" "$checkout")
  done < <(subproject_checkouts "$entries")
  echo "Applied $applied sub-project patches"
  while IFS= read -r checkout; do
    [[ -n "$checkout" ]] && printf 'sub-project %s at %s\n' "$checkout" "$(git -C "$src/$checkout" rev-parse --short=10 HEAD)"
  done < <(subproject_checkouts "$entries")
}
