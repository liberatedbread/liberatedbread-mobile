#!/usr/bin/env bash
# Copyright 2026 Pigs Can Fly Labs LLC
# SPDX-License-Identifier: Apache-2.0
#
# Guided App Store release: docs/RELEASE.md's checklist for iOS, with the
# Apple side from docs/APP_STORE_SUBMISSION.md (Steps 5-9). Every step a shell
# can do is done here (fetch, CI gate, clean worktree, host tests, iPhone
# preflight, tag, signed IPA build, verify_ios_app.sh, hashes, tag push, the
# upload itself when an App Store Connect API key is available, GitHub
# Release, release record). For every step that happens in App Store Connect,
# TestFlight or on the phone it says what to do and waits.
#
# Usage:
#   ./scripts/release-apple.sh                   # asks: new tag, or existing tag
#   ./scripts/release-apple.sh --new-tag         # cut pubspec.yaml's version on origin/main
#   ./scripts/release-apple.sh --new-tag 0.2.0   # bump pubspec.yaml + CHANGELOG.md to 0.2.0 on main, then cut it
#   ./scripts/release-apple.sh --from-tag v0.1.0 # build a tag that already exists
#
# macOS only (the release Mac). Needs gh (signed in), the Flutter SDK from
# ./scripts/setup.sh, Xcode, the Apple Distribution certificate and the
# "Liberated Bread App Store" profile (runbook Steps 2-4), and an iPhone.
#
# Uploading: with ASC_KEY_ID and ASC_ISSUER_UUID set (or entered when asked)
# and AuthKey_<KEYID>.p8 in ~/.appstoreconnect/private_keys/, the IPA goes up
# through `xcrun altool`; otherwise Transporter is opened and the script waits.
#
# With that same key, scripts/asc_api.py does the App Store Connect steps that
# need no judgement: it waits for the build to finish processing (no waiting
# for Apple's email), adds it to the internal TestFlight group, creates the
# App Store version, selects the validated build and sets "What's New", and
# submits for review and releases once approved, each after a confirmation.
# Without the key, or when the API refuses, the script says what to click, as
# before. Metadata, screenshots and App Review Information stay by hand.
#
# --ci-build builds and signs the IPA in GitHub Actions; this Mac then needs no
# Distribution certificate, only Xcode's command-line tools for the checks.

# shellcheck disable=SC2034  # PLATFORM* and *_KEY are read by release-lib.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=release-lib.sh
source "$SCRIPT_DIR/release-lib.sh"

PLATFORM=ios
PLATFORM_KEY=IOS
PLATFORM_NAME=iOS
BUILD_NUMBER_KEY=IOS_BUILD_NUMBER
ARTIFACT_SHA_KEY=IPA_SHA256
TEAM_ID=GQ358PSWM3
PROFILE_NAME="Liberated Bread App Store"
ASC_URL="https://appstoreconnect.apple.com/"
ARTIFACT_EXT=ipa
APPSTORE_NOTES_LIMIT=4000   # characters in "What's New in This Version"
ASC_API="$RELEASE_LIB_DIR/asc_api.py"   # this checkout's, not the release worktree's
PLISTBUDDY=/usr/libexec/PlistBuddy

platform_preflight() {
  [[ "$(uname -s)" == Darwin ]] ||
    die "iOS releases build on the release Mac. Use ./scripts/release-android.sh here."
  command -v xcrun &>/dev/null || die "xcrun not found: install Xcode."
  # A CI build signs in GitHub Actions: this Mac's keychain is not involved.
  if [[ "$BUILD_WHERE" != ci ]]; then
    check_distribution_identity
    check_profile
  fi
}

# Runbook Step 2. A missing identity fails ten minutes into the build instead.
check_distribution_identity() {
  if security find-identity -v -p codesigning 2>/dev/null |
    grep -q "Apple Distribution.*($TEAM_ID)"; then
    log "Apple Distribution identity for $TEAM_ID found."
    return
  fi
  warn "No 'Apple Distribution' signing identity for team $TEAM_ID in the keychain"
  warn "(docs/APP_STORE_SUBMISSION.md Step 2). The signed export will fail."
  confirm "Continue anyway?" n || exit 1
}

# Runbook Step 4: the App Store profile, by the name ExportOptions-appstore.plist
# uses, carrying the multicast entitlement. Xcode can fetch one at export time,
# so a miss here is a warning.
check_profile() {
  local dir file tmp name found=""
  tmp="$(mktemp)"
  for dir in "$HOME/Library/MobileDevice/Provisioning Profiles" \
    "$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles"; do
    [[ -d "$dir" ]] || continue
    for file in "$dir"/*.mobileprovision; do
      [[ -f "$file" ]] || continue
      security cms -D -i "$file" >"$tmp" 2>/dev/null || continue
      name="$("$PLISTBUDDY" -c 'Print :Name' "$tmp" 2>/dev/null || true)"
      [[ "$name" == "$PROFILE_NAME" ]] || continue
      if "$PLISTBUDDY" -c 'Print :Entitlements:com.apple.developer.networking.multicast' \
        "$tmp" &>/dev/null; then
        found="$file"
      else
        warn "Profile '$PROFILE_NAME' ($file) lacks the multicast entitlement;"
        warn "regenerate it (runbook Step 4) or signing will fail."
      fi
    done
  done
  rm -f "$tmp"
  if [[ -n "$found" ]]; then
    log "Profile '$PROFILE_NAME' with multicast: $found"
  else
    warn "No installed profile named '$PROFILE_NAME' carrying multicast."
    warn "Download it (runbook Step 4) unless Xcode manages it for you."
    confirm "Continue anyway?" n || exit 1
  fi
}

platform_gates() {
  checklist \
    "Apple runbook Steps 1-4 are done (multicast grant, Distribution certificate, App Store Connect record, multicast-bearing App Store profile)" \
    "The runbook's Step 6-9 metadata (export compliance, App Privacy, listing, screenshots) has been reviewed for this version"
}

platform_device_tests() {
  # RELEASE_DEVICE_TEST_ARGS (release-lib.sh): no printing suite, and no
  # connection to whichever BLE peripheral happens to be strongest.
  local args=("${RELEASE_DEVICE_TEST_ARGS[@]}") extra
  if confirm "Does this Mac's iPhone development profile carry the multicast entitlement (pass --keep-multicast)?" y; then
    args+=(--keep-multicast)
  fi
  # The last answer is the default (- for none).
  extra="$(ask "Extra arguments for run-ios-device-tests.sh (e.g. --device UDID, --live-ble-any), - for none" \
    "${LB_RELEASE_DEVICE_ARGS:-$(recorded DEVICE_TEST_ARGS_IOS)}")"
  [[ "$extra" != - ]] || extra=""
  record DEVICE_TEST_ARGS_IOS "${extra:--}"
  say "Not passing --allow-keychain-wipe: add it above only if every credential" \
    "the app holds on that iPhone is disposable."
  # shellcheck disable=SC2086  # extra is word-split on purpose: it is flags
  run_until_pass "run-ios-device-tests.sh ${args[*]} $extra" \
    ./scripts/run-ios-device-tests.sh "${args[@]}" $extra
}

platform_build() {
  # Without this declaration App Store Connect rejects the upload with
  # ITMS-91053 for the Rust core's file-timestamp API use (runbook Step 5).
  grep -q NSPrivacyAccessedAPICategoryFileTimestamp ios/Runner/PrivacyInfo.xcprivacy ||
    die "ios/Runner/PrivacyInfo.xcprivacy lacks NSPrivacyAccessedAPICategoryFileTimestamp (ITMS-91053)."

  # A reused worktree can hold an earlier IPA; take only what this build wrote.
  local marker ipas count
  marker="$(mktemp)"
  log "./scripts/release.sh ios (log: $BUILD_LOG)"
  ./scripts/release.sh ios 2>&1 | tee "$BUILD_LOG" ||
    die "release.sh ios failed; the log is $BUILD_LOG."
  BUILD_NUMBER="$(build_number_from_log <"$BUILD_LOG")"
  ipas="$(find build/ios/ipa -maxdepth 1 -name '*.ipa' -newer "$marker" 2>/dev/null || true)"
  rm -f "$marker"
  count="$(printf '%s' "$ipas" | grep -c . || true)"
  [[ "$count" == 1 ]] || die "Expected one new IPA under build/ios/ipa, found $count. Never guess which was built."
  ARTIFACT="$ipas"
}

platform_verify() {
  run_until_pass "verify_ios_app.sh $ARTIFACT" ./scripts/verify_ios_app.sh "$ARTIFACT"
}

asc_key_file() {
  local dir
  for dir in "$HOME/.appstoreconnect/private_keys" "$HOME/private_keys" \
    "$HOME/.private_keys" ./private_keys; do
    [[ -f "$dir/AuthKey_$1.p8" ]] && { printf '%s\n' "$dir/AuthKey_$1.p8"; return 0; }
  done
  return 1
}

# asc_ready — status 0 when an App Store Connect API key is usable: the IDs
# from the environment (or the upload prompt) and its .p8 on disk.
asc_ready() {
  [[ -n "${ASC_KEY_ID:-}" && -n "${ASC_ISSUER_UUID:-}" ]] && asc_key_file "$ASC_KEY_ID" >/dev/null
}

# asc ARGS... — scripts/asc_api.py with the key. Its last stdout line is a
# JSON summary; progress and Apple's messages go to stderr.
asc() {
  python3 "$ASC_API" --key-id "$ASC_KEY_ID" --issuer "$ASC_ISSUER_UUID" \
    --key-file "$(asc_key_file "$ASC_KEY_ID")" "$@"
}

platform_upload() {
  local how key
  ASC_KEY_ID="${ASC_KEY_ID:-$(recorded ASC_KEY_ID)}"
  ASC_ISSUER_UUID="${ASC_ISSUER_UUID:-$(recorded ASC_ISSUER_UUID)}"
  how="$(choose "Upload build $BUILD_NUMBER to App Store Connect with" \
    "xcrun altool and an App Store Connect API key (automatic)" \
    "Transporter (by hand)")"
  if [[ "$how" == 1 ]]; then
    ASC_KEY_ID="$(ask "API key ID (ASC_KEY_ID)" "$ASC_KEY_ID")"
    ASC_ISSUER_UUID="$(ask "Issuer ID (ASC_ISSUER_UUID)" "$ASC_ISSUER_UUID")"
    if [[ -z "$ASC_KEY_ID" || -z "$ASC_ISSUER_UUID" ]] || ! key="$(asc_key_file "$ASC_KEY_ID")"; then
      warn "Need a key ID, an issuer ID and AuthKey_${ASC_KEY_ID:-<KEYID>}.p8 in"
      warn "$HOME/.appstoreconnect/private_keys/ (App Store Connect → Users and Access →"
      warn "Integrations → Team Keys). Falling back to Transporter."
      how=2
    else
      # The IDs are not secrets (the .p8 is, and stays where it is), and
      # keeping them spares the later steps and a resumed run the prompt.
      record ASC_KEY_ID "$ASC_KEY_ID"
      record ASC_ISSUER_UUID "$ASC_ISSUER_UUID"
      log "Uploading with key $ASC_KEY_ID ($key)"
      run_until_pass "xcrun altool --upload-app" \
        xcrun altool --upload-app -f "$ARTIFACT" -t ios \
        --apiKey "$ASC_KEY_ID" --apiIssuer "$ASC_ISSUER_UUID"
    fi
  fi
  if [[ "$how" == 2 ]]; then
    open -a Transporter 2>/dev/null ||
      warn "Could not open Transporter; install it from the Mac App Store."
    say "In Transporter, signed in to an Apple ID on Pigs Can Fly Labs LLC ($TEAM_ID):" \
      "Add App → $ARTIFACT → Deliver." \
      "(build $BUILD_NUMBER, SHA-256 $(recorded IPA_SHA256)). This uploads; it does not publish."
    pause
  fi
  wait_for_processing
}

# wait_for_processing — until App Store Connect has processed the build and
# TestFlight can use it. Polled through the API when there is a key; Apple's
# email otherwise.
wait_for_processing() {
  local rc
  if asc_ready; then
    while true; do
      log "Waiting for App Store Connect to process build $BUILD_NUMBER (polling; up to 90 minutes)"
      rc=0
      asc wait-build --version "$VERSION" --build "$BUILD_NUMBER" >/dev/null || rc=$?
      case "$rc" in
        0) log "Build $BUILD_NUMBER is processed and ready for TestFlight."; return ;;
        3) open_url "$ASC_URL"
           say "Build $BUILD_NUMBER is processed but marked Missing Compliance (above)." \
             "App Store Connect → TestFlight → the build → Manage: uses encryption →" \
             "standard algorithms → exempt under EAR 740.17(b)(1) (APP_STORE_SUBMISSION.md Step 6)."
           pause ;;
        4) confirm "Still processing after 90 minutes. Keep waiting?" y ||
             die "Stopped while Apple processes build $BUILD_NUMBER; re-run with --from-tag $TAG." ;;
        *) warn "Could not follow the build through the API (above); falling back to Apple's email."
           break ;;
      esac
    done
  fi
  open_url "$ASC_URL"
  say "App Store Connect → Apps → Liberated Bread → TestFlight: wait for Apple's" \
    "processing-complete email for build $BUILD_NUMBER. If it says Missing Compliance," \
    "answer Step 6 of docs/APP_STORE_SUBMISSION.md: uses encryption → standard" \
    "algorithms → exempt under EAR 740.17(b)(1)." \
    "A duplicate-build-number refusal arrives by EMAIL: then stop (q), re-run, and" \
    "answer No to reusing the build so the next one gets a higher number."
  pause
  record_url TESTFLIGHT_BUILD_URL "Processed TestFlight build URL (blank to skip)"
}

platform_closed_test() {
  local out
  ASC_KEY_ID="${ASC_KEY_ID:-$(recorded ASC_KEY_ID)}"
  ASC_ISSUER_UUID="${ASC_ISSUER_UUID:-$(recorded ASC_ISSUER_UUID)}"
  if asc_ready && out="$(asc add-to-group --version "$VERSION" --build "$BUILD_NUMBER")"; then
    log "Build $BUILD_NUMBER is available to internal TestFlight group '$(json_field group <<<"$out")'."
    say "On the iPhone, open TestFlight (accept the invitation if this tester is new)" \
      "and install build $BUILD_NUMBER. An App Store IPA cannot be sideloaded; this is" \
      "the only way to test it."
  else
    asc_ready && warn "Could not add the build to a TestFlight group through the API (above)."
    say "TestFlight → an Internal Testing group: add build $BUILD_NUMBER to it (testers" \
      "must be App Store Connect users on this app). On the iPhone, accept the" \
      "invitation in the TestFlight app and install that build. An App Store IPA" \
      "cannot be sideloaded; this is the only way to test it."
  fi
  pause
}

platform_publish() {
  ASC_KEY_ID="${ASC_KEY_ID:-$(recorded ASC_KEY_ID)}"
  ASC_ISSUER_UUID="${ASC_ISSUER_UUID:-$(recorded ASC_ISSUER_UUID)}"
  store_notes appstore "$APPSTORE_NOTES_LIMIT"
  if asc_ready && publish_through_api; then
    return
  fi
  asc_ready && warn "Continuing in App Store Connect by hand."
  publish_by_hand
}

# version_state — the App Store version's state, or "" when there is none yet
# (or the API could not say).
version_state() {
  local out
  out="$(asc version-state --version "$VERSION" 2>/dev/null)" || return 0
  json_field appStoreState <<<"$out"
}

# publish_through_api — runbook Step 9 driven by the version's state, so a
# run stopped while Apple reviews (q) picks up where it was. Status 1 hands
# over to publish_by_hand.
publish_through_api() {
  local state out
  while true; do
    state="$(version_state)"
    log "App Store version $VERSION: ${state:-not created yet}"
    case "$state" in
      "" | PREPARE_FOR_SUBMISSION | DEVELOPER_REJECTED | REJECTED | METADATA_REJECTED | INVALID_BINARY)
        [[ "$state" == REJECTED || "$state" == METADATA_REJECTED ]] &&
          say "Rejected. Over metadata: fix it and resubmit this same build. Over code:" \
            "stop (q); that is a new version, a new tag and a new run of this script."
        confirm "Create/update App Store version $VERSION with build $BUILD_NUMBER and its What's New text?" y ||
          return 1
        out="$(asc prepare-version --version "$VERSION" --build "$BUILD_NUMBER" \
          --whats-new-file "$STORE_NOTES")" || return 1
        [[ "$(json_field whatsNew <<<"$out")" == updated ]] ||
          warn "What's New was not set (Apple refuses it on an app's first version); that is expected for 1.0."
        record APP_STORE_VERSION_ID "$(json_field versionId <<<"$out")"
        open_url "$ASC_URL"
        say "Version $VERSION has build $BUILD_NUMBER selected. In App Store Connect → Apps →" \
          "Liberated Bread → App Store → $VERSION, finish what the API does not:" \
          "Steps 6-8 complete, Pricing and Availability, category, age rating, App Review" \
          "Information (contact, review notes, mock-device video; docs/RELEASE.md § Review)," \
          "and Version Release: 'Manually release this version' recommended."
        pause
        confirm "Submit $VERSION (build $BUILD_NUMBER) for App Review now?" y || return 1
        asc submit --version "$VERSION" >/dev/null || return 1
        log "Submitted for review." ;;
      READY_FOR_REVIEW)
        # Added to a review submission but not submitted: an earlier run
        # stopped between the two, or "Add for Review" was clicked alone.
        # Apple has nothing yet; asc submit finishes that same draft.
        confirm "$VERSION is ready for review but not submitted. Submit it (build $BUILD_NUMBER) now?" y ||
          return 1
        asc submit --version "$VERSION" >/dev/null || return 1
        log "Submitted for review." ;;
      WAITING_FOR_REVIEW | IN_REVIEW | PENDING_CONTRACT | WAITING_FOR_EXPORT_COMPLIANCE)
        say "Apple has it ($state). Approval can take days: q stops here, and" \
          "re-running with --from-tag $TAG checks again. Enter checks now."
        pause ;;
      PENDING_DEVELOPER_RELEASE)
        confirm "Approved and waiting for you. Release $VERSION to the App Store now?" y || {
          say "Left in Pending Developer Release. Re-run with --from-tag $TAG to release it."
          exit 0
        }
        asc release --version "$VERSION" >/dev/null || return 1
        log "Release requested." ;;
      PROCESSING_FOR_APP_STORE | PENDING_APPLE_RELEASE | READY_FOR_SALE | READY_FOR_DISTRIBUTION)
        log "$VERSION is released or being released by Apple ($state)."
        return 0 ;;
      *)
        warn "Unexpected state $state for $VERSION."
        return 1 ;;
    esac
  done
}

publish_by_hand() {
  open_url "$ASC_URL"
  say "Needs Account Holder, Admin or App Manager. Runbook Step 9, in App Store Connect" \
    "→ Apps → Liberated Bread → App Store:" \
    "  A. Open the 'Prepare for Submission' version or '+ Version', version $VERSION" \
    "     (no +N, no build number). Steps 6-8 complete, Pricing and Availability set," \
    "     Utilities / Lifestyle, age rating. Build → Select Build → build $BUILD_NUMBER" \
    "     (the TestFlight-validated one; check the number). What's New: $STORE_NOTES." \
    "     App Review Information: contact, review notes and mock-device video" \
    "     (docs/RELEASE.md § Review). Version Release: 'Manually release this version'" \
    "     recommended."
  pause
  record_url APP_STORE_VERSION_URL "App Store version URL (blank to skip)"
  say "  B. 'Add for Review' → create the submission, THEN open it and 'Submit for" \
    "     Review'. The first alone sends nothing. Wait for 'In Review'."
  pause
  say "  C. After approval: with manual release the version waits in 'Pending" \
    "     Developer Release' — open it and choose 'Release This Version'. With" \
    "     automatic release Apple publishes it." \
    "  A rejection over metadata: fix and resubmit the same build. Over code: a new" \
    "  version, a new tag, and a new run of this script." \
    "(Approval can take days. q stops here; re-run with --from-tag $TAG to resume.)"
  pause
}

release_main "$@"
