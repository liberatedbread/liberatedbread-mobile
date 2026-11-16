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
#   ./scripts/release-android.sh --new-tag 0.2.0   # bump pubspec.yaml + CHANGELOG.md to 0.2.0 on main, then cut it
#   ./scripts/release-android.sh --from-tag v0.1.0 # build a tag that already exists
#
# Runs on Linux or macOS. Needs gh (signed in), the Flutter SDK from
# ./scripts/setup.sh, a JDK's jarsigner, python3, the upload keystore (or
# --ci-build, which signs in GitHub Actions), and an Android phone. See
# scripts/release-lib.sh for the shared flow, the flags and the record.
#
# With a Google Play service account (docs/RELEASE.md, "Play Developer API"),
# the upload to Internal testing and the promotion to Production go through
# scripts/play_publish.py instead of Play Console; without one, or if the API
# refuses, the script says what to do in Play Console, as before. The key's
# JSON is read from LB_PLAY_SERVICE_ACCOUNT, else
# ~/.config/liberatedbread/play-service-account.json.

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
ARTIFACT_EXT=aab
PLAY_NOTES_LIMIT=500   # characters per language in Play's "What's new"
PLAY_SERVICE_ACCOUNT="${LB_PLAY_SERVICE_ACCOUNT:-$HOME/.config/liberatedbread/play-service-account.json}"
# The tools this checkout brings, not the release worktree's: a release of an
# older tag must still be checked and uploaded by today's scripts.
PLAY_PUBLISH="$RELEASE_LIB_DIR/play_publish.py"
VERIFY_AAB="$RELEASE_LIB_DIR/verify_aab.py"

# key.properties is read and written through java.util.Properties, the class
# Gradle loads it with (android/app/build.gradle), so this script and the
# build agree on every value. A sed over the raw text disagreed on escapes:
# `\\` is one backslash to Gradle, so a password with a backslash failed the
# preflight below although Gradle signed with it. Writing raw text was wrong
# the other way: Gradle reads the file as ISO-8859-1, so a UTF-8 `é` in a
# password reached the signing config as two other characters. Needs a JDK 11+
# `java`, which comes with the jarsigner this script already requires.
#
#   key_prop FILE KEY   prints KEY's value, or nothing when it is absent.
#   key_props_write FILE
#                       writes storeFile, storePassword, keyAlias and
#                       keyPassword from LB_KP_STOREFILE, LB_KP_STOREPASS,
#                       LB_KP_ALIAS and LB_KP_KEYPASS (the environment, so no
#                       password is ever on a command line), owner-only.
_key_props_java() {
  local src rc=0
  src="$(mktemp -d)" || return 1
  cat >"$src/KeyProps.java" <<'JAVA'
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.util.Properties;
public class KeyProps {
  public static void main(String[] a) throws Exception {
    Properties p = new Properties();
    if (a[0].equals("get")) {
      try (FileInputStream in = new FileInputStream(a[1])) { p.load(in); }
      String v = p.getProperty(a[2]);
      if (v != null) System.out.print(v);
      return;
    }
    String[][] keys = {{"storeFile", "LB_KP_STOREFILE"}, {"storePassword", "LB_KP_STOREPASS"},
                       {"keyAlias", "LB_KP_ALIAS"}, {"keyPassword", "LB_KP_KEYPASS"}};
    for (String[] k : keys) p.setProperty(k[0], System.getenv(k[1]));
    try (FileOutputStream out = new FileOutputStream(a[1])) { p.store(out, "Upload key for release builds; written by release-android.sh"); }
  }
}
JAVA
  # `|| true` in the filter: grep -v exits 1 when java wrote nothing else to
  # stderr (the usual case), and release_main's `set -E` carries its ERR trap
  # into this process substitution, which then printed "Stopped by an
  # unexpected failure ... :74" for every call although nothing had stopped.
  java "$src/KeyProps.java" "$@" 2> >(grep -v '^Picked up JAVA_TOOL_OPTIONS' >&2 || true) || rc=$?
  rm -f "$src/KeyProps.java"
  rmdir "$src" 2>/dev/null || true
  return "$rc"
}

key_prop() {
  _key_props_java get "$1" "$2" || { err "java could not read $2 from $1."; return 1; }
}

key_props_write() {
  (umask 077 && _key_props_java put "$1") || { err "java could not write $1."; return 1; }
}

platform_preflight() {
  command -v jarsigner &>/dev/null ||
    die "jarsigner not found: install a JDK (it checks the AAB's upload signature)."
  command -v java &>/dev/null ||
    die "java not found: install a JDK (it reads android/key.properties the way Gradle does)."
}

platform_gates() {
  checklist \
    "The Android upload keystore is backed up off this machine" \
    "Play Console's listing, Data safety, ads, location declaration and content rating are complete (docs/RELEASE.md 'Google Play, the first time')"
}

# RELEASE_DEVICE_TEST_ARGS (release-lib.sh): no printing suite, and no
# connection to whichever BLE peripheral happens to be strongest.
platform_device_tests() {
  local extra
  # The last answer is the default (- for none), so a re-run on the same
  # phone is one Enter.
  extra="$(ask "Extra arguments for run-android-device-tests.sh (e.g. --device SERIAL, --live-ble-any), - for none" \
    "${LB_RELEASE_DEVICE_ARGS:-$(recorded DEVICE_TEST_ARGS_ANDROID)}")"
  [[ "$extra" != - ]] || extra=""
  record DEVICE_TEST_ARGS_ANDROID "${extra:--}"
  # shellcheck disable=SC2086  # extra is word-split on purpose: it is flags
  run_until_pass "run-android-device-tests.sh ${RELEASE_DEVICE_TEST_ARGS[*]} $extra" \
    ./scripts/run-android-device-tests.sh "${RELEASE_DEVICE_TEST_ARGS[@]}" $extra
}

# The worktree is fresh, and key.properties is gitignored, so it is never
# there on a first run. Copy the main checkout's, point at one, or write one.
#
# The file holds the keystore passwords, so whether git ignores it is checked
# twice. The first check runs BEFORE anything is written: `git check-ignore`
# matches the path against the worktree's ignore rules whether or not the
# file exists, so a release worktree whose .gitignore lost the entry stops the
# run with no secrets on disk. The second check runs AFTER the file is in
# place, against the real file. If that one fails, a file this run wrote is
# deleted before the run stops, so it cannot be staged by accident.
ensure_key_properties() {
  local props=android/key.properties src store wrote=false
  if [[ ! -s "$props" ]]; then
    git check-ignore -q "$props" ||
      die "$props is not gitignored in the release worktree; refusing to put the signing passwords there."
    log "$props is gitignored in the release worktree."
    if [[ -s "$PROJECT_DIR/$props" ]] &&
      confirm "Copy $PROJECT_DIR/$props into the release worktree? (verified gitignored there before the copy, and checked again after it)" y; then
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
    wrote=true
  fi
  chmod 600 "$props"
  if ! git check-ignore -q "$props"; then
    if [[ "$wrote" == true ]]; then
      rm -f "$props"
      die "$props is not gitignored here; deleted the copy just written and refusing to continue."
    fi
    die "$props is not gitignored here; refusing to continue."
  fi
  log "$props is in place and still gitignored."

  store="$(key_prop "$props" storeFile)"
  KEY_ALIAS="$(key_prop "$props" keyAlias)"
  [[ "$store" == /* ]] || die "storeFile in $props must be an absolute path (got '$store')."
  [[ -f "$store" ]] || die "The upload keystore $store does not exist."
  [[ -n "$KEY_ALIAS" ]] || die "$props has no keyAlias."
  KEYSTORE="$store"
  check_signing_key "$props"
}

# Gradle's :app:signReleaseBundle fails with a bare NullPointerException, and
# no message, when its signing config holds a null. That happens when
# key.properties has no storePassword, or names a keyAlias the keystore does
# not hold. A wrong password fails the same task minutes into the build. So
# sign a throwaway jar with exactly these values first: it takes seconds, and
# jarsigner says what is wrong. Passwords go through the environment, never
# the command line.
#
# keyPassword defaults to storePassword, as android/app/build.gradle does: in
# a PKCS12 keystore (keytool's default since JDK 9) they are the same password.
check_signing_key() {
  local props="$1" store_pw key_pw probe out rc=0
  store_pw="$(key_prop "$props" storePassword)"
  [[ -n "$store_pw" ]] ||
    die "$props has no storePassword. Gradle's signReleaseBundle fails on that with a bare NullPointerException."
  key_pw="$(key_prop "$props" keyPassword)"
  if [[ -z "$key_pw" ]]; then
    key_pw="$store_pw"
    log "$props has no keyPassword; using storePassword for the key, as the Gradle build does."
  fi
  command -v jar &>/dev/null || die "jar not found: install a full JDK (it checks the upload key before the build)."
  probe="$(mktemp -d)" || die "mktemp failed."
  printf 'probe\n' >"$probe/probe.txt"
  (cd "$probe" && jar cf probe.jar probe.txt) || die "jar could not build the probe jar in $probe."
  out="$(LB_STOREPASS="$store_pw" LB_KEYPASS="$key_pw" \
    jarsigner -keystore "$KEYSTORE" -storepass:env LB_STOREPASS -keypass:env LB_KEYPASS \
    -signedjar "$probe/signed.jar" "$probe/probe.jar" "$KEY_ALIAS" 2>&1)" || rc=$?
  rm -f "$probe/probe.txt" "$probe/probe.jar" "$probe/signed.jar"
  rmdir "$probe" 2>/dev/null || true
  if (( rc != 0 )); then
    printf '%s\n' "$out" >&2
    die "The upload key in $props does not work (jarsigner, above): check keyAlias is in $KEYSTORE" \
      "(keytool -list -keystore $KEYSTORE) and that storePassword (and keyPassword, if set) are right." \
      "For a PKCS12 keystore, leave keyPassword out or set it equal to storePassword."
  fi
  log "Upload key '$KEY_ALIAS' opens with the passwords in $props."
}

write_key_properties() {
  local store alias store_pw key_pw
  store="$(ask_required "Absolute path to the upload keystore (.jks)")"
  alias="$(ask "Key alias" upload)"
  printf '\033[1m?\033[0m Keystore password: ' >&2
  IFS= read -r -s store_pw; printf '\n' >&2
  printf '\033[1m?\033[0m Key password (Enter if the same): ' >&2
  IFS= read -r -s key_pw; printf '\n' >&2
  LB_KP_STOREFILE="$store" LB_KP_STOREPASS="$store_pw" LB_KP_ALIAS="$alias" \
    LB_KP_KEYPASS="${key_pw:-$store_pw}" key_props_write "$1" ||
    die "Could not write $1."
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
# A bundle built in GitHub Actions comes with no keystore on this machine:
# its signing certificate is compared, by SHA-256, with the upload key's,
# which a local build records and Play Console shows.
platform_verify() {
  if [[ -n "${KEYSTORE:-}" ]]; then
    verify_with_keystore
  else
    verify_upload_fingerprint
  fi
  # The contents, as verify_ios_app.sh checks the IPA: the Rust core in every
  # ABI, 16 KB page alignment, the merged manifest's package and permissions,
  # and that the bundle's versionCode/versionName are this build's.
  run_until_pass "verify_aab.py $ARTIFACT" python3 "$VERIFY_AAB" "$ARTIFACT" \
    --expect-version-code "$BUILD_NUMBER" --expect-version-name "$VERSION"
}

verify_with_keystore() {
  log "jarsigner -verify --strict (alias $KEY_ALIAS)"
  local out store_pw fp
  store_pw="$(key_prop android/key.properties storePassword)"
  out="$(LB_STOREPASS="$store_pw" \
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
  # Kept for the day this release (or the next) is built in CI.
  fp="$(LB_STOREPASS="$store_pw" keytool -list -v -keystore "$KEYSTORE" -alias "$KEY_ALIAS" \
    -storepass:env LB_STOREPASS 2>/dev/null | sed -n 's/^[[:space:]]*SHA256:[[:space:]]*//p' | head -n 1 || true)"
  [[ -z "$fp" ]] || record ANDROID_UPLOAD_CERT_SHA256 "$fp"
}

# fingerprint_norm FP — upper-case hex, no colons or spaces.
fingerprint_norm() { printf '%s' "$1" | tr -d ': ' | tr '[:lower:]' '[:upper:]'; }

verify_upload_fingerprint() {
  local out want got
  out="$(jarsigner -verify "$ARTIFACT" 2>&1)" || {
    printf '%s\n' "$out" >&2
    die "jarsigner -verify failed on $ARTIFACT."
  }
  grep -q 'jar verified' <<<"$out" || {
    printf '%s\n' "$out" >&2
    die "jarsigner did not report 'jar verified' for $ARTIFACT."
  }
  want="${LB_ANDROID_UPLOAD_CERT_SHA256:-$(recorded ANDROID_UPLOAD_CERT_SHA256)}"
  if [[ -z "$want" ]]; then
    say "No upload-key fingerprint is on record yet. Play Console → Liberated Bread →" \
      "Test and release → App integrity → App signing → Upload key certificate: SHA-256."
    want="$(ask_required "Upload key certificate SHA-256")"
  fi
  got="$(keytool -printcert -jarfile "$ARTIFACT" 2>/dev/null |
    sed -n 's/^[[:space:]]*SHA256:[[:space:]]*//p' | head -n 1 || true)"
  if [[ -z "$got" || "$(fingerprint_norm "$got")" != "$(fingerprint_norm "$want")" ]]; then
    die "$ARTIFACT is signed by certificate SHA-256 ${got:-<none>}, not the upload key's $want. Play would reject it."
  fi
  record ANDROID_UPLOAD_CERT_SHA256 "$want"
  log "Signed by the upload key (certificate SHA-256 matches)."
}

# play_api — status 0 when a service account is configured for play_publish.py.
play_api() {
  [[ -f "$PLAY_SERVICE_ACCOUNT" ]] && return 0
  log "No Play service account at $PLAY_SERVICE_ACCOUNT (LB_PLAY_SERVICE_ACCOUNT); this step is by hand."
  return 1
}

platform_upload() {
  store_notes play "$PLAY_NOTES_LIMIT"
  local out status
  if play_api; then
    log "Uploading build $BUILD_NUMBER to Internal testing through the Play Developer API"
    if out="$(python3 "$PLAY_PUBLISH" upload --service-account "$PLAY_SERVICE_ACCOUNT" \
      --aab "$ARTIFACT" --track internal --expect-version-code "$BUILD_NUMBER" \
      --notes-file "$STORE_NOTES" --release-name "$VERSION ($BUILD_NUMBER)")"; then
      status="$(json_field status <<<"$out")"
      record PLAY_INTERNAL_STATUS "$status"
      if [[ "$status" == draft ]]; then
        open_url "$PLAY_CONSOLE_URL"
        say "Liberated Bread has never been published, so Play holds this as a DRAFT" \
          "release on Internal testing. Play Console → Testing → Internal testing →" \
          "the draft → review it and start the rollout to Internal testing."
        pause
      else
        log "Build $BUILD_NUMBER is rolled out to Internal testing."
      fi
      return
    fi
    warn "The Play Developer API upload did not go through (above). Upload by hand instead:"
  fi
  open_url "$PLAY_CONSOLE_URL"
  say "Play Console → Liberated Bread → Testing → Internal testing → Releases:" \
    "  1. Create a release and upload" \
    "       $ARTIFACT" \
    "     (versionCode $BUILD_NUMBER, SHA-256 $(recorded AAB_SHA256))." \
    "  2. Paste the release notes from $STORE_NOTES, review the" \
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
  store_notes play "$PLAY_NOTES_LIMIT"
  local fraction args out status
  if play_api; then
    say "Promotion carries the tested AAB (versionCode $BUILD_NUMBER) from Internal testing" \
      "to Production: nothing is rebuilt or uploaded. A staged rollout starts with a" \
      "fraction of users, and is widened later with play_publish.py rollout."
    fraction="$(ask "Fraction of users to start the Production rollout with (1 for everyone)" 0.2)"
    args=(promote --service-account "$PLAY_SERVICE_ACCOUNT" --version-code "$BUILD_NUMBER"
      --from internal --to production --notes-file "$STORE_NOTES")
    [[ "$fraction" == 1 || "$fraction" == 1.0 ]] || args+=(--user-fraction "$fraction")
    if confirm "Promote versionCode $BUILD_NUMBER to Production at $fraction of users?" y &&
      out="$(python3 "$PLAY_PUBLISH" "${args[@]}")"; then
      status="$(json_field status <<<"$out")"
      record PLAY_PRODUCTION_STATUS "$status"
      record PLAY_ROLLOUT_FRACTION "$fraction"
      if [[ "$status" == draft ]]; then
        open_url "$PLAY_CONSOLE_URL"
        say "Play created the Production release as a DRAFT (the app has never been" \
          "published). Play Console → Production → the draft → check the store forms," \
          "review the release and start its rollout."
        pause
      else
        say "Production release created ($status). Play reviews the update before users" \
          "see it. Widen the rollout once vitals look healthy:" \
          "  python3 $PLAY_PUBLISH rollout --version-code $BUILD_NUMBER --user-fraction 0.5" \
          "  python3 $PLAY_PUBLISH rollout --version-code $BUILD_NUMBER --complete" \
          "(--halt stops it)."
      fi
      return
    fi
    warn "Not promoted through the API. Promote by hand instead:"
  fi
  open_url "$PLAY_CONSOLE_URL"
  say "Play Console → Testing → Internal testing → the tested release (versionCode" \
    "$BUILD_NUMBER) → Promote release → Production. This carries the SAME AAB" \
    "forward: do not rebuild or upload anything new." \
    "Release notes: $STORE_NOTES. Check the store forms, review the Production" \
    "release, and start its rollout (staged, when offered)."
  pause
  record_url PLAY_PRODUCTION_RELEASE_URL "Production release URL (blank to skip)"
}

release_main "$@"
