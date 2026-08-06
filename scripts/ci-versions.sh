#!/usr/bin/env bash
# Copyright 2026 Pigs Can Fly Labs LLC
# SPDX-License-Identifier: Apache-2.0
#
# Single source of truth for the toolchain a dev environment needs: the values
# are READ OUT OF .github/workflows/ci.yml rather than pinned again here, so
# local machines, Claude Code sessions (.claude/hooks/session-start.sh) and
# scripts/setup.sh follow CI automatically when CI moves.
#
# Usage:
#   source scripts/ci-versions.sh      # defines CI_* variables (see below)
#   ./scripts/ci-versions.sh           # prints them, one KEY=value per line
#
# Every value has a fallback, so a parse miss degrades to "slightly stale pin"
# rather than "setup explodes"; a miss is reported on stderr so it gets fixed.
# If you change how CI declares one of these (rename the env key, swap the
# emulator action, move the apt install), update the matching parser below.
#
# Variables defined:
#   CI_FLUTTER_VERSION        Flutter SDK pin
#   CI_NDK_VERSION            Android NDK cargokit builds against
#   CI_ANDROID_API            Android platform API level
#   CI_BUILD_TOOLS_VERSION    Android build-tools
#   CI_JAVA_VERSION           JDK major version Gradle runs on
#   CI_FRB_VERSION            flutter_rust_bridge_codegen
#   CI_RUST_ANDROID_TARGETS   space-separated rustup targets for Android
#   CI_RUST_IOS_TARGETS       space-separated rustup targets for iOS
#   CI_EMULATOR_API           API level of the AVD CI boots
#   CI_EMULATOR_TARGET        system image target (e.g. google_apis)
#   CI_EMULATOR_ARCH          system image arch (e.g. x86_64)
#   CI_EMULATOR_PROFILE       device profile (e.g. pixel_6)
#   CI_EMULATOR_SYSTEM_IMAGE  full sdkmanager package built from the three above
#   CI_LINUX_DESKTOP_PACKAGES space-separated apt packages for `flutter build linux`

# Resolve the workflow relative to this script so sourcing works from anywhere.
_ci_versions_self="${BASH_SOURCE[0]:-$0}"
CI_WORKFLOW="${CI_WORKFLOW:-$(cd "$(dirname "$_ci_versions_self")/.." && pwd)/.github/workflows/ci.yml}"

_ci_warn() { printf '[ci-versions] %s\n' "$*" >&2; }

# First `key: value` at any indent, with surrounding quotes, trailing comment
# and trailing whitespace stripped. Optional third arg restricts the search to
# lines at or after the first line matching a marker regex.
_ci_scalar() {
  local key="$1" marker="${2:-}"
  [ -r "$CI_WORKFLOW" ] || return 1
  awk -v k="$key" -v marker="$marker" -v q="'\"" '
    marker != "" && !armed { if ($0 ~ marker) armed = 1; next }
    $0 ~ "^[[:space:]]*" k ":[[:space:]]*" {
      sub("^[[:space:]]*" k ":[[:space:]]*", "")
      sub(/[[:space:]]*#.*$/, "")
      sub(/[[:space:]]+$/, "")
      gsub("^[" q "]|[" q "]$", "")
      if (length($0)) { print; exit }
    }
  ' "$CI_WORKFLOW"
}

# Highest number matching a pattern of the form <prefix><number>, e.g.
# `platforms;android-34` -> 34. Highest rather than first so a matrix that
# gains a newer API level pulls the newer one.
_ci_max_number() {
  local pattern="$1"
  [ -r "$CI_WORKFLOW" ] || return 1
  grep -oE "$pattern" "$CI_WORKFLOW" \
    | grep -oE '[0-9]+([.][0-9]+)*$' \
    | sort -V \
    | tail -1
}

# Packages from every `apt-get install` in the workflow, including continuation
# lines. Flags (-y, --no-install-recommends) and the command words themselves
# are dropped; the result is deduplicated. Comments are stripped first — both
# YAML comments and shell ones inside `run:` blocks use `#`, and prose about
# apt-get install (there is some, above the `env:` block) must not be mistaken
# for packages.
_ci_apt_packages() {
  [ -r "$CI_WORKFLOW" ] || return 1
  awk '
    { sub(/[[:space:]]*#.*$/, "") }
    /^[[:space:]]*$/ { next }
    /apt-get[[:space:]]+install/ { collecting = 1 }
    collecting {
      line = $0
      cont = (line ~ /\\[[:space:]]*$/)
      sub(/\\[[:space:]]*$/, "", line)
      n = split(line, w, /[[:space:]]+/)
      for (i = 1; i <= n; i++) {
        t = w[i]
        if (t == "" || t == "sudo" || t == "apt-get" || t == "install") continue
        if (t ~ /^-/) continue
        print t
      }
      if (!cont) collecting = 0
    }
  ' "$CI_WORKFLOW" | sort -u | tr '\n' ' ' | sed 's/ $//'
}

# Comma-separated `targets:` list for a rustup toolchain step, picked by the
# platform suffix that appears in it (android / apple-ios).
_ci_rust_targets() {
  local suffix="$1"
  [ -r "$CI_WORKFLOW" ] || return 1
  grep -E '^[[:space:]]*targets:' "$CI_WORKFLOW" \
    | grep -F -- "$suffix" \
    | head -1 \
    | sed -E 's/^[[:space:]]*targets:[[:space:]]*//; s/[[:space:]]*$//' \
    | tr ',' ' '
}

# Assign $1=$3 if $3 is non-empty, else fall back to $2 and say so.
_ci_set() {
  local var="$1" fallback="$2" parsed="$3"
  if [ -n "$parsed" ]; then
    printf -v "$var" '%s' "$parsed"
  else
    printf -v "$var" '%s' "$fallback"
    _ci_warn "could not read $var from ${CI_WORKFLOW}; using fallback '$fallback'"
  fi
}

ci_versions_load() {
  if [ ! -r "$CI_WORKFLOW" ]; then
    _ci_warn "workflow not readable at ${CI_WORKFLOW}; using fallbacks for everything"
  fi

  _ci_set CI_FLUTTER_VERSION '3.44.8' "$(_ci_scalar FLUTTER_VERSION || true)"
  _ci_set CI_NDK_VERSION '28.2.13676358' "$(_ci_scalar FLUTTER_NDK_VERSION || true)"
  _ci_set CI_ANDROID_API '34' "$(_ci_max_number 'platforms;android-[0-9]+' || true)"
  _ci_set CI_BUILD_TOOLS_VERSION '34.0.0' "$(_ci_max_number 'build-tools;[0-9.]+' || true)"
  _ci_set CI_JAVA_VERSION '17' "$(_ci_scalar java-version || true)"
  _ci_set CI_FRB_VERSION '2.9.0' \
    "$(grep -oE 'flutter_rust_bridge_codegen@[0-9]+\.[0-9]+\.[0-9]+' "$CI_WORKFLOW" 2>/dev/null \
        | head -1 | cut -d@ -f2 || true)"

  _ci_set CI_RUST_ANDROID_TARGETS \
    'aarch64-linux-android armv7-linux-androideabi x86_64-linux-android i686-linux-android' \
    "$(_ci_rust_targets '-android' || true)"
  _ci_set CI_RUST_IOS_TARGETS \
    'aarch64-apple-ios aarch64-apple-ios-sim x86_64-apple-ios' \
    "$(_ci_rust_targets 'apple-ios' || true)"

  # The emulator job's matrix API level can differ from the build platform, so
  # it is read separately; the rest come from the emulator-runner step's own
  # `with:` block.
  _ci_set CI_EMULATOR_API "$CI_ANDROID_API" \
    "$(_ci_max_number 'api-level:[[:space:]]*\[[0-9, ]*[0-9]+' || true)"
  _ci_set CI_EMULATOR_TARGET 'google_apis' \
    "$(_ci_scalar target 'android-emulator-runner' || true)"
  _ci_set CI_EMULATOR_ARCH 'x86_64' \
    "$(_ci_scalar arch 'android-emulator-runner' || true)"
  _ci_set CI_EMULATOR_PROFILE 'pixel_6' \
    "$(_ci_scalar profile 'android-emulator-runner' || true)"
  CI_EMULATOR_SYSTEM_IMAGE="system-images;android-${CI_EMULATOR_API};${CI_EMULATOR_TARGET};${CI_EMULATOR_ARCH}"

  _ci_set CI_LINUX_DESKTOP_PACKAGES \
    'clang cmake libgtk-3-dev libjsoncpp-dev liblzma-dev libsecret-1-dev ninja-build pkg-config xvfb' \
    "$(_ci_apt_packages || true)"
}

ci_versions_print() {
  ci_versions_load
  local v
  for v in CI_FLUTTER_VERSION CI_NDK_VERSION CI_ANDROID_API CI_BUILD_TOOLS_VERSION \
           CI_JAVA_VERSION CI_FRB_VERSION CI_RUST_ANDROID_TARGETS CI_RUST_IOS_TARGETS \
           CI_EMULATOR_API CI_EMULATOR_TARGET CI_EMULATOR_ARCH CI_EMULATOR_PROFILE \
           CI_EMULATOR_SYSTEM_IMAGE CI_LINUX_DESKTOP_PACKAGES; do
    printf '%s=%s\n' "$v" "${!v}"
  done
}

# Sourced: define the variables. Executed: print them.
if [ "${BASH_SOURCE[0]:-}" = "${0}" ]; then
  ci_versions_print
else
  ci_versions_load
fi
