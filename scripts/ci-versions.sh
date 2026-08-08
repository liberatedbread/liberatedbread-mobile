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
#
# HOW THIS READS THE WORKFLOW, and why it is boring on purpose.
#
# Exactly one thing is parsed: the top-level `env:` mapping of ci.yml. Every
# pinned version is declared there and every step interpolates it, so this
# script never has to guess which of several occurrences of a number is the
# real one.
#
# It used to guess. The previous version scraped values out of step bodies with
# file-wide greps: the HIGHEST `platforms;android-NN` anywhere in the file, the
# FIRST `targets:` line containing "-android", packages recovered from
# `apt-get install` and its backslash continuations, `target:`/`arch:`/
# `profile:` found by scanning forward from a marker regex. Each of those could
# be tripped by a comment, and each of them was: mentioning a version in prose
# ("CI installs platforms;android-34") changed what dev machines installed,
# because prose and configuration were indistinguishable to a grep. That is a
# silent, wrong result — the worst failure mode for a provisioning script.
#
# The one value that cannot come from `env:` is the emulator's API level:
# GitHub does not expose the `env` context to `strategy:`, so ci.yml declares
# ANDROID_EMULATOR_API in env AND repeats the literal in the matrix. This
# script trusts env; test/platform/deployment_targets_test.dart is what keeps
# the two from drifting.
#
# So: to add a value, add a key to ci.yml's env block and read it here with
# _ci_env. Do not add a new place to look.
#
# Variables defined:
#   CI_FLUTTER_VERSION        Flutter SDK pin
#   CI_NDK_VERSION            Android NDK cargokit builds against
#   CI_ANDROID_API            Android platform API level the app compiles against
#   CI_BUILD_TOOLS_VERSION    Android build-tools
#   CI_CMAKE_VERSION          Android SDK CMake (Flutter's Gradle plugin needs it)
#   CI_JAVA_VERSION           JDK major version Gradle runs on
#   CI_FRB_VERSION            flutter_rust_bridge_codegen
#   CI_RUST_ANDROID_TARGETS   space-separated rustup targets for Android
#   CI_RUST_IOS_TARGETS       space-separated rustup targets for iOS
#   CI_EMULATOR_API           API level of the AVD CI boots
#   CI_EMULATOR_TARGET        system image target (e.g. aosp_atd)
#   CI_EMULATOR_ARCH          system image arch (e.g. x86_64)
#   CI_EMULATOR_PROFILE       device profile (e.g. pixel_6)
#   CI_EMULATOR_SYSTEM_IMAGE  full sdkmanager package built from the three above
#   CI_LINUX_DESKTOP_PACKAGES space-separated apt packages for `flutter build linux`

# Resolve the workflow relative to this script so sourcing works from anywhere.
_ci_versions_self="${BASH_SOURCE[0]:-$0}"
CI_WORKFLOW="${CI_WORKFLOW:-$(cd "$(dirname "$_ci_versions_self")/.." && pwd)/.github/workflows/ci.yml}"

_ci_warn() { printf '[ci-versions] %s\n' "$*" >&2; }

# Value of KEY from ci.yml's TOP-LEVEL `env:` mapping, or empty.
#
# Scoped deliberately and tightly:
#   * Only the block introduced by a column-0 `env:` is read. A job-level
#     `env:` is indented, so it is never mistaken for this one.
#   * The block ends at the first non-blank, non-comment line that is not
#     indented — in practice `jobs:`. Nothing after it can contribute a value.
#   * Only `  KEY: value` at exactly one indent level counts, so a nested
#     mapping cannot smuggle a key in.
#   * Comments are stripped, and a `#` inside a quoted value is preserved
#     (none today, but a password-ish pin would otherwise be truncated).
#   * Surrounding single or double quotes are removed.
#
# Grepping the whole file for a version is what this replaces; see the header.
_ci_env() {
  local key="$1"
  [ -r "$CI_WORKFLOW" ] || return 1
  awk -v k="$key" '
    # Enter the top-level env: block (no leading whitespace).
    !inblock && /^env:[[:space:]]*$/ { inblock = 1; next }
    !inblock { next }
    # Blank lines and whole-line comments do not end the block.
    /^[[:space:]]*$/ { next }
    /^[[:space:]]*#/ { next }
    # Any other column-0 line ends it (jobs:, on:, ...).
    /^[^[:space:]]/ { exit }
    # Exactly one indent level, and the key we want.
    $0 ~ "^  " k ":[[:space:]]*" {
      line = $0
      sub("^  " k ":[[:space:]]*", "", line)
      # Strip a trailing comment only when it is outside quotes.
      out = ""; inq = ""
      n = length(line)
      for (i = 1; i <= n; i++) {
        c = substr(line, i, 1)
        if (inq == "") {
          if (c == "\"" || c == "'"'"'") { inq = c; out = out c; continue }
          if (c == "#") break
          out = out c
        } else {
          out = out c
          if (c == inq) inq = ""
        }
      }
      sub(/[[:space:]]+$/, "", out)
      # Remove one layer of matching surrounding quotes.
      if (out ~ /^".*"$/ || out ~ /^'"'"'.*'"'"'$/) {
        out = substr(out, 2, length(out) - 2)
      }
      if (length(out)) { print out; exit }
    }
  ' "$CI_WORKFLOW"
}

# A comma-separated env value as a space-separated one (rustup target lists are
# declared in the comma form dtolnay/rust-toolchain's `targets:` input wants).
_ci_env_list() {
  local raw
  raw="$(_ci_env "$1")" || return 1
  printf '%s' "$raw" | tr ',' ' '
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

  _ci_set CI_FLUTTER_VERSION '3.44.8' "$(_ci_env FLUTTER_VERSION || true)"
  _ci_set CI_NDK_VERSION '28.2.13676358' "$(_ci_env FLUTTER_NDK_VERSION || true)"
  _ci_set CI_ANDROID_API '36' "$(_ci_env ANDROID_API || true)"
  _ci_set CI_BUILD_TOOLS_VERSION '34.0.0' "$(_ci_env ANDROID_BUILD_TOOLS || true)"
  _ci_set CI_CMAKE_VERSION '3.22.1' "$(_ci_env ANDROID_CMAKE || true)"
  _ci_set CI_JAVA_VERSION '17' "$(_ci_env JAVA_VERSION || true)"
  _ci_set CI_FRB_VERSION '2.9.0' "$(_ci_env FRB_VERSION || true)"

  _ci_set CI_RUST_ANDROID_TARGETS \
    'aarch64-linux-android armv7-linux-androideabi x86_64-linux-android i686-linux-android' \
    "$(_ci_env_list RUST_ANDROID_TARGETS || true)"
  _ci_set CI_RUST_IOS_TARGETS \
    'aarch64-apple-ios aarch64-apple-ios-sim x86_64-apple-ios' \
    "$(_ci_env_list RUST_IOS_TARGETS || true)"

  # The emulator is a separate axis from the compile SDK — nothing requires the
  # AVD to run the API the app compiles against — so it has its own keys rather
  # than defaulting to CI_ANDROID_API.
  _ci_set CI_EMULATOR_API '34' "$(_ci_env ANDROID_EMULATOR_API || true)"
  _ci_set CI_EMULATOR_TARGET 'aosp_atd' "$(_ci_env ANDROID_EMULATOR_TARGET || true)"
  _ci_set CI_EMULATOR_ARCH 'x86_64' "$(_ci_env ANDROID_EMULATOR_ARCH || true)"
  _ci_set CI_EMULATOR_PROFILE 'pixel_6' "$(_ci_env ANDROID_EMULATOR_PROFILE || true)"
  # shellcheck disable=SC2034  # read by setup.sh / the session hook, which source this file
  CI_EMULATOR_SYSTEM_IMAGE="system-images;android-${CI_EMULATOR_API};${CI_EMULATOR_TARGET};${CI_EMULATOR_ARCH}"

  _ci_set CI_LINUX_DESKTOP_PACKAGES \
    'clang cmake libgtk-3-dev libjsoncpp-dev liblzma-dev libsecret-1-dev ninja-build pkg-config xvfb' \
    "$(_ci_env LINUX_DESKTOP_PACKAGES || true)"
}

ci_versions_print() {
  ci_versions_load
  local v
  for v in CI_FLUTTER_VERSION CI_NDK_VERSION CI_ANDROID_API CI_BUILD_TOOLS_VERSION \
           CI_CMAKE_VERSION CI_JAVA_VERSION CI_FRB_VERSION \
           CI_RUST_ANDROID_TARGETS CI_RUST_IOS_TARGETS \
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
