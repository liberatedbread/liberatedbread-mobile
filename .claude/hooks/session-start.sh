#!/usr/bin/env bash
# Copyright 2026 Pigs Can Fly Labs LLC
# SPDX-License-Identifier: Apache-2.0
#
# SessionStart hook for Claude Code on the web. Provisions the toolchain the
# repo's own checks need, in three tiers:
#
#   1. Host  (always)  Flutter SDK, Dart deps, host Rust library — everything
#                      scripts/test.sh needs to mirror CI's flutter + rust jobs.
#   2. Linux desktop   The GTK/CMake/ninja/xvfb stack CI's linux-desktop job
#      (auto)          installs, so `flutter build linux` and the headless
#                      integration tests can run here too.
#   3. Android (auto)  SDK platform, build-tools, NDK, emulator + an AVD
#                      matching CI's android-integration job, so
#                      `flutter build apk` and `flutter test integration_test`
#                      work against a local emulator.
#
# Tier 2 and 3 are skipped when they cannot work (no apt, no root, no KVM, not
# enough disk) rather than failing the session. Force or suppress them with:
#
#   LB_SETUP_LINUX_DESKTOP=1|0   (default: auto — on wherever apt is usable)
#   LB_SETUP_ANDROID=1|0         (default: auto — on when KVM and disk allow)
#
# Versions are NOT pinned here: scripts/ci-versions.sh reads them out of
# .github/workflows/ci.yml, so this environment follows CI when CI moves.
# Idempotent and safe to re-run.
set -euo pipefail

# Only provision in the remote (web) environment; local machines use setup.sh.
if [ "${CLAUDE_CODE_REMOTE:-}" != "true" ]; then
  exit 0
fi

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"
FLUTTER_HOME="${FLUTTER_HOME:-$HOME/.flutter-sdk}"
ANDROID_SDK_HOME="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-$HOME/Android/Sdk}}"
AVD_NAME="${AVD_NAME:-liberated_bread_test}"

# The one version CI cannot supply: CI installs the Android command-line tools
# through android-actions/setup-android, which resolves "latest" itself and
# never names a build number. Google only serves them from a build-numbered
# URL, so it is pinned here. Bump when it ages out (the download 404s).
ANDROID_CMDLINE_TOOLS_BUILD="${ANDROID_CMDLINE_TOOLS_BUILD:-11076708}"

# Tier 3 needs the NDK (~3.5 GB), a system image (~1.6 GB) and the platform
# and build-tools on top; below this much free space it would either fail
# mid-download or leave no room for a build.
ANDROID_MIN_FREE_GB="${ANDROID_MIN_FREE_GB:-14}"

# Toolchain versions, read from .github/workflows/ci.yml.
# shellcheck source=../../scripts/ci-versions.sh
source "$PROJECT_DIR/scripts/ci-versions.sh"

log()  { printf '[session-start] %s\n' "$*"; }
warn() { printf '[session-start] %s\n' "$*" >&2; }

# Keep verbose build output out of the session context; surface it only on
# failure. The EXIT trap prints that tail first, then removes the log and any
# half-finished SDK download, so a failed run leaves nothing behind — the
# Flutter tarball alone is a few hundred MB.
WORK_LOG="$(mktemp)"
DOWNLOAD_TMP=""

on_exit() {
  rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "[session-start] FAILED (exit $rc). Last output:"
    tail -n 40 "$WORK_LOG"
  fi
  rm -f "$WORK_LOG"
  if [ -n "$DOWNLOAD_TMP" ]; then
    rm -rf "$DOWNLOAD_TMP"
  fi
  exit "$rc"
}
trap on_exit EXIT

# ── helpers ──────────────────────────────────────────────────────────────────

have() { command -v "$1" >/dev/null 2>&1; }

# Prefix for commands needing root. Empty when already root; empty and
# unusable-marked when there is no passwordless sudo, which the optional tiers
# check via can_root before doing anything.
SUDO=""
can_root() {
  if [ "$(id -u)" -eq 0 ]; then
    SUDO=""
    return 0
  fi
  if have sudo && sudo -n true 2>/dev/null; then
    SUDO="sudo -n"
    return 0
  fi
  return 1
}

free_gb() {
  df -Pk "${1:-$HOME}" 2>/dev/null | awk 'NR==2 { print int($4 / 1048576) }'
}

# True when every named package is already installed, so a re-run of this hook
# skips apt entirely instead of paying for an update+install round trip.
apt_packages_present() {
  local pkg
  for pkg in "$@"; do
    if ! dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q '^install ok installed$'; then
      return 1
    fi
  done
  return 0
}

apt_install() {
  [ "$#" -gt 0 ] || return 0
  if apt_packages_present "$@"; then
    return 0
  fi
  # shellcheck disable=SC2086  # $SUDO is a deliberately word-split prefix
  DEBIAN_FRONTEND=noninteractive $SUDO apt-get update >>"$WORK_LOG" 2>&1
  # shellcheck disable=SC2086
  DEBIAN_FRONTEND=noninteractive $SUDO apt-get install -y --no-install-recommends \
    "$@" >>"$WORK_LOG" 2>&1
}

# ── 1. host toolchain (always) ───────────────────────────────────────────────

if [ ! -x "$FLUTTER_HOME/bin/flutter" ]; then
  log "Installing Flutter ${CI_FLUTTER_VERSION} (from ci.yml)..."
  archive="flutter_linux_${CI_FLUTTER_VERSION}-stable.tar.xz"
  url="https://storage.googleapis.com/flutter_infra_release/releases/stable/linux/${archive}"
  # Tracked in DOWNLOAD_TMP so the EXIT trap reclaims it if curl or tar fails
  # part-way; cleared on success once it has been moved into place.
  DOWNLOAD_TMP="$(mktemp -d)"
  curl -fSL -o "$DOWNLOAD_TMP/$archive" "$url" >>"$WORK_LOG" 2>&1
  mkdir -p "$(dirname "$FLUTTER_HOME")"
  tar xf "$DOWNLOAD_TMP/$archive" -C "$DOWNLOAD_TMP" >>"$WORK_LOG" 2>&1
  rm -rf "$FLUTTER_HOME"
  mv "$DOWNLOAD_TMP/flutter" "$FLUTTER_HOME"
  rm -rf "$DOWNLOAD_TMP"
  DOWNLOAD_TMP=""
else
  log "Flutter already installed at $FLUTTER_HOME"
fi

export PATH="$FLUTTER_HOME/bin:$HOME/.cargo/bin:$PATH"

# Flutter shells out to git inside its SDK; mark it safe when ownership differs
# (containers often extract the SDK as a different user).
if ! git config --global --get-all safe.directory 2>/dev/null | grep -Fxq "$FLUTTER_HOME"; then
  git config --global --add safe.directory "$FLUTTER_HOME" || true
fi

log "flutter pub get..."
(cd "$PROJECT_DIR" && flutter pub get) >>"$WORK_LOG" 2>&1

# Host Rust library so the FFI-backed flutter tests can load it. Skipped
# gracefully if no Rust toolchain is present (those tests self-skip).
if have cargo; then
  log "cargo build (host Rust library)..."
  (cd "$PROJECT_DIR/rust" && cargo build) >>"$WORK_LOG" 2>&1
else
  log "cargo not found; skipping host Rust build (FFI tests will self-skip)."
fi

# ── 2. Linux desktop toolchain (auto) ────────────────────────────────────────
#
# Same package list CI's linux-desktop job installs, parsed from the workflow:
# clang/cmake/ninja/pkg-config, GTK 3 and friends, plus xvfb for the headless
# integration test run.

setup_linux_desktop() {
  local want="${LB_SETUP_LINUX_DESKTOP:-auto}"
  if [ "$want" = "0" ]; then
    log "Linux desktop toolchain: skipped (LB_SETUP_LINUX_DESKTOP=0)."
    return 0
  fi
  if ! have apt-get; then
    log "Linux desktop toolchain: skipped (no apt-get on this image)."
    return 0
  fi
  if ! can_root; then
    log "Linux desktop toolchain: skipped (no root/passwordless sudo)."
    return 0
  fi

  # shellcheck disable=SC2086  # the package list is intentionally word-split
  if apt_packages_present $CI_LINUX_DESKTOP_PACKAGES; then
    log "Linux desktop toolchain already present."
    return 0
  fi

  log "Installing Linux desktop build deps (from ci.yml): ${CI_LINUX_DESKTOP_PACKAGES}"
  # shellcheck disable=SC2086
  if ! apt_install $CI_LINUX_DESKTOP_PACKAGES; then
    warn "Linux desktop deps failed to install; 'flutter build linux' will not work."
    return 0
  fi
}

# ── 3. Android SDK + emulator (auto) ─────────────────────────────────────────
#
# Mirrors CI's android-build and android-integration jobs: the same platform,
# build-tools and NDK, and an AVD built from the same system image and device
# profile the emulator-runner step uses.

android_should_run() {
  local want="${LB_SETUP_ANDROID:-auto}"
  case "$want" in
    0) log "Android SDK/emulator: skipped (LB_SETUP_ANDROID=0)."; return 1 ;;
    1) return 0 ;;
  esac

  # auto: only worth several GB and several minutes when the emulator can
  # actually be accelerated, and only when there is room for it.
  if [ ! -e /dev/kvm ]; then
    log "Android SDK/emulator: skipped (no /dev/kvm — an unaccelerated x86_64"
    log "  emulator is unusable). Set LB_SETUP_ANDROID=1 to install anyway."
    return 1
  fi
  local avail
  avail="$(free_gb "$HOME")"
  if [ -n "$avail" ] && [ "$avail" -lt "$ANDROID_MIN_FREE_GB" ]; then
    log "Android SDK/emulator: skipped (${avail}GB free, need ${ANDROID_MIN_FREE_GB}GB)."
    return 1
  fi
  return 0
}

install_android_cmdline_tools() {
  local sdkmanager="$ANDROID_SDK_HOME/cmdline-tools/latest/bin/sdkmanager"
  if [ -x "$sdkmanager" ]; then
    return 0
  fi
  log "Installing Android command-line tools..."
  local zip url
  zip="commandlinetools-linux-${ANDROID_CMDLINE_TOOLS_BUILD}_latest.zip"
  url="https://dl.google.com/android/repository/${zip}"
  DOWNLOAD_TMP="$(mktemp -d)"
  curl -fSL -o "$DOWNLOAD_TMP/$zip" "$url" >>"$WORK_LOG" 2>&1
  # The zip contains a bare `cmdline-tools/`; sdkmanager insists on living in
  # cmdline-tools/latest/ or it cannot locate the SDK root.
  unzip -q "$DOWNLOAD_TMP/$zip" -d "$DOWNLOAD_TMP" >>"$WORK_LOG" 2>&1
  mkdir -p "$ANDROID_SDK_HOME/cmdline-tools"
  rm -rf "$ANDROID_SDK_HOME/cmdline-tools/latest"
  mv "$DOWNLOAD_TMP/cmdline-tools" "$ANDROID_SDK_HOME/cmdline-tools/latest"
  rm -rf "$DOWNLOAD_TMP"
  DOWNLOAD_TMP=""
}

setup_android() {
  android_should_run || return 0

  if ! have unzip; then
    if have apt-get && can_root; then
      apt_install unzip || true
    fi
    if ! have unzip; then
      warn "Android SDK: skipped (unzip not available to unpack the tools)."
      return 0
    fi
  fi

  # sdkmanager and Gradle both need a JDK; CI runs on temurin ${CI_JAVA_VERSION}.
  if ! have java; then
    if have apt-get && can_root; then
      log "Installing JDK ${CI_JAVA_VERSION} for sdkmanager/Gradle..."
      apt_install "openjdk-${CI_JAVA_VERSION}-jdk-headless" \
        || apt_install default-jdk-headless \
        || true
    fi
    if ! have java; then
      warn "Android SDK: skipped (no JDK — sdkmanager cannot run)."
      return 0
    fi
  fi

  if ! install_android_cmdline_tools; then
    warn "Android SDK: command-line tools download failed; skipping."
    return 0
  fi

  export ANDROID_HOME="$ANDROID_SDK_HOME"
  export ANDROID_SDK_ROOT="$ANDROID_SDK_HOME"
  local sdkmanager="$ANDROID_SDK_HOME/cmdline-tools/latest/bin/sdkmanager"
  local avdmanager="$ANDROID_SDK_HOME/cmdline-tools/latest/bin/avdmanager"

  yes | "$sdkmanager" --licenses >>"$WORK_LOG" 2>&1 || true

  log "Installing Android SDK packages (API ${CI_ANDROID_API}, build-tools ${CI_BUILD_TOOLS_VERSION}, NDK ${CI_NDK_VERSION}, from ci.yml)..."
  if ! "$sdkmanager" \
        "platform-tools" \
        "platforms;android-${CI_ANDROID_API}" \
        "build-tools;${CI_BUILD_TOOLS_VERSION}" \
        "ndk;${CI_NDK_VERSION}" \
        >>"$WORK_LOG" 2>&1; then
    warn "Some Android SDK packages failed to install; see the log tail above."
    return 0
  fi

  # `flutter build apk` reads both paths from android/local.properties, exactly
  # as CI writes them before its Android jobs.
  {
    echo "flutter.sdk=$FLUTTER_HOME"
    echo "sdk.dir=$ANDROID_SDK_HOME"
  } > "$PROJECT_DIR/android/local.properties"

  # Android cross-compilation targets — cargokit builds the crate for these
  # during `flutter build apk`.
  if have rustup; then
    # shellcheck disable=SC2086  # target list is intentionally word-split
    rustup target add $CI_RUST_ANDROID_TARGETS >>"$WORK_LOG" 2>&1 || true
  fi

  log "Installing emulator + ${CI_EMULATOR_SYSTEM_IMAGE} (from ci.yml)..."
  if ! "$sdkmanager" "emulator" "$CI_EMULATOR_SYSTEM_IMAGE" >>"$WORK_LOG" 2>&1; then
    warn "Emulator/system image install failed; APK builds still work."
    return 0
  fi

  if "$avdmanager" list avd 2>/dev/null | grep -q "Name: ${AVD_NAME}$"; then
    log "AVD ${AVD_NAME} already exists."
  else
    log "Creating AVD ${AVD_NAME} (${CI_EMULATOR_PROFILE}, API ${CI_EMULATOR_API})..."
    # -d is best-effort: profile names come and go between SDK releases, and a
    # generic AVD still boots and runs the integration tests.
    if ! echo "no" | "$avdmanager" create avd \
          -n "$AVD_NAME" \
          -k "$CI_EMULATOR_SYSTEM_IMAGE" \
          -d "$CI_EMULATOR_PROFILE" \
          --force >>"$WORK_LOG" 2>&1; then
      warn "Could not create AVD with device profile ${CI_EMULATOR_PROFILE}; retrying without it."
      echo "no" | "$avdmanager" create avd \
        -n "$AVD_NAME" \
        -k "$CI_EMULATOR_SYSTEM_IMAGE" \
        --force >>"$WORK_LOG" 2>&1 \
        || warn "AVD creation failed; ./scripts/run-android.sh will have no emulator to boot."
    fi
  fi

  ANDROID_READY=true
}

ANDROID_READY=false
setup_linux_desktop || warn "Linux desktop setup hit an error; continuing."
setup_android || warn "Android setup hit an error; continuing."

# ── 4. persist environment for the session ───────────────────────────────────

if [ -n "${CLAUDE_ENV_FILE:-}" ]; then
  {
    echo "export PATH=\"$FLUTTER_HOME/bin:\$HOME/.cargo/bin:\$PATH\""
    echo "export LD_LIBRARY_PATH=\"$PROJECT_DIR/rust/target/debug:\${LD_LIBRARY_PATH:-}\""
    if [ -x "$ANDROID_SDK_HOME/cmdline-tools/latest/bin/sdkmanager" ]; then
      echo "export ANDROID_HOME=\"$ANDROID_SDK_HOME\""
      echo "export ANDROID_SDK_ROOT=\"$ANDROID_SDK_HOME\""
      echo "export PATH=\"$ANDROID_SDK_HOME/cmdline-tools/latest/bin:$ANDROID_SDK_HOME/platform-tools:$ANDROID_SDK_HOME/emulator:\$PATH\""
    fi
  } >> "$CLAUDE_ENV_FILE"
fi

log "Ready. ./scripts/test.sh mirrors CI (Flutter + Rust host jobs)."
if [ "$ANDROID_READY" = "true" ]; then
  log "Android: ./scripts/run-android.sh boots the ${AVD_NAME} AVD;"
  log "  flutter test integration_test --dart-define=LIBERATED_BREAD_MOCK=true runs on it."
else
  log "Android SDK/emulator not provisioned — see the notes above, or run"
  log "  LB_SETUP_ANDROID=1 .claude/hooks/session-start.sh to force it."
fi
