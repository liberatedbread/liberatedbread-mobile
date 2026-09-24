#!/usr/bin/env bash
# Copyright 2026 Pigs Can Fly Labs LLC
# SPDX-License-Identifier: Apache-2.0
#
# Drives scripts/ci-install-shellcheck.sh against a stub release served over
# file://, so the part that matters — a tarball that does not match its
# pinned hash installs nothing — is exercised without the network and without
# trusting that this run's download happened to be the honest one.
#
# Usage:
#   ./scripts/ci-install-shellcheck-selftest.sh

set -uo pipefail
cd "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)" || exit 1

status=0
checks=0
pass() { checks=$((checks + 1)); printf '  ok    %s\n' "$1"; }
fail() { checks=$((checks + 1)); printf '  FAIL  %s\n' "$1" >&2; status=1; }
check_eq() { # label expected actual
  if [[ "$2" == "$3" ]]; then pass "$1"; else fail "$1: expected '$2', got '$3'"; fi
}

WORK="$(mktemp -d)"
# shellcheck disable=SC2317,SC2329  # reached through the EXIT trap below, which shellcheck cannot see
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

V=9.9.9
case "$(uname -s)" in Linux) os=linux ;; Darwin) os=darwin ;; *) os=unknown ;; esac
case "$(uname -m)" in x86_64|amd64) arch=x86_64 ;; arm64|aarch64) arch=aarch64 ;; *) arch=unknown ;; esac
tarball="shellcheck-v$V.$os.$arch.tar.xz"

# A release directory with the upstream layout: <base>/v<V>/<tarball>, and in
# the tarball the binary at shellcheck-v<V>/shellcheck — here a stub that
# answers --version the way the real one does.
release="$WORK/release/v$V"
mkdir -p "$release" "$WORK/src/shellcheck-v$V"
cat > "$WORK/src/shellcheck-v$V/shellcheck" <<STUB
#!/usr/bin/env bash
if [ "\${1:-}" = "--version" ]; then printf 'ShellCheck - shell script analysis tool\nversion: $V\n'; exit 0; fi
exit 0
STUB
chmod +x "$WORK/src/shellcheck-v$V/shellcheck"
tar -cJf "$release/$tarball" -C "$WORK/src" "shellcheck-v$V"
if command -v sha256sum >/dev/null 2>&1; then
  good="$(sha256sum "$release/$tarball" | awk '{ print $1 }')"
else
  good="$(shasum -a 256 "$release/$tarball" | awk '{ print $1 }')"
fi

# The script's own arguments pass through; a hash for one call is supplied
# the shell way, `SHELLCHECK_SHA256=... install`, which bash exports to the
# command the function runs.
install() {
  env SHELLCHECK_VERSION="$V" SHELLCHECK_HOME="$WORK/home" \
      SHELLCHECK_RELEASE_BASE="file://$WORK/release" \
      ./scripts/ci-install-shellcheck.sh "$@"
}

# A version with no hash in the table, and none supplied, is refused before
# anything is fetched.
out="$(install 2>&1)"; rc=$?
check_eq "a version with no pinned hash is refused (exit 1)" "1" "$rc"
if grep -q 'no pinned sha256' <<<"$out"; then pass "...and says which table to add it to"; else fail "...but the message did not name the table: $out"; fi
if [[ ! -e "$WORK/home/v$V/shellcheck" ]]; then pass "...and installed nothing"; else fail "...but a binary appeared"; fi

# The wrong hash installs nothing and says so.
out="$(SHELLCHECK_SHA256="$(printf '0%.0s' {1..64})" install 2>&1)"; rc=$?
check_eq "a tarball that does not match its hash is refused (exit 1)" "1" "$rc"
if grep -q 'does not match its pinned sha256' <<<"$out"; then pass "...naming the mismatch"; else fail "...but the message did not name the mismatch: $out"; fi
if [[ ! -e "$WORK/home/v$V/shellcheck" ]]; then pass "...and installed nothing"; else fail "...but a binary appeared"; fi
if ! install --print-path >/dev/null 2>&1; then pass "...so --print-path says it is not installed"; else fail "--print-path found a binary after a refused install"; fi

# The right hash installs, and --print-path finds it.
out="$(SHELLCHECK_SHA256="$good" install 2>&1)"; rc=$?
check_eq "a tarball matching its hash installs (exit 0)" "0" "$rc"
path="$(install --print-path 2>/dev/null)"; rc=$?
check_eq "...and --print-path finds it (exit 0)" "0" "$rc"
check_eq "...at the version-named path" "$WORK/home/v$V/shellcheck" "$path"
check_eq "...and it runs as the pinned version" "$V" "$("$path" --version | awk '/^version:/ { print $2 }')"

# Installed once, it is not downloaded again: the release is gone, the
# install still succeeds, and says why.
rm -rf "$WORK/release"
out="$(install 2>&1)"; rc=$?
check_eq "a second run with the binary present does not download (exit 0)" "0" "$rc"
if grep -q 'already installed' <<<"$out"; then pass "...and says so"; else fail "...but did not say so: $out"; fi

# A binary that is there but is the WRONG version is replaced, not trusted.
printf '#!/usr/bin/env bash\nprintf "version: 0.0.1\\n"\n' > "$WORK/home/v$V/shellcheck"
out="$(SHELLCHECK_SHA256="$good" install 2>&1)"; rc=$?
check_eq "a binary of the wrong version is not accepted as installed (exit 1 with the release gone)" "1" "$rc"
if grep -q 'could not download' <<<"$out"; then pass "...and it tried to fetch a fresh one"; else fail "...but did not try to fetch: $out"; fi

if (( status == 0 )); then
  echo "ci-install-shellcheck selftest: all ${checks} passed"
else
  echo "ci-install-shellcheck selftest: FAILED" >&2
fi
exit "$status"
