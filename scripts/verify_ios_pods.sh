#!/usr/bin/env bash
# Copyright 2026 Pigs Can Fly Labs LLC
# SPDX-License-Identifier: Apache-2.0
#
# Liberated Bread Mobile — assert that the pods whose absence is silently
# fatal at runtime are locked, and (after a build) installed.
#
# WHAT GUARDS WHAT
#
# A SKIPPED or out-of-sync pod install is not this script's job: the Runner
# target's first build phase, "[CP] Check Pods Manifest.lock", diffs
# Pods/Manifest.lock against Podfile.lock and fails `flutter build ios` with
# "The sandbox is not in sync with the Podfile.lock". A pod install that ran
# and changed the lockfile is caught by ci.yml's drift step. This header used
# to claim Podfile.lock proved resolution happened; ios/Podfile.lock is
# committed, so it exists after checkout whatever the build did.
#
# What this script adds is the pod LIST: the three runtime-critical federated
# pods must be in the committed lockfile, so dropping or renaming a plugin
# fails here rather than as a MissingPluginException on a phone. When
# Pods/Manifest.lock exists (it is gitignored and written only by a real
# `pod install`) the same pods are asserted there too, so the check also reads
# what was actually installed.
#
# The pod names are the federated iOS implementations from
# .flutter-plugins-dependencies, NOT the pub package names — flutter_blue_plus
# ships its iOS code as flutter_blue_plus_darwin, and asserting the pub name
# would assert nothing.
#
# integration_test is deliberately not on the list: it is a dev-dependency
# plugin, newer Flutter versions exclude those from release pod installs, and
# the simulator test step is a far better check for it anyway.
#
# Usage:
#   ./scripts/verify_ios_pods.sh            # against ios/
#   ./scripts/verify_ios_pods.sh macos      # against macos/
#
# Runs on a Mac, normally after `flutter build ios`. It reads committed and
# generated files only — no Xcode, no simulator — so it is also the cheapest of the iOS
# checks to run while iterating.

set -uo pipefail

cd "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)" || exit 1

PLATFORM_DIR="${1:-ios}"
LOCKFILE="$PLATFORM_DIR/Podfile.lock"
MANIFEST="$PLATFORM_DIR/Pods/Manifest.lock"

# The pods whose absence is silently fatal at runtime: each provides a platform
# channel the app calls unconditionally, and a missing one is a
# MissingPluginException on a code path with no fallback.
REQUIRED_PODS=(
  liberated_bread_core
  flutter_blue_plus_darwin
  permission_handler_apple
)

log() { printf '\033[1;32m[verify-pods]\033[0m %s\n' "$*"; }

# ios/Podfile.lock is committed; macos/Podfile.lock is not, so there a
# missing file does mean CocoaPods never resolved for that platform.
if [ ! -f "$LOCKFILE" ]; then
  echo "::error file=$PLATFORM_DIR/Podfile::$LOCKFILE does not exist — run the build (or pod install) for $PLATFORM_DIR/ first; no plugin pod can be linked without it." >&2
  exit 1
fi

lockfiles=("$LOCKFILE")
if [ -f "$MANIFEST" ]; then
  lockfiles+=("$MANIFEST")
else
  log "$MANIFEST absent (no pod install here yet): checking the committed lockfile only."
fi

missing=0
for file in "${lockfiles[@]}"; do
  for pod in "${REQUIRED_PODS[@]}"; do
    # `^ +- <pod> (` matches the PODS: section's entries, not the
    # DEPENDENCIES/SPEC CHECKSUMS ones, so a pod named only as a dependency of
    # something that failed to install cannot satisfy this.
    if grep -qE "^ +- ${pod} \(" "$file"; then
      log "  ok  pod ${pod} in ${file}"
    else
      echo "::error file=$PLATFORM_DIR/Podfile::Pod '${pod}' is missing from $file — its platform channels would be unavailable at runtime." >&2
      missing=1
    fi
  done
done

# Informational, not asserted. This is the exact knob behind the iOS BLE
# outage: permission_handler_apple compiles each permission strategy out unless
# the Podfile's post_install hook defines the matching PERMISSION_* macro, and
# PermissionHandlerEnums.h defaults them all to 0.
# lib/services/real_ble_service.dart deliberately no longer depends on
# PERMISSION_BLUETOOTH (CoreBluetooth raises its own prompt), so asserting a
# value here would encode a requirement the code does not have. Printing the
# resolved macros instead makes any future flip visible in the log, next to the
# code that would need it.
xcconfig="$PLATFORM_DIR/Pods/Target Support Files/permission_handler_apple/permission_handler_apple.debug.xcconfig"
if [ -f "$xcconfig" ]; then
  log "permission_handler_apple compile-time macros:"
  grep -E 'GCC_PREPROCESSOR_DEFINITIONS' "$xcconfig" | sed 's/^/  /' || true
fi

if [ "$missing" -eq 0 ]; then
  log "All CocoaPods checks passed for $PLATFORM_DIR/"
fi
exit "$missing"
