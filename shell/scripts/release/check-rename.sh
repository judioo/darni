#!/usr/bin/env bash
# The rename gate. ReArc was renamed Darni at build 1054, and only the names people see
# changed. Every identifier an installed copy depends on must stay as it was, or existing
# users lose their data or stop getting updates:
#
#   the name people see         CFBundleName, SUBundleName, each locale's CFBundleDisplayName
#                               and the file name: Darni (Info.plist's own CFBundleDisplayName
#                               is ReArc, the file name of updated copies, so macOS shows Darni)
#   bundle id                   com.rearc.browser, and the helper and framework ids under it
#                               (a new id is a new app to macOS, and Sparkle finds a renamed
#                               app inside an update only by its bundle id)
#   executable                  Contents/MacOS/ReArc
#   update feed                 SUFeedURL https://rearc.imara.ae/updates/appcast.xml
#   update key                  SUPublicEDKey, scripts/release/sparkle-public-key.txt
#   iCloud container            iCloud.com.rearc.browser, when the bundle is signed for iCloud
#   blocklists URL              https://rearc.imara.ae/blocklists/latest.json, in the executable
#   Safe Storage keychain item  "ReArc Safe Storage" / account "ReArc"
#                               (check-safe-storage-name.py: the engine binary, BRANDING and,
#                               with --engine-out, the header the engine build generated)
#
# Usage: scripts/release/check-rename.sh APP [--engine-out DIR] [--qa]
#   Without --qa the bundle must be a release bundle: ReArcRelease is true, SUFeedURL is the
#   address above, and LSEnvironment sets no REARC_* variable (the mark of an update test
#   copy, check-rename-update.sh, which opens a data directory of its own).
#   --qa   a test bundle that is never distributed may lack the release marker and may carry
#          another SUFeedURL (REARC_APPCAST_URL, for a local update feed); everything else is
#          still checked.
# Reads files only: no launch, no Keychain, no network.
set -euo pipefail

NAME="Darni"
# The file name of every copy updated from a ReArc build; Sparkle never renames it.
OLD_FILE_NAME="ReArc"
BUNDLE_ID="com.rearc.browser"
EXECUTABLE="ReArc"
FEED_URL="https://rearc.imara.ae/updates/appcast.xml"
BLOCKLISTS_URL="https://rearc.imara.ae/blocklists/latest.json"
ICLOUD_CONTAINER="iCloud.com.rearc.browser"

HERE="$(cd "$(dirname "$0")" && pwd)"
usage="usage: check-rename.sh APP [--engine-out DIR] [--qa]"
APP=""
ENGINE_OUT=""
QA=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --engine-out) ENGINE_OUT="${2:?$usage}"; shift ;;
    --qa) QA=1 ;;
    -*) echo "$usage" >&2; exit 64 ;;
    *) APP="$1" ;;
  esac
  shift
done
[[ -n $APP && -d $APP ]] || { echo "check-rename: no app bundle at '$APP' ($usage)" >&2; exit 1; }
APP="$(cd "$APP" && pwd)"
PLIST="$APP/Contents/Info.plist"
failed=0
fail() { echo "check-rename: FAIL: $*" >&2; failed=1; }
key() { plutil -extract "$2" raw "$1" 2>/dev/null || true; }
expect() { # KEY EXPECTED WHY
  local actual; actual="$(key "$PLIST" "$1")"
  [[ $actual == "$2" ]] || fail "$1 is '$actual', expected '$2' ($3)"
}

# The names people see.
[[ "$(basename "$APP")" == "$NAME.app" ]] || fail "the bundle is named $(basename "$APP"), expected $NAME.app"
expect CFBundleName "$NAME" "the menu bar"
expect SUBundleName "$NAME" "Sparkle's windows and User-Agent"
# Finder, the Dock and Spotlight show the localized name only while the file name equals the
# Info.plist's own CFBundleDisplayName: ReArc, the name of every updated copy (bundle-chromium.sh).
expect CFBundleDisplayName "$OLD_FILE_NAME" "it must equal an updated copy's file name, ReArc.app, or macOS shows that file name"
expect LSHasLocalizedDisplayName true "macOS reads the localized CFBundleDisplayName only with it"
expect MDItemKeywords "Darni, ReArc" "Spotlight finds Darni.app by ReArc too"
locales=0
for strings in "$APP/Contents/Resources"/*.lproj/InfoPlist.strings; do
  [[ -f $strings ]] || continue
  locales=$((locales + 1))
  shown="$(key "$strings" CFBundleDisplayName)"
  [[ $shown == "$NAME" ]] || fail "$(basename "$(dirname "$strings")")/InfoPlist.strings has CFBundleDisplayName '$shown', expected '$NAME' (what an updated ReArc.app shows)"
done
[[ $locales -gt 0 ]] || fail "no <locale>.lproj/InfoPlist.strings: an updated ReArc.app would show and be found as ReArc"

# What must not move.
expect CFBundleIdentifier "$BUNDLE_ID" "a new id is a new app to macOS, and Sparkle could not find the update"
expect CFBundleExecutable "$EXECUTABLE" "the scripts and crash reports name it"
[[ -x "$APP/Contents/MacOS/$EXECUTABLE" ]] || fail "no executable at Contents/MacOS/$EXECUTABLE"
release="$(key "$PLIST" ReArcRelease)"
if [[ $release != true ]]; then
  if [[ $QA == 1 ]]; then
    echo "check-rename: NOTE: --qa bundle without ReArcRelease: no updater, so no feed or update key to check" >&2
  else
    fail "ReArcRelease is '$release', expected 'true': this is not a release bundle, and its feed and update key cannot be checked"
  fi
fi
feed="$(key "$PLIST" SUFeedURL)"
if [[ $feed != "$FEED_URL" ]]; then
  if [[ $QA == 1 ]]; then
    [[ -z $feed ]] || echo "check-rename: NOTE: --qa bundle with SUFeedURL '$feed' (not $FEED_URL); never distribute it" >&2
  else
    fail "SUFeedURL is '${feed:-missing}', expected '$FEED_URL' (every installed build polls the URL built into it)"
  fi
fi
if [[ $release == true ]]; then
  expect SUPublicEDKey "$(tr -d '[:space:]' <"$HERE/sparkle-public-key.txt")" "updates are accepted on this key's signature"
fi
# A REARC_* variable in LSEnvironment redirects every launch (REARC_DATA_DIR: another data
# directory). Only an update test copy has one.
launch_env="$(python3 -I -c 'import plistlib, sys
env = plistlib.load(open(sys.argv[1], "rb")).get("LSEnvironment") or {}
print(" ".join(sorted(k for k in env if k.upper().startswith("REARC_"))))' "$PLIST" 2>/dev/null || echo unreadable)"
if [[ -n $launch_env ]]; then
  if [[ $QA == 1 ]]; then
    echo "check-rename: NOTE: --qa bundle with LSEnvironment $launch_env; never distribute it" >&2
  else
    fail "LSEnvironment sets $launch_env: a shipped bundle must not redirect its own launches"
  fi
fi
container="$(key "$PLIST" ReArcICloudContainer)"
[[ -z $container || $container == "$ICLOUD_CONTAINER" ]] \
  || fail "ReArcICloudContainer is '$container', expected '$ICLOUD_CONTAINER' (CloudKit containers cannot be renamed)"

FRAMEWORK="$APP/Contents/Frameworks/Chromium Framework.framework"
framework_id="$(key "$FRAMEWORK/Versions/Current/Resources/Info.plist" CFBundleIdentifier)"
[[ $framework_id == "$BUNDLE_ID.framework" ]] || fail "the engine framework's id is '$framework_id', expected '$BUNDLE_ID.framework'"
helpers=0
for helper in "$FRAMEWORK/Versions/Current/Helpers"/*.app; do
  [[ -d $helper ]] || continue
  helpers=$((helpers + 1))
  id="$(key "$helper/Contents/Info.plist" CFBundleIdentifier)"
  case "$id" in
    "$BUNDLE_ID.helper"|"$BUNDLE_ID.helper.renderer"|"$BUNDLE_ID.framework.AlertNotificationService") ;;
    *) fail "$(basename "$helper") has the id '$id', expected one under $BUNDLE_ID" ;;
  esac
  # The helpers keep Chromium's file and executable names (engine/docs/PACKAGING-MAC.md).
  [[ "$(basename "$helper")" == "Chromium Helper"* ]] || fail "unexpected helper bundle $(basename "$helper")"
done
[[ $helpers -gt 0 ]] || fail "no helper bundles under $FRAMEWORK/Versions/Current/Helpers"

LC_ALL=C grep -a -q -F "$BLOCKLISTS_URL" "$APP/Contents/MacOS/$EXECUTABLE" 2>/dev/null \
  || fail "the executable does not hold $BLOCKLISTS_URL (BlocklistStore.swift): installed builds and the mirror use that URL"

storage=(python3 -I "$HERE/check-safe-storage-name.py" "$APP")
[[ -z $ENGINE_OUT ]] || storage+=(--engine-out "$ENGINE_OUT")
"${storage[@]}" || failed=1

[[ $failed == 0 ]] || { echo "check-rename: FAIL ($APP)" >&2; exit 1; }
echo "check-rename: PASS ($APP): $NAME, id $BUNDLE_ID, feed, update key and Safe Storage name unchanged"
