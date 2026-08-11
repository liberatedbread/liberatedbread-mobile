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
# Deliberately narrow. It only ever replaces the SDK at the default,
# project-managed location — $HOME/.flutter-sdk, the one scripts/setup.sh and
# the session hook install. A Flutter from Homebrew, Android Studio, the distro,
# a hand-managed checkout, or a caller-overridden FLUTTER_HOME is never touched:
# the run scripts prepend FLUTTER_HOME to PATH, so path containment under an
# arbitrary FLUTTER_HOME is NOT proof of ownership. For those we only warn about
# the mismatch, exactly as scripts/setup.sh does. A failed download leaves the
# existing SDK intact and the run continues, so being offline degrades to
# "slightly stale" rather than "cannot run at all".
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

# Take (or steal, when its owner is dead) the upgrade lock at $1. This file is
# SOURCED by the run scripts, so an INT/TERM trap here would hijack the
# caller's shell — an interrupted swap therefore cannot clean up after itself,
# and the lock plus _fev_heal_interrupted below are how the next run recovers
# instead. The lock also keeps two concurrent run*.sh from interleaving their
# swaps, which could nest one SDK inside the other. Non-zero when another live
# process holds it.
_fev_lock() {
  local lock="$1" pid
  if mkdir "$lock" 2>/dev/null; then
    printf '%s\n' "$$" > "$lock/pid"
    return 0
  fi
  pid="$(cat "$lock/pid" 2>/dev/null || true)"
  if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
    return 1
  fi
  # The owner died (an interrupted upgrade cannot release — see above).
  rm -rf "$lock"
  mkdir "$lock" 2>/dev/null || return 1
  printf '%s\n' "$$" > "$lock/pid"
}

# Repair what an interrupted _fev_install left behind at the default SDK
# location: a kill between "move the old SDK aside" and "move the new one in"
# leaves no SDK at $1, the previous one stranded at $1.old.<pid>, and a
# multi-GB staging dir next to it. Restore the newest backup when the SDK is
# gone, then sweep leftovers — callers hold the upgrade lock, so nothing here
# can race a live swap's backup.
_fev_heal_interrupted() {
  local home="$1" backup leftover
  if [ ! -e "$home" ]; then
    backup="$(ls -td "${home}".old.* 2>/dev/null | head -n 1)"
    if [ -n "$backup" ] && [ -d "$backup" ]; then
      warn "Restoring the Flutter SDK from an interrupted upgrade (${backup})."
      mv "$backup" "$home" || warn "Could not restore ${backup}; run ./scripts/setup.sh."
    fi
  fi
  for leftover in "${home}".old.* "$(dirname "$home")"/.flutter-upgrade.*; do
    [ -e "$leftover" ] || continue
    rm -rf "$leftover"
  done
  return 0
}

# Download Flutter $1 and swap it into FLUTTER_HOME ($2). Everything is staged
# in a temp dir and only moved into place once the download AND extraction have
# succeeded, so a failure leaves the existing SDK untouched. Non-zero on any
# failure (with the reason already reported). Callers hold the upgrade lock.
_fev_install() {
  local version="$1" home="$2"
  local os archive url parent stage backup
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

  # Stage on the SAME filesystem as $home (a sibling temp dir), so the swap
  # below is an atomic rename and never a cross-filesystem copy that could fail
  # half-done on disk space or I/O — which, after the old SDK was removed, would
  # leave FLUTTER_HOME empty.
  parent="$(dirname "$home")"
  if ! mkdir -p "$parent"; then
    err "Cannot create ${parent} to install Flutter into."
    return 1
  fi
  if ! stage="$(mktemp -d "$parent/.flutter-upgrade.XXXXXX")"; then
    err "Cannot create a staging directory next to ${home}."
    return 1
  fi

  if ! curl -fSL -o "$stage/$archive" "$url"; then
    err "Download of ${url} failed."
    rm -rf "$stage"
    return 1
  fi

  local extracted=0
  case "$archive" in
    *.tar.xz) tar xf "$stage/$archive" -C "$stage" && extracted=1 ;;
    *.zip)    unzip -q "$stage/$archive" -d "$stage" && extracted=1 ;;
  esac
  if [ "$extracted" -ne 1 ] || [ ! -d "$stage/flutter" ]; then
    err "Failed to extract the Flutter archive from ${archive}."
    rm -rf "$stage"
    return 1
  fi

  # Swap, preserving the old SDK until the new one is actually in place: move
  # the current SDK aside, move the new tree in, and only then drop the old. If
  # the install move fails, restore the old SDK so a failed upgrade never leaves
  # FLUTTER_HOME missing. Every mv here is a same-filesystem rename.
  backup=""
  if [ -e "$home" ]; then
    backup="${home}.old.$$"
    rm -rf "$backup"
    if ! mv "$home" "$backup"; then
      err "Could not move the existing SDK aside; leaving it untouched."
      rm -rf "$stage"
      return 1
    fi
  fi

  if ! mv "$stage/flutter" "$home"; then
    err "Could not move the new Flutter into place at ${home}."
    if [ -n "$backup" ]; then
      rm -rf "$home"
      mv "$backup" "$home" || err "Failed to restore the previous SDK from ${backup}."
    fi
    rm -rf "$stage"
    return 1
  fi

  # New SDK is in place. Record the version ONLY now — a stamp written before a
  # successful swap could make a partial install look like a completed upgrade.
  # Then reclaim the old tree and the staging dir.
  printf '%s\n' "$version" > "$home/$_fev_stamp_name"
  [ -n "$backup" ] && rm -rf "$backup"
  rm -rf "$stage"
}

# Ensure the Flutter that ./scripts/run*.sh will use is CI's pinned version,
# upgrading it in place when it is the repo-managed SDK under FLUTTER_HOME.
# No-op (with a warning) for a Flutter managed anywhere else, and a no-op when
# already current. Never fails the caller: an upgrade that cannot happen is a
# warning, not an abort.
flutter_ensure_ci_version() {
  local home="${FLUTTER_HOME:-$HOME/.flutter-sdk}"
  local default_home="$HOME/.flutter-sdk"
  local want="${CI_FLUTTER_VERSION:-}"

  if [ "${LB_FLUTTER_AUTO_UPGRADE:-1}" = "0" ]; then
    return 0
  fi
  if [ -z "$want" ]; then
    # ci-versions.sh already warned; nothing sensible to compare against.
    return 0
  fi

  # Before anything looks at $home: put back what an interrupted previous
  # upgrade may have torn down, or the ownership check below would conclude
  # "no SDK of ours here" about an SDK that is merely mid-swap. Only ever at
  # the default project-managed location, under the same lock the swap takes;
  # skipped silently when a live upgrade holds it.
  local upgrade_lock="${default_home}.upgrade-lock"
  if _fev_lock "$upgrade_lock"; then
    _fev_heal_interrupted "$default_home"
    rm -rf "$upgrade_lock"
  fi

  # Resolve the paths we compare, following symlinks where possible.
  local resolved="" home_real="$home" default_real="$default_home"
  if command -v readlink >/dev/null 2>&1; then
    home_real="$(readlink -f "$home" 2>/dev/null || echo "$home")"
    default_real="$(readlink -f "$default_home" 2>/dev/null || echo "$default_home")"
  fi
  if command -v flutter >/dev/null 2>&1; then
    resolved="$(command -v flutter)"
    if command -v readlink >/dev/null 2>&1; then
      resolved="$(readlink -f "$resolved" 2>/dev/null || echo "$resolved")"
    fi
  fi

  # Ownership is established by LOCATION, not by PATH containment. We only ever
  # replace the SDK at the default project-managed path ($HOME/.flutter-sdk),
  # and only when the flutter that would actually run lives there. A caller who
  # points FLUTTER_HOME at a hand-managed checkout keeps it: the run scripts
  # prepend FLUTTER_HOME to PATH, so containment there is not proof it is ours
  # to delete.
  local ours=false
  if [ "$home_real" = "$default_real" ]; then
    case "$resolved" in
      "$home_real"/*|"$home"/*) ours=true ;;
    esac
  fi

  local installed
  installed="$(_fev_installed_version "$home" || true)"

  if [ "$ours" != "true" ]; then
    # Some other Flutter is in charge — a custom FLUTTER_HOME, or one from
    # Homebrew/Android Studio/the distro. Only nag when it differs from the pin;
    # like scripts/setup.sh, we never touch an SDK we did not install.
    local cur="$installed"
    if [ -z "$cur" ] && [ -n "$resolved" ]; then
      cur="$(flutter --version --machine 2>/dev/null \
        | grep -o '"frameworkVersion": *"[^"]*"' \
        | sed 's/.*"\([^"]*\)"$/\1/' || true)"
    fi
    if [ -n "$cur" ] && [ "$cur" != "$want" ]; then
      warn "Flutter ${cur} on your PATH (${resolved:-unknown}) is not CI's pinned ${want}."
      if [ "$home_real" != "$default_real" ]; then
        warn "FLUTTER_HOME is ${home}, not the project-managed ${default_home}, so it is left alone."
      else
        warn "It is not the project-managed SDK at ${default_home}, so it is left alone."
      fi
      warn "To use the pinned one: unset FLUTTER_HOME and run ./scripts/setup.sh."
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

  if ! _fev_lock "$upgrade_lock"; then
    warn "Another Flutter upgrade appears to be running; leaving it to finish."
    return 0
  fi
  if ! _fev_install "$want" "$home"; then
    rm -rf "$upgrade_lock"
    warn "Auto-upgrade to Flutter ${want} failed; continuing with the existing SDK."
    warn "Re-run ./scripts/setup.sh once the network is back to fix it."
    return 0
  fi
  rm -rf "$upgrade_lock"

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
