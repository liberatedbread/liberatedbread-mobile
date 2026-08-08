#!/usr/bin/env bash
# Copyright 2026 Pigs Can Fly Labs LLC
# SPDX-License-Identifier: Apache-2.0
#
# Keep the repo-managed Flutter SDK on the version CI pins — used by the
# ./scripts/run*.sh entry points so a version bump in CI does not turn into a
# confusing local failure.
#
# The run scripts default FLUTTER_HOME to ~/.flutter-sdk: the SDK that
# scripts/setup.sh and the Claude Code session hook install there. When CI's
# pinned Flutter (FLUTTER_VERSION in .github/workflows/ci.yml, surfaced by
# scripts/ci-versions.sh) moves ahead of what is on disk, that SDK is stale,
# and `flutter pub get` then fails pubspec's Dart SDK constraint rather than
# anything obvious. This upgrades it in place so `./scripts/run.sh` just works
# after a bump, without a separate `./scripts/setup.sh` run.
#
# Deliberately narrow. It only ever replaces an SDK that actually lives under
# FLUTTER_HOME — the one this project installed. A Flutter that comes from
# Homebrew, Android Studio, the distro, or a hand-managed checkout elsewhere is
# never touched (it is not ours to overwrite); we only warn about the mismatch,
# exactly as scripts/setup.sh does. A failed download leaves the existing SDK
# intact and the run continues, so being offline degrades to "slightly stale"
# rather than "cannot run at all".
#
# Opt out with LB_FLUTTER_AUTO_UPGRADE=0 (e.g. when deliberately testing a
# different Flutter). Sourced by the run scripts; also runnable on its own,
# which just performs the check against the current environment.

# Resolve CI_FLUTTER_VERSION from ci.yml. Idempotent, and the same read
# scripts/setup.sh and the session hook do, so all three agree on the pin.
_fev_self="${BASH_SOURCE[0]:-$0}"
_fev_dir="$(cd "$(dirname "$_fev_self")" && pwd)"
# shellcheck source=ci-versions.sh
source "$_fev_dir/ci-versions.sh"

# Fall back to plain messaging only when the caller has not defined log/warn/err
# (i.e. this file run on its own). Sourced by a run script, its prefixed
# versions are used instead, so upgrade output matches the rest of the run.
if ! declare -F log  >/dev/null 2>&1; then log()  { printf '[flutter] %s\n' "$*"; }        fi
if ! declare -F warn >/dev/null 2>&1; then warn() { printf '[flutter] %s\n' "$*" >&2; }    fi
if ! declare -F err  >/dev/null 2>&1; then err()  { printf '[flutter] %s\n' "$*" >&2; }    fi

# The stamp scripts/setup.sh and the session hook write at install time: a
# cheap, exact answer for "what is in FLUTTER_HOME" without spinning up the Dart
# VM. Keep the name in sync with .claude/hooks/session-start.sh.
_fev_stamp_name=".liberated-bread-version"

# Version string of the SDK installed at $1 (its bin/flutter), or empty when
# there is none. Prefers the stamp; falls back to asking the tool.
_fev_installed_version() {
  local home="$1"
  [ -x "$home/bin/flutter" ] || return 0
  if [ -r "$home/$_fev_stamp_name" ]; then
    cat "$home/$_fev_stamp_name"
    return 0
  fi
  "$home/bin/flutter" --version --machine 2>/dev/null \
    | grep -o '"frameworkVersion": *"[^"]*"' \
    | sed 's/.*"\([^"]*\)"$/\1/'
}

# Download Flutter $1 and swap it into FLUTTER_HOME ($2). Everything is staged
# in a temp dir and only moved into place once the download AND extraction have
# succeeded, so a failure leaves the existing SDK untouched. Non-zero on any
# failure (with the reason already reported).
_fev_install() {
  local version="$1" home="$2"
  local os archive url tmp
  os="$(uname -s)"
  case "$os" in
    Linux)
      archive="flutter_linux_${version}-stable.tar.xz"
      url="https://storage.googleapis.com/flutter_infra_release/releases/stable/linux/${archive}"
      ;;
    Darwin)
      if [ "$(uname -m)" = "arm64" ]; then
        archive="flutter_macos_arm64_${version}-stable.zip"
      else
        archive="flutter_macos_${version}-stable.zip"
      fi
      url="https://storage.googleapis.com/flutter_infra_release/releases/stable/macos/${archive}"
      ;;
    *)
      err "Cannot auto-upgrade Flutter on unsupported OS '${os}'; run ./scripts/setup.sh."
      return 1
      ;;
  esac

  if [ "$archive" != "${archive%.zip}" ] && ! command -v unzip >/dev/null 2>&1; then
    err "unzip is required to unpack the Flutter archive but was not found."
    return 1
  fi

  tmp="$(mktemp -d)"
  if ! curl -fSL -o "$tmp/$archive" "$url"; then
    err "Download of ${url} failed."
    rm -rf "$tmp"
    return 1
  fi

  local extracted=0
  case "$archive" in
    *.tar.xz) tar xf "$tmp/$archive" -C "$tmp" && extracted=1 ;;
    *.zip)    unzip -q "$tmp/$archive" -d "$tmp" && extracted=1 ;;
  esac
  if [ "$extracted" -ne 1 ] || [ ! -d "$tmp/flutter" ]; then
    err "Failed to extract the Flutter archive from ${archive}."
    rm -rf "$tmp"
    return 1
  fi

  mkdir -p "$(dirname "$home")"
  rm -rf "$home"
  mv "$tmp/flutter" "$home"
  rm -rf "$tmp"
  printf '%s\n' "$version" > "$home/$_fev_stamp_name"
}

# Ensure the Flutter that ./scripts/run*.sh will use is CI's pinned version,
# upgrading it in place when it is the repo-managed SDK under FLUTTER_HOME.
# No-op (with a warning) for a Flutter managed anywhere else, and a no-op when
# already current. Never fails the caller: an upgrade that cannot happen is a
# warning, not an abort.
flutter_ensure_ci_version() {
  local home="${FLUTTER_HOME:-$HOME/.flutter-sdk}"
  local want="${CI_FLUTTER_VERSION:-}"

  if [ "${LB_FLUTTER_AUTO_UPGRADE:-1}" = "0" ]; then
    return 0
  fi
  if [ -z "$want" ]; then
    # ci-versions.sh already warned; nothing sensible to compare against.
    return 0
  fi

  # Which flutter would actually run? The run scripts put "$home/bin" first on
  # PATH, so a resolved path under "$home" means we are on the repo-managed SDK.
  # Anything else belongs to another installer and is left untouched.
  local resolved="" home_real="$home"
  if command -v flutter >/dev/null 2>&1; then
    resolved="$(command -v flutter)"
    if command -v readlink >/dev/null 2>&1; then
      resolved="$(readlink -f "$resolved" 2>/dev/null || echo "$resolved")"
      home_real="$(readlink -f "$home" 2>/dev/null || echo "$home")"
    fi
  fi

  local ours=false
  case "$resolved" in
    "$home_real"/*|"$home"/*) ours=true ;;
  esac

  local installed
  installed="$(_fev_installed_version "$home" || true)"

  if [ "$ours" != "true" ]; then
    # A Flutter from somewhere else is on PATH. Only nag when it differs from
    # the pin — like scripts/setup.sh, we never touch an SDK we did not install.
    local cur="$installed"
    if [ -z "$cur" ] && [ -n "$resolved" ]; then
      cur="$(flutter --version --machine 2>/dev/null \
        | grep -o '"frameworkVersion": *"[^"]*"' \
        | sed 's/.*"\([^"]*\)"$/\1/' || true)"
    fi
    if [ -n "$cur" ] && [ "$cur" != "$want" ]; then
      warn "Flutter ${cur} on your PATH (${resolved:-unknown}) is not CI's pinned ${want},"
      warn "but it is not the repo-managed SDK at ${home}, so it is left alone."
      warn "To use the pinned one: FLUTTER_HOME=\"\$HOME/.flutter-sdk\" ./scripts/setup.sh"
    fi
    return 0
  fi

  if [ "$installed" = "$want" ]; then
    return 0
  fi

  if [ -n "$installed" ]; then
    log "Flutter ${installed} at ${home} is not CI's pinned ${want}; upgrading..."
  else
    log "Installing Flutter ${want} (CI's pin) at ${home}..."
  fi

  if ! _fev_install "$want" "$home"; then
    warn "Auto-upgrade to Flutter ${want} failed; continuing with the existing SDK."
    warn "Re-run ./scripts/setup.sh once the network is back to fix it."
    return 0
  fi

  # Flutter shells out to git inside its SDK; mark the freshly extracted tree
  # safe when it is owned by another user (common in containers) so that
  # `flutter --version` does not report 0.0.0-unknown and break pub get.
  if command -v git >/dev/null 2>&1 \
     && ! git config --global --get-all safe.directory 2>/dev/null \
          | grep -Fxq -- "$home"; then
    git config --global --add safe.directory "$home" || true
  fi

  # The new binary sits at the same path as the old one; drop any cached PATH
  # lookup so the upgraded version is what actually runs next.
  hash -r 2>/dev/null || true

  log "Flutter ${want} is now installed at ${home}."
}

# Executed directly (not sourced): run the check against the current
# environment. Lets you verify behavior with ./scripts/flutter-ensure-version.sh
if [ "${BASH_SOURCE[0]:-}" = "${0}" ]; then
  flutter_ensure_ci_version
fi
