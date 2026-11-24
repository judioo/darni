# Readability.js (vendored, pinned)

The reader view's article extraction (docs/FEATURE-SPECS/READER-VIEW.md).

| | |
|---|---|
| Upstream | https://github.com/mozilla/readability |
| Version | 0.6.0 |
| Revision | d7949dc47dd9ed9ee1d3b34ffdcf3bce28cde435 (2025-09-29) |
| Licence | Apache-2.0 (`LICENSE.md`, copied from upstream) |
| Copied from | the engine checkout at the Chromium pin, `third_party/readability/src` (upstream's own files, not Chromium's `modded_src`) |

| File | SHA-256 |
|---|---|
| `Readability.js` | `e9330028c8a5a4aa7d75147be2605d520f7f213c7b28474947dc0e9c984e9bed` |
| `Readability-readerable.js` | `e73600367067be2da322c0f26be9c4ec7759cd01b630dbb57278c326e5b5aba8` |

The files are byte for byte upstream's. Darni never fetches them: they ship in
the app and are run in an isolated world of the page.

`ReaderScripts` holds the same version, revision and hashes, refuses to run a
file whose hash differs, and `ReaderVendoredScriptTests` checks the files
against them.

## Updating

An update is its own commit range, with nothing else in it: replace the two
files and `LICENSE.md` from one upstream revision, change the version, revision
and hashes here and in `ReaderScripts.swift`, and run the reader tests.
