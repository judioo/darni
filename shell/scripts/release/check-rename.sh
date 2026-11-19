#!/usr/bin/env bash
# The rename gate. ReArc was renamed Darni at build 1054, and only the names people see
# changed. Every identifier an installed copy depends on must stay as it was, or existing
# users lose their data or stop getting updates:
#
#   the name people see         CFBundleName, CFBundleDisplayName and the file name: Darni
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
#   --qa   a test bundle that is never distributed may carry another SUFeedURL
#          (REARC_APPCAST_URL, for a local update feed); everything else is still checked.
# Reads files only: no launch, no Keychain, no network.
set -euo pipefail

NAME="Darni"
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
expect CFBundleName "$NAME" "the menu bar and Sparkle's User-Agent"
expect CFBundleDisplayName "$NAME" "Finder, the Dock and macOS prompts"

# What must not move.
expect CFBundleIdentifier "$BUNDLE_ID" "a new id is a new app to macOS, and Sparkle could not find the update"
expect CFBundleExecutable "$EXECUTABLE" "the scripts and crash reports name it"
[[ -x "$APP/Contents/MacOS/$EXECUTABLE" ]] || fail "no executable at Contents/MacOS/$EXECUTABLE"
if [[ "$(key "$PLIST" ReArcRelease)" == true ]]; then
  feed="$(key "$PLIST" SUFeedURL)"
  if [[ $feed != "$FEED_URL" ]]; then
    if [[ $QA == 1 ]]; then
      echo "check-rename: NOTE: --qa bundle with SUFeedURL '$feed' (not $FEED_URL); never distribute it" >&2
    else
      fail "SUFeedURL is '$feed', expected '$FEED_URL' (every installed build polls the URL built into it)"
    fi
  fi
  expect SUPublicEDKey "$(tr -d '[:space:]' <"$HERE/sparkle-public-key.txt")" "updates are accepted on this key's signature"
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
