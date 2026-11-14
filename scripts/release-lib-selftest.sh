#!/usr/bin/env bash
# Copyright 2026 Pigs Can Fly Labs LLC
# SPDX-License-Identifier: Apache-2.0
#
# Exercises the parts of scripts/release-lib.sh that decide WHAT gets released,
# without a phone, a store or a network: the prompts, the version and
# changelog parsing, the release record, and tag resolution against a
# throwaway repo with a throwaway "origin". The guided release itself only
# runs a few times a year, so its own bugs would otherwise surface mid-release.
#
# Runs in scripts/test.sh and CI's gate job; needs bash, git and awk.

# shellcheck disable=SC2015,SC2034  # `a && pass || fail` is the idiom here; REMOTE is read by the sourced lib
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)" || exit 1
# shellcheck source=release-lib.sh
source "$ROOT/scripts/release-lib.sh"

status=0
pass() { printf '  ok    %s\n' "$1"; }
fail() { printf '  FAIL  %s\n' "$1" >&2; status=1; }
expect() { # expect LABEL WANT GOT
  if [[ "$2" == "$3" ]]; then pass "$1"; else fail "$1: want [$2], got [$3]"; fi
}

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# ── prompts ──────────────────────────────────────────────────────────────────

expect "ask: empty line takes the default" "dflt" "$(ask q dflt <<<"" 2>/dev/null)"
expect "ask: an answer wins" "mine" "$(ask q dflt <<<"mine" 2>/dev/null)"
expect "ask_required: skips blank lines" "x" "$(printf '\n\nx\n' | ask_required q 2>/dev/null)"
confirm q y <<<"" 2>/dev/null && pass "confirm: default y" || fail "confirm: default y"
confirm q <<<"" 2>/dev/null && fail "confirm: default n" || pass "confirm: default n"
confirm q n <<<"YES" 2>/dev/null && pass "confirm: case-insensitive" || fail "confirm: case-insensitive"
expect "confirm: re-asks on junk" 0 "$(printf 'maybe\ny\n' | confirm q 2>/dev/null; echo $?)"
expect "choose: re-asks out of range" 2 "$(printf '0\n9\nx\n2\n' | choose q a b 2>/dev/null)"
(pause <<<"" 2>/dev/null; echo "after") | grep -q after && pass "pause: Enter continues" ||
  fail "pause: Enter continues"
expect "pause: q exits 0 without continuing" "" "$( (pause <<<"q" >/dev/null 2>&1; echo after) )"
expect "checklist: a no stops" 1 "$( (checklist a b <<<$'y\nn' >/dev/null 2>&1); echo $?)"

# ── parsing ──────────────────────────────────────────────────────────────────

expect "pubspec_version strips +N" "0.1.0" "$(printf 'name: x\nversion: 0.1.0+1\n' | pubspec_version)"
expect "pubspec_version without +N" "1.2.3" "$(printf 'version:   1.2.3\n' | pubspec_version)"
expect "build_number_from_log" "202611111830" \
  "$(printf 'x\n[release] flutter build ipa --release --build-number=202611111830\n' | build_number_from_log)"

cat >"$TMP/CHANGELOG.md" <<'EOF'
# Changelog

## [Unreleased]

## [0.2.0] - 2026-12-01

### Added

- two point oh

## [0.1.0] - 2026-11-20

### Fixed

- one

[0.1.0]: https://example.invalid
EOF
expect "changelog_heading finds the dated heading" "## [0.2.0] - 2026-12-01" \
  "$(changelog_heading 0.2.0 <"$TMP/CHANGELOG.md")"
expect "changelog_heading: dots are literal" "" "$(changelog_heading 0x2x0 <"$TMP/CHANGELOG.md")"
expect "changelog_section: body only, trimmed" $'### Added\n\n- two point oh' \
  "$(changelog_section 0.2.0 <"$TMP/CHANGELOG.md")"
expect "changelog_section: stops at link refs" $'### Fixed\n\n- one' \
  "$(changelog_section 0.1.0 <"$TMP/CHANGELOG.md")"
expect "changelog_section: missing version is empty" "" "$(changelog_section 9.9.9 <"$TMP/CHANGELOG.md")"

# ── release record ───────────────────────────────────────────────────────────

R="$TMP/record.txt"
expect "record_get on a missing file" "" "$(record_get "$R" A)"
record_set "$R" A 1
record_set "$R" B 'https://x/y?a=b&c=d'
record_set "$R" A 2
expect "record_set replaces in place" $'A=2\nB=https://x/y?a=b&c=d' "$(cat "$R")"
expect "record_get with & and / in the value" 'https://x/y?a=b&c=d' "$(record_get "$R" B)"
expect "record_get: prefix keys do not collide" "" "$(record_get "$R" AB)"

# ── tag resolution against a throwaway origin ────────────────────────────────

git_q() { git -c user.name=t -c user.email=t@t -c init.defaultBranch=main "$@" >/dev/null 2>&1; }
git_q init --bare "$TMP/origin.git"
git_q clone "$TMP/origin.git" "$TMP/work"
cd "$TMP/work" || exit 1
printf 'version: 0.1.0+1\n' >pubspec.yaml
cp "$TMP/CHANGELOG.md" CHANGELOG.md
git_q add -A && git_q commit -m one && git_q push origin HEAD:main
git_q tag -a v0.1.0 -m v0.1.0
git_q tag -a v0.0.9 -m wrong
REMOTE=origin

resolve() { ( TAG="$1"; resolve_existing_tag <<<"" >/dev/null 2>&1 && echo "$RELEASE_SHA $TAG_ON_REMOTE" ); }
HEAD_SHA="$(git rev-parse HEAD)"
expect "existing tag, local only" "$HEAD_SHA 0" "$(resolve v0.1.0)"
expect "existing tag, version mismatch refused" "" "$(resolve v0.0.9)"
git_q push origin refs/tags/v0.1.0
expect "existing tag, on origin" "$HEAD_SHA 1" "$(resolve v0.1.0)"
# Someone moved the tag on origin: a refusal, never a pick.
git_q commit --allow-empty -m two
git_q tag -f -a v0.1.0 -m moved
expect "local and origin tag disagree: refused" "" "$(resolve v0.1.0)"

if [[ "$status" == 0 ]]; then echo "release-lib selftest: all passed"; fi
exit "$status"
