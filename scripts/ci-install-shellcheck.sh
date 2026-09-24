#!/usr/bin/env bash
# Copyright 2026 Pigs Can Fly Labs LLC
# SPDX-License-Identifier: Apache-2.0
#
# Make sure the PINNED shellcheck is installed, and do nothing if it already
# is. The sibling of scripts/ci-install-llvm-cov.sh, for a linter instead of a
# coverage tool.
#
# WHY A PIN, when every runner and every Mac already has a shellcheck
#
# Because they have different ones, and the difference is not cosmetic.
# ubuntu-latest preinstalls whatever its image ships — 0.9.0, from 2022 — and
# Homebrew installs the newest release. Between those two, the same finding
# has moved codes (a function reached only through `trap` is SC2317 on its
# body in 0.9, SC2329 on the function from 0.10, and not reported at all by
# 0.11), so a `# shellcheck disable=` that satisfied the laptop did not
# satisfy CI, and scripts/test.sh — the mirror — was green for a week while
# the analyze job was red. A lint whose verdict depends on which machine asks
# is not a gate. One version, named in ci.yml next to every other pin,
# installed by this script on both, is.
#
# WHY A DOWNLOAD VERIFIED BY HASH, and not apt or brew
#
# apt has one version per distro release and brew has the newest; neither
# can be asked for 0.11.0 on both an Ubuntu runner and a Mac. The upstream
# release tarballs can, and pinning their sha256 here means a bump is a
# deliberate edit of this file that names what it trusts, rather than
# "whatever github.com served today". The binary goes under $SHELLCHECK_HOME
# in a directory named for its version; scripts/ci-shellcheck.sh looks there
# first. PATH is not touched, so a developer's own shellcheck stays theirs.
#
# Usage:
#   ./scripts/ci-install-shellcheck.sh                # version from ci.yml
#   SHELLCHECK_VERSION=0.11.0 ./scripts/ci-install-shellcheck.sh
#   ./scripts/ci-install-shellcheck.sh --print-path   # path of the pinned
#                                                     # binary; exit 1 if it
#                                                     # is not installed
#
# Environment:
#   SHELLCHECK_VERSION       Pin override; otherwise read from ci.yml.
#   SHELLCHECK_HOME          Where versions are kept. Default
#                            ~/.cache/liberatedbread/shellcheck.
#   SHELLCHECK_RELEASE_BASE  Where the tarballs come from. Default the
#                            upstream GitHub releases; the selftest points it
#                            at a file:// directory.
#   SHELLCHECK_SHA256        Expected hash of the tarball, overriding the
#                            table below. For the selftest, and for trying a
#                            version before its hashes are added here.

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
cd "$SELF_DIR/.." || exit 1

if [ -z "${SHELLCHECK_VERSION:-}" ]; then
  # shellcheck source=ci-versions.sh
  source "$SELF_DIR/ci-versions.sh"
  SHELLCHECK_VERSION="$CI_SHELLCHECK_VERSION"
fi

SHELLCHECK_HOME="${SHELLCHECK_HOME:-$HOME/.cache/liberatedbread/shellcheck}"
SHELLCHECK_RELEASE_BASE="${SHELLCHECK_RELEASE_BASE:-https://github.com/koalaman/shellcheck/releases/download}"
dest_dir="$SHELLCHECK_HOME/v$SHELLCHECK_VERSION"
dest="$dest_dir/shellcheck"

if [ "${1:-}" = "--print-path" ]; then
  if [ -x "$dest" ]; then printf '%s\n' "$dest"; exit 0; fi
  exit 1
fi

# The artifact is what is checked, not a bookkeeping file next to it: a
# binary that runs and says the pinned version is installed, whatever else
# happened to the directory.
installed_version() { "$1" --version 2>/dev/null | awk '/^version:/ { print $2 }'; }

if [ -x "$dest" ] && [ "$(installed_version "$dest")" = "$SHELLCHECK_VERSION" ]; then
  echo "shellcheck ${SHELLCHECK_VERSION} already installed at ${dest}; skipping the download."
  exit 0
fi

case "$(uname -s)" in
  Linux)  os=linux ;;
  Darwin) os=darwin ;;
  *) echo "::error::no shellcheck release for $(uname -s); install ${SHELLCHECK_VERSION} by hand at ${dest}." >&2; exit 1 ;;
esac
case "$(uname -m)" in
  x86_64|amd64)  arch=x86_64 ;;
  arm64|aarch64) arch=aarch64 ;;
  *) echo "::error::no shellcheck release for $(uname -m); install ${SHELLCHECK_VERSION} by hand at ${dest}." >&2; exit 1 ;;
esac

# sha256 of each upstream release tarball this script is allowed to install.
# A `case`, not an associative array: macOS ships bash 3.2, which has none.
# To bump the pin: download the four tarballs, hash them, add a block here,
# then change SHELLCHECK_VERSION in ci.yml.
expected="${SHELLCHECK_SHA256:-}"
if [ -z "$expected" ]; then
  case "${SHELLCHECK_VERSION}/${os}.${arch}" in
    0.11.0/linux.x86_64)   expected=8c3be12b05d5c177a04c29e3c78ce89ac86f1595681cab149b65b97c4e227198 ;;
    0.11.0/linux.aarch64)  expected=12b331c1d2db6b9eb13cfca64306b1b157a86eb69db83023e261eaa7e7c14588 ;;
    0.11.0/darwin.aarch64) expected=56affdd8de5527894dca6dc3d7e0a99a873b0f004d7aabc30ae407d3f48b0a79 ;;
    0.11.0/darwin.x86_64)  expected=3c89db4edcab7cf1c27bff178882e0f6f27f7afdf54e859fa041fca10febe4c6 ;;
    *)
      echo "::error file=scripts/ci-install-shellcheck.sh::no pinned sha256 for shellcheck ${SHELLCHECK_VERSION} on ${os}.${arch}. Hash the upstream tarball and add it to the table in this script (or set SHELLCHECK_SHA256 to try it once)." >&2
      exit 1 ;;
  esac
fi

tarball="shellcheck-v${SHELLCHECK_VERSION}.${os}.${arch}.tar.xz"
url="${SHELLCHECK_RELEASE_BASE}/v${SHELLCHECK_VERSION}/${tarball}"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

echo "Downloading ${url}"
if ! curl -fsSL --retry 3 -o "$work/$tarball" "$url"; then
  echo "::error::could not download ${url}" >&2
  exit 1
fi

# Whichever hasher this machine has: coreutils on Linux, perl's on macOS.
if command -v sha256sum >/dev/null 2>&1; then
  actual="$(sha256sum "$work/$tarball" | awk '{ print $1 }')"
else
  actual="$(shasum -a 256 "$work/$tarball" | awk '{ print $1 }')"
fi
if [ "$actual" != "$expected" ]; then
  echo "::error::${tarball} does not match its pinned sha256." >&2
  echo "  expected ${expected}" >&2
  echo "  got      ${actual}" >&2
  echo "  Nothing was installed. If upstream re-cut the release, re-verify it before updating the hash in scripts/ci-install-shellcheck.sh." >&2
  exit 1
fi

if ! tar -xJf "$work/$tarball" -C "$work"; then
  echo "::error::could not unpack ${tarball}" >&2
  exit 1
fi
if [ ! -f "$work/shellcheck-v${SHELLCHECK_VERSION}/shellcheck" ]; then
  echo "::error::${tarball} does not contain shellcheck-v${SHELLCHECK_VERSION}/shellcheck; the release layout changed." >&2
  exit 1
fi

mkdir -p "$dest_dir" || exit 1
# Into place under a temporary name, then renamed: a parallel run (the mirror's
# legs, say) that finds a half-copied binary would fail for a reason that
# reads as a broken pin.
if ! { cp "$work/shellcheck-v${SHELLCHECK_VERSION}/shellcheck" "$dest.tmp.$$" \
       && chmod +x "$dest.tmp.$$" \
       && mv -f "$dest.tmp.$$" "$dest"; }; then
  rm -f "$dest.tmp.$$"
  exit 1
fi

got="$(installed_version "$dest")"
if [ "$got" != "$SHELLCHECK_VERSION" ]; then
  echo "::error::the installed binary reports version '${got}', not ${SHELLCHECK_VERSION}." >&2
  rm -f "$dest"
  exit 1
fi
echo "shellcheck ${SHELLCHECK_VERSION} installed at ${dest}."
