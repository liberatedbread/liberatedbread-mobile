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
# Usage:
#   ./scripts/release.sh android   # Play app bundle -> build/app/outputs/bundle/release/
#   ./scripts/release.sh ios       # App Store IPA   -> build/ios/ipa/ (macOS)

set -euo pipefail

cd "$(dirname "$0")/.."

stamp="$(git describe --tags --always --dirty)"
version="$(sed -n 's/^version:[[:space:]]*\([^+[:space:]]*\).*/\1/p' pubspec.yaml)"

# A tag that disagrees with pubspec.yaml would put one version in the store
# listing and another in every bug report.
if tag="$(git describe --tags --exact-match 2>/dev/null)" && [ "$tag" != "v$version" ]; then
  echo "error: HEAD is tagged $tag but pubspec.yaml says $version" >&2
  exit 1
fi

case "${1:-}" in
  android)
    # Minutes since the epoch: rises with every build, and stays far below
    # Play's versionCode ceiling of 2,100,000,000.
    flutter build appbundle --release \
      --build-number="$(($(date -u +%s) / 60))" \
      --dart-define=LIBERATED_BREAD_BUILD="$stamp"
    ;;
  ios)
    # The timestamp docs/APP_STORE_SUBMISSION.md had people type by hand, so
    # anything already uploaded that way stays below builds from here.
    flutter build ipa --release \
      --build-number="$(date +%Y%m%d%H%M)" \
      --dart-define=LIBERATED_BREAD_BUILD="$stamp" \
      --export-options-plist=ios/ExportOptions-appstore.plist
    ;;
  *)
    sed -n '/^# Usage:/,/^$/p' "$0" >&2
    exit 1
    ;;
esac
