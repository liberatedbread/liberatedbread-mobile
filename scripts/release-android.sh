#!/usr/bin/env bash
# Copyright 2026 Pigs Can Fly Labs LLC
# SPDX-License-Identifier: Apache-2.0
#
# Guided Google Play release: docs/RELEASE.md's checklist for Android, start to
# finish. Every step a shell can do is done here (fetch, CI gate, clean
# worktree, host tests, phone preflight, tag, signed AAB build, jarsigner
# check, hashes, tag push, GitHub Release, release record). For every step that
# happens in Play Console or on a phone it says what to do and waits.
#
# Usage:
#   ./scripts/release-android.sh                   # asks: new tag, or existing tag
#   ./scripts/release-android.sh --new-tag         # cut pubspec.yaml's version on origin/main
#   ./scripts/release-android.sh --from-tag v0.1.0 # build a tag that already exists
#
# Runs on Linux or macOS. Needs gh (signed in), the Flutter SDK from
# ./scripts/setup.sh, a JDK's jarsigner, the upload keystore, and an Android
# phone. See scripts/release-lib.sh for the shared flow and the record.

# shellcheck disable=SC2034  # PLATFORM* and *_KEY are read by release-lib.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=release-lib.sh
source "$SCRIPT_DIR/release-lib.sh"

PLATFORM=android
PLATFORM_KEY=ANDROID
PLATFORM_NAME=Android
BUILD_NUMBER_KEY=ANDROID_VERSION_CODE
ARTIFACT_SHA_KEY=AAB_SHA256
PLAY_CONSOLE_URL="https://play.google.com/console"
AAB_PATH=build/app/outputs/bundle/release/app-release.aab

# key_prop FILE KEY — one value from a key.properties file.
key_prop() { sed -n "s/^[[:space:]]*$2[[:space:]]*=[[:space:]]*//p" "$1" | tail -n 1; }

platform_preflight() {
  command -v jarsigner &>/dev/null ||
    die "jarsigner not found: install a JDK (it checks the AAB's upload signature)."
}

platform_gates() {
  checklist \
    "The Android upload keystore is backed up off this machine" \
    "Play Console's listing, Data safety, ads, location declaration and content rating are complete (docs/RELEASE.md 'Google Play, the first time')"
}

platform_device_tests() {
  local extra
  extra="$(ask "Extra arguments for run-android-device-tests.sh (e.g. --device SERIAL), blank for none" "")"
  # shellcheck disable=SC2086  # extra is word-split on purpose: it is flags
  run_until_pass "run-android-device-tests.sh --all --expect-lan-devices --live-ble-any $extra" \
    ./scripts/run-android-device-tests.sh --all --expect-lan-devices --live-ble-any $extra
}

# The worktree is fresh, and key.properties is gitignored, so it is never
# there on a first run. Copy the main checkout's, point at one, or write one.
ensure_key_properties() {
  local props=android/key.properties src store
  if [[ ! -s "$props" ]]; then
    if [[ -s "$PROJECT_DIR/$props" ]] &&
      confirm "Copy $PROJECT_DIR/$props into the release worktree?" y; then
      src="$PROJECT_DIR/$props"
    else
      src="$(ask "Path to an existing key.properties (blank to write a new one)" "")"
    fi
    if [[ -n "$src" ]]; then
      [[ -s "$src" ]] || die "$src is missing or empty."
      (umask 077 && cp "$src" "$props")
    else
      write_key_properties "$props"
    fi
  fi
  chmod 600 "$props"
  git check-ignore -q "$props" || die "$props is not gitignored here; refusing to continue."

  store="$(key_prop "$props" storeFile)"
  KEY_ALIAS="$(key_prop "$props" keyAlias)"
  [[ "$store" == /* ]] || die "storeFile in $props must be an absolute path (got '$store')."
  [[ -f "$store" ]] || die "The upload keystore $store does not exist."
  [[ -n "$KEY_ALIAS" ]] || die "$props has no keyAlias."
  KEYSTORE="$store"
}

write_key_properties() {
  local store alias store_pw key_pw
  store="$(ask_required "Absolute path to the upload keystore (.jks)")"
  alias="$(ask "Key alias" upload)"
  printf '\033[1m?\033[0m Keystore password: ' >&2
  IFS= read -r -s store_pw; printf '\n' >&2
  printf '\033[1m?\033[0m Key password (Enter if the same): ' >&2
  IFS= read -r -s key_pw; printf '\n' >&2
  (
    umask 077
    printf 'storeFile=%s\nstorePassword=%s\nkeyAlias=%s\nkeyPassword=%s\n' \
      "$store" "$store_pw" "$alias" "${key_pw:-$store_pw}" >"$1"
  )
  log "Wrote $RELEASE_DIR/$1 (owner-only)."
}

platform_build() {
  ensure_key_properties
  log "./scripts/release.sh android (log: $BUILD_LOG)"
  ./scripts/release.sh android 2>&1 | tee "$BUILD_LOG" ||
    die "release.sh android failed; the log is $BUILD_LOG."
  BUILD_NUMBER="$(build_number_from_log <"$BUILD_LOG")"
  ARTIFACT="$AAB_PATH"
}

# docs/RELEASE.md Step 4: the keystore is the trust source for the self-signed
# upload certificate, and the alias makes a bundle signed by any other key
# fail. The password goes through the environment, never the command line.
platform_verify() {
  log "jarsigner -verify --strict (alias $KEY_ALIAS)"
  local out
  out="$(LB_STOREPASS="$(key_prop android/key.properties storePassword)" \
    jarsigner -verify --strict -keystore "$KEYSTORE" -storepass:env LB_STOREPASS \
    "$ARTIFACT" "$KEY_ALIAS" 2>&1)" || {
    printf '%s\n' "$out" >&2
    die "The AAB is not signed by the upload key $KEY_ALIAS. Play would reject it."
  }
  grep -q 'jar verified' <<<"$out" || {
    printf '%s\n' "$out" >&2
    die "jarsigner did not report 'jar verified'."
  }
  log "Signed by the upload key."
}

platform_upload() {
  open_url "$PLAY_CONSOLE_URL"
  say "Play Console → Liberated Bread → Testing → Internal testing → Releases:" \
    "  1. Create a release and upload" \
    "       $ARTIFACT" \
    "     (versionCode $BUILD_NUMBER, SHA-256 $(recorded AAB_SHA256))." \
    "  2. Paste the release notes (CHANGELOG.md's [$VERSION] section), review the" \
    "     release, and start the rollout to Internal testing. Not Production." \
    "If Play refuses the versionCode, stop (q) and re-run: answer No to reusing" \
    "the build, and the next build gets a higher one."
  pause
  record_url PLAY_INTERNAL_RELEASE_URL "Internal-testing release URL (blank to skip)"
}

platform_closed_test() {
  say "Add the test Google account as a tester on the Internal testing track, open" \
    "the track's tester link on the Android phone, and install build $BUILD_NUMBER" \
    "from Play. An AAB cannot be sideloaded; this is the only way to test it."
  pause
}

platform_publish() {
  open_url "$PLAY_CONSOLE_URL"
  say "Play Console → Testing → Internal testing → the tested release (versionCode" \
    "$BUILD_NUMBER) → Promote release → Production. This carries the SAME AAB" \
    "forward: do not rebuild or upload anything new." \
    "Check the release notes and store forms, review the Production release, and" \
    "start its rollout (staged, when offered)."
  pause
  record_url PLAY_PRODUCTION_RELEASE_URL "Production release URL (blank to skip)"
}

release_main "$@"
