#!/usr/bin/env bash
# Copyright 2026 Pigs Can Fly Labs LLC
# SPDX-License-Identifier: Apache-2.0
#
# Liberated Bread Mobile — developer environment setup
# Installs the Flutter SDK, Rust toolchain, FRB codegen, the Linux desktop
# build dependencies, and the Android SDK/NDK plus an emulator AVD matching the
# one CI boots. Versions come from .github/workflows/ci.yml (see
# scripts/ci-versions.sh), not from pins in this file.
# Idempotent — safe to run multiple times.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Versions are not pinned here — scripts/ci-versions.sh reads them out of
# .github/workflows/ci.yml so a local environment tracks CI automatically.
# That covers the Flutter SDK, the NDK cargokit builds against (which must
# match `flutter.ndkVersion`, since android/app/build.gradle sets
# `ndkVersion = flutter.ndkVersion`), the Android platform/build-tools, the
# rustup cross targets, the FRB codegen pin, the Linux desktop apt packages
# and the emulator system image + device profile.
# shellcheck source=ci-versions.sh
source "$SCRIPT_DIR/ci-versions.sh"

FLUTTER_VERSION="$CI_FLUTTER_VERSION"
FLUTTER_HOME="${FLUTTER_HOME:-$HOME/.flutter-sdk}"
NDK_VERSION="$CI_NDK_VERSION"
ANDROID_API="$CI_ANDROID_API"
BUILD_TOOLS_VERSION="$CI_BUILD_TOOLS_VERSION"
FRB_VERSION="$CI_FRB_VERSION"
AVD_NAME="${AVD_NAME:-liberated_bread_test}"

# Not derived from CI: the Rust toolchain there is whatever dtolnay/
# rust-toolchain@stable resolves to on the day, which names no version. This is
# the floor the crate needs to compile.
RUST_MIN_VERSION="1.82.0"

# ── helpers ──────────────────────────────────────────────────────────────────

log()  { printf '\033[1;32m[setup]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[setup]\033[0m %s\n' "$*"; }
err()  { printf '\033[1;31m[setup]\033[0m %s\n' "$*" >&2; }

command_exists() { command -v "$1" &>/dev/null; }

# Idempotently mark a path as safe in the global gitconfig. Repeated runs
# of this script must not pile up duplicate `safe.directory` entries.
# Surfaces failures (read-only or unwritable global gitconfig) instead of
# swallowing them — otherwise we'd continue as if the SDK was marked safe
# and only fail later with `flutter --version` reporting 0.0.0-unknown.
ensure_safe_directory() {
  local path="$1"
  if git config --global --get-all safe.directory 2>/dev/null \
       | grep -Fxq -- "$path"; then
    return 0
  fi
  if ! git config --global --add safe.directory "$path"; then
    err "Failed to add '$path' to git's global safe.directory list."
    err "Likely cause: the global gitconfig is read-only or unwritable."
    err "Fix: run the following with appropriate permissions, then re-run setup:"
    err "  git config --global --add safe.directory '$path'"
    exit 1
  fi
}

# Return 0 iff git refuses to read `$1` because of dubious ownership —
# the only case the `safe.directory` write actually fixes. Other failures
# (corrupt repo, missing HEAD) shouldn't be papered over, and a working
# repo shouldn't need any global-config write at all.
sdk_needs_safe_directory() {
  local path="$1"
  if [[ ! -d "$path/.git" ]]; then
    return 1
  fi
  local probe
  if probe="$(git -C "$path" rev-parse HEAD 2>&1)"; then
    return 1  # git already works without safe.directory
  fi
  if [[ "$probe" == *"dubious ownership"* ]]; then
    return 0
  fi
  return 1
}

# Return 0 iff version $1 is >= version $2 (dotted numeric).
version_ge() {
  [[ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -1)" == "$2" ]]
}

# Extract "MAJOR.MINOR.PATCH" from `rustc --version` output.
rustc_version() {
  rustc --version 2>/dev/null | awk '{print $2}'
}

PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
OS="$(uname -s)"
CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/liberated-bread-setup"

# ── Flutter SDK ──────────────────────────────────────────────────────────────

install_flutter() {
  if command_exists flutter; then
    # When the Flutter SDK checkout is owned by a different user
    # (e.g. shared sandbox cache), git refuses to read it and
    # `flutter --version` reports 0.0.0-unknown — pub get then fails
    # the SDK constraint check. We only paper over that specific
    # case; if git already works, we don't touch the global gitconfig
    # at all (so a read-only ~/.gitconfig is fine for normal installs).
    local flutter_root
    flutter_root="$(flutter --version --machine 2>/dev/null | grep -o '"flutterRoot": *"[^"]*"' | sed 's/.*"\([^"]*\)"$/\1/' || true)"
    if [[ -z "$flutter_root" ]] && [[ -n "${FLUTTER_HOME:-}" ]] && [[ -d "$FLUTTER_HOME/.git" ]]; then
      flutter_root="$FLUTTER_HOME"
    fi
    if [[ -n "$flutter_root" ]] && command_exists git \
       && sdk_needs_safe_directory "$flutter_root"; then
      ensure_safe_directory "$flutter_root"
    fi
    log "Flutter already installed: $(flutter --version 2>/dev/null | head -1)"

    # An existing SDK is not necessarily the one CI is on, and a stale one
    # fails `flutter pub get` on pubspec's Dart SDK constraint rather than
    # anything obvious. Say so — but don't touch an SDK this script didn't
    # install; it may be managed by Android Studio, brew, or the distro.
    local installed
    installed="$(flutter --version --machine 2>/dev/null \
      | grep -o '"frameworkVersion": *"[^"]*"' \
      | sed 's/.*"\([^"]*\)"$/\1/' || true)"
    if [[ -n "$installed" ]] && [[ "$installed" != "$FLUTTER_VERSION" ]]; then
      warn "Flutter ${installed} is on your PATH, but CI pins ${FLUTTER_VERSION}."
      if [[ "$flutter_root" == "$FLUTTER_HOME" ]]; then
        warn "To move this checkout to the pinned version:"
        warn "  rm -rf \"${FLUTTER_HOME}\" && ./scripts/setup.sh"
      else
        warn "That SDK lives in ${flutter_root:-an unknown location} and is left alone."
        warn "Use the pinned one instead with:  FLUTTER_HOME=\"$HOME/.flutter-sdk\" ./scripts/setup.sh"
      fi
    fi
    return
  fi

  log "Installing Flutter SDK ${FLUTTER_VERSION} to ${FLUTTER_HOME}..."

  case "$OS" in
    Linux)
      local archive="flutter_linux_${FLUTTER_VERSION}-stable.tar.xz"
      local url="https://storage.googleapis.com/flutter_infra_release/releases/stable/linux/${archive}"
      ;;
    Darwin)
      if [[ "$(uname -m)" == "arm64" ]]; then
        local archive="flutter_macos_arm64_${FLUTTER_VERSION}-stable.zip"
      else
        local archive="flutter_macos_${FLUTTER_VERSION}-stable.zip"
      fi
      local url="https://storage.googleapis.com/flutter_infra_release/releases/stable/macos/${archive}"
      ;;
    *)
      err "Unsupported OS: ${OS}. This script supports Linux and macOS."
      exit 1
      ;;
  esac

  mkdir -p "$(dirname "$FLUTTER_HOME")" "$CACHE_DIR"

  local archive_path="$CACHE_DIR/$archive"
  local marker="$CACHE_DIR/$archive.ok"

  fetch_archive() {
    log "Downloading ${url}..."
    rm -f "$archive_path" "$marker"
    curl -fSL -o "$archive_path.part" "$url"
    mv "$archive_path.part" "$archive_path"
  }

  verify_archive() {
    case "$archive" in
      *.tar.xz) tar -tf "$archive_path" >/dev/null 2>&1 ;;
      *.zip)    unzip -tq "$archive_path" >/dev/null 2>&1 ;;
    esac
  }

  if [[ -f "$archive_path" && -f "$marker" ]] && \
     [[ "$(cat "$marker" 2>/dev/null)" == "$url" ]] && \
     verify_archive; then
    log "Using cached ${archive} from ${CACHE_DIR}"
  else
    fetch_archive
    if ! verify_archive; then
      warn "Downloaded archive failed verification; retrying once..."
      fetch_archive
      if ! verify_archive; then
        err "Flutter archive is corrupt after re-download: $archive_path"
        exit 1
      fi
    fi
  fi

  # Extract into a private staging directory, never into $(dirname
  # "$FLUTTER_HOME"): the archive's top-level `flutter/` would silently
  # overwrite an unrelated ~/flutter checkout — exactly what a developer whose
  # manual install isn't on PATH (the only way to reach this branch) may have.
  # Staged under CACHE_DIR rather than /tmp so the final mv is a same-
  # filesystem rename, not a multi-GB copy through a possibly-tmpfs /tmp.
  local staging
  staging="$(mktemp -d "$CACHE_DIR/flutter-extract.XXXXXX")"
  case "$archive" in
    *.tar.xz)
      tar xf "$archive_path" -C "$staging"
      ;;
    *.zip)
      unzip -qo "$archive_path" -d "$staging"
      ;;
  esac
  rm -rf "$FLUTTER_HOME"
  mv "$staging/flutter" "$FLUTTER_HOME"
  rm -rf "$staging"

  # Mark the cached archive as good only after extraction succeeded.
  printf '%s\n' "$url" > "$marker"

  # Flutter shells out to `git` inside its SDK to read the framework
  # revision. In containers/CI sandboxes the extracted tree may be owned
  # by a different user, in which case git refuses to read it and
  # `flutter` reports version 0.0.0-unknown, which then breaks
  # `flutter pub get`. Mark the SDK safe only when that actually
  # happens — on a normal local install where the user owns the
  # extracted tree, git works fine and we leave ~/.gitconfig alone.
  if command_exists git && sdk_needs_safe_directory "$FLUTTER_HOME"; then
    ensure_safe_directory "$FLUTTER_HOME"
  fi

  log "Flutter installed to ${FLUTTER_HOME}"
  warn "Add to your shell profile:  export PATH=\"${FLUTTER_HOME}/bin:\$PATH\""
}

# ── Rust toolchain ───────────────────────────────────────────────────────────

install_rust() {
  if command_exists rustup; then
    local v
    v="$(rustc_version)"
    log "Rust already installed: $(rustc --version)"
    if [[ -z "$v" ]] || ! version_ge "$v" "$RUST_MIN_VERSION"; then
      warn "Rust ${v:-unknown} is below required ${RUST_MIN_VERSION}. Running 'rustup update stable'..."
      rustup update stable
      rustup default stable
      v="$(rustc_version)"
      if [[ -z "$v" ]] || ! version_ge "$v" "$RUST_MIN_VERSION"; then
        err "Rust ${v:-unknown} is still below required ${RUST_MIN_VERSION} after update."
        exit 1
      fi
    fi
  elif command_exists rustc; then
    local v
    v="$(rustc_version)"
    err "Found rustc ${v:-unknown} but no rustup."
    err "This project requires rustup (needed to install Android/iOS cross-compilation targets)."
    err "Remove your distro Rust (e.g. 'sudo apt remove rustc cargo') and install via rustup:"
    err "  curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh"
    exit 1
  else
    log "Installing Rust via rustup..."
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --default-toolchain stable
    if [[ -f "$HOME/.cargo/env" ]]; then
      # shellcheck source=/dev/null
      source "$HOME/.cargo/env"
    fi
  fi

  log "Adding Android cross-compilation targets: ${CI_RUST_ANDROID_TARGETS}"
  # shellcheck disable=SC2086  # the target list is intentionally word-split
  rustup target add $CI_RUST_ANDROID_TARGETS

  if [[ "$OS" == "Darwin" ]]; then
    # Same target set CI installs: device, Apple-Silicon simulator, and
    # Intel-Mac simulator.
    log "Adding iOS cross-compilation targets: ${CI_RUST_IOS_TARGETS}"
    # shellcheck disable=SC2086
    rustup target add $CI_RUST_IOS_TARGETS
  fi
}

# ── Linux desktop toolchain ──────────────────────────────────────────────────

# The same packages CI's linux-desktop job installs (clang/cmake/ninja/
# pkg-config, GTK 3 and friends, libsecret for flutter_secure_storage_linux,
# and xvfb for headless runs), read from the workflow. Only apt-based distros
# are handled automatically; elsewhere we print the list and move on.
setup_linux_desktop() {
  if [[ "$OS" != "Linux" ]]; then
    return
  fi

  if ! command_exists apt-get; then
    warn "Non-apt distro: install the Linux desktop equivalents of:"
    warn "  ${CI_LINUX_DESKTOP_PACKAGES}"
    return
  fi

  local sudo_cmd=""
  if [[ "$(id -u)" -ne 0 ]]; then
    if command_exists sudo; then
      sudo_cmd="sudo"
    else
      warn "Not root and no sudo; install these yourself for Linux desktop builds:"
      warn "  ${CI_LINUX_DESKTOP_PACKAGES}"
      return
    fi
  fi

  # Skip the apt round trip when everything is already there — this script is
  # meant to be re-run.
  local missing=()
  local pkg
  for pkg in $CI_LINUX_DESKTOP_PACKAGES; do
    if ! dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q '^install ok installed$'; then
      missing+=("$pkg")
    fi
  done
  if [[ ${#missing[@]} -eq 0 ]]; then
    log "Linux desktop toolchain already installed."
    return
  fi

  log "Installing Linux desktop build deps: ${missing[*]}"
  $sudo_cmd apt-get update
  DEBIAN_FRONTEND=noninteractive $sudo_cmd apt-get install -y --no-install-recommends \
    "${missing[@]}" \
    || warn "Some Linux desktop packages failed to install; 'flutter build linux' may not work."
}

# ── flutter_rust_bridge codegen ──────────────────────────────────────────────

install_frb_codegen() {
  if command_exists flutter_rust_bridge_codegen; then
    # Same version parse as scripts/test.sh — keep the two in sync so both
    # agree on what "matches the pin" means.
    local current
    current="$(flutter_rust_bridge_codegen --version 2>/dev/null \
      | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)"
    if [[ "$current" == "$FRB_VERSION" ]]; then
      log "flutter_rust_bridge_codegen ${FRB_VERSION} already installed."
      return
    fi
    warn "flutter_rust_bridge_codegen ${current:-unknown} does not match pinned ${FRB_VERSION}. Reinstalling..."
    cargo install --locked --force "flutter_rust_bridge_codegen@${FRB_VERSION}"
    return
  fi

  log "Installing flutter_rust_bridge_codegen v${FRB_VERSION}..."
  cargo install --locked "flutter_rust_bridge_codegen@${FRB_VERSION}"
}

# ── Android SDK ──────────────────────────────────────────────────────────────

setup_android_sdk() {
  local sdkmanager=""
  if command_exists sdkmanager; then
    sdkmanager="sdkmanager"
  elif [[ -n "${ANDROID_HOME:-}" ]] && [[ -x "${ANDROID_HOME}/cmdline-tools/latest/bin/sdkmanager" ]]; then
    sdkmanager="${ANDROID_HOME}/cmdline-tools/latest/bin/sdkmanager"
  elif [[ -x "$HOME/Android/Sdk/cmdline-tools/latest/bin/sdkmanager" ]]; then
    sdkmanager="$HOME/Android/Sdk/cmdline-tools/latest/bin/sdkmanager"
  fi

  if [[ -z "$sdkmanager" ]]; then
    warn "sdkmanager not found. Please install Android SDK command-line tools."
    warn "See: https://developer.android.com/studio#command-line-tools-only"
    return
  fi

  log "Installing Android SDK components (API ${ANDROID_API}, build-tools ${BUILD_TOOLS_VERSION}, NDK ${NDK_VERSION})..."
  yes | "$sdkmanager" --licenses 2>/dev/null || true

  # Don't hide stderr on the installs below: when they fail, the reason
  # (network, licenses, disk) must reach the user alongside the warning.
  "$sdkmanager" \
    "platform-tools" \
    "build-tools;${BUILD_TOOLS_VERSION}" \
    "platforms;android-${ANDROID_API}" \
    "ndk;${NDK_VERSION}" \
    || warn "Some SDK components may have failed to install."

  # Create emulator AVD
  local avdmanager=""
  if command_exists avdmanager; then
    avdmanager="avdmanager"
  elif [[ -n "${ANDROID_HOME:-}" ]] && [[ -x "${ANDROID_HOME}/cmdline-tools/latest/bin/avdmanager" ]]; then
    avdmanager="${ANDROID_HOME}/cmdline-tools/latest/bin/avdmanager"
  elif [[ -x "$HOME/Android/Sdk/cmdline-tools/latest/bin/avdmanager" ]]; then
    avdmanager="$HOME/Android/Sdk/cmdline-tools/latest/bin/avdmanager"
  fi

  if [[ -n "$avdmanager" ]]; then
    if "$avdmanager" list avd 2>/dev/null | grep -q "Name: ${AVD_NAME}$"; then
      log "AVD ${AVD_NAME} already exists."
    else
      # The emulator binary itself is a separate SDK package; without it
      # scripts/run-android.sh has nothing to launch.
      log "Installing emulator and ${CI_EMULATOR_SYSTEM_IMAGE}..."
      "$sdkmanager" "emulator" "$CI_EMULATOR_SYSTEM_IMAGE" || true

      # Same image and device profile as CI's android-integration job, so a
      # test that passes locally is testing the configuration CI gates on.
      log "Creating AVD ${AVD_NAME} (${CI_EMULATOR_PROFILE}, API ${CI_EMULATOR_API})..."
      # -d is best-effort: device profile ids come and go between SDK
      # releases, and a generic AVD still boots and runs the tests.
      if ! echo "no" | "$avdmanager" create avd \
            -n "$AVD_NAME" \
            -k "$CI_EMULATOR_SYSTEM_IMAGE" \
            -d "$CI_EMULATOR_PROFILE" \
            --force; then
        warn "Could not create the AVD with device profile ${CI_EMULATOR_PROFILE}; retrying without it."
        echo "no" | "$avdmanager" create avd \
          -n "$AVD_NAME" \
          -k "$CI_EMULATOR_SYSTEM_IMAGE" \
          --force || warn "Failed to create AVD. You may need to create it manually."
      fi
    fi
  else
    warn "avdmanager not found. Skipping emulator AVD creation."
  fi

  if [[ "$OS" == "Linux" ]] && [[ ! -e /dev/kvm ]]; then
    warn "/dev/kvm is missing — the x86_64 emulator will fall back to software"
    warn "emulation and is effectively unusable. On a physical Linux machine:"
    warn "  sudo apt-get install -y qemu-kvm && sudo usermod -aG kvm \"\$USER\""
    warn "Inside a container without KVM, use the Linux desktop target instead:"
    warn "  ./scripts/run-linux.sh --mock"
  fi
}

# ── macOS: Xcode & CocoaPods ────────────────────────────────────────────────

setup_macos() {
  if [[ "$OS" != "Darwin" ]]; then
    return
  fi

  if ! xcode-select -p &>/dev/null; then
    warn "Xcode not found. Install from the App Store for iOS development."
  else
    log "Xcode found at $(xcode-select -p)"
  fi

  if command_exists pod; then
    log "CocoaPods found. Running pod install..."
    (cd "$PROJECT_DIR/ios" && pod install) || warn "pod install failed — may need Xcode project first."
  else
    warn "CocoaPods not found. Install with: gem install cocoapods"
  fi
}

# ── Project dependencies ─────────────────────────────────────────────────────

setup_project() {
  export PATH="${FLUTTER_HOME}/bin:$HOME/.cargo/bin:$PATH"

  if ! command_exists flutter; then
    err "Flutter not found on PATH after setup. Add ${FLUTTER_HOME}/bin to your PATH and re-run."
    exit 1
  fi

  # Warn (don't fail) if platform scaffolds are missing. They should be
  # committed — if you see this warning, restore them from git or regenerate
  # via `flutter create .` (see README).
  if [[ ! -f "$PROJECT_DIR/android/app/build.gradle" ]]; then
    warn "android/app/build.gradle is missing. The Android build will fail."
    warn "If intentional, run: flutter create . --platforms=android,ios"
  fi

  log "Running flutter pub get..."
  (cd "$PROJECT_DIR" && flutter pub get)

  # Generate FRB bindings if Rust crate and API module are both present.
  if [[ -d "$PROJECT_DIR/rust/src/api" ]]; then
    log "Generating flutter_rust_bridge bindings..."
    (cd "$PROJECT_DIR" && flutter_rust_bridge_codegen generate) || \
      warn "FRB codegen failed — mock mode (--mock) will still work."
  fi

  log "Running flutter doctor..."
  flutter doctor || true
}

# ── main ─────────────────────────────────────────────────────────────────────

main() {
  log "Liberated Bread Mobile — Developer Setup"
  log "OS: ${OS} ($(uname -m))"
  log "Project: ${PROJECT_DIR}"
  echo

  install_flutter
  install_rust
  install_frb_codegen
  setup_linux_desktop
  setup_android_sdk
  setup_macos
  setup_project

  echo
  log "Setup complete!"
  log ""
  log "Next steps:"
  log "  1. Ensure Flutter is on your PATH:  export PATH=\"${FLUTTER_HOME}/bin:\$PATH\""
  log "  2. Run the app:  ./scripts/run.sh"
  log "  3. Run in mock mode:  ./scripts/run.sh --mock"
  log "  4. Android emulator (AVD ${AVD_NAME}):  ./scripts/run-android.sh --mock"
  log "  5. Linux desktop, no emulator needed:  ./scripts/run-linux.sh --mock"
}

main "$@"
