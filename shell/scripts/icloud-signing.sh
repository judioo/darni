# shellcheck shell=bash
# iCloud (CloudKit) signing opt-in shared by bundle-chromium.sh and bundle-webkit-dev.sh.
# Sourced, never run. See docs/ICLOUD-SETUP.md.
#
# Off unless REARC_ICLOUD_CONTAINER is set (environment or shell/signing.local.env). When
# off, bundles carry no iCloud entitlement and no ReArcICloudContainer marker, and the app
# shows "iCloud sync unavailable in this build". When on, the bundle gets:
#   - Contents/embedded.provisionprofile (the development profile you downloaded),
#   - the iCloud/CloudKit entitlements, merged into scripts/ReArc.entitlements,
#   - Info.plist ReArcICloudContainer = the container, which the shell checks against
#     its signed entitlements before it creates anything CloudKit,
#   - keychain-access-groups with <team>.<bundle id>.webauthn, when the group is wanted
#     (webauthn_group_wanted below): "this Mac" passkeys. A bundle in release verification
#     mode never gets it, and a wanted group the profile does not cover stops the build.
# iCloud entitlements are restricted: macOS kills an app at launch unless an embedded
# profile allows them for this Mac, so the profile is checked first and the build stops
# on any mismatch.

# webauthn_group_wanted APP: whether APP is signed with the keychain access group of "this Mac"
# passkeys. Prints why not, and returns 1, when it is not; returns 2 for a setting it cannot read.
#
# REARC_WEBAUTHN_KEYCHAIN_GROUP=1 asks for the group and =0 refuses it; unset, the caller's
# REARC_WEBAUTHN_GROUP_DEFAULT decides (sign-release.sh sets it; a development bundle has none,
# so it gets the group only when asked).
#
# A bundle in release verification mode (ReArcReleaseVerification in its Info.plist: the
# bundle release.sh runs its gates on, a --qa bundle, the copies upgrade-bundles.sh and
# check-rename-update.sh make of a previous release) never gets it, whatever is asked. Such a
# copy is signed by the same team, so with the group it shares the access group of the
# person's own Darni, and started on a copy of their profile it could use, list and delete
# their real passkeys (security advance read 2026-11-24, point 5).
webauthn_group_wanted() {
  local app="$1"
  if [[ "$(plutil -extract ReArcReleaseVerification raw "$app/Contents/Info.plist" 2>/dev/null || true)" == true ]]; then
    echo "a bundle in release verification mode never gets it"
    return 1
  fi
  case "${REARC_WEBAUTHN_KEYCHAIN_GROUP:-${REARC_WEBAUTHN_GROUP_DEFAULT:-0}}" in
    1) return 0 ;;
    0) echo "REARC_WEBAUTHN_KEYCHAIN_GROUP is not 1"; return 1 ;;
    *) echo "REARC_WEBAUTHN_KEYCHAIN_GROUP must be 0 or 1"; return 2 ;;
  esac
}

# icloud_prepare APP BUNDLE_ID PROFILE BASE_ENTITLEMENTS OUT_ENTITLEMENTS
# Needs SIGN_IDENTITY and TEAM_ID. Writes OUT_ENTITLEMENTS; embeds the profile and marker.
icloud_prepare() {
  local app="$1" bundle_id="$2" profile="$3" base="$4" out="$5"
  local container="$REARC_ICLOUD_CONTAINER"
  local environment="${REARC_ICLOUD_ENVIRONMENT:-Development}"
  [[ -n ${SIGN_IDENTITY:-} ]] || die "REARC_ICLOUD_CONTAINER needs REARC_SIGN_IDENTITY (an Apple Development identity); ad-hoc signatures cannot carry iCloud"
  [[ -n ${TEAM_ID:-} ]] || die "REARC_ICLOUD_CONTAINER needs REARC_TEAM_ID"
  [[ -n $profile ]] || die "REARC_ICLOUD_CONTAINER needs a provisioning profile path (see docs/ICLOUD-SETUP.md)"
  [[ -f $profile ]] || die "provisioning profile not found: $profile"
  [[ $environment == Development || $environment == Production ]] || die "REARC_ICLOUD_ENVIRONMENT must be Development or Production"

  local decoded
  decoded="$(mktemp "${TMPDIR:-/tmp}/rearc-profile.XXXXXX")"
  security cms -D -i "$profile" >"$decoded" 2>/dev/null || { rm -f "$decoded"; die "cannot decode provisioning profile $profile"; }
  local pb=/usr/libexec/PlistBuddy
  local app_id
  app_id="$($pb -c "Print :Entitlements:com.apple.application-identifier" "$decoded" 2>/dev/null || true)"
  if [[ $app_id != "$TEAM_ID.$bundle_id" && $app_id != "$TEAM_ID.*" ]]; then
    rm -f "$decoded"
    die "profile is for '$app_id', not $TEAM_ID.$bundle_id"
  fi
  if ! $pb -c "Print :Entitlements:com.apple.developer.icloud-container-identifiers" "$decoded" 2>/dev/null \
      | sed -E 's/^[[:space:]]+//' | grep -qxF "$container"; then
    rm -f "$decoded"
    die "profile does not include iCloud container $container (enable it for the App ID, then regenerate the profile)"
  fi
  if ! $pb -c "Print :Entitlements:com.apple.developer.icloud-services" "$decoded" 2>/dev/null \
      | sed -E 's/^[[:space:]]+//' | grep -qE '^(CloudKit|\*)$'; then
    rm -f "$decoded"
    die "profile does not allow the CloudKit service"
  fi
  # Development profiles list the Macs they run on; launching elsewhere is killed by macOS.
  if $pb -c "Print :ProvisionedDevices" "$decoded" >/dev/null 2>&1; then
    local udid
    udid="$(system_profiler SPHardwareDataType 2>/dev/null | sed -n 's/.*Provisioning UDID: //p')"
    if [[ -n $udid ]] && ! $pb -c "Print :ProvisionedDevices" "$decoded" | sed -E 's/^[[:space:]]+//' | grep -qxF "$udid"; then
      rm -f "$decoded"
      die "this Mac ($udid) is not in the profile's devices; register it and regenerate the profile"
    fi
  fi
  local expires
  expires="$(plutil -extract ExpirationDate raw -o - "$decoded" 2>/dev/null || true)"
  local has_environment=0 allowed_environments=""
  if allowed_environments="$($pb -c "Print :Entitlements:com.apple.developer.icloud-container-environment" "$decoded" 2>/dev/null)"; then
    has_environment=1
    # A Developer ID profile allows Production only: signing Development into it makes a
    # bundle macOS refuses to launch (launchd 163, amfid "No matching profile found"),
    # which is what happened to 968's --qa bundle (security review, 2026-11-18).
    allows() { sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//' <<<"$allowed_environments" | grep -qxF "$1"; }
    # Unset, the environment follows the profile: Production for a Developer ID profile.
    if [[ -z ${REARC_ICLOUD_ENVIRONMENT:-} ]] && ! allows "$environment" && allows Production; then
      environment=Production
    fi
    if ! allows "$environment"; then
      rm -f "$decoded"
      die "the profile does not allow iCloud environment $environment (it allows: $(sed -E 's/^[[:space:]]+//' <<<"$allowed_environments" | grep -vE '^(Array \{|\})$' | tr '\n' ' ')); set REARC_ICLOUD_ENVIRONMENT"
    fi
  fi
  # "This Mac" passkeys (engine patch tab/097, docs/FEATURE-SPECS/PASSKEYS-AND-SITE-PERMISSIONS.md):
  # Chromium's profile authenticator keeps its keys in the keychain access group
  # <team>.<bundle id>.webauthn and is offered only when the app is signed with that group
  # (device/fido/mac/touch_id_context.mm). It needs no Apple browser entitlement, but the
  # group is a restricted entitlement like iCloud's: the profile has to allow it.
  # The key lists two groups, the app's own identifier and the passkey group, and the
  # profile has to cover both: an app whose entitlements outrun its profile is killed at
  # launch. (The condition here once accepted a profile with the passkey group alone.)
  # A wanted group the profile does not cover stops the build; it is never left out quietly,
  # because a release without a group that has shipped loses people their passkeys (PK-01).
  local webauthn_group="$TEAM_ID.$bundle_id.webauthn" has_webauthn_group=0 webauthn_why webauthn_status=0
  webauthn_why="$(webauthn_group_wanted "$app")" || webauthn_status=$?
  [[ $webauthn_status != 2 ]] || { rm -f "$decoded"; die "$webauthn_why"; }
  if [[ $webauthn_status == 0 ]]; then
    local profile_groups group
    profile_groups="$($pb -c "Print :Entitlements:keychain-access-groups" "$decoded" 2>/dev/null \
      | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//' || true)"
    for group in "$TEAM_ID.$bundle_id" "$webauthn_group"; do
      if ! grep -qxF -e "$TEAM_ID.*" -e "$group" <<<"$profile_groups"; then
        rm -f "$decoded"
        die "the keychain access group for \"this Mac\" passkeys is wanted, and the profile does not allow $group (it needs $TEAM_ID.* or both $TEAM_ID.$bundle_id and $webauthn_group); regenerate the profile, or set REARC_WEBAUTHN_KEYCHAIN_GROUP=0 for a build that must not have the group"
      fi
    done
    has_webauthn_group=1
  fi
  rm -f "$decoded"

  cp "$base" "$out"
  $pb -c "Add :com.apple.application-identifier string $TEAM_ID.$bundle_id" "$out" >/dev/null
  $pb -c "Add :com.apple.developer.team-identifier string $TEAM_ID" "$out" >/dev/null
  $pb -c "Add :com.apple.developer.icloud-container-identifiers array" "$out" >/dev/null
  $pb -c "Add :com.apple.developer.icloud-container-identifiers:0 string $container" "$out" >/dev/null
  $pb -c "Add :com.apple.developer.icloud-services array" "$out" >/dev/null
  $pb -c "Add :com.apple.developer.icloud-services:0 string CloudKit" "$out" >/dev/null
  # Only when the profile grants it; an entitlement the profile lacks gets the app killed.
  if [[ $has_environment == 1 ]]; then
    $pb -c "Add :com.apple.developer.icloud-container-environment string $environment" "$out" >/dev/null
  fi
  if [[ $has_webauthn_group == 1 ]]; then
    # The app's own identifier first: it is the default access group without this key, and
    # stays the default with it, so nothing the app keeps elsewhere moves.
    $pb -c "Add :keychain-access-groups array" "$out" >/dev/null
    $pb -c "Add :keychain-access-groups:0 string $TEAM_ID.$bundle_id" "$out" >/dev/null
    $pb -c "Add :keychain-access-groups:1 string $webauthn_group" "$out" >/dev/null
  fi
  plutil -lint "$out" >/dev/null

  cp "$profile" "$app/Contents/embedded.provisionprofile"
  plutil -replace ReArcICloudContainer -string "$container" "$app/Contents/Info.plist"
  echo "==> iCloud: container $container (${environment}), profile expires ${expires:-unknown}"
  if [[ $has_webauthn_group == 1 ]]; then
    echo "==> passkeys: keychain access group $webauthn_group (this Mac)"
  else
    echo "==> passkeys: no keychain access group for this Mac ($webauthn_why)"
  fi
}

# icloud_verify EXECUTABLE: the signed entitlements carry the container.
icloud_verify() {
  codesign -d --entitlements - --xml "$1" 2>/dev/null | grep -qF "$REARC_ICLOUD_CONTAINER" \
    || die "signed executable lacks the iCloud entitlement for $REARC_ICLOUD_CONTAINER"
  echo "==> iCloud entitlements signed into $(basename "$1")"
}
