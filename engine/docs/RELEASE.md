# ReArc macOS release build

How to produce a release-quality, hardened-runtime ReArc.app and DMG from this tree, what
was verified, and what only the account holder can do. Packaging background (branding,
helper IDs, Safe Storage naming) is in PACKAGING-MAC.md; the shell/engine linking contract
is in C-ABI.md, "Linking and startup".

Today the only missing input is a **Developer ID Application** certificate. Everything else
(engine, bundle, nested signing, entitlements, launch, self-test, DMG) is built and verified
with the Apple Development identity, which macOS accepts locally but Gatekeeper rejects for
distribution.

## Scripts (all in shell/scripts)

| Script | Does |
|---|---|
| `build-engine-release.sh` | Optimized non-component engine in `out/ReArc-release-arm64`. Same preflight as `engine/scripts/build.sh`; never touches `out/ReArc-dev-arm64`. `--gen-only` runs just `gn gen`. |
| `release.sh` | End to end from a built release engine: release shell build from committed HEAD, bundle, version stamp, nested signing, dSYMs, LaunchServices launch check, real-Keychain self-test, optional `--dmg`. Output `shell/dist/release`. |
| `release.sh` verification mode | The gates run on the bundle signed with `ReArcReleaseVerification` in its Info.plist: only that release bundle takes `REARC_RELEASE_VERIFICATION=1` with `--rearc-selftest` or `--rearc-launch-probe`, a throwaway `REARC_DATA_DIR` or a `--user-data-dir`. After the gates `release.sh` removes the key and signs the bundle again, so the bundle that is notarized and shipped refuses to start with `REARC_DATA_DIR` or `--user-data-dir` and has no self-test or probe (security RC-0.1.0-602 T-04, F-03). For test launches on a throwaway data dir, build with `release.sh --qa`, which keeps the key and refuses `--dmg`, `--appcast` and `--notarize`. `check-launch.sh`, `check-safe-browsing-lists.sh`, `check-upgrade.sh` and `check-upgrade-data.py` refuse a shipped bundle as the new build. The two upgrade checks launch a previous release of build 608 or earlier as it is (those honour `REARC_DATA_DIR`); a later, shipped previous release is copied, given the key and signed again with the release identity, and the copy runs instead. `release/upgrade-bundles.sh` holds that cut-off (`LAST_DATA_DIR_BUILD`) for both. Neither passes `REARC_RELEASE_VERIFICATION`: they use no self-test or probe. |
| `bundle-chromium.sh` | Unchanged behavior for dev bundles. New: `--engine-out DIR` (same as `REARC_CHROMIUM_OUT`), and a monolithic engine build is accepted, with no dylib closure outside the bundle. Its build guard blocks only on a `siso ninja` of the out dir being bundled, so a release build no longer blocks dev bundles. |
| `sign-release.sh` | Inside-out signing of an assembled monolithic bundle with hardened runtime, secure timestamps and Chromium's per-role entitlements; verifies. |
| `make-dmg.sh` | Signed UDZO DMG: app, Applications link, volume icon, branded Finder background. |
| `notarize.sh` | `notarytool submit --keychain-profile rearc-notary --wait`, then `stapler staple`/`validate`. Refuses anything not Developer ID signed. **Not run yet.** |
| `release/BRANDING` | Release BRANDING input: the overlay's BRANDING. `build-engine-release.sh` appends `MAC_TEAM_ID` from `REARC_TEAM_ID` (environment or `shell/signing.local.env`) into `shell/.build-release/BRANDING`. |
| `release/entitlements/` | `app`, `helper-renderer`, `helper-gpu` entitlements, copied from `chrome/app/*-entitlements.plist` at the pin. |
| `release/version.py` | ReArc's version, `YYYY.MMDD.<build>`, from a RELEASES.md heading or a commit; checks the heading, names the DMG and the tag (see Versioning). |
| `release/rebrand-bundle.py` | Run by `bundle-chromium.sh` before signing. Puts Darni's name and icon where the engine build leaves Chromium's or ReArc's: the two alerts helpers macOS shows as the notifying app, the permission reasons in the app's `InfoPlist.strings`, `CFBundleDisplayName` Darni in every app locale, and every helper's `CFBundleName`. Prints the helpers it changed, which the bundle step signs again ad hoc. |
| `blocklists/build-blocklists.py` | The built-in blocklists (see "Lists key" below and `docs/FEATURE-SPECS/CONTENT-BLOCKING.md` §4). `build` converts the pinned upstream filter lists to the engine's rules and signs the manifest. `install` verifies a bundle and copies it without the raw lists: `bundle-chromium.sh` runs it to put the bundle in the app. `pack` verifies the app's bundle and writes `blocklists-<version>.tar.gz` and `latest.json`: `release.sh` runs it into `<dist>/blocklists`, and `--blocklists DIR` copies the two files out. Its tests are in `blocklists/tests`. |
| `blocklists/blocklists-public-key.txt` | The lists keys a bundle may be signed with, the key in use first. The app carries the same keys (`BlocklistSigningKey.compiledInTexts`). |
| `release/signing-env.sh` | Shared loader for `shell/signing.local.env`. Environment wins, and it never prints a value. |
| `release/dmg-background.swift` | Draws the DMG background (brand canvas and cobalt arrow). |

## The rename: ReArc is Darni from build 1054

ReArc was renamed Darni on 2026-11-19. The first Darni build is the "bridge" release. It
changes only the names people read, so an installed ReArc takes it as an ordinary update.
The rest of this document was written before the rename. Where it says `ReArc.app` or
`ReArc-<version>.dmg`, builds from 1054 on make `Darni.app` and `Darni-<version>.dmg`.

What a release makes now:

| | Up to build 1053 | From build 1054 |
|---|---|---|
| App bundle | `ReArc.app` | `Darni.app` |
| `CFBundleName`, `SUBundleName` | ReArc | Darni |
| `CFBundleDisplayName` in Info.plist | ReArc | Darni in 1054 to 1105; ReArc again after 1105, the file name of every updated copy, so macOS shows the localized one |
| `CFBundleDisplayName` in each app `<locale>.lproj/InfoPlist.strings`, with `LSHasLocalizedDisplayName` | none | Darni after 1105: Finder, the Dock and Spotlight show an updated `ReArc.app` as Darni |
| `MDItemKeywords` (Spotlight's extra search words, from build 1105) | none | "Darni, ReArc": a new download, `Darni.app`, is found by ReArc too |
| DMG | `ReArc-<version>.dmg`, volume "ReArc" | `Darni-<version>.dmg`, volume "Darni" |
| Delta (named by Sparkle's `generate_appcast`) | `ReArc<to>-<from>.delta` | `Darni<to>-<from>.delta` |
| `RELEASES.md` heading and release title | `## ReArc <version>`, "ReArc <version>" | `## Darni <version>`, "Darni <version>" |
| Update check User-Agent (Sparkle builds it from the name) | `ReArc/<version> Sparkle/2.10.1` | `Darni/<version> Sparkle/2.10.1` |
| Git tag | `v<version>` | `v<version>` |

`release/version.py` holds the build number of the change (`FIRST_DARNI_BUILD`) and decides
the heading and the DMG name for a build. The feed's channel title stays "ReArc":
`generate_appcast` names a feed when it creates it and never again, and nothing shows it.

What must never change, because installed copies depend on it:

| Identifier | Value | What breaks if it changes |
|---|---|---|
| Bundle id, and the helper and framework ids under it | `com.rearc.browser` | macOS sees a new app: preferences, privacy permissions, default browser and passkeys are lost. Sparkle finds a renamed app in an update only by its bundle id, so the update fails for everyone. |
| Safe Storage Keychain item | "ReArc Safe Storage", account "ReArc", from `PRODUCT_SHORTNAME=ReArc` in `release/BRANDING` | The engine makes a new key. Everyone is signed out and saved passwords cannot be read. Nothing migrates the old item. |
| iCloud container | `iCloud.com.rearc.browser` | CloudKit containers cannot be renamed. Synced data is stranded. |
| Data folder | `~/Library/Application Support/ReArc` | A first-launch migration with nothing to gain. |
| Update feed and key | `SUFeedURL` `https://rearc.imara.ae/updates/appcast.xml`, `SUPublicEDKey`, the Keychain account `ReArc` of the private key | Installed builds poll the URL and accept the key built into them. |
| Feed marker | prefix `rearc:`, namespace `https://rearc.imara.ae/xml-namespaces/update` | Older builds read `rearc:requiredBelow` by that name. |
| Blocklists URL | `https://rearc.imara.ae/blocklists/latest.json` | Built into every installed build. |
| Executable, icon file, Info.plist keys, `REARC_*`, `~/.config/rearc`, module and folder names | `Contents/MacOS/ReArc`, `ReArc.icns`, `ReArcRelease` and the rest | Nothing a person reads. Scripts, crash report names and tests use them. |

Never change the app's file name and its bundle id in the same release, and never the update
key and the Team ID in the same release.

`PRODUCT_SHORTNAME` reaches two things besides the Keychain item: the app's `CFBundleName`,
which `bundle-chromium.sh` sets to Darni, and each helper's `CFBundleName` ("ReArc Helper
(Renderer)"), which `rebrand-bundle.py` rewrites to "Darni Helper (Renderer)". The Keychain
item's own name is the one place where a person still reads "ReArc": in Keychain Access, and
in the macOS prompt if the item's access is ever asked for again.

The gates, all without a launch:

| Script | Checks |
|---|---|
| `release/check-rename.sh APP [--engine-out DIR] [--qa]` | Run by `release.sh` on every build, after bundling and again on the bundle as it ships. The bundle is `Darni.app` with `CFBundleName` and `SUBundleName` Darni, Info.plist's `CFBundleDisplayName` ReArc with `LSHasLocalizedDisplayName`, Darni as `CFBundleDisplayName` in every app `InfoPlist.strings`, and `MDItemKeywords` "Darni, ReArc". The bundle id, the helper and framework ids, the executable, `SUFeedURL`, `SUPublicEDKey`, the iCloud container and the blocklists URL in the executable are the values above. Without `--qa` the bundle must be a release bundle: `ReArcRelease` true, the feed URL present, and no `REARC_*` variable in `LSEnvironment` (the mark of an update test copy). `--qa` (passed for `release.sh --qa`) lets a test bundle lack the release marker or carry another feed URL. |
| `release/check-safe-storage-name.py APP [--engine-out DIR]` | Called by `check-rename.sh`. `release/BRANDING` says `PRODUCT_SHORTNAME=ReArc`, the engine binary in the bundle holds "ReArc Safe Storage" and no other "<name> Safe Storage" except Chromium's "Endpoint Verification Safe Storage", and the header the engine build generated names the same service and account. |
| `release/tests/test_sparkle_rename.py` | Sparkle 2.10.1's rule for finding the app in an update (`SUInstaller.m`), ported, on a DMG's layout: a ReArc install finds `Darni.app` by bundle id, an updated or new install by name, and a new bundle id is never found. With Sparkle's own `generate_appcast` and `BinaryDelta` and a throwaway key: one feed for archives of both names, the delta's name, and the delta applied to a host named `ReArc.app` and one named `Darni.app`. |

The live check, which launches the app and needs the screen, is
`release/check-rename-update.sh`: a test copy of an installed build updates itself from a
feed on 127.0.0.1 with Sparkle's own installer. The script's header has the four cases to run
before the bridge release ships and what makes a test copy safe beside the person's own
install (a throwaway update key, and a throwaway data directory in the copy's `LSEnvironment`
so that Sparkle's relaunch cannot open the real profile).

Engine strings a person reads (the version line of `chrome://version`, the blocker
extension's name and description) are in overlay patch
`engine/patches/chrome/008-darni-visible-names.patch`. **It is held back: the file is kept
but it is not in `engine/patches/series`, and the bridge release's engine does not have it.**
Security's condition 1 for the bridge release (`security/PRE-darni-bridge.md`) is that its
engine stays as built, overlay `9f2767b4c1`, through `tab/098`. Add the patch's line to
`series` after `tab/098` for the first engine build after the bridge. `series` must always
match what is built: `engine/tests/replay_overlay.py` compares the two.

## Exact steps

```sh
# 0. Once: shell/signing.local.env has REARC_SIGN_IDENTITY, REARC_TEAM_ID and, for iCloud,
#    REARC_ICLOUD_CONTAINER + REARC_PROVISIONING_PROFILE (docs/ICLOUD-SETUP.md).
#    For distribution also REARC_RELEASE_IDENTITY="Developer ID Application: … (<TEAM_ID>)"
#    and REARC_RELEASE_PROVISIONING_PROFILE (a Developer ID profile, below).
# 1. Engine (3-4 h on first build, minutes incrementally). Start it when no other
#    `siso ninja` is active; it shows up in `pgrep -fl 'siso[ ]ninja'` while it runs.
shell/scripts/build-engine-release.sh
# 2. Commit the shell changes you want to ship, then:
shell/scripts/release.sh --dmg
# 3. With Developer ID only (never before):
shell/scripts/notarize.sh shell/dist/release/Darni.app      # notarize + staple the app
shell/scripts/make-dmg.sh shell/dist/release/Darni.app      # DMG from the stapled app
shell/scripts/notarize.sh shell/dist/release/Darni-<version>.dmg   # Darni-2026.1119.1079.dmg
```

`release.sh --worktree` builds the uncommitted working tree for local testing; its
`ReArcSourceRevision` gets a `-dirty` suffix. Do not distribute such a build.

`release.sh --dmg` checks Chromiumdash's latest **Mac Stable and Extended Stable**
releases before packaging, and requires the engine output version to match
`engine/CHROMIUM_PIN`. The pin must be current on its supported milestone (156
currently uses Extended Stable); an unsupported milestone or unavailable release
data fails closed. `--allow-outdated-engine` explicitly bypasses the freshness
check with a prominent warning. It does not bypass the built-version check.

`release.sh --dmg` also refuses an engine built without a real Google API key, because
Safe Browsing cannot work without one (next section). `--allow-no-safe-browsing` makes the
DMG anyway and prints a loud warning. Such a build shows Safe Browsing as unavailable in
Settings › Privacy. Never distribute it to users.

## Safe Browsing key

Safe Browsing puts the build's Google API key (`google_apis::GetAPIKey()`) on every list
update and hash lookup. With no key Chromium sends `dummytoken`. Google answers that with
HTTP 400 `API_KEY_INVALID`, the threat lists never download, and phishing and malware pages
load with no warning. The release engine therefore needs ReArc's own key:

- It comes from ReArc's Google Cloud project, with the key restricted to the **Safe Browsing
  API** only. ReArc does not use Google sign-in: leave `google_default_client_id` and
  `google_default_client_secret` unset.
- It lives outside the repository, in `~/.config/rearc/google-api-keys.gn` (mode 600),
  as one line: `google_api_key = "AIza…"`. `REARC_GOOGLE_API_KEYS_FILE` points elsewhere,
  and a `google_api_key` environment variable overrides the file. Never commit the key or
  paste it into a log or report.
- `build-engine-release.sh` writes `out/ReArc-release-arm64/args.gn` (mode 600) and appends
  the key with `engine/scripts/google-api-keys.py append`. That script refuses a key file
  inside the repo and accepts only quoted credential assignments. It prints a warning,
  never the key, when no real key (`AIza` plus 35 characters) is configured. The build
  still runs.
- `release.sh --dmg` runs `google-api-keys.py check`: the engine's `google_api_key` GN arg
  must be a real key, and the release framework must contain it. Otherwise it stops
  unless `--allow-no-safe-browsing` is given.
- A key in the build does not prove the lists download. After the self-test, `release.sh
  --dmg` runs `scripts/release/check-safe-browsing-lists.sh`: it launches the signed app in the
  background (`open -n -g`, `--no-onboarding`, a throwaway `REARC_DATA_DIR`), waits up to
  6 minutes for non-empty `UrlSoceng.store` and `UrlMalware.store` (the phishing and malware
  lists) in `<data>/Chromium/Safe Browsing`, then quits that instance. Without both the release
  fails. `--allow-no-safe-browsing` skips this check too. The gate checks the lists only: it
  loads no test page, so check Google's phishing test page shows the warning by hand once per
  engine update (security RC-0.1.0-602 T-11).
- The field-trial gate reads the generated build-flag header and then the framework itself:
  `scripts/release/check-fieldtrial-binary.py` fails when fewer than half of the macOS study
  names in `testing/variations/fieldtrial_testing_config.json` are in the binary as their own
  strings, that is when the testing config is not compiled in (builds 562 and 608 have all 551,
  the engine of 602 and 605 had 58). See "Engine build".
- `check-launch.sh` also counts minidumps under `~/Library/Application Support/Chromium/Crashpad`
  (and the probe profile's `Crashpad`) that name `ReArc.app`: helper crashes never reach
  DiagnosticReports.
  The check needs the network, and a firewall prompt for the new copy's helpers stalls it.
- At run time the shell asks the engine (`ReArcEngineSafeBrowsingAvailable`, ABI 1.57) and
  then looks at the same folder: Settings › Profiles shows Safe Browsing as Unavailable (no
  key), Starting (no lists yet, first 10 minutes), On (lists stored and updated within a
  day), Not working (no lists after 10 minutes) or Out of date. Dev engines
  (`engine/scripts/build.sh`) are built without a key, so they show Safe Browsing as
  unavailable, like any keyless build.

The key passes to the compiler as a define on `google_apis` compiles only, so it appears in
the local `out/ReArc-release-arm64` build files and compiler command lines, which are never
committed. Filter `AIza` out of anything copied from a build log.

## Engine build

`out/ReArc-release-arm64` args (`gn args --list --short --overrides-only`):

```
target_os="mac" target_cpu="arm64" is_chrome_branded=false is_official_build=false
use_system_xcode=true use_remoteexec=false use_siso=true chrome_pgo_phase=0
symbol_level=1 treat_warnings_as_errors=false
is_debug=false is_component_build=false dcheck_always_on=false
enable_dsyms=true enable_stripping=true
branding_file_path="<repo>/shell/.build-release/BRANDING"   (generated, carries MAC_TEAM_ID)
google_api_key="…"   (appended from ~/.config/rearc/google-api-keys.gn, "Safe Browsing key")
```

The engine is built WITH Chromium's field-trial testing config (the default for an unbranded
build), because builds 500 to 564 were and profiles carry its storage formats: see "Stored site
data" below. `release.sh --dmg` refuses an engine whose
`gen/components/variations/service/buildflags.h` has the testing config off, or whose framework
lacks the config's study names (`check-fieldtrial-binary.py`). Never add
`disable_fieldtrial_testing_config=true`: builds 602 and 605 had it.

N-01 from the security review of 544 ("the release engine runs Chromium's field-trial testing
config") is knowingly open again since 608. Users run the 663 features the config switches on
for the Mac, unlaunched V8 compiler work among them, as builds 500 to 564 did. Closing it again
needs more than the GN flag: every feature a profile has been written under must stay on (the
search-engine migrations in `persistedProfileFeatures`, `DomStorageSqliteNewDatabases` and
`IdbSqliteOnDiskRollout`, and any other found by a full review of the config), turned on by the
shell, with `check-upgrade-data.py` passing against the release on the feed.


- These are the dev args, which set no other branding arguments, with the release
  changes. `engine/scripts/build.sh --release` cannot be used because its fixed argument
  set lacks `dcheck_always_on=false` (non-official builds default DCHECKs on,
  `build/config/dcheck_always_on.gni`) and `branding_file_path`. PACKAGING-MAC.md says a
  production pipeline must supply its own complete GN configuration.
- `is_component_build=false` gives a monolithic `Chromium Framework` with no
  `libchrome_dll.dylib` and no 500+ dylib closure. `Libraries/` keeps only the GL/Vulkan
  dylibs that Chromium always ships there.
- `symbol_level=1` with `enable_dsyms` and `enable_stripping`: line tables go into
  `*.dSYM` (copied to `dist/release/symbols/`), and the shipped binaries are stripped. This
  is what official builds do for symbols, without the rest of `is_official_build`.
- **Not `is_official_build`.** PACKAGING-MAC.md does not require it. On Mac it turns on
  ThinLTO and the official-build optimizations, which would take many hours on this 10-core
  machine, and expects PGO profiles (`chrome_pgo_phase`). It also selects Google
  official-build behavior that this unbranded overlay neither needs nor has validated.
  `is_debug=false` already gives `NDEBUG`, which is what the overlay's test-only code keys on.
  Revisit for performance tuning, not correctness.
- `MAC_TEAM_ID=<TEAM_ID>` is compiled into `MAC_TEAM_IDENTIFIER_STRING`, which Chromium
  uses for keychain access groups (WebAuthn, payments, device trust). The dev BRANDING
  leaves it empty. Developer ID certificates belong to the same Individual team, so the
  value does not change when that certificate arrives. The bundle ID stays
  `com.rearc.browser` (the script refuses a mismatch with the overlay's BRANDING).
- **Client-certificate test store**: `rearc_client_cert_test_store.cc` is guarded by
  `#if !defined(NDEBUG) && !defined(OFFICIAL_BUILD)` (WAVE-18H-REPORT.md). The release
  build defines `NDEBUG`, so it compiles to the empty `InstallTestClientCertStore` stub.
  Verified in R1: `obj/chrome/browser/core/rearc_client_cert_test_store.o` defines only
  `rearc::InstallTestClientCertStore(Profile*)`, and the
  `rearc-test-client-cert-dir` switch string is absent from the release framework.
- **Release-only defect fixed in overlay patch tab/060**
  (`tab/060-release-framework-exports.patch`, overlay commit `f511949e6b`). A
  non-component framework exports only what `chrome/app/framework.exports` lists. Waves
  after tab/018 added ABI functions to the header without listing most of them, so the
  first release framework exported 52 of the 110 header functions, and the release shell
  could not link against it. Component builds export everything from
  `libchrome_dll.dylib`, which hid the gap. tab/060 adds the 58 missing functions to
  `framework.exports` and to `framework.order` before `_ChromeMain`, so
  `verify_chrome_framework_order` still passes. Replay: `REPLAY PASS 61/61` reverse and
  forward (`engine/replay-r1.log`). `build-engine-release.sh` now fails if any function
  declared in `rearc_engine_abi.h` or `rearc_engine_entry_mac.h` is missing from
  `nm -gU` of the framework. **When adding an ABI function, add it to both files.**
- First build: 12,098 s (3 h 22 min) on 10 cores with other agents active
  (`engine/build-release-r1.log`). The tab/060 relink took 122 s.

## Signing

`sign-release.sh` mirrors `chrome/installer/mac/signing/parts.py` at the pin, inside-out:

| Code object | Options | Entitlements |
|---|---|---|
| `Libraries/*.dylib` | none (library) | none |
| `Chromium Helper (Renderer).app`, `(Aperitif Renderer)` | `restrict,kill,runtime` | `helper-renderer` (allow-jit) |
| `Chromium Helper (GPU).app`, `(Aperitif GPU)` | `restrict,kill,runtime` | `helper-gpu` (allow-jit) |
| `Chromium Helper.app`, `(Aperitif)`, `(Alerts)`, `(Aperitif Alerts)` | `restrict,library,runtime,kill` | none |
| `chrome_crashpad_handler`, `app_mode_loader`, `web_app_shortcut_copier` | `restrict,library,runtime,kill` | none |
| `Chromium Framework.framework` | none (framework) | none |
| `ReArc.app` (identifier `com.rearc.browser`) | `restrict,library,runtime,kill` | `app` + iCloud (below) |

- Each signature gets `--timestamp` (Apple's timestamp server). `REARC_TIMESTAMP=none`
  is for offline signing only, and notarization rejects it.
- JIT helpers are signed without `library`: Chromium does the same, because library
  validation conflicts with the JIT entitlement there. All code is signed by the same team,
  so library validation in the other processes passes.
- **Renderer entitlements**: at this pin Chromium's renderer and GPU helpers carry only
  `com.apple.security.cs.allow-jit`. V8 allocates JIT pages with `MAP_JIT`.
  `allow-unsigned-executable-memory` was dropped upstream and is **not** added, because it
  would weaken the hardened runtime for no gain. The self-test loads and runs JavaScript in
  hardened-runtime renderers with only allow-jit (Verification). Add it only if a renderer
  is ever killed with a code-signing exception.
- The app entitlements are Chromium's `app-entitlements.plist` (camera, microphone,
  Bluetooth, print, USB, location, photos). That is a superset of
  `scripts/ReArc.entitlements`, and the usage strings stay in Info.plist. With
  `REARC_ICLOUD_CONTAINER`, `icloud_prepare` (icloud-signing.sh) merges in
  application-identifier, team-identifier, the iCloud container, CloudKit and, when the
  profile allows it, `icloud-container-environment`. It also embeds the profile and the
  `ReArcICloudContainer` marker. `REARC_RELEASE_PROVISIONING_PROFILE` takes precedence over
  the development `REARC_PROVISIONING_PROFILE`.
- The script refuses component bundles, ad-hoc identities and any Mach-O it does not sign
  on purpose. It checks the team, timestamp and runtime flag on every object it signed, and
  allow-jit on the renderer and GPU helpers. Then it runs `codesign --verify --deep --strict`
  and prints `spctl -a -vv`.
- The Safe Storage Keychain item ("ReArc Safe Storage" / "ReArc") trusts the designated
  requirement: identifier `com.rearc.browser` plus the signing certificate. A release
  bundle signed with the same Apple Development identity matches the item that the
  development iCloud bundle created, so it does not prompt. After the switch to Developer
  ID, the requirement changes, and macOS asks once on first launch ("Always Allow"). Users
  of a distributed build only ever see the Developer ID requirement.

## Versioning

- `CFBundleShortVersionString` = `YYYY.MMDD.<build>`, for example `2026.1114.741` for build
  741 released on 14 November 2026. Display only: About, Sparkle's window, the feed's
  `sparkle:shortVersionString`, the User-Agent of update checks. Nothing in ReArc or in
  the release scripts decides anything from it.
  - The date has one source. For a release (`release.sh --dmg` or `--appcast`) it is the
    date in the build's `RELEASES.md` heading (Release notes, below). Any other build
    (`--qa`, `--worktree`, a plain `release.sh`, `bundle-chromium.sh` and
    `bundle-webkit-dev.sh` development bundles) takes the day of the commit it is built
    from, in Asia/Dubai time.
  - `<build>` is written as it is (741). `BUILD_DIGITS` in `release/version.py` pads it
    (5 would give `2026.1114.00741`); the heading check and the DMG name follow it.
  - Builds up to 726 were `0.1.0`; their feed items keep it.
- `CFBundleVersion` = `git rev-list --count HEAD` of the outer repo, the plain number (741).
  It increases with every commit on the release branch, which is what LaunchServices and
  Sparkle compare: `sparkle:version`, `minimumAutoupdateVersion`,
  `criticalUpdate sparkle:version` and ReArc's `rearc:requiredBelow` are all build numbers,
  so an install of 677 or 608 is offered 741 whatever either display version says
  (`release/tests/test_sparkle_feed_order.py`). Never put the date in it. Cut releases from
  one branch (main).
- `ReArcEngineVersion` = the Chromium version (156.0.8078.114), `ReArcEngineRevision` = the
  overlay commit, `ReArcSourceRevision` = the outer commit (`-dirty` for `--worktree`).
- The framework keeps `Versions/156.0.8078.114` and its own plist. Never rename it.
- Chromium's upgrade detector would compare the outer `CFBundleShortVersionString` with
  the running Chromium version (`updater::CurrentlyInstalledVersion` in
  `browser_updater_client_util_mac.mm`) and report an update when the outer one is higher,
  as 2026.1112 is. ReArc's engine is not Chrome-branded, so `enable_updater` is false and it
  builds `updater_no_updater.cc`, whose `CurrentlyInstalledVersion` is the engine's own
  version: the detector never sees the outer one. Keep it that way: an engine built with
  `enable_updater` would report an update that is not there. Crashpad's `ver` annotation
  is the framework's version (Chromium's), not ReArc's; macOS crash reports show both.
- DMG name: `Darni-<CFBundleShortVersionString>.dmg` from build 1054, for example
  `Darni-2026.1119.1079.dmg`, and `ReArc-<CFBundleShortVersionString>.dmg` before it
  (`version.py dmg-name`). Builds up to 726 were `ReArc-0.1.0-<build>.dmg`. The same name
  is used in `dist/` and in the update feed; delta names (`ReArc741-677.delta`) are
  Sparkle's.
- Git tag: `v<CFBundleShortVersionString>`, `v2026.1114.741` (`version.py tag`); builds
  up to 726 were tagged `v0.1.0-<build>`.
- The User-Agent of Sparkle's requests is `ReArc/<CFBundleShortVersionString> Sparkle/2.10.1`,
  `ReArc/2026.1114.741 Sparkle/2.10.1`. About ReArc's look at the feed sends the same.

## Upgrade check

`release.sh --dmg` needs `--previous-app PATH`: the `ReArc.app` of the release that is on the
update feed now. `scripts/release/check-upgrade.sh` launches that app in the background to make
a profile, then opens the profile with the new build, which must stay up for 45 seconds with no
crash report. `REARC_UPGRADE_PROFILES` adds saved data directories of older builds.

Build 602 is why. It passed the launch check, the self-test and the Safe Browsing check, all on
fresh profiles, and aborted at launch on every profile made by 500, 544 or 564. Those engines
ran Chromium's field-trial testing config, which switched on `PrepopulatedEnginesMigration` and
recorded it in the profile's keyword database; 602's engine had the feature off, and Chromium
treats that as a rollback and hits a fatal `NOTREACHED`. The shell now always passes
`--enable-features=PrepopulatedEnginesMigration,ApplySearchEngineTypeMigration`
(`ChromiumLaunchArguments.persistedProfileFeatures`). Any change to the engine's feature set
can do this again: features leave marks in profiles.

### Stored site data

`check-upgrade.sh` only sees crashes. `scripts/release/check-upgrade-data.py PREVIOUS_APP NEW_APP`
runs next in `release.sh --dmg`: the previous release stores a value in local storage, IndexedDB,
a cookie and Cache Storage on a loopback page (port 18765, `REARC_UPGRADE_DATA_PORT`), and the
new build must read all four back. As in `check-upgrade.sh`, the new build is the bundle being
verified, and a shipped previous release after 608 runs as a re-signed verification copy. The
page acts only for the run in progress: a window restored from an earlier run reloads its old
address and stays inert.

`REARC_UPGRADE_DATA_PROFILES` (colon-separated) adds data directories saved with
`check-upgrade-data.py --keep DIR APP …`; the new build must read back what that chain stored
last (`DIR/.rearc-upgrade-data-label`). Keep one made by `check-upgrade-data.py --keep DIR
rc564/ReArc.app rc605/ReArc.app` for profiles that ran 605 (that chain itself reports 605's loss).

Build 605 is why. Its engine was built with `disable_fieldtrial_testing_config=true`, to get
Safe Browsing off the v5 list protocol. That also switched off `DomStorageSqliteNewDatabases`
and `IdbSqliteOnDiskRollout`, so local storage and IndexedDB went back from SQLite to LevelDB:
profiles from 500 to 564 read both as empty, and each site's IndexedDB data was deleted on its
first visit. The engine is built with the testing config again, and the shell passes
`--disable-features=SafeBrowsingLocalListsUseSBv5` (`ChromiumLaunchArguments.disabledEngineFeatures`).
Since 2026-11-14 that list also turns off `LazyBrowserInterfaceBroker`, a security mitigation
for CVE-2026-121035 that changes no stored data.
Since 2026-11-22 it also turns off `PreemptiveSodaDownload`, which the testing config turns on:
with it a new profile fetched the speech recognition library and a language pack at its first
start, with Live Caption off. It changes no stored data: a profile that has the library keeps it
until Chromium's unused timer (30 days) removes it, and Live Caption fetches it when turned on.

The rule: a build is safe for an existing profile only when every engine feature that was on
when the profile was written is still on. Never change the engine's feature set, a GN flag that
changes it, or the Chromium pin without this check passing against the release on the feed.

## Release notes

`RELEASES.md` at the repo root records every distributed build, newest first. Each entry is
headed `## ReArc <YYYY.MMDD>.<build> — <YYYY-MM-DD>`, for example
`## ReArc 2026.1114.741 — 2026-11-14`, and lists, for ReArc's users, all the features and
fixes since the previous release. The heading's date is the release's: it is the date in
the build's version. `release.sh --dmg` (and `--appcast`) stops before building when the
committed `RELEASES.md` at HEAD lacks that heading for the build being made, or when its
version is not its own date and build (`version.py release`, which also refuses a heading
it cannot read). Entries up to 726 keep the old heading, `## ReArc 0.1.0 (726) — 2026-11-12`;
the check accepts it for them and only the new one for the build being made.

The build number is the commit count, so the notes commit has to carry its own number. Add
the entry as the last commit before the release, numbered
`$(( $(git rev-list --count HEAD) + 1 ))`, and build from that commit.

## Verification (this machine, Apple Development identity)

R1 run: shell HEAD `667658d9`, overlay `f511949e6b`, version 0.1.0 (98).
Logs are in `shell/dist/release/` (`sign-release.log`, `selftest-release*.log`) and
`shell/dist/release-r{1,2}.log`.

| Check | Result |
|---|---|
| `codesign --verify --deep --strict --verbose=2 ReArc.app` | **pass**: valid on disk, satisfies its Designated Requirement. Sixteen code objects, each with team <TEAM_ID> and a secure timestamp. |
| Flags | app, Helper, Alerts, crashpad: `kill,restrict,library-validation,runtime`. Renderer, GPU: `kill,restrict,runtime` + allow-jit. |
| App entitlements | Chromium app set + `<TEAM_ID>.com.rearc.browser`, `iCloud.com.rearc.browser`, CloudKit, environment Development (development profile) |
| `spctl -a -vv -t exec ReArc.app` | `rejected` / `origin=Apple Development: <Your Name> (<CERT_ID>)`, as expected without Developer ID and notarization |
| `spctl -a -t open --context context:primary-signature -vv ReArc-0.1.0.dmg` | `rejected` / `origin=Apple Development: <Your Name> (<CERT_ID>)`, as expected |
| `check-launch.sh` (LaunchServices `open`, plain and with a link) | **PASS**: `ready=1 engine=chromium source=infoPlist abi_minor=41`, GetURL link delivered, no crash reports |
| Self-test, real Keychain (`--rearc-selftest`, no `--use-mock-keychain`) | `keychain: macOS Keychain ('ReArc Safe Storage')`, **no prompt and no stall**. Ninety-seven PASS lines in about 70 s, including page script evaluation in hardened-runtime renderers with only allow-jit. **RESULT FAIL, 1 failure:** `timed out waiting for ⌥⌘I closed the frontend tab`. See below. |
| `notarize.sh ReArc-0.1.0.dmg` | Refuses before any network call: "not signed with a Developer ID Application certificate" |
| DMG | UDZO, 160 MB, signed; app inside verifies; Applications link, custom volume icon, Retina background and Finder layout |

**Self-test failure: a shell bug, not a release defect.** A dev bundle (component, debug,
mock Keychain) built from the same HEAD fails the same step in the same way. No earlier
wave-28 dev run reached it, because those runs timed out sooner under the release build's
load. Release runs 2 and 3 failed earlier, at the omnibox step, with a stale row from the
previous query (`suggestion row nav suggestion one`). That is a race in the shell
self-test. Probable cause of the DevTools failure:
`BrowserViewModel.closeDevTools` closes the frontend tab only through
`ChromiumEngine.deinit` (`devToolsEngines[tabID] = nil`). The self-test, and possibly the
docked view, still holds a reference (`let frontend`), so the tab never closes. The
shell's owner should close the frontend explicitly and fix the suggestion race. Then the
release self-test is expected to pass, since every engine-backed step before it does.

Size and launch, release vs a dev bundle of the same HEAD:

| | Release (`dist/release`) | Dev (component, debug) |
|---|---|---|
| ReArc.app | 382 MB, self-contained | 191 MB app + 518 dylibs (6.6 GB) outside the bundle, 7.1 GB total |
| Chromium Framework binary | 256 MB, stripped | reexport stub + `libchrome_dll.dylib` and closure |
| Shell executable | 20.7 MB | 30.2 MB |
| DMG | 160 MB | — |
| dSYMs (`dist/release/symbols`, not shipped) | 2.0 GB (16, incl. ReArc.dSYM) | — |
| LaunchServices probe (launch → ready → shutdown), 2 runs | 4.6 s, 4.6 s | 8.2 s, 7.2 s |
| Self-test to the DevTools step | ~70 s | ~160 s |
| `release.sh` with a built engine | 125–146 s to a signed bundle | — |

## What the account holder must do

1. **Developer ID Application certificate**: in Xcode → Settings → Accounts → Manage
   Certificates → "+" → Developer ID Application, or on developer.apple.com →
   Certificates. Only the Account Holder of team <TEAM_ID> can create it. It then shows up
   in `security find-identity -v -p codesigning`. Put
   `REARC_RELEASE_IDENTITY="Developer ID Application: <name> (<TEAM_ID>)"` in
   `shell/signing.local.env`.
2. **Notary credentials**, stored in your keychain (never in a file in this repo):
   `xcrun notarytool store-credentials rearc-notary --apple-id <apple-id> --team-id <TEAM_ID>`,
   with an app-specific password from appleid.apple.com. `notarize.sh` only names the
   profile.
3. **iCloud for distribution**:
   - Before **every release**, import `shell/cloudkit/schema.ckdb` into
     **Development**, then deploy the schema to **Production** for
     `iCloud.com.rearc.browser`. From the repo root:
     `xcrun cktool import-schema --team-id <TEAM_ID> --container-id iCloud.com.rearc.browser --environment development --validate --file shell/cloudkit/schema.ckdb`.
     Or use CloudKit Console > Development > Schema > Import Schema, then
     Deploy Schema Changes to Production. Export/back up the current schema
     first and review changes (docs/ICLOUD-SETUP.md §7). Confirm all five types,
     especially `SidebarBoostRecord` and `SidebarSpaceStyleRecord`, plus encrypted
     payload and the six integer indexes per type. A just-in-time Development
     schema can omit types the developer's profile never saved; importing the
     committed file is mandatory even when that Mac already syncs successfully.
     Distributed builds cannot create missing types or fields in Production.
   - Create a **Developer ID provisioning profile** for App ID `com.rearc.browser` with
     iCloud/CloudKit and the container. Developer ID profiles list no devices. Set
     `REARC_RELEASE_PROVISIONING_PROFILE=<path>` and `REARC_ICLOUD_ENVIRONMENT=Production`.
     The development profile only runs on registered Macs.
4. Run the exact steps above. `spctl -a -vv` must then report
   `source=Notarized Developer ID`. Test on a clean Mac or user account: first launch from
   the DMG, the Keychain prompt for Safe Storage, camera/microphone/location TCC prompts,
   and iCloud sign-in.

## Known limits

- No universal (x64) build: run
  `build-engine-release.sh --target-cpu=x64` into its own out dir. Lipo/universal packaging
  is not scripted.
- No clean-machine test has been done yet. That needs the notarized build.
- **Build into a normal folder, not an agent's `/private/tmp/claude-*` scratchpad.** On
  2026-11-10 release candidate 481 failed `check-launch.sh` with "the probe did not shut down
  cleanly" and `Teardown watchdog expired` in the probe log. The code was not at fault: the
  same signed bundle passed once copied to `~/Library/Caches`. Copies of the shipped build 476
  passed from `$TMPDIR`, `shell/dist` and a 303-character path, and failed the same way in the
  scratchpad. In that tree Little Snitch
  reported the helpers as having "no code signature", did not apply ReArc's existing rule,
  and held the network service's connections behind a connection alert. DNS got no answer,
  and at shutdown each `close()` of a held UDP socket blocked in the kernel content filter
  for about 3 s. So the network process outlived the 10 s that
  `BrowserProcessIOThread::ProcessHostCleanUp` waits for it, and the 10 s teardown watchdog
  fired first. If the watchdog fires, look for a pending firewall alert and sample the
  network-service helper before suspecting the engine.


## Lists key

The built-in ad and tracker blocking takes its lists from a signed bundle
(`docs/FEATURE-SPECS/CONTENT-BLOCKING.md`, section 4). The lists key signs that bundle. It is
not the Sparkle key and cannot update the app.

- **Private key:** `~/.config/rearc/blocklists/signing.key` on the build Mac (Ed25519, mode
  600, not in the Keychain, not in the repository).
- **Public keys:** `shell/scripts/blocklists/blocklists-public-key.txt`, one key a line, the key
  in use first. The app carries the same keys in the same order
  (`BlocklistSigningKey.compiledInTexts` in `shell/Sources/SidebarModel/Blocklists.swift`), and
  a test fails when the two differ.
- **A bundle is accepted when any one of those keys signed it.** There is one key in ordinary
  times. The list is there so that a key can be replaced.

**What someone with the private key can do.** They can sign a bundle. To get it into an
install they must also control what `rearc.imara.ae/blocklists/` serves, or sit on the
network path with a certificate the Mac trusts. A signed bundle can block requests or stop
blocking them, in installs that have blocking on. It cannot redirect a request or change
headers: the build script, the app and the engine each refuse a bundle with such a rule.

### If the lists key leaks

One release. The app of that release trusts the new key and no longer the leaked one: there
is no release in which both are trusted. Keeping the leaked key for one more release would
buy nothing. The new app's built-in bundle is newer than any download, and the mirror is
signed with the new key in the same release.

1. **Rotate.**
   - Delete the leaked `signing.key`. Do not keep a copy.
   - Make the new key: `shell/scripts/blocklists/build-blocklists.py keygen`. It prints the
     new public key.
   - Put the new public key on the **first** line of `blocklists-public-key.txt`. Leave the
     leaked public key on the second line until the next sub-step is done: the build checks
     the bundle it converts again, which the leaked key signed.
   - Sign the built-in bundle with the new key. This converts the same upstream files again
     and fetches nothing:

     ```sh
     B=~/.config/rearc/blocklists/bundles
     OLD=$(python3 -c 'import json; print(json.load(open("shell/Resources/Blocklists/manifest.json"))["version"])')
     NEW=$(date -u +%Y%m%d%H%M)
     shell/scripts/blocklists/build-blocklists.py build --from-bundle shell/Resources/Blocklists \
       --raw-dir "$B/$OLD/raw" --version "$NEW" --out "$B/$NEW"
     shell/scripts/blocklists/build-blocklists.py install "$B/$NEW" shell/Resources/Blocklists
     ```

   - **Take the leaked public key out**: delete its line from `blocklists-public-key.txt`, and
     make the new key the only entry of `BlocklistSigningKey.compiledInTexts`.
   - Run `python3 -m unittest discover -s shell/scripts/blocklists/tests` and
     `cd shell && swift test --filter Blocklist`, then commit the key file, `Blocklists.swift`
     and `shell/Resources/Blocklists`. The tests check that the built-in bundle verifies with
     the one key that is left.
2. **Ship the app.** Make the release as usual. An install that updates deletes any
   downloaded bundle the leaked key signed and uses its built-in one.
   - **Mark the release critical only if a bad bundle was served**: the mirror held, or an
     install took, a bundle that this script did not build. Then people are being attacked and
     should update today ("Critical and required updates" below).
   - A leak with no sign of use is an ordinary release. The critical mark is kept for what is
     attacked, and a leaked lists key by itself needs the mirror or the network path as well
     (above).
3. **Re-sign the mirror, in the same release.** `release.sh` writes
   `blocklists-<version>.tar.gz` and `latest.json` from the app's bundle, which the new key
   signed in step 1. Have the site thread publish them with the appcast. From then on an
   install that has not updated cannot verify the mirror's bundle: it keeps the lists it has
   until it updates.

Notes:

- **An install that never updates trusts the leaked key for good.** Nothing on the mirror can
  change that; the limits above are what bound the damage.
- **A lost key** (no leak) takes the same steps and is never critical.

### Planned replacement

Only here are two keys trusted at once. The overlap lets every install that has the first
release go on taking the mirror's bundle when the key is switched. It is not for a leak.

1. **Release N: bring the new key in.** Make it beside the one in use
   (`build-blocklists.py keygen --key ~/.config/rearc/blocklists/signing-next.key`) and add its
   public key as the **second** entry of `blocklists-public-key.txt` and of
   `BlocklistSigningKey.compiledInTexts`. Bundles are still signed with the old key.
2. **Release N+1: switch.** Move `signing-next.key` to `signing.key`, put the new public key
   first and the old one second in both places, and sign the built-in bundle again as in the
   leak steps. The mirror is signed with the new key from this release on; an install with
   release N or later accepts it.
3. **Release N+2: drop the old key** from both places.

### Unattended signing

Keep the private key off any machine that signs lists without a person. If a job ever does,
it runs `build` with every check on:

- never `--allow-count-change`;
- never `--accept-gained-page-exceptions`. A list that gained an exception for whole pages or
  frames fails the job, and a person reads the exceptions the build printed before building
  with that flag by hand.

## Sparkle updates (DMG distribution)

The Chromium shell pins Sparkle **2.10.1** exactly in SwiftPM. WebKit builds have no
Sparkle dependency. Only bundles stamped `ReArcRelease = YES` by `bundle-chromium.sh
--release` start the updater or show its menu/settings. ReArc ships outside the Mac
App Store as a Developer ID signed, notarized DMG.

Release packaging stamps `SUFeedURL` from `REARC_APPCAST_URL` (default
`https://rearc.imara.ae/updates/appcast.xml`, the alpha host), `SUPublicEDKey` from
`shell/scripts/release/sparkle-public-key.txt`, automatic checks/download/install defaults
on, and a daily (86400 second) check interval. The feed URL is fixed in each build, so
installed copies only ever look there: keep serving `appcast.xml` at that address, or ship
an update whose `SUFeedURL` points at the new host before moving (for example to
rearc.net). The download URL prefix for generated enclosures is `REARC_UPDATE_DOWNLOAD_URL`
(default `https://rearc.imara.ae/updates/`); set both when using another host.

Sparkle compares appcast `sparkle:version` against **CFBundleVersion**, the increasing
commit count; `sparkle:shortVersionString` is display only. `release.sh --appcast` passes
`generate-appcast.sh --display-version`, which refuses a new item that does not show the
stamped version or does not download `ReArc-<version>.dmg`, and every item's
`sparkle:shortVersionString` must be digits and dots (a dated one carrying its own build). Keep release history linear
and never reuse a build number. Rollback means rebuilding the old code with a **higher
build number**, then publishing it as a new release, never serving a downgrade.

### Keychain and preparing archives

The EdDSA private key was created with Sparkle's `generate_keys --account ReArc`. It lives
only in this Mac's login Keychain; `generate_keys --account ReArc` reuses it. To retrieve
only the public key, use `generate_keys --account ReArc -p`. Never use `-x`, put private
key material in files/environment variables, or commit it. Losing this Keychain item
requires planning a key rotation before signing further updates.

Download the [2.10.1 distribution](https://github.com/sparkle-project/Sparkle/releases/tag/2.10.1)
and set `REARC_SPARKLE_TOOLS` to its `bin` directory. The helper verifies that the
Keychain public key matches the committed public key before generating signatures.

```sh
# Local development signing verification, no launch and no notarization:
REARC_SPARKLE_TOOLS=/path/to/Sparkle-2.10.1/bin \
  shell/scripts/release.sh --dist /tmp/rearc-release --no-verify \
  --appcast /tmp/rearc-updates --channel beta

# Distribution, ONLY after Developer ID + notary profile setup:
REARC_SPARKLE_TOOLS=/path/to/Sparkle-2.10.1/bin \
  shell/scripts/release.sh --dist /path/to/release --notarize \
  --appcast /path/to/update-archives
```

`--appcast DIR` implies `--dmg`, copies a version/build-named DMG into the persistent
archive directory, then runs `generate_appcast --account ReArc`. Keep this directory
outside `--dist`, which packaging replaces. `--channel beta` affects newly generated
items; stable releases omit it. No command uploads. `--notarize` first notarizes/staples
the app, makes the DMG, notarizes/staples the DMG, then generates the appcast. Any failure
stops the pipeline. Without that flag, notarization is never attempted. If notarizing
manually, finish it before generating the appcast: stapling changes the signed archive.
For example, after `notarize.sh /path/ReArc.dmg` succeeds, copy that final DMG into the
archives directory and run `shell/scripts/release/generate-appcast.sh DIR [beta]`.

Upload the final DMG, appcast.xml, release notes and generated delta files to their HTTPS
locations yourself. Do not upload `old_updates/`. The Apple Development test artifacts
are not distributable: obtain a Developer ID Application certificate and configure
`rearc-notary` (or `REARC_NOTARY_PROFILE`) first.

### Appcast policy examples

Use the following XML within an RSS feed declaring
`xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"`. Let
`generate_appcast` produce real enclosure signatures and lengths; the placeholders below
must be replaced. Each example below is an independent item policy, not a combined policy.
See Sparkle's [publishing guide](https://sparkle-project.org/documentation/publishing/).

A normal item (build 500, display version 2026.1109.500):

```xml
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>ReArc</title>
    <item>
      <title>ReArc 2026.1109.500</title>
      <sparkle:version>500</sparkle:version>
      <sparkle:shortVersionString>2026.1109.500</sparkle:shortVersionString>
      <pubDate>Mon, 09 Nov 2026 12:00:00 +0000</pubDate>
      <enclosure url="https://rearc.net/updates/ReArc-2026.1109.500.dmg"
                 sparkle:edSignature="REPLACE_WITH_GENERATED_SIGNATURE"
                 length="REPLACE_WITH_BYTE_LENGTH" type="application/octet-stream"/>
    </item>
  </channel>
</rss>
```

Add one of these directly under `<item>` (alongside version/enclosure):

```xml
<!-- Critical for every older build: prompt promptly; no Skip button. -->
<sparkle:criticalUpdate/>
```

```xml
<!-- Critical only for installed builds below 450 (exclusive). -->
<sparkle:criticalUpdate sparkle:version="450"/>
```

```xml
<!-- Installed builds below 450 require the update UI, even with auto-download on. -->
<sparkle:minimumAutoupdateVersion>450</sparkle:minimumAutoupdateVersion>
```

```xml
<!-- Seen by users who enable Receive beta updates (stable remains eligible too). -->
<sparkle:channel>beta</sparkle:channel>
```

```xml
<!-- Seven rollout groups, one day between groups; pubDate is required. -->
<pubDate>Mon, 09 Nov 2026 12:00:00 +0000</pubDate>
<sparkle:phasedRolloutInterval>86400</sparkle:phasedRolloutInterval>
```

```xml
<!-- Show a website action instead of installing, for all installed builds. -->
<sparkle:informationalUpdate/>
<link>https://rearc.net/updates/important-notice</link>
```

```xml
<!-- Informational only for builds below 450; other builds can install enclosure. -->
<sparkle:informationalUpdate>
  <sparkle:belowVersion>450</sparkle:belowVersion>
</sparkle:informationalUpdate>
<link>https://rearc.net/updates/important-notice</link>
```

Critical updates bypass phased rollout; manual checks also bypass rollout. Critical does
not forcibly terminate the browser or defeat user consent: Sparkle removes skipping and
uses prominent reminders. From the build with the sidebar's update notice
(docs/FEATURE-SPECS/UPDATE-NOTICE.md), a scheduled find, critical included, shows only in
the notice (the pill above the space strip, and the menu's “Update Available…” / “1 update”
badge); Check for Updates… keeps Sparkle's window. Builds before it (677 and older) show
ordinary updates on the menu's badge and critical ones in Sparkle's alert. Automatic
downloads install on quit when eligible; Sparkle may remind a long-running app after its
impatient interval. `minimumAutoupdateVersion` requires UI below the threshold; it does
not establish a minimum supported build or force installation. Beta opt-in is stored in
UserDefaults and supplied by `allowedChannels(for:)` on subsequent checks.

### Critical and required updates

`release.sh --appcast DIR` takes two flags that mark the new item (both need `--appcast`;
`generate-appcast.sh` takes the same, with `--version BUILD`):

- `--critical`: Sparkle's own `<sparkle:criticalUpdate/>`, for every older build. The
  notice reads "Critical Update Available" with a shield, adds "This update fixes a
  security problem.", stays open until the pointer has been over it and cannot be hidden;
  Sparkle removes Skip and the item bypasses phased rollout. Use it for a security fix
  people should install today: a Chromium security release, a fix for a ReArc
  vulnerability. Not for features or ordinary bug fixes, or it stops meaning anything.
- `--required-below N`: ReArc's `<rearc:requiredBelow>N</rearc:requiredBelow>` (namespace
  `https://rearc.imara.ae/xml-namespaces/update`, declared on `<rss>`), for builds below N,
  N at most this build (N = this build: every older one). Builds below N read "Required
  Update" and "This version of ReArc is no longer supported. Restart to update."; builds
  from N on see a normal (or critical) update. Use it when old builds stop working or must
  not run any more: a sync or data format they would damage, a server change they cannot
  follow, a Chromium base so old it is unsafe. It is display only for now: nothing is forced
  (UPDATE-NOTICE.md §5 lists the enforcement options), and it does not bypass phased
  rollout; add `--critical` too when it must reach everyone at once.

Both can be combined. With `--required-below`, the script cuts generate_appcast's
signature off, stamps the item (`scripts/release/appcast-marker.py stamp`: one inserted line
and the namespace declaration, every other byte unchanged), signs again with `sign_update
--account ReArc --disable-signing-warning` (a second Keychain grant), checks the signed bytes
are the stamped ones exactly, verifies the signature and every ReArc marker
(`verify-appcast.sh`), and checks the new item has exactly the flags asked for; any failure
writes no feed. A flag applies only to an item generated in this run: generate_appcast keeps
existing items as they are, and stamping an item that already has the marker is refused.
Builds that predate the notice (677, 608) parse such a feed and update as usual: Sparkle keeps
the ReArc element in the item's properties and nothing reads it; a critical item shows them
Sparkle's alert.

Signing follows Sparkle's [manual signing recipe](https://sparkle-project.org/documentation/sandboxing/):
Installer.xpc, Downloader.xpc, Autoupdate, Updater.app, then Sparkle.framework, all with
hardened runtime and secure timestamps and no inherited development entitlements. Both
XPC services remain sealed but their sandbox-only opt-in keys are unset (ReArc is not
sandboxed). The release signer rejects `get-task-allow`, unexpected executables, missing
team/timestamps/runtime flags, and finishes with `codesign --verify --deep --strict`.
