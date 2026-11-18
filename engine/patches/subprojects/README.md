# Patches for sub-projects

Chromium keeps ffmpeg, Skia, V8, ANGLE, Dawn and PDFium in their own checkouts
under `third_party/`. `engine/patches/series` is applied inside `chromium/src`
and cannot change a file in one of them.

Patches here are for those checkouts. Each folder is named after the checkout
(`third_party/ffmpeg`, `third_party/angle`, and `v8` at the top of `src`), and each
patch's paths are relative to it.

`engine/patches/series-subprojects` lists them, one per line: the checkout under
`chromium/src`, then the patch. `engine/scripts/fetch.sh --apply-subprojects` (also run at
the end of `--apply-overlay`) applies each with `git apply --index` and commits it inside
its checkout, with the subject `rearc subproject patch: <patch>`; a patch that does not
apply stops the script. `gclient sync` and the pin bump recipe reset these checkouts, so
run `--apply-subprojects` again after either. `shell/scripts/build-engine-release.sh`
refuses a checkout that lacks a listed patch and prints each patched checkout's head
beside the overlay's in the build log. Shared code: `engine/scripts/subprojects.sh`.

Rules the step enforces (security review of c285c5ce, 2026-11-18):
- A checkout must be exactly the revision `src` pins plus the listed patches' commits, in
  list order. A stray commit, a patch dropped from the list or a different order is refused
  by `fetch.sh` (with the `git reset --hard <pinned>` that fixes it) and by the release
  engine build. To drop a patch: remove its line, run that reset, rerun
  `--apply-subprojects`, rebuild.
- Each commit carries `patch-sha256:` of its patch file; a patch edited under the same name
  is refused until its checkout is reset. Never edit an applied patch: give a revision a new
  number.
- No loose changes: the release engine build refuses uncommitted tracked changes in `src`
  and in each listed checkout.
- Commits use a fixed identity and date, so the same patches on the same revision give the
  same heads on any Mac.
- `fetch.sh --sync` ignores the listed checkouts in its `src` clean check; `gclient sync`
  resets them, so run `--apply-subprojects` after it and after a pin bump.

Order for the list, most urgent first:

| Patch | Chrome's rating | Reach in ReArc |
|---|---|---|
| `ffmpeg/001-cve-2026-131060-mov-trun.patch` | Critical | Any page with an MP4 `<video>` |
| `ffmpeg/002-cve-2026-121047-mov-frag-index.patch` | High | The same |
| `angle/002-cve-2026-130954-switch-variable-rename.patch` | High (two CVEs) | Any page with WebGL, Metal shader translator |
| `angle/001-cve-2026-130910-switch-folding-order.patch` | High | Any page with WebGL |
| `angle/003-cve-2026-121037-constructor-size-after-inference.patch` | High | Any page with WebGL |
| `v8/001-cve-2026-125344-iterator-close-termination.patch` | High | Any page's script |
| `v8/002-cve-2026-131042-regexp-flush-errors.patch` | High | Any page's script. One upstream hunk left out; see its header. |

The security reviewer owns the patches in this folder, as with
`engine/patches/security`. The ledger is `security/BACKPORTS.md` on branch
`security/rc-500`.
