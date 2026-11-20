#!/usr/bin/env bash
# The live update check for the rename: an installed copy updates itself from a feed on
# 127.0.0.1, with Sparkle's own installer, and keeps its file name, bundle id, data and
# Keychain item. Run it for each row before the bridge release ships:
#
#   installed copy          on disk      update to         proves
#   1027 (oldest on feed)   ReArc.app    the bridge build  Sparkle finds Darni.app by bundle id
#   1053 (latest ReArc)     ReArc.app    the bridge build  the same, from the latest build
#   the bridge build        ReArc.app    a later build     the update after the bridge, updated user
#   the bridge build        Darni.app    a later build     the update after the bridge, new download
#
# The first two rows continue into the third with `advance`. The archive side of all four
# (feed, delta names, delta contents, Sparkle's lookup rule) is tests/test_sparkle_rename.py,
# which needs no launch.
#
# Usage:
#   check-rename-update.sh prepare --from APP --to APP [--next APP] [--installed-as NAME.app]
#                                  [--port N] --work DIR
#       No launch. Makes test copies of the bundles in DIR, signed again with the release
#       identity (sign-release.sh, or REARC_UPGRADE_SIGN), a DMG of --to and of --next, and a
#       signed feed. --next defaults to a copy of --to with its build number raised by 10.
#       --installed-as is the file name of the installed copy (default: --from's own).
#   check-rename-update.sh serve DIR
#       Serves DIR/feed on 127.0.0.1 only, in the foreground, and logs each request's
#       User-Agent to DIR/http.log. Stop it with Ctrl-C.
#   check-rename-update.sh launch DIR
#       NEEDS THE SCREEN. Opens the installed copy in the background (`open -n -g`). Then, by
#       hand: <app menu> > Check for Updates..., install, and let it relaunch.
#   check-rename-update.sh verify DIR
#       After the relaunch (quit the copy first). Checks the installed copy against the build
#       the feed offers: same path and file name, new build, CFBundleName Darni, same bundle
#       id, a valid signature, the feed asked with the right User-Agent, the data directory
#       kept, no "Darni Safe Storage" Keychain item and no Application Support/Darni folder.
#   check-rename-update.sh advance DIR
#       Adds --next to the feed, for the update after the bridge. Then serve, launch and
#       verify again.
#
# What makes a test copy safe to run beside the person's own ReArc:
# - Its SUFeedURL is http://127.0.0.1:PORT/appcast.xml and its SUPublicEDKey a throwaway key
#   made here. The real update key is never read, and nothing here can be published: the
#   rename gate (check-rename.sh) refuses a bundle with either value.
# - It carries ReArcReleaseVerification and LSEnvironment REARC_DATA_DIR=DIR/data, so every
#   launch through LaunchServices, Sparkle's relaunch included, opens the throwaway data
#   directory and never the person's own. All three builds carry the same value.
# - It shares the bundle id, so it also shares the preferences domain com.rearc.browser
#   (Sparkle's last check time among them) and reads the real "ReArc Safe Storage" item, as
#   check-upgrade.sh's copies do. A separate macOS user account avoids both and is the better
#   place for the first run; it is also the fresh-install check.
# - A copy already running, and the person's own ReArc or Arc, are left alone.
#
# Also reads: REARC_OPENSSL (an OpenSSL 3 for the throwaway Ed25519 key, default: Homebrew's
# or the one on PATH) and REARC_SPARKLE_TOOLS (Sparkle's command line tools, default: the
# ones under shell/.build-chromium, as generate-appcast.sh).
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SHELL_DIR="$(cd "$HERE/../.." && pwd)"
die() { echo "check-rename-update: $*" >&2; exit 1; }
key() { plutil -extract "$2" raw "$1/Contents/Info.plist" 2>/dev/null || true; }
note() { echo "check-rename-update: $*"; }

openssl3() {
  local candidate
  for candidate in "${REARC_OPENSSL:-}" /opt/homebrew/bin/openssl /usr/local/bin/openssl "$(command -v openssl || true)"; do
    [[ -n $candidate && -x $candidate ]] || continue
    if "$candidate" version 2>/dev/null | grep -Eq '^OpenSSL ([3-9]|[1-9][0-9])\.'; then echo "$candidate"; return 0; fi
  done
  return 1
}

# stamp APP: the test values, then signed again (Info.plist is sealed by the signature).
stamp() {
  local app="$1" plist="$1/Contents/Info.plist"
  plutil -replace SUFeedURL -string "http://127.0.0.1:$PORT/appcast.xml" "$plist"
  plutil -replace SUPublicEDKey -string "$PUBLIC_KEY" "$plist"
  plutil -remove ReArcReleaseVerification "$plist" 2>/dev/null || true
  plutil -insert ReArcReleaseVerification -bool true "$plist"
  plutil -extract LSEnvironment raw -expect dictionary "$plist" >/dev/null 2>&1 || plutil -insert LSEnvironment -dictionary "$plist"
  plutil -replace LSEnvironment.REARC_DATA_DIR -string "$WORK/data" "$plist"
  "$SIGN" "$app" >"$WORK/logs/sign-$(key "$app" CFBundleVersion)-$(basename "$app" .app).log" 2>&1 \
    || die "signing $app failed (log in $WORK/logs)"
}

# copy_of SRC LABEL [NAME]: a clone of SRC in WORK/builds/LABEL, under its own or another file name.
copy_of() {
  local src="$1" dest="$WORK/builds/$2/${3:-$(basename "$1")}"
  rm -rf "$(dirname "$dest")"
  mkdir -p "$(dirname "$dest")"
  cp -Rc "$src" "$dest" 2>/dev/null || cp -R "$src" "$dest"
  echo "$dest"
}

archive_name() { python3 -I "$HERE/version.py" dmg-name "$(key "$1" CFBundleShortVersionString)" "$(key "$1" CFBundleVersion)"; }

generate() {
  "$TOOLS/generate_appcast" --ed-key-file "$WORK/throwaway-ed25519.key" \
    --download-url-prefix "http://127.0.0.1:$PORT/" "$WORK/feed" >"$WORK/logs/generate-appcast.log" 2>&1 \
    || die "generate_appcast failed (log $WORK/logs/generate-appcast.log)"
  note "feed: $(grep -c '<item>' "$WORK/feed/appcast.xml") item(s), deltas: $(cd "$WORK/feed" && ls *.delta 2>/dev/null | tr '\n' ' ')"
}

load() {
  WORK="$(cd "${1:?usage: check-rename-update.sh $COMMAND DIR}" && pwd)"
  [[ -f "$WORK/settings" ]] || die "$WORK was not made by prepare"
  # shellcheck disable=SC1091
  source "$WORK/settings"
  TOOLS="${REARC_SPARKLE_TOOLS:-$SHELL_DIR/.build-chromium/artifacts/sparkle/Sparkle/bin}"
}

COMMAND="${1:-}"
[[ $# -gt 0 ]] && shift
case "$COMMAND" in
  prepare)
    FROM="" TO="" NEXT="" INSTALLED_AS="" PORT=8123 WORK=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --from) FROM="$(cd "$2" && pwd)"; shift ;;
        --to) TO="$(cd "$2" && pwd)"; shift ;;
        --next) NEXT="$(cd "$2" && pwd)"; shift ;;
        --installed-as) INSTALLED_AS="$2"; shift ;;
        --port) PORT="$2"; shift ;;
        --work) mkdir -p "$2"; WORK="$(cd "$2" && pwd)"; shift ;;
        *) die "unknown option: $1" ;;
      esac
      shift
    done
    [[ -n $FROM && -n $TO && -n $WORK ]] || die "prepare needs --from APP --to APP --work DIR"
    [[ $PORT =~ ^[0-9]{4,5}$ ]] || die "--port needs a port number"
    [[ $WORK != /private/tmp/claude-* && $WORK != /tmp/claude-* ]] || die "choose a --work directory outside the agent's scratch space"
    for app in "$FROM" "$TO" ${NEXT:+"$NEXT"}; do
      [[ -x "$app/Contents/MacOS/ReArc" ]] || die "no app bundle (Contents/MacOS/ReArc) at $app"
      [[ "$(key "$app" CFBundleIdentifier)" == com.rearc.browser ]] || die "$app is not com.rearc.browser"
    done
    INSTALLED_AS="${INSTALLED_AS:-$(basename "$FROM")}"
    [[ $INSTALLED_AS == *.app && $INSTALLED_AS != */* ]] || die "--installed-as needs a file name ending in .app"
    (( $(key "$FROM" CFBundleVersion) < $(key "$TO" CFBundleVersion) )) || die "--to must be a later build than --from"
    TOOLS="${REARC_SPARKLE_TOOLS:-$SHELL_DIR/.build-chromium/artifacts/sparkle/Sparkle/bin}"
    [[ -x "$TOOLS/generate_appcast" ]] || die "no Sparkle tools in $TOOLS (build the shell once, or set REARC_SPARKLE_TOOLS)"
    SIGN="${REARC_UPGRADE_SIGN:-$SHELL_DIR/scripts/sign-release.sh}"
    OPENSSL="$(openssl3)" || die "needs OpenSSL 3 or later for the throwaway Ed25519 key (brew install openssl, or set REARC_OPENSSL)"
    rm -rf "$WORK/builds" "$WORK/feed" "$WORK/Applications" "$WORK/data" "$WORK/logs"
    mkdir -p "$WORK/builds" "$WORK/feed" "$WORK/Applications" "$WORK/logs"

    # A throwaway update key: the seed and the public key are the last 32 bytes of each DER form.
    "$OPENSSL" genpkey -algorithm ed25519 -outform DER -out "$WORK/throwaway-ed25519.der"
    tail -c 32 "$WORK/throwaway-ed25519.der" | base64 >"$WORK/throwaway-ed25519.key"
    PUBLIC_KEY="$("$OPENSSL" pkey -inform DER -in "$WORK/throwaway-ed25519.der" -pubout -outform DER | tail -c 32 | base64)"
    rm -f "$WORK/throwaway-ed25519.der"
    [[ "$PUBLIC_KEY" != "$(tr -d '[:space:]' <"$HERE/sparkle-public-key.txt")" ]] || die "the throwaway key equals the shipped key"

    from_copy="$(copy_of "$FROM" from "$INSTALLED_AS")"
    to_copy="$(copy_of "$TO" to)"
    if [[ -n $NEXT ]]; then
      next_copy="$(copy_of "$NEXT" next)"
    else
      next_copy="$(copy_of "$TO" next)"
      build=$(( $(key "$next_copy" CFBundleVersion) + 10 ))
      version="$(key "$next_copy" CFBundleShortVersionString)"
      plutil -replace CFBundleVersion -string "$build" "$next_copy/Contents/Info.plist"
      plutil -replace CFBundleShortVersionString -string "${version%.*}.$build" "$next_copy/Contents/Info.plist"
    fi
    for copy in "$from_copy" "$to_copy" "$next_copy"; do
      note "signing the test copy of build $(key "$copy" CFBundleVersion) ($(basename "$copy"))"
      stamp "$copy"
    done

    # The installed copy, and its own archive in the feed folder: generate_appcast makes the
    # delta from it. A zip keeps the bundle's file name, as the DMG it shipped in did.
    cp -Rc "$from_copy" "$WORK/Applications/$INSTALLED_AS" 2>/dev/null || cp -R "$from_copy" "$WORK/Applications/$INSTALLED_AS"
    from_archive="$(archive_name "$from_copy")"
    ditto -c -k --keepParent "$from_copy" "$WORK/feed/${from_archive%.dmg}.zip"
    "$SHELL_DIR/scripts/make-dmg.sh" "$to_copy" --out "$WORK/feed/$(archive_name "$to_copy")" >"$WORK/logs/make-dmg-to.log" 2>&1 \
      || die "the DMG of --to failed (log $WORK/logs/make-dmg-to.log)"
    mkdir -p "$WORK/next"
    "$SHELL_DIR/scripts/make-dmg.sh" "$next_copy" --out "$WORK/next/$(archive_name "$next_copy")" >"$WORK/logs/make-dmg-next.log" 2>&1 \
      || die "the DMG of --next failed (log $WORK/logs/make-dmg-next.log)"
    {
      printf 'PORT=%q\nINSTALLED_AS=%q\nFROM_BUILD=%q\nTO_BUILD=%q\nNEXT_BUILD=%q\nEXPECT_BUILD=%q\n' \
        "$PORT" "$INSTALLED_AS" "$(key "$from_copy" CFBundleVersion)" "$(key "$to_copy" CFBundleVersion)" \
        "$(key "$next_copy" CFBundleVersion)" "$(key "$to_copy" CFBundleVersion)"
    } >"$WORK/settings"
    generate
    cat <<EOF

Prepared in $WORK:
  installed copy  Applications/$INSTALLED_AS, build $(key "$from_copy" CFBundleVersion), named "$(key "$from_copy" CFBundleName)"
  the feed offers build $(key "$to_copy" CFBundleVersion) ($(archive_name "$to_copy")), then build $(key "$next_copy" CFBundleVersion) after \`advance\`
Next, with the screen:
  1. $0 serve "$WORK"        (leave it running in another terminal)
  2. $0 launch "$WORK"       then <app menu> > Check for Updates..., install, relaunch, quit
  3. $0 verify "$WORK"
  4. $0 advance "$WORK"      and steps 2 and 3 again for the update after it
EOF
    ;;

  serve)
    load "${1:-}"
    note "serving $WORK/feed on http://127.0.0.1:$PORT/ (log: $WORK/http.log)"
    cd "$WORK/feed"
    exec python3 -I - "$PORT" "$WORK/http.log" <<'PY'
import http.server, sys, time
port, log = int(sys.argv[1]), sys.argv[2]
class Handler(http.server.SimpleHTTPRequestHandler):
    def log_message(self, fmt, *args):
        with open(log, "a", encoding="utf-8") as handle:
            handle.write("%s\t%s\t%s\n" % (time.strftime("%H:%M:%S"), self.headers.get("User-Agent", "-") if self.headers else "-", fmt % args))
http.server.ThreadingHTTPServer(("127.0.0.1", port), Handler).serve_forever()
PY
    ;;

  launch)
    load "${1:-}"
    app="$WORK/Applications/$INSTALLED_AS"
    [[ -d $app ]] || die "no installed copy at $app"
    [[ "$(key "$app" LSEnvironment.REARC_DATA_DIR)" == "$WORK/data" ]] || die "$app has no throwaway data directory in LSEnvironment; it would open the person's own data"
    curl -fsS -m 5 -o /dev/null "http://127.0.0.1:$PORT/appcast.xml" || die "the feed is not being served: run \`$0 serve $WORK\` first"
    mkdir -p "$WORK/data"
    # A data directory with a sidebar is an existing install: no first-run onboarding.
    [[ -f "$WORK/data/sidebar.json" ]] || echo '{"version":1,"spaces":[],"profiles":[]}' >"$WORK/data/sidebar.json"
    note "opening build $(key "$app" CFBundleVersion) at $app in the background; it expects build $EXPECT_BUILD from the feed"
    open -n -g "$app"
    ;;

  verify)
    load "${1:-}"
    app="$WORK/Applications/$INSTALLED_AS"
    failed=0
    fail() { echo "check-rename-update: FAIL: $*" >&2; failed=1; }
    [[ -d $app ]] || die "the installed copy is gone from $app: Sparkle moved or renamed it"
    ! pgrep -f "$app/Contents/MacOS/ReArc" >/dev/null || die "the copy at $app is still running; quit it first"
    others="$(ls "$WORK/Applications" | grep -vxF "$INSTALLED_AS" || true)"
    [[ -z $others ]] || fail "other items appeared beside the installed copy: $others"
    [[ "$(key "$app" CFBundleVersion)" == "$EXPECT_BUILD" ]] || fail "the installed copy is build $(key "$app" CFBundleVersion), expected $EXPECT_BUILD: the update did not install"
    [[ "$(key "$app" CFBundleIdentifier)" == com.rearc.browser ]] || fail "bundle id $(key "$app" CFBundleIdentifier)"
    # Info.plist's own CFBundleDisplayName is ReArc, the copy's file name, so macOS shows the
    # localized one, Darni (bundle-chromium.sh); the rest of the bundle is check-rename.sh's.
    # `key` reads a bundle's Info.plist, so the strings file is read with plutil directly.
    shown="$(plutil -extract CFBundleDisplayName raw "$app/Contents/Resources/en.lproj/InfoPlist.strings" 2>/dev/null || true)"
    [[ "$(key "$app" CFBundleName)" == Darni && "$(key "$app" SUBundleName)" == Darni && $shown == Darni ]] \
      || fail "the installed copy is named '$(key "$app" CFBundleName)' / '$(key "$app" SUBundleName)' / '$shown', expected Darni"
    [[ "$(key "$app" LSEnvironment.REARC_DATA_DIR)" == "$WORK/data" ]] || fail "the installed copy lost its throwaway data directory"
    codesign --verify --deep --strict "$app" 2>/dev/null || fail "the installed copy's signature does not verify"
    [[ -d "$WORK/data/Chromium" ]] || fail "no Chromium profile in $WORK/data: the copy did not run on the throwaway data"
    # The feed was asked by the old build under its own name, and after the update by Darni.
    agents="$(cut -f2 "$WORK/http.log" 2>/dev/null | grep -E ' Sparkle/' | sort -u || true)"
    echo "$agents" | sed 's/^/check-rename-update: User-Agent: /'
    grep -q "^Darni/.*\.$EXPECT_BUILD Sparkle/" <<<"$agents" \
      || echo "check-rename-update: NOTE: no request from Darni/<version>.$EXPECT_BUILD yet; it asks at its next check (Check for Updates... once more, then verify again)"
    # The Keychain: attributes only, so nothing is read and nothing prompts.
    if security find-generic-password -s "Darni Safe Storage" >/dev/null 2>&1; then fail "a \"Darni Safe Storage\" Keychain item exists: the engine made a new key"; fi
    security find-generic-password -s "ReArc Safe Storage" -a ReArc >/dev/null 2>&1 || fail "no \"ReArc Safe Storage\" Keychain item"
    [[ ! -e "$HOME/Library/Application Support/Darni" ]] || fail "$HOME/Library/Application Support/Darni exists: the data folder must stay Application Support/ReArc"
    [[ $failed == 0 ]] || { echo "check-rename-update: FAIL ($app)" >&2; exit 1; }
    note "PASS: $INSTALLED_AS is build $EXPECT_BUILD, named Darni, id com.rearc.browser, same path, Keychain item and data kept"
    ;;

  advance)
    load "${1:-}"
    [[ $EXPECT_BUILD != "$NEXT_BUILD" ]] || die "the feed already offers build $NEXT_BUILD"
    mv "$WORK/next/"*.dmg "$WORK/feed/"
    generate
    sed -i '' "s/^EXPECT_BUILD=.*/EXPECT_BUILD=$NEXT_BUILD/" "$WORK/settings"
    note "the feed now offers build $NEXT_BUILD; launch, update and verify again"
    ;;

  *) sed -n '2,36p' "$0"; exit 64 ;;
esac
