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
expect "ask_required: end of input fails, not loops" 1 \
  "$( (x="$(ask_required q </dev/null 2>/dev/null)" || exit 1); echo $?)"
expect "ask_version: re-asks on junk, drops a v" "1.2.3" "$(printf 'junk\nv1.2.3\n' | ask_version 0.0.1 2>/dev/null)"
expect "ask_version: end of input fails, not loops" 1 \
  "$( (x="$(ask_version 0.0.1 </dev/null 2>/dev/null)" || exit 1); echo $?)"
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

# ── version bump and CHANGELOG cut ───────────────────────────────────────────

version_valid 1.2.3 && pass "version_valid: X.Y.Z" || fail "version_valid: X.Y.Z"
version_valid 1.2.3-rc.1 && pass "version_valid: prerelease" || fail "version_valid: prerelease"
version_valid 1.2 && fail "version_valid: X.Y refused" || pass "version_valid: X.Y refused"
version_valid 1.2.3+4 && fail "version_valid: +N refused" || pass "version_valid: +N refused"
version_gt 0.10.0 0.9.9 && pass "version_gt: numeric, not string" || fail "version_gt: numeric, not string"
version_gt 1.0.0 1.0.0 && fail "version_gt: equal is not greater" || pass "version_gt: equal is not greater"
version_gt 1.0.0 1.0.0-rc1 && pass "version_gt: release beats prerelease" || fail "version_gt: release beats prerelease"
version_gt 1.0.0-rc2 1.0.0-rc1 && pass "version_gt: rc2 > rc1" || fail "version_gt: rc2 > rc1"
version_gt 0.9.0 1.0.0-rc1 && fail "version_gt: lower core" || pass "version_gt: lower core"
expect "version_bump patch" "0.3.8" "$(version_bump patch 0.3.7)"
expect "version_bump minor" "0.4.0" "$(version_bump minor 0.3.7)"
expect "version_bump major drops a prerelease" "2.0.0" "$(version_bump major 1.9.9-rc1)"
expect "pubspec_set_version keeps +N and the rest" $'name: x\nversion: 0.2.0+7 # c\nfoo: version: 1' \
  "$(printf 'name: x\nversion: 0.1.0+7 # c\nfoo: version: 1\n' | pubspec_set_version 0.2.0)"
expect "pubspec_set_version without +N" "version: 1.0.0" \
  "$(printf 'version:   0.9.0\n' | pubspec_set_version 1.0.0)"

cat >"$TMP/unrel.md" <<'EOF'
# Changelog

## Unreleased

### Added

- the new thing


## [0.1.0] - 2026-11-20

- one
EOF
expect "changelog_cut: entries move under a dated heading" "# Changelog

## Unreleased

## [0.2.0] - 2026-12-01

### Added

- the new thing

## [0.1.0] - 2026-11-20

- one" "$(changelog_cut 0.2.0 2026-12-01 <"$TMP/unrel.md")"
expect "changelog_cut: the result parses" $'### Added\n\n- the new thing' \
  "$(changelog_cut 0.2.0 2026-12-01 <"$TMP/unrel.md" | changelog_section 0.2.0)"
expect "changelog_cut: bracketed heading, last section, link refs kept" \
  $'## [Unreleased]\n\n## [1.0.0] - d\n\n- a\n\n[0.1.0]: https://example.invalid' \
  "$(printf '## [Unreleased]\n- a\n\n[0.1.0]: https://example.invalid\n' | changelog_cut 1.0.0 d)"
expect "changelog_cut: no blank line added at EOF" $'## Unreleased\n\n## [1.0.0] - d\n\n- a' \
  "$(printf '## Unreleased\n\n- a\n' | changelog_cut 1.0.0 d)"
expect "changelog_cut: placeholder only is empty (2)" 2 \
  "$(printf '## Unreleased\n\nNothing yet :p\n\n## [0.0.0] - x\n' | changelog_cut 0.1.0 d >/dev/null; echo $?)"
expect "changelog_cut: placeholder dropped beside entries" $'## Unreleased\n\n## [0.1.0] - d\n\n- real' \
  "$(printf '## Unreleased\n\nNothing yet.\n- real\n' | changelog_cut 0.1.0 d)"
expect "changelog_cut: existing section refused (3)" 3 \
  "$(changelog_cut 0.1.0 d <"$TMP/unrel.md" >/dev/null; echo $?)"
expect "changelog_cut: no Unreleased heading (4)" 4 \
  "$(printf '# C\n\n## [0.1.0] - x\n' | changelog_cut 0.2.0 d >/dev/null; echo $?)"

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

# ── preparing the release commit against the throwaway origin ────────────────

git_q reset --hard origin/main
cp "$TMP/unrel.md" CHANGELOG.md
printf 'name: x\nversion: 0.1.0+1\n' >pubspec.yaml
git_q add -A && git_q commit -m notes && git_q push origin HEAD:main
git_q fetch origin main --tags
RELEASE_SHA="$(git rev-parse origin/main)"
PROJECT_DIR="$TMP/work"
LB_RELEASE_PREP_WORKTREE="$TMP/prep"
TODAY="$(date +%F)"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
# The PR is the one outward step with no throwaway stand-in: record the call.
# shellcheck disable=SC2329  # called by the sourced lib, not here
gh() {
  printf '%s\n' "$*" >>"$TMP/gh.log"
  if [[ "$1 $2" == "pr create" ]]; then echo https://example.invalid/pr/1; fi
}

# git's v:refname sort ranks v0.1.0-rc1 above v0.1.0; latest_tag_version must not.
git_q tag v0.1.0-rc1 "$RELEASE_SHA"
expect "latest_tag_version: a release outranks its rc" "0.1.0" "$(latest_tag_version)"
expect "check_new_version: an rc below the release tag" 1 \
  "$( (check_new_version 0.1.0-rc2 >/dev/null 2>&1); echo $?)"
git_q tag -d v0.1.0-rc1
expect "check_new_version: not above the latest tag" 1 \
  "$( (check_new_version 0.0.5 >/dev/null 2>&1); echo $?)"
expect "check_new_version: an existing tag" 1 "$( (check_new_version 0.1.0 >/dev/null 2>&1); echo $?)"
VERSION=0.1.0
expect "suggest_version: next patch once tagged" "0.1.1" "$(suggest_version)"
VERSION=0.2.0
expect "suggest_version: an untagged bump already on main" "0.2.0" "$(suggest_version)"

# Answers: commit y, push and PR y. A subshell, since die exits.
( prepare_release_commit 0.2.0 && open_release_pr 0.2.0 ) <<<$'y\ny' >/dev/null 2>&1
expect "prep: branch pushed to origin" 1 \
  "$(git ls-remote --heads origin refs/heads/release/v0.2.0 | wc -l | tr -d ' ')"
expect "prep: pubspec bumped" "0.2.0" "$(git show release/v0.2.0:pubspec.yaml | pubspec_version)"
expect "prep: CHANGELOG dated today" "## [0.2.0] - $TODAY" \
  "$(git show release/v0.2.0:CHANGELOG.md | changelog_heading 0.2.0)"
expect "prep: one commit on top of main" "$RELEASE_SHA" "$(git rev-parse release/v0.2.0~1)"
expect "prep: only the two files change" $'CHANGELOG.md\npubspec.yaml' \
  "$(git diff --name-only "$RELEASE_SHA" release/v0.2.0)"
[[ ! -e "$TMP/prep" ]] && pass "prep: worktree removed after push" ||
  fail "prep: worktree removed after push"
grep -q -- '--head release/v0.2.0' "$TMP/gh.log" 2>/dev/null && pass "prep: PR opened for the branch" ||
  fail "prep: PR opened for the branch"
expect "prep: the user's checkout is untouched" "" "$(git status --porcelain)"
expect "prep again: branch already on origin is status 1" 1 \
  "$( (prepare_release_commit 0.2.0 </dev/null >/dev/null 2>&1); echo $?)"

# Declining the commit leaves nothing behind.
( prepare_release_commit 0.3.0 ) <<<'n' >/dev/null 2>&1
git rev-parse -q --verify refs/heads/release/v0.3.0 >/dev/null &&
  fail "prep declined: branch discarded" || pass "prep declined: branch discarded"
[[ ! -e "$TMP/prep" ]] && pass "prep declined: worktree discarded" ||
  fail "prep declined: worktree discarded"

if [[ "$status" == 0 ]]; then echo "release-lib selftest: all passed"; fi
exit "$status"
