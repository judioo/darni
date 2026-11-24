<p align="center">
  <img src="brand/logo-wordmark.svg" alt="Darni" width="420">
</p>

# Darni

An open-source reimplementation of the Arc browser's ideas on macOS: a native
Swift/SwiftUI shell over a lightly patched Chromium that stays easy to update.

Darni was called ReArc until November 2026. It is the same browser with the same data
and settings. The bundle identifier (`com.rearc.browser`) and the names in the code
keep the old name, so installed copies keep their data and their updates.

## Download

Darni is an alpha for Apple silicon Macs on macOS 14 or later.
Download the DMG from [darni.imara.ae](https://darni.imara.ae). It is Developer ID signed and notarized,
and updates itself through Sparkle (Darni › Check for Updates…). What changed in
each release is in [RELEASES.md](RELEASES.md).

On first launch a short onboarding imports your spaces, pinned tabs, favorites,
bookmarks, history and extensions from Arc, Chrome or Brave. Extensions install
in the background, one copy of each. Darni never reads your passwords or cookies.

## What's in the repo

- **`shell/`**: the browser UI in SwiftUI and AppKit. Sidebar with spaces,
  folders and pinned tabs, command bar, split view, profiles, containers (a separate
  browsing session for one space inside its profile, so a site can be signed in to a
  different account there than in the rest of the profile), Peek and Little Darni,
  themes, media and picture in picture, boosts, easels and capture, onboarding and
  import, developer tools docking, Sparkle updates and the iCloud sync foundation.
  `cd shell && swift build && swift test`.
- **`engine/`**: the Chromium pin (`156.0.8078.109`, in `engine/CHROMIUM_PIN`) and
  the patch overlay (`engine/patches/series`). Also the fetch and build scripts,
  the C ABI the shell talks to (`engine/docs/C-ABI.md`) and its native test hosts.
  The Chromium checkout itself is not in this repo: `engine/scripts/fetch.sh` gets it.
- **`brand/`**: the "Sunrise" mark, the wordmark and the brand guidelines.

## Building

1. Fetch and build the engine: `engine/scripts/fetch.sh`, then `engine/scripts/build.sh`.
2. Build and bundle the shell: `shell/scripts/bundle-chromium.sh`. It makes `Darni.app`.
3. Signing, iCloud and release builds read your Apple Team ID and identities from
   `shell/signing.local.env`. That file is git-ignored; copy it from
   `shell/signing.example.env`. No personal identifiers live in the repo.

### Release builds

`shell/scripts/build-engine-release.sh` builds the release engine and
`shell/scripts/release.sh` signs, verifies and packages the app. Its `--dmg`,
`--notarize` and `--appcast` options are described in
[engine/docs/RELEASE.md](engine/docs/RELEASE.md). A distributable build also needs:

- **A Safe Browsing key.** Use a Google API key restricted to the Safe Browsing API,
  in `~/.config/rearc/google-api-keys.gn` (outside the repo) as
  `google_api_key = "…"`. `release.sh --dmg` refuses an engine built without one.
- **A current engine.** `release.sh --dmg` refuses an engine pin that is behind
  Chrome's latest Mac Stable or Extended Stable security release.
- **Release notes.** `release.sh --dmg` refuses to build until `RELEASES.md` has an
  entry for that build number.

## License

Darni is licensed under the [Apache License 2.0](LICENSE). The patch overlay
modifies Chromium, which is © The Chromium Authors under a BSD-style licence;
see [NOTICE](NOTICE).

Arc is a product of The Browser Company. Darni is an independent project, not
affiliated with or endorsed by The Browser Company, and contains none of its code
or assets.
