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
  java "$src/KeyProps.java" "$@" 2> >(grep -v '^Picked up JAVA_TOOL_OPTIONS' >&2) || rc=$?
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

platform_device_tests() {
  local extra
  extra="$(ask "Extra arguments for run-android-device-tests.sh (e.g. --device SERIAL), blank for none" "")"
  # shellcheck disable=SC2086  # extra is word-split on purpose: it is flags
  run_until_pass "run-android-device-tests.sh --all --expect-lan-devices --live-ble-any $extra" \
    ./scripts/run-android-device-tests.sh --all --expect-lan-devices --live-ble-any $extra
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
# key.properties has no storePassword or keyPassword, or names a keyAlias the
# keystore does not hold. A wrong password fails the same task minutes into
# the build. So sign a throwaway jar with exactly these values first: it takes
# seconds, and jarsigner says what is wrong. Passwords go through the
# environment, never the command line.
check_signing_key() {
  local props="$1" key missing=() probe out rc=0
  for key in storePassword keyPassword; do
    [[ -n "$(key_prop "$props" "$key")" ]] || missing+=("$key")
  done
  (( ${#missing[@]} == 0 )) ||
    die "$props has no ${missing[*]}. Gradle's signReleaseBundle fails on that with a bare NullPointerException."
  command -v jar &>/dev/null || die "jar not found: install a full JDK (it checks the upload key before the build)."
  probe="$(mktemp -d)" || die "mktemp failed."
  printf 'probe\n' >"$probe/probe.txt"
  (cd "$probe" && jar cf probe.jar probe.txt) || die "jar could not build the probe jar in $probe."
  out="$(LB_STOREPASS="$(key_prop "$props" storePassword)" \
    LB_KEYPASS="$(key_prop "$props" keyPassword)" \
    jarsigner -keystore "$KEYSTORE" -storepass:env LB_STOREPASS -keypass:env LB_KEYPASS \
    -signedjar "$probe/signed.jar" "$probe/probe.jar" "$KEY_ALIAS" 2>&1)" || rc=$?
  rm -f "$probe/probe.txt" "$probe/probe.jar" "$probe/signed.jar"
  rmdir "$probe" 2>/dev/null || true
  if (( rc != 0 )); then
    printf '%s\n' "$out" >&2
    die "The upload key in $props does not work (jarsigner, above): check keyAlias is in $KEYSTORE" \
      "(keytool -list -keystore $KEYSTORE) and that storePassword and keyPassword are right." \
      "For a PKCS12 keystore, keyPassword must equal storePassword."
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
