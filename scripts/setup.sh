#!/usr/bin/env bash
# Copyright 2026 Pigs Can Fly Labs LLC
# SPDX-License-Identifier: Apache-2.0
#
# OpenGreenIoT Mobile — developer environment setup
# Installs Flutter SDK, Rust toolchain, Android SDK components, and FRB codegen.
# Idempotent — safe to run multiple times.

set -euo pipefail

FLUTTER_VERSION="3.24.5"
FLUTTER_HOME="${FLUTTER_HOME:-$HOME/.flutter-sdk}"
NDK_VERSION="26.1.10909125"
ANDROID_API="34"
FRB_VERSION="2.9.0"
RUST_MIN_VERSION="1.82.0"

# ── helpers ──────────────────────────────────────────────────────────────────

log()  { printf '\033[1;32m[setup]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[setup]\033[0m %s\n' "$*"; }
err()  { printf '\033[1;31m[setup]\033[0m %s\n' "$*" >&2; }

command_exists() { command -v "$1" &>/dev/null; }

# Return 0 iff version $1 is >= version $2 (dotted numeric).
version_ge() {
  [[ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -1)" == "$2" ]]
}

# Extract "MAJOR.MINOR.PATCH" from `rustc --version` output.
rustc_version() {
  rustc --version 2>/dev/null | awk '{print $2}'
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
OS="$(uname -s)"
CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/opengreeniot-setup"

# ── Flutter SDK ──────────────────────────────────────────────────────────────

install_flutter() {
  if command_exists flutter; then
    log "Flutter already installed: $(flutter --version 2>/dev/null | head -1)"
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

  local parent
  parent="$(dirname "$FLUTTER_HOME")"
  case "$archive" in
    *.tar.xz)
      tar xf "$archive_path" -C "$parent"
      ;;
    *.zip)
      unzip -qo "$archive_path" -d "$parent"
      ;;
  esac
  if [[ "$parent/flutter" != "$FLUTTER_HOME" ]]; then
    rm -rf "$FLUTTER_HOME"
    mv "$parent/flutter" "$FLUTTER_HOME"
  fi

  # Mark the cached archive as good only after extraction succeeded.
  printf '%s\n' "$url" > "$marker"

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

  log "Adding Android cross-compilation targets..."
  rustup target add \
    aarch64-linux-android \
    armv7-linux-androideabi \
    x86_64-linux-android \
    i686-linux-android

  if [[ "$OS" == "Darwin" ]]; then
    log "Adding iOS cross-compilation targets..."
    rustup target add \
      aarch64-apple-ios \
      aarch64-apple-ios-sim
  fi

  if ! command_exists cargo-ndk; then
    log "Installing cargo-ndk..."
    cargo install cargo-ndk
  else
    log "cargo-ndk already installed."
  fi
}

# ── flutter_rust_bridge codegen ──────────────────────────────────────────────

install_frb_codegen() {
  if command_exists flutter_rust_bridge_codegen; then
    local current
    current="$(flutter_rust_bridge_codegen --version 2>/dev/null | awk '{print $NF}' || echo unknown)"
    if [[ "$current" == "$FRB_VERSION" ]]; then
      log "flutter_rust_bridge_codegen ${FRB_VERSION} already installed."
      return
    fi
    warn "flutter_rust_bridge_codegen ${current} does not match pinned ${FRB_VERSION}. Reinstalling..."
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

  log "Installing Android SDK components..."
  yes | "$sdkmanager" --licenses 2>/dev/null || true

  "$sdkmanager" \
    "platform-tools" \
    "build-tools;${ANDROID_API}.0.0" \
    "platforms;android-${ANDROID_API}" \
    "ndk;${NDK_VERSION}" \
    2>/dev/null || warn "Some SDK components may have failed to install."

  # Create emulator AVD
  local avdmanager=""
  if command_exists avdmanager; then
    avdmanager="avdmanager"
  elif [[ -n "${ANDROID_HOME:-}" ]] && [[ -x "${ANDROID_HOME}/cmdline-tools/latest/bin/avdmanager" ]]; then
    avdmanager="${ANDROID_HOME}/cmdline-tools/latest/bin/avdmanager"
  fi

  if [[ -n "$avdmanager" ]]; then
    if "$avdmanager" list avd 2>/dev/null | grep -q "opengreeniot_test"; then
      log "AVD opengreeniot_test already exists."
    else
      log "Installing system image for emulator..."
      "$sdkmanager" "system-images;android-${ANDROID_API};google_apis;x86_64" 2>/dev/null || true

      log "Creating AVD opengreeniot_test..."
      echo "no" | "$avdmanager" create avd \
        -n opengreeniot_test \
        -k "system-images;android-${ANDROID_API};google_apis;x86_64" \
        --force 2>/dev/null || warn "Failed to create AVD. You may need to create it manually."
    fi
  else
    warn "avdmanager not found. Skipping emulator AVD creation."
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
    (cd "$PROJECT_DIR/ios" && pod install 2>/dev/null) || warn "pod install failed — may need Xcode project first."
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
  log "OpenGreenIoT Mobile — Developer Setup"
  log "OS: ${OS} ($(uname -m))"
  log "Project: ${PROJECT_DIR}"
  echo

  install_flutter
  install_rust
  install_frb_codegen
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
}

main "$@"
