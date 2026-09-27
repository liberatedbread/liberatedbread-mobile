#!/usr/bin/env bash
# Copyright 2026 Pigs Can Fly Labs LLC
# SPDX-License-Identifier: Apache-2.0
#
# Build a store release with its identity stamped in.
#
# Neither store shows users a commit, and many uploads share one marketing
# version, so the build carries `git describe --tags --always --dirty` as
# AppConstants.appVersion: `v0.1.0` on a tag, `v0.1.0-3-g1a2b3c4` three commits
# later, `-dirty` if the tree had uncommitted changes. Diagnostics shows it and
# puts it on line one of every copied bug report.
#
# The marketing version comes from pubspec.yaml. The build number must rise on
# every upload to either store, so it is read off the clock instead of being
# bumped by hand. See docs/RELEASE.md.
#
# A store build has to lead back to one commit, so the script refuses an
# untagged HEAD and a dirty tree. A throwaway build can override either:
#   LB_RELEASE_UNTAGGED=1   no tag on HEAD: the stamp is a bare commit SHA
#   LB_RELEASE_DIRTY=1      uncommitted changes: tracked edits stamp `-dirty`
# Stray files in the bundled asset directories have no override, because the
# stamp cannot see them at all (see below).
#
# Usage:
#   ./scripts/release.sh android   # Play app bundle -> build/app/outputs/bundle/release/
#   ./scripts/release.sh ios       # App Store IPA   -> build/ios/ipa/ (macOS)

set -euo pipefail

FLUTTER_HOME="${FLUTTER_HOME:-$HOME/.flutter-sdk}"
export PATH="${FLUTTER_HOME}/bin:$HOME/.cargo/bin:$PATH"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

log()  { printf '\033[1;32m[release]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[release]\033[0m %s\n' "$*"; }
err()  { printf '\033[1;31m[release]\033[0m %s\n' "$*" >&2; }

# Auto-upgrades the repo-managed SDK at ~/.flutter-sdk to CI's pinned Flutter.
# shellcheck source=flutter-ensure-version.sh
source "$SCRIPT_DIR/flutter-ensure-version.sh"

# ── parse args ───────────────────────────────────────────────────────────────

TARGET="${1:-}"
case "$TARGET" in
  android|ios) ;;
  *)
    sed -n '/^# Usage:/,/^$/p' "$0" >&2
    exit 1
    ;;
esac

if [[ "$TARGET" == "ios" && "$(uname -s)" != "Darwin" ]]; then
  err "iOS builds require macOS. Use ./scripts/release.sh android on this host."
  exit 1
fi

# ── tool checks ──────────────────────────────────────────────────────────────

if ! command -v flutter &>/dev/null; then
  err "Flutter not found. Run ./scripts/setup.sh first."
  exit 1
fi

# Follow CI's Flutter pin: upgrade ~/.flutter-sdk in place when it is stale, so
# a store build never goes out on an SDK no CI job has tested. A Flutter
# installed elsewhere is left alone. (LB_FLUTTER_AUTO_UPGRADE=0 skips.)
flutter_ensure_ci_version

cd "$PROJECT_DIR"

# ── files the stamp cannot see ───────────────────────────────────────────────
#
# pubspec.yaml bundles device-specs/devices/, device-specs/examples/ and
# assets/radio/ as DIRECTORIES, so whatever sits in them ships, tracked or
# not, while `git describe --dirty` only reports tracked changes.
# examples/index-temp.json is this repo's own generated output
# (scripts/regen-spec-index.sh writes it on every run-*.sh launch, and the
# app prefers it over index.json): drop it so
# the release reads upstream's committed index.json, which CI's
# `update-specs.sh --check` proves names every vendored spec. The next launch
# rebuilds it. Finder's .DS_Store goes the same way: it is ignored too, so
# the guard below would refuse it, and browsing the spec folder on the Mac
# (the only host that builds for iOS) writes one there. It is the one file a
# Mac leaves behind that says nothing about the catalogue, and Finder
# recreates it. The three paths are enough: none of them nests, and a
# Flutter directory asset is not recursive. A new directory asset in
# pubspec.yaml must be added here, or a stray file in it ships unseen.
# Anything else left there is data no commit describes, so there is no
# override: remove it, or commit it (upstream, for the spec directories).
#
# Only the directory assets are checked, not all of vendor/protocol-specs:
# update-specs.sh runs upstream's generate_index.py in place, and the ignored
# __pycache__/ that leaves under its scripts/ ships nothing.
rm -f vendor/protocol-specs/device-specs/examples/index-temp.json \
  vendor/protocol-specs/device-specs/devices/.DS_Store \
  vendor/protocol-specs/device-specs/examples/.DS_Store \
  assets/radio/.DS_Store
# git's exit is checked on its own line: inside the pipeline below, `|| true`
# would turn a failing git status into an empty (clean-looking) answer.
STRAY_STATUS="$(git status --porcelain --ignored=matching --untracked-files=all \
  -- vendor/protocol-specs/device-specs/devices \
     vendor/protocol-specs/device-specs/examples \
     assets/radio)"
STRAY="$(printf '%s\n' "$STRAY_STATUS" | grep '^[?!]' || true)"
if [[ -n "$STRAY" ]]; then
  err "Untracked or ignored files in a bundled asset directory would ship in"
  err "the store build, and the build stamp cannot record them:"
  printf '%s\n' "$STRAY" | sed 's/^/  /' >&2
  err "Remove or commit them (spec files upstream) before building a release."
  exit 1
fi

# ── one build, one commit ────────────────────────────────────────────────────

# A tree with uncommitted changes stamps `-dirty`, which names no commit a bug
# report could be reproduced from; an untracked source file does not even do
# that. docs/RELEASE.md builds from a clean checkout of the tag.
# --untracked-files stated, so a user's status.showUntrackedFiles=no cannot
# hide an untracked source file from this check.
DIRTY="$(git status --porcelain --untracked-files=normal)"
if [[ -n "$DIRTY" ]]; then
  if [[ "${LB_RELEASE_DIRTY:-0}" == "1" ]]; then
    warn "LB_RELEASE_DIRTY=1: building with uncommitted changes. Tracked edits"
    warn "stamp -dirty; untracked files leave no trace in the build at all."
  else
    err "The tree has uncommitted changes, so no commit describes this build:"
    printf '%s\n' "$DIRTY" | sed 's/^/  /' >&2
    err "Commit or stash them, or set LB_RELEASE_DIRTY=1 for a throwaway build."
    exit 1
  fi
fi

VERSION="$(sed -n 's/^version:[[:space:]]*\([^+[:space:]]*\).*/\1/p' pubspec.yaml)"
if TAG="$(git describe --tags --exact-match 2>/dev/null)"; then
  # A tag that disagrees with pubspec.yaml would put one version in the store
  # listing and another in every bug report. No override: fix the tag.
  if [[ "$TAG" != "v$VERSION" ]]; then
    err "HEAD is tagged $TAG but pubspec.yaml says $VERSION."
    exit 1
  fi
elif [[ "${LB_RELEASE_UNTAGGED:-0}" == "1" ]]; then
  warn "LB_RELEASE_UNTAGGED=1: building an untagged HEAD; the stamp names a"
  warn "commit (vX.Y.Z-N-g<sha>, or a bare SHA before the first tag), not a"
  warn "release."
else
  # Without a tag, `git describe --always` falls back to a bare SHA, and the
  # version check above never runs.
  err "HEAD carries no tag, so the stamp would name a commit (vX.Y.Z-N-g<sha>,"
  err "or a bare SHA before the first tag) rather than a release. Tag it first"
  err "(git tag -a v$VERSION, per docs/RELEASE.md), or set LB_RELEASE_UNTAGGED=1"
  err "for a throwaway build."
  exit 1
fi

STAMP="$(git describe --tags --always --dirty)"
log "Build stamp: $STAMP (version $VERSION)"

# ── build ────────────────────────────────────────────────────────────────────

case "$TARGET" in
  android)
    # Minutes since the epoch: rises with every build, and stays far below
    # Play's versionCode ceiling of 2,100,000,000.
    BUILD_NUMBER="$(($(date -u +%s) / 60))"
    log "flutter build appbundle --release --build-number=$BUILD_NUMBER"
    flutter build appbundle --release \
      --build-number="$BUILD_NUMBER" \
      --dart-define=LIBERATED_BREAD_BUILD="$STAMP"
    ;;
  ios)
    # YYYYMMDDHHMM in UTC. Local time would repeat an hour when clocks fall
    # back (or differ on a Mac in another zone) and hand App Store Connect a
    # CFBundleVersion no higher than the last upload, which it refuses. UTC is
    # ahead of the US zones, so this stays above the local-time timestamps
    # docs/APP_STORE_SUBMISSION.md once had people type by hand.
    BUILD_NUMBER="$(date -u +%Y%m%d%H%M)"
    log "flutter build ipa --release --build-number=$BUILD_NUMBER"
    flutter build ipa --release \
      --build-number="$BUILD_NUMBER" \
      --dart-define=LIBERATED_BREAD_BUILD="$STAMP" \
      --export-options-plist=ios/ExportOptions-appstore.plist
    ;;
esac
