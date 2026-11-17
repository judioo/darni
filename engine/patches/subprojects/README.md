# Patches for sub-projects

Chromium keeps ffmpeg, Skia, V8, ANGLE, Dawn and PDFium in their own checkouts
under `third_party/`. `engine/patches/series` is applied inside `chromium/src`
and cannot change a file in one of them.

Patches here are for those checkouts. Each folder is named after the checkout
under `third_party/`, and each patch's paths are relative to it.

**`engine/scripts/fetch.sh` does not apply these yet.** Until it does, a patch
here is not in the engine. What the script needs:

1. A list, `engine/patches/series-subprojects`, with lines of the form
   `third_party/ffmpeg ffmpeg/001-cve-2026-131060-mov-trun.patch`.
2. After the series: for each line, `git -C src/<checkout> apply --index <patch>`
   and a local commit in that checkout, so the tree is not left with loose
   changes and the build log can name the commit.
3. Refuse to go on when a patch does not apply. Do not skip it silently.
4. The pin bump recipe (merge-tree) and any `gclient sync` reset these
   checkouts, so the step has to run again after either.
5. `build-engine-release.sh` prints each patched checkout's head next to the
   overlay's, and the release log keeps that line.

Order for the list, most urgent first:

| Patch | Chrome's rating | Reach in ReArc |
|---|---|---|
| `ffmpeg/001-cve-2026-131060-mov-trun.patch` | Critical | Any page with an MP4 `<video>` |
| `ffmpeg/002-cve-2026-121047-mov-frag-index.patch` | High | The same |
| `angle/002-cve-2026-130954-switch-variable-rename.patch` | High (two CVEs) | Any page with WebGL, Metal shader translator |
| `angle/001-cve-2026-130910-switch-folding-order.patch` | High | Any page with WebGL |
| `angle/003-cve-2026-121037-constructor-size-after-inference.patch` | High | Any page with WebGL |

The security reviewer owns the patches in this folder, as with
`engine/patches/security`. The ledger is `security/BACKPORTS.md` on branch
`security/rc-500`.
