#!/usr/bin/env bash
# Copyright 2026 Pigs Can Fly Labs LLC
# SPDX-License-Identifier: Apache-2.0
#
# The guided store release, shared by scripts/release-android.sh and
# scripts/release-apple.sh. Sourced, not executed: each entry script defines
# the platform_* hooks below and then calls release_main.
#
# It walks docs/RELEASE.md's "Cutting a release" checklist in order, runs every
# step a shell can run, and stops to tell the release manager exactly what to
# do (and waits) for every step that happens in a store console or on a phone.
# The build itself is still scripts/release.sh; nothing here relaxes its
# guards, and none of LB_RELEASE_UNTAGGED / _DIRTY / _DEBUG_SIGNED is ever set.
#
# Two ways in, asked at the start (or given as a flag):
#
#   --new-tag [X.Y.Z]  cut vX.Y.Z on the CI-green tip of origin/main: tests,
#                      phone preflight, local tag, build, static checks, THEN
#                      push the tag. With a version (or when main is not
#                      ready), it first prepares the release commit itself:
#                      pubspec.yaml's version bumped and CHANGELOG.md's
#                      Unreleased entries moved under a dated [X.Y.Z]
#                      heading, committed straight onto main (only those two
#                      files change, so the CI gate takes the parent's green
#                      run). If main refuses the push, it opens a PR instead
#                      and carries on once that merges.
#   --from-tag vX.Y.Z  build an existing tag (the other platform's script, or
#                      an earlier run, already cut it). Pushes it if it is
#                      only local.
#
# State lives in a release record outside every worktree (docs/RELEASE.md's
# KEY=value list, plus *_DONE_SHA markers), so an interrupted run can be
# re-run with --from-tag and offers to skip what already passed for the same
# commit:
#
#   ../liberatedbread-release-records/<version>/release-record.txt
#   ../liberatedbread-release-records/<version>/logs/        build logs
#   ../liberatedbread-release-records/<version>/artifacts/   uploaded AAB/IPA
#
# Environment:
#   LB_RELEASE_REMOTE      git remote to release from (default: origin)
#   LB_RELEASE_HOME        record directory (default: above)
#   LB_RELEASE_WORKTREE    release worktree (default:
#                          ../liberatedbread-release-<version>, as the docs)
#   LB_RELEASE_PREP_WORKTREE  where the release commit is prepared (default:
#                          ../liberatedbread-release-prep-<version>; removed
#                          once the branch is pushed)
#
# Hooks each entry script defines (all run inside the release worktree):
#   platform_preflight     host tools, signing material — before anything slow
#   platform_gates         print the platform's one-time gates (Step 1.2)
#   platform_device_tests  the physical-phone preflight (Step 3)
#   platform_build         build; set ARTIFACT and BUILD_NUMBER (Step 4)
#   platform_verify        static checks on ARTIFACT (Step 4)
#   platform_upload        to closed testing (Step 5)
#   platform_closed_test   install the closed-testing build on a phone
#   platform_publish       submit / promote / release (Step 7)
# and these variables: PLATFORM (android|ios), PLATFORM_KEY (ANDROID|IOS, for
# record keys), PLATFORM_NAME, BUILD_NUMBER_KEY, ARTIFACT_SHA_KEY.
#
# Written for bash 3.2 too (macOS's /bin/bash): no ${x,,}/${x^^}, no mapfile,
# no empty arrays under set -u.

# shellcheck disable=SC2034  # variables here are read by the entry scripts

RELEASE_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$RELEASE_LIB_DIR/.." && pwd)"
FLUTTER_HOME="${FLUTTER_HOME:-$HOME/.flutter-sdk}"
export PATH="${FLUTTER_HOME}/bin:$HOME/.cargo/bin:$PATH"

REMOTE="${LB_RELEASE_REMOTE:-origin}"
GITHUB_RELEASES_URL="https://github.com/liberatedbread/liberatedbread-mobile/releases"

# ── output ───────────────────────────────────────────────────────────────────

log()  { printf '\033[1;32m[release]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[release]\033[0m %s\n' "$*" >&2; }
err()  { printf '\033[1;31m[release]\033[0m %s\n' "$*" >&2; }
die()  { err "$@"; exit 1; }

# A numbered step heading, so a long run's scrollback shows where it is.
step() { printf '\n\033[1;36m══ %s ══\033[0m\n' "$*"; }

# Indented instructions for the human: one argument per line.
say() { local line; for line in "$@"; do printf '   %s\n' "$line"; done; }

lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

# ── prompts ──────────────────────────────────────────────────────────────────
#
# All of them read stdin, so the selftest can drive them with a here-string;
# release_main insists stdin is a terminal before the first one.

# ask PROMPT [DEFAULT] — prints the answer (the default on an empty line).
ask() {
  local prompt="$1" default="${2:-}" answer
  if [[ -n "$default" ]]; then
    printf '\033[1m?\033[0m %s [%s]: ' "$prompt" "$default" >&2
  else
    printf '\033[1m?\033[0m %s: ' "$prompt" >&2
  fi
  IFS= read -r answer || die "No answer (end of input); stopping."
  printf '%s\n' "${answer:-$default}"
}

# ask_required PROMPT — like ask, but repeats until the answer is non-empty.
# The `|| return 1`s: ask's die only ends its $(...) subshell, so without
# them end of input would re-prompt forever whenever a caller has disabled
# errexit (any `x="$(ask_required ...)" || ...`).
ask_required() {
  local answer=""
  while [[ -z "$answer" ]]; do answer="$(ask "$1")" || return 1; done
  printf '%s\n' "$answer"
}

# confirm QUESTION [y|n] — status 0 for yes. Default n.
confirm() {
  local question="$1" default="${2:-n}" hint answer
  [[ "$default" == y ]] && hint="Y/n" || hint="y/N"
  while true; do
    printf '\033[1m?\033[0m %s [%s]: ' "$question" "$hint" >&2
    IFS= read -r answer || die "No answer (end of input); stopping."
    answer="$(lower "${answer:-$default}")"
    case "$answer" in
      y|yes) return 0 ;;
      n|no)  return 1 ;;
    esac
  done
}

# pause — wait until the human has done what was just described. `q` stops
# the run; nothing done so far is undone, and the record says where it got.
pause() {
  local answer
  printf '\033[1m→\033[0m Press Enter when done (q to stop here): ' >&2
  IFS= read -r answer || die "No answer (end of input); stopping."
  if [[ "$(lower "$answer")" == q ]]; then
    log "Stopped. Re-run with --from-tag (or the same choice) to pick up here."
    exit 0
  fi
}

# choose QUESTION OPTION... — prints the 1-based number of the choice.
choose() {
  local question="$1" i answer
  shift
  printf '\033[1m?\033[0m %s\n' "$question" >&2
  for ((i = 1; i <= $#; i++)); do printf '   %d) %s\n' "$i" "${!i}" >&2; done
  while true; do
    printf '   choice [1-%d]: ' "$#" >&2
    IFS= read -r answer || die "No answer (end of input); stopping."
    if [[ "$answer" =~ ^[0-9]+$ ]] && ((answer >= 1 && answer <= $#)); then
      printf '%s\n' "$answer"
      return 0
    fi
  done
}

# checklist ITEM... — every item must be confirmed; any "no" stops the run.
checklist() {
  local item
  for item in "$@"; do
    confirm "$item" || die "Not confirmed: $item" \
      "— any failure stops the release here. Fix it, then re-run."
  done
}

open_url() {
  say "Open: $1"
  if command -v open &>/dev/null && [[ "$(uname -s)" == Darwin ]]; then
    open "$1" 2>/dev/null || true
  elif command -v xdg-open &>/dev/null && [[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]]; then
    xdg-open "$1" &>/dev/null || true
  fi
}

# ── small pure helpers (covered by scripts/release-lib-selftest.sh) ──────────

# pubspec_version — the X.Y.Z of the pubspec.yaml on stdin, same regex as
# release.sh, so the two can never disagree about it.
pubspec_version() {
  sed -n 's/^version:[[:space:]]*\([^+[:space:]]*\).*/\1/p'
}

# changelog_heading VERSION < CHANGELOG.md — the `## [X.Y.Z] ...` line, if any.
changelog_heading() {
  local v="${1//./\\.}"
  grep -E "^## \[$v\]" | head -n 1 || true
}

# changelog_section VERSION < CHANGELOG.md — the section's body: everything
# after its heading up to the next `## [` heading (or a link-reference block),
# leading and trailing blank lines trimmed.
changelog_section() {
  awk -v want="## [$1]" '
    index($0, want) == 1 { on = 1; next }
    on && (/^## \[/ || /^\[[^]]+\]: /) { exit }
    on { lines[n++] = $0 }
    END {
      first = 0; while (first < n && lines[first] ~ /^[[:space:]]*$/) first++
      last = n - 1; while (last >= first && lines[last] ~ /^[[:space:]]*$/) last--
      for (i = first; i <= last; i++) print lines[i]
    }'
}

# version_valid VERSION — status 0 for X.Y.Z, optionally with a -prerelease.
# No +build: the pubspec's +N is the build number, which release.sh sets.
version_valid() {
  [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$ ]]
}

# version_gt A B — status 0 when A is a later version than B. Numeric on
# X.Y.Z; with equal cores a release beats a prerelease, and two prereleases
# compare as strings (enough for -rc1 < -rc2; not full semver precedence).
version_gt() {
  local a="$1" b="$2" a_pre="" b_pre="" a1 a2 a3 b1 b2 b3
  if [[ "$a" == *-* ]]; then a_pre="${a#*-}"; a="${a%%-*}"; fi
  if [[ "$b" == *-* ]]; then b_pre="${b#*-}"; b="${b%%-*}"; fi
  IFS=. read -r a1 a2 a3 <<<"$a"
  IFS=. read -r b1 b2 b3 <<<"$b"
  if ((10#$a1 != 10#$b1)); then ((10#$a1 > 10#$b1)); return; fi
  if ((10#$a2 != 10#$b2)); then ((10#$a2 > 10#$b2)); return; fi
  if ((10#$a3 != 10#$b3)); then ((10#$a3 > 10#$b3)); return; fi
  [[ -z "$a_pre" && -n "$b_pre" ]] && return 0
  [[ -n "$a_pre" && -n "$b_pre" && "$a_pre" > "$b_pre" ]]
}

# version_bump patch|minor|major VERSION — the next version of that kind
# (a prerelease suffix is dropped).
version_bump() {
  local x y z
  IFS=. read -r x y z <<<"${2%%-*}"
  case "$1" in
    major) printf '%d.0.0\n' "$((10#$x + 1))" ;;
    minor) printf '%d.%d.0\n' "$((10#$x))" "$((10#$y + 1))" ;;
    *)     printf '%d.%d.%d\n' "$((10#$x))" "$((10#$y))" "$((10#$z + 1))" ;;
  esac
}

# pubspec_set_version VERSION < pubspec.yaml — the same file with the first
# version: line's X.Y.Z replaced. Its +N (ignored by release.sh) and anything
# after it are kept, so the diff is that one number.
pubspec_set_version() {
  NEW="$1" awk '
    !done && /^version:/ {
      sub(/^version:[[:space:]]*[^+[:space:]#]*/, "version: " ENVIRON["NEW"])
      done = 1
    }
    { print }'
}

# changelog_cut VERSION DATE < CHANGELOG.md — the same file with the entries
# under its Unreleased heading (`## Unreleased` or `## [Unreleased]`) moved
# into a new `## [VERSION] - DATE` section right below it, and the Unreleased
# heading left in place with nothing under it. Placeholder lines ("Nothing
# yet") are dropped rather than released. Exit status, with nothing useful on
# stdout: 2 the Unreleased section has no entries, 3 a [VERSION] section
# already exists, 4 there is no Unreleased heading.
changelog_cut() {
  V="$1" D="$2" awk '
    function flush(   first, last, i) {
      first = 0; while (first < n && body[first] ~ /^[[:space:]]*$/) first++
      last = n - 1; while (last >= first && body[last] ~ /^[[:space:]]*$/) last--
      if (first > last) { bad = 2; exit 2 }
      out[m++] = ""
      out[m++] = "## [" ENVIRON["V"] "] - " ENVIRON["D"]
      out[m++] = ""
      for (i = first; i <= last; i++) out[m++] = body[i]
      out[m++] = ""
      state = 2
    }
    index($0, "## [" ENVIRON["V"] "]") == 1 { bad = 3; exit }
    state == 0 && tolower($0) ~ /^## \[?unreleased\]?[[:space:]]*$/ {
      out[m++] = $0; state = 1; next
    }
    state == 1 && (/^## / || /^\[[^]]+\]: /) { flush() }
    state == 1 {
      if (tolower($0) !~ /^[[:space:]]*_?nothing yet/) body[n++] = $0
      next
    }
    { out[m++] = $0 }
    END {
      if (!bad && state == 1) { flush(); m-- }   # no blank line at EOF
      if (!bad && state == 0) bad = 4
      if (bad) exit bad
      for (i = 0; i < m; i++) print out[i]
    }'
}

# bump_only_commit SHA — status 0 when SHA has one parent and changes nothing
# but pubspec.yaml's version: line and CHANGELOG.md: a release commit, which
# needs no CI run of its own (its parent's covers every line that is built
# or tested). Anything else, or a parent missing from a shallow clone, is 1.
bump_only_commit() {
  local sha="$1" files f
  [[ "$(git rev-list --parents -n 1 "$sha" 2>/dev/null | wc -w | tr -d ' ')" == 2 ]] || return 1
  files="$(git diff --name-only "$sha^" "$sha" 2>/dev/null)" || return 1
  [[ -n "$files" ]] || return 1
  for f in $files; do
    case "$f" in pubspec.yaml | CHANGELOG.md) ;; *) return 1 ;; esac
  done
  ! git diff -U0 "$sha^" "$sha" -- pubspec.yaml |
    grep -E '^[-+]' | grep -vE '^(\+\+\+|---) ' | grep -qvE '^[-+]version:'
}

# build_number_from_log — the --build-number release.sh logged.
build_number_from_log() {
  sed -n 's/.*--build-number=\([0-9][0-9]*\).*/\1/p' | head -n 1
}

# record_get FILE KEY — the value, or nothing.
record_get() {
  [[ -f "$1" ]] || return 0
  sed -n "s/^$2=//p" "$1" | tail -n 1
}

# record_set FILE KEY VALUE — replace the KEY= line, or append one.
record_set() {
  local file="$1" key="$2" value="$3" tmp
  [[ "$value" != *$'\n'* ]] || die "record_set $key: value has a newline"
  tmp="$(mktemp "$file.XXXXXX")"
  if [[ -f "$file" ]] && grep -q "^$key=" "$file"; then
    KEY="$key" VALUE="$value" awk '
      BEGIN { k = ENVIRON["KEY"] "=" }
      index($0, k) == 1 { print k ENVIRON["VALUE"]; next }
      { print }' "$file" >"$tmp"
  else
    { [[ -f "$file" ]] && cat "$file"; printf '%s=%s\n' "$key" "$value"; } >"$tmp"
  fi
  mv "$tmp" "$file"
}

sha256_of() {
  if command -v sha256sum &>/dev/null; then
    sha256sum "$1" | awk '{ print $1 }'
  else
    shasum -a 256 "$1" | awk '{ print $1 }'
  fi
}

utc_stamp() { date -u +%Y%m%dT%H%M%SZ; }

# ── record-backed resumption ─────────────────────────────────────────────────

record() { record_set "$RECORD" "$@"; }
recorded() { record_get "$RECORD" "$1"; }

# already_done MARKER WHAT — status 0 when MARKER was set for this exact
# commit by an earlier run AND the human agrees to skip it.
already_done() {
  if [[ "$(recorded "$1")" == "$RELEASE_SHA" ]]; then
    confirm "$2 already passed for $SHORT_SHA in an earlier run. Skip it?" y
    return
  fi
  return 1
}
mark_done() { record "$1" "$RELEASE_SHA"; }

# record_url KEY PROMPT — ask for a console URL/number and keep it.
record_url() {
  local current answer
  current="$(recorded "$1")"
  answer="$(ask "$2" "$current")"
  if [[ -n "$answer" ]]; then record "$1" "$answer"; fi
}

# ── steps ────────────────────────────────────────────────────────────────────

usage() {
  cat >&2 <<EOF
Usage: $(basename "$0") [--new-tag [X.Y.Z] | --from-tag vX.Y.Z]

Guided $PLATFORM_NAME store release (docs/RELEASE.md). Asks which of the two
modes when neither flag is given:
  --new-tag          tag pubspec.yaml's version on CI-green $REMOTE/main,
                     build, check, then push the tag
  --new-tag X.Y.Z    the same, releasing X.Y.Z: if $REMOTE/main is not there
                     yet, bump pubspec.yaml, date CHANGELOG.md's Unreleased
                     entries as [X.Y.Z], and push that commit to main first
  --from-tag vX.Y.Z  build an existing tag (pushing it first if only local)
EOF
}

parse_args() {
  MODE="" TAG="" WANT_VERSION=""
  while (($#)); do
    case "$1" in
      --new-tag)
        MODE=new
        # An optional version: the next word, if it looks like one.
        if [[ $# -ge 2 ]] && version_valid "${2#v}"; then
          WANT_VERSION="${2#v}"
          shift
        fi
        ;;
      --new-tag=*)
        MODE=new WANT_VERSION="${1#*=}"
        WANT_VERSION="${WANT_VERSION#v}"
        version_valid "$WANT_VERSION" ||
          die "--new-tag=$WANT_VERSION: not an X.Y.Z version."
        ;;
      --from-tag)
        [[ $# -ge 2 ]] || { usage; exit 1; }
        MODE=existing TAG="$2"
        shift
        ;;
      --from-tag=*) MODE=existing TAG="${1#*=}" ;;
      -h|--help) usage; exit 0 ;;
      *) usage; exit 1 ;;
    esac
    shift
  done
  if [[ "$MODE" == existing && -n "$WANT_VERSION" ]]; then
    die "--from-tag builds a tag as it is; a new version goes with --new-tag X.Y.Z."
  fi
}

check_tools() {
  local tool
  for tool in git gh flutter awk sed; do
    command -v "$tool" &>/dev/null ||
      die "$tool not found. Run ./scripts/setup.sh (and install the GitHub CLI for gh)."
  done
  gh auth status &>/dev/null ||
    die "gh is not signed in; the CI gate reads runs through it. Run: gh auth login"
}

choose_mode() {
  [[ -n "$MODE" ]] && return
  local pick
  pick="$(choose "How is this release being made?" \
    "Cut a NEW tag from $REMOTE/main (tag is pushed after the build checks pass)" \
    "Build from an EXISTING tag (already cut, e.g. by the other platform's script)")" || exit 1
  case "$pick" in
    1) MODE=new ;;
    2) MODE=existing ;;
  esac
}

# remote_tag_sha TAG — the commit TAG names on the remote, or nothing.
remote_tag_sha() {
  local out
  out="$(git ls-remote --tags "$REMOTE" "refs/tags/$1" "refs/tags/$1^{}")" ||
    die "Could not list tags on $REMOTE."
  # An annotated tag lists twice; the ^{} line is the commit.
  { grep '\^{}$' <<<"$out" || printf '%s\n' "$out"; } | awk 'NF { print $1; exit }'
}

resolve_existing_tag() {
  if [[ -z "$TAG" ]]; then
    local latest
    latest="$(git tag --list 'v*' --sort=-v:refname | head -n 1)"
    [[ -n "$latest" ]] || die "No v* tags exist. Choose 'cut a new tag' instead."
    log "Most recent tags:"
    git tag --list 'v*' --sort=-v:refname | head -n 5 | sed 's/^/   /' >&2
    TAG="$(ask "Tag to release" "$latest")"
  fi
  git rev-parse -q --verify "refs/tags/$TAG" >/dev/null ||
    die "No tag $TAG here (fetched from $REMOTE too)."
  [[ "$(git cat-file -t "$TAG")" == tag ]] ||
    warn "$TAG is a lightweight tag; docs/RELEASE.md cuts annotated ones (git tag -a)."
  RELEASE_SHA="$(git rev-parse "$TAG^{commit}")"
  VERSION="$(git show "$RELEASE_SHA:pubspec.yaml" | pubspec_version)"
  [[ "$TAG" == "v$VERSION" ]] ||
    die "$TAG's pubspec.yaml says $VERSION. release.sh would refuse it; a tag is never moved, so cut v$VERSION instead."

  local remote_sha
  remote_sha="$(remote_tag_sha "$TAG")"
  if [[ -z "$remote_sha" ]]; then
    TAG_ON_REMOTE=0
    warn "$TAG exists only locally. It will be pushed after the build checks pass."
  elif [[ "$remote_sha" != "$RELEASE_SHA" ]]; then
    die "$TAG is $RELEASE_SHA here but $remote_sha on $REMOTE. Never move a tag; find out which one was uploaded."
  else
    TAG_ON_REMOTE=1
  fi
}

# latest_tag_version — the highest vX.Y.Z tag's X.Y.Z by version_gt, or
# nothing. Not git's --sort=v:refname: without versionsort.suffix it ranks
# v1.0.0-rc1 above v1.0.0, which would let a release go out below a tag.
latest_tag_version() {
  local t v best=""
  for t in $(git tag --list 'v*'); do
    v="${t#v}"
    version_valid "$v" || continue
    if [[ -z "$best" ]] || version_gt "$v" "$best"; then best="$v"; fi
  done
  printf '%s\n' "$best"
}

# ask_version DEFAULT — prompt until the answer is an X.Y.Z (a leading v is
# dropped). Prints it.
ask_version() {
  local answer
  while true; do
    answer="$(ask "New version (X.Y.Z)" "$1")" || return 1
    answer="${answer#v}"
    version_valid "$answer" && break
    err "'$answer' is not an X.Y.Z version."
  done
  printf '%s\n' "$answer"
}

# suggest_version — the version to release from RELEASE_SHA: its own pubspec
# version if that has never been tagged and is above every tag (the bump
# landed, the CHANGELOG cut did not), else the next patch after the highest
# tag. A minor or major release is asked for with --new-tag X.Y.Z.
suggest_version() {
  local latest
  latest="$(latest_tag_version)"
  if [[ -z "$latest" ]] || version_gt "$VERSION" "$latest"; then
    printf '%s\n' "$VERSION"
  else
    version_bump patch "$latest"
  fi
}

# check_new_version NEW — die unless NEW can be released: a valid version,
# not tagged already, and above the highest existing tag.
check_new_version() {
  local new="$1" latest
  version_valid "$new" || die "'$new' is not an X.Y.Z version."
  if git rev-parse -q --verify "refs/tags/v$new" >/dev/null; then
    die "v$new already exists; tags are never reused. Pick a later version."
  fi
  latest="$(latest_tag_version)"
  if [[ -n "$latest" ]] && ! version_gt "$new" "$latest"; then
    die "$new is not above the latest tag, v$latest."
  fi
}

# prepare_release_commit NEW — Step 1.1 done for the human: on a new branch
# release/vNEW off RELEASE_SHA ($REMOTE/main), in a scratch worktree, set
# pubspec.yaml's version to NEW and move CHANGELOG.md's Unreleased entries
# under `## [NEW] - <today>`, then commit. The human's checkout is never
# touched. Sets PREP_BRANCH and PREP_DIR; status 1 when there is nothing to
# do because the branch is already on $REMOTE (its PR is just not merged).
prepare_release_commit() {
  local new="$1" today old rc tmp editor
  today="$(date +%F)"
  PREP_BRANCH="release/v$new"
  PREP_DIR="${LB_RELEASE_PREP_WORKTREE:-$(dirname "$PROJECT_DIR")/liberatedbread-release-prep-$new}"
  check_new_version "$new"

  if [[ -n "$(git ls-remote --heads "$REMOTE" "refs/heads/$PREP_BRANCH")" ]]; then
    local pr
    pr="$(gh pr view "$PREP_BRANCH" --json url,state --jq '.url + " (" + .state + ")"' 2>/dev/null || true)"
    warn "$PREP_BRANCH is already on $REMOTE${pr:+: $pr}."
    warn "Get it merged into main (or delete the branch on $REMOTE to start over)."
    return 1
  fi
  [[ ! -e "$PREP_DIR" ]] ||
    die "$PREP_DIR already exists (an earlier, unfinished prep?)." \
      "Inspect it, then: git worktree remove \"$PREP_DIR\" and re-run."
  if git rev-parse -q --verify "refs/heads/$PREP_BRANCH" >/dev/null; then
    die "A local branch $PREP_BRANCH already exists. Push it and open its PR," \
      "or delete it (git branch -D $PREP_BRANCH) to start over."
  fi

  step "Prepare the $new release commit (docs/RELEASE.md Step 1.1)"
  git worktree add --quiet -b "$PREP_BRANCH" "$PREP_DIR" "$RELEASE_SHA" ||
    die "git worktree add $PREP_DIR failed."
  cd "$PREP_DIR" || die "cd $PREP_DIR failed."

  old="$(pubspec_version <pubspec.yaml)"
  if [[ "$old" != "$new" ]]; then
    tmp="$(mktemp pubspec.yaml.XXXXXX)"
    pubspec_set_version "$new" <pubspec.yaml >"$tmp" && mv "$tmp" pubspec.yaml
    [[ "$(pubspec_version <pubspec.yaml)" == "$new" ]] ||
      discard_prep "Could not rewrite pubspec.yaml's version: line."
    log "pubspec.yaml: $old → $new"
  fi

  editor="${VISUAL:-${EDITOR:-}}"
  while true; do
    tmp="$(mktemp CHANGELOG.md.XXXXXX)"
    rc=0
    changelog_cut "$new" "$today" <CHANGELOG.md >"$tmp" || rc=$?
    if [[ "$rc" == 0 ]]; then mv "$tmp" CHANGELOG.md; break; fi
    rm -f "$tmp"
    case "$rc" in
      3) discard_prep "CHANGELOG.md on $REMOTE/main already has a [$new] section;" \
           "date it by hand (or pick another version)." ;;
      4) discard_prep "CHANGELOG.md on $REMOTE/main has no '## Unreleased' heading to release." ;;
    esac
    # rc 2: nothing under Unreleased. Notes are normally written PR by PR,
    # but they can be written here, as part of the release commit.
    warn "CHANGELOG.md's Unreleased section has no entries, so there is nothing to"
    warn "put under [$new] (or in the store and GitHub release notes)."
    # $editor unquoted on purpose: EDITOR="code -w" is a command and a flag.
    # shellcheck disable=SC2086
    if [[ -n "$editor" ]] && confirm "Write them now in $editor ($PREP_DIR/CHANGELOG.md)?" y; then
      $editor CHANGELOG.md || true
    elif confirm "Write them under '## Unreleased' in $PREP_DIR/CHANGELOG.md yourself, then continue?" y; then
      pause
    else
      discard_prep "Stopped: no CHANGELOG entries to release."
    fi
  done
  log "CHANGELOG.md: Unreleased entries now under '## [$new] - $today'."

  say "" "The release commit's changes:"
  git --no-pager diff --stat >&2
  changelog_section "$new" <CHANGELOG.md | head -n 30 | sed 's/^/   │ /' >&2
  say "" "These notes become the GitHub Release and the start of the store notes."
  # shellcheck disable=SC2086
  if [[ -n "$editor" ]] && confirm "Edit CHANGELOG.md in $editor before committing?" n; then
    $editor CHANGELOG.md || true
    [[ -n "$(changelog_heading "$new" <CHANGELOG.md)" ]] ||
      discard_prep "The edited CHANGELOG.md lost its '## [$new]' heading."
  fi
  confirm "Commit this on $PREP_BRANCH as 'Release $new'?" y ||
    discard_prep "Stopped before committing; nothing was pushed."

  git add pubspec.yaml CHANGELOG.md
  git commit --quiet -m "Release $new" \
    -m "Bump pubspec.yaml to $new and move CHANGELOG.md's Unreleased entries under [$new] - $today (docs/RELEASE.md Step 1.1)." ||
    discard_prep "git commit failed."
  require_clean "The prep worktree $PREP_DIR"
  log "Committed $(git log -1 --format='%h %s') on $PREP_BRANCH."
  cd "$PROJECT_DIR" || die "cd $PROJECT_DIR failed."
}

# discard_prep MESSAGE... — undo a prepare_release_commit that will not be
# pushed (the worktree and branch it made, nothing else), then die.
discard_prep() {
  cd "$PROJECT_DIR" || true
  git worktree remove --force "$PREP_DIR" 2>/dev/null || true
  git branch -D "$PREP_BRANCH" >/dev/null 2>&1 || true
  die "$@"
}

# push_release_commit NEW — put PREP_BRANCH's one commit straight onto
# $REMOTE/main (a fast-forward: the branch is off RELEASE_SHA). It touches
# only pubspec.yaml's version and CHANGELOG.md, so it needs no PR or CI run of
# its own (see bump_only_commit). Status 0 once pushed; when declined or
# refused (branch protection, or main moved on), it offers the PR instead and
# returns 1.
push_release_commit() {
  local new="$1"
  step "Push the release commit to main"
  if confirm "Push 'Release $new' straight onto $REMOTE/main?" y &&
    git push --quiet "$REMOTE" "refs/heads/$PREP_BRANCH:refs/heads/main"; then
    log "$REMOTE/main is now $(git log -1 --format='%h %s' "$PREP_BRANCH")."
    git worktree remove "$PREP_DIR" ||
      warn "Could not remove $PREP_DIR; the commit is on main, so it can go."
    git branch -D "$PREP_BRANCH" >/dev/null 2>&1 || true
    return 0
  fi
  warn "Not pushed to $REMOTE/main (declined, refused by branch protection, or main moved on)."
  open_release_pr "$new"
  return 1
}

# open_release_pr NEW — push PREP_BRANCH and open its PR against main. The
# merge itself stays with the human (and CI, and review), like any change.
open_release_pr() {
  local new="$1" url
  step "Open the release PR"
  if ! confirm "Push $PREP_BRANCH to $REMOTE and open a PR into main?" y; then
    say "Left as local branch $PREP_BRANCH (worktree $PREP_DIR). Push it and" \
      "open its PR yourself; this script waits for it on $REMOTE/main."
    return
  fi
  git push --quiet -u "$REMOTE" "$PREP_BRANCH" || die "Pushing $PREP_BRANCH failed."
  if url="$(gh pr create --base main --head "$PREP_BRANCH" --title "Release $new" \
    --body "Bumps pubspec.yaml to $new and moves CHANGELOG.md's Unreleased entries under [$new], per docs/RELEASE.md Step 1.1. Prepared by scripts/$(basename "$0"); once this is on main with green CI, that run tags v$new.")"; then
    log "PR: $url"
    open_url "$url"
  else
    warn "gh pr create failed; open the PR for $PREP_BRANCH by hand."
  fi
  git worktree remove "$PREP_DIR" ||
    warn "Could not remove $PREP_DIR; the branch is pushed, so it can go."
}

resolve_new_tag() {
  local local_main
  while true; do
    RELEASE_SHA="$(git rev-parse "$REMOTE/main")"
    VERSION="$(git show "$RELEASE_SHA:pubspec.yaml" | pubspec_version)"
    [[ -n "$VERSION" ]] || die "No version: line in pubspec.yaml at $REMOTE/main."
    TAG="v$VERSION"
    log "Release commit: $REMOTE/main = $(git log -1 --format='%h %s' "$RELEASE_SHA")"
    log "Version from pubspec.yaml: $VERSION → tag $TAG"

    local_main="$(git rev-parse -q --verify refs/heads/main || true)"
    if [[ -n "$local_main" && "$local_main" != "$RELEASE_SHA" ]] &&
      ! git merge-base --is-ancestor "$local_main" "$RELEASE_SHA"; then
      warn "Your local main has commits $REMOTE/main does not. A release is cut"
      warn "from what is on $REMOTE/main, never from local commits."
    fi

    local problems="" heading released=0
    if [[ -z "$WANT_VERSION" ]] && git rev-parse -q --verify "refs/tags/$TAG" >/dev/null &&
      [[ "$(git rev-parse "$TAG^{commit}")" != "$RELEASE_SHA" ]]; then
      # $TAG went out from an earlier commit and main has moved on: the usual
      # state between releases, not a mistake. The next version is the next
      # patch after the highest tag, and Step 1.1 is done for you.
      released=1
      WANT_VERSION="$(suggest_version)"
      check_new_version "$WANT_VERSION"
      log "$TAG is already released (on $(git rev-parse --short "$TAG^{commit}")); $REMOTE/main has moved on."
      log "Next version: $WANT_VERSION, the next patch after the highest tag. --new-tag X.Y.Z picks another."
      problems+="pubspec.yaml on $REMOTE/main says $VERSION, not $WANT_VERSION."$'\n'
    elif [[ -n "$WANT_VERSION" && "$WANT_VERSION" != "$VERSION" ]]; then
      problems+="pubspec.yaml on $REMOTE/main says $VERSION, not $WANT_VERSION."$'\n'
    else
      heading="$(git show "$RELEASE_SHA:CHANGELOG.md" 2>/dev/null | changelog_heading "$VERSION")"
      if [[ -z "$heading" ]]; then
        problems+="CHANGELOG.md has no '## [$VERSION] - YYYY-MM-DD' section."$'\n'
      elif ! [[ "$heading" =~ [0-9]{4}-[0-9]{2}-[0-9]{2} ]]; then
        problems+="CHANGELOG.md's '$heading' heading carries no date."$'\n'
      fi
      if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then
        if [[ "$(git rev-parse "$TAG^{commit}")" != "$RELEASE_SHA" ]]; then
          problems+="$TAG already exists on another commit. Bump pubspec.yaml's version; tags are never reused."$'\n'
        fi
      fi
    fi

    if [[ -z "$problems" ]]; then
      if [[ -n "$WANT_VERSION" ]]; then
        confirm "Release $REMOTE/main (${RELEASE_SHA:0:10}) as $TAG?" y ||
          die "Stopped before doing anything."
        break
      fi
      # Captured first: a die inside $(...) only ends the subshell, and a
      # case on its empty output would carry on as if answered.
      local pick
      pick="$(choose "Release $REMOTE/main (${RELEASE_SHA:0:10}) as $TAG?" \
        "Yes, release $TAG" \
        "No, release a new version (bump pubspec.yaml and CHANGELOG.md first)" \
        "Stop")" || exit 1
      case "$pick" in
        1) break ;;
        2) WANT_VERSION="$(ask_version "$(version_bump patch "$VERSION")")" || exit 1
           check_new_version "$WANT_VERSION"
           continue ;;
        3) die "Stopped before doing anything." ;;
      esac
    fi

    if [[ "$released" == 1 ]]; then
      say "" "Preparing it: pubspec.yaml → $WANT_VERSION, CHANGELOG.md's Unreleased entries" \
        "under '## [$WANT_VERSION] - $(date +%F)', committed straight onto $REMOTE/main."
    else
      err "Not ready to cut v${WANT_VERSION:-$VERSION} from $REMOTE/main:"
      printf '%s' "$problems" | sed 's/^/   - /' >&2
      say "" \
        "Step 1 of docs/RELEASE.md: bump pubspec.yaml's version if it is changing," \
        "move CHANGELOG.md's Unreleased entries under '## [X.Y.Z] - $(date +%F)'," \
        "leave a new empty Unreleased section, and get that commit onto $REMOTE/main" \
        "This script can make that commit and push it to main."
    fi
    if [[ "$released" == 1 ]] || confirm "Prepare the release commit now?" y; then
      if [[ -z "$WANT_VERSION" ]]; then
        WANT_VERSION="$(ask_version "$(suggest_version)")" || exit 1
      fi
      if prepare_release_commit "$WANT_VERSION" && push_release_commit "$WANT_VERSION"; then
        git fetch --quiet "$REMOTE" main --tags || die "git fetch $REMOTE failed."
        continue
      fi
      say "" "Merge it into main once CI and review pass. This script then re-checks" \
        "$REMOTE/main and carries on with v$WANT_VERSION."
    fi
    pause
    git fetch --quiet "$REMOTE" main --tags || die "git fetch $REMOTE failed."
  done

  local remote_sha
  remote_sha="$(remote_tag_sha "$TAG")"
  if [[ -n "$remote_sha" ]]; then
    die "$TAG is already on $REMOTE. Use --from-tag $TAG to build it, or bump the version."
  fi
  TAG_ON_REMOTE=0
}

init_record() {
  RELEASE_HOME="${LB_RELEASE_HOME:-$(dirname "$PROJECT_DIR")/liberatedbread-release-records/$VERSION}"
  RECORD="$RELEASE_HOME/release-record.txt"
  mkdir -p "$RELEASE_HOME/logs" "$RELEASE_HOME/artifacts"
  local recorded_sha
  recorded_sha="$(recorded RELEASE_SHA)"
  if [[ -n "$recorded_sha" && "$recorded_sha" != "$RELEASE_SHA" ]]; then
    die "$RECORD belongs to commit $recorded_sha, not $RELEASE_SHA." \
      "Move it aside (it records a different build of $VERSION) and re-run."
  fi
  if [[ ! -f "$RECORD" ]]; then
    cat >"$RECORD" <<EOF
# Liberated Bread release record — docs/RELEASE.md. Filled in by
# scripts/release-android.sh and scripts/release-apple.sh as each step lands.
# Keep this directory (record, logs/, artifacts/) in the release archive.
EOF
  fi
  record VERSION "$VERSION"
  record TAG "$TAG"
  record RELEASE_SHA "$RELEASE_SHA"
  log "Release record: $RECORD"
}

ci_gate() {
  step "CI for $SHORT_SHA"
  if [[ -n "$(recorded CI_RUN_URL)" && "$(recorded CI_DONE_SHA)" == "$RELEASE_SHA" ]]; then
    log "CI already recorded green: $(recorded CI_RUN_URL)"
    return
  fi
  # A release commit that only bumps the version and dates the CHANGELOG is
  # gated on the run for the commit it sits on: nothing it changes is built
  # differently or tested.
  local gate="$RELEASE_SHA" row id status conclusion url
  while bump_only_commit "$gate"; do gate="$(git rev-parse "$gate^")"; done
  if [[ "$gate" != "$RELEASE_SHA" ]]; then
    log "$SHORT_SHA only bumps pubspec.yaml's version and CHANGELOG.md; gating on CI for"
    log "$(git log -1 --format='%h %s' "$gate")."
  fi
  while true; do
    row="$(gh run list --workflow ci.yml --commit "$gate" --limit 1 \
      --json databaseId,status,conclusion,url \
      --jq '.[0] | select(.) | [.databaseId, .status, .url, .conclusion] | @tsv')" ||
      die "gh run list failed."
    if [[ -z "$row" ]]; then
      warn "No CI run for $gate yet. CI runs on every push to main."
      confirm "Check again?" y || die "A release needs a green CI run for its exact commit."
      continue
    fi
    # conclusion last: it is empty while running, and adjacent tabs collapse.
    IFS=$'\t' read -r id status url conclusion <<<"$row"
    if [[ "$status" != completed ]]; then
      log "CI run $url is $status; watching it."
      gh run watch "$id" --interval 30 >/dev/null || true
      continue
    fi
    if [[ "$conclusion" != success ]]; then
      die "CI for $gate concluded '$conclusion': $url" \
        "A failed or cancelled job is a stop, not something to explain in the notes."
    fi
    break
  done
  log "CI green: $url"
  record CI_RUN_URL "$url"
  record CI_GATE_SHA "$gate"
  mark_done CI_DONE_SHA
}

one_time_gates() {
  step "One-time gates (docs/RELEASE.md Step 1.2)"
  if [[ "$(recorded "GATES_${PLATFORM_KEY}_DONE_SHA")" == "$RELEASE_SHA" ]]; then
    log "Already confirmed for this commit."
    return
  fi
  checklist \
    "liberatedbread.com/privacy/ and /disclaimer/ resolve, and the support page shows a contact method" \
    "The privacy policy, store privacy answers and ios/Runner/PrivacyInfo.xcprivacy still describe the app's actual outbound connections"
  platform_gates
  mark_done "GATES_${PLATFORM_KEY}_DONE_SHA"
}

prepare_worktree() {
  step "Clean release worktree"
  RELEASE_DIR="${LB_RELEASE_WORKTREE:-$(dirname "$PROJECT_DIR")/liberatedbread-release-$VERSION}"
  if [[ -e "$RELEASE_DIR" ]]; then
    local head
    head="$(git -C "$RELEASE_DIR" rev-parse HEAD 2>/dev/null)" ||
      die "$RELEASE_DIR exists but is not a git checkout. Move it aside."
    [[ "$head" == "$RELEASE_SHA" ]] ||
      die "$RELEASE_DIR is at $head, not $RELEASE_SHA." \
        "Inspect it, then: git worktree remove \"$RELEASE_DIR\" (no --force) and re-run."
    log "Reusing $RELEASE_DIR (already at $SHORT_SHA)."
  else
    log "git worktree add --detach $RELEASE_DIR $SHORT_SHA"
    git worktree add --detach "$RELEASE_DIR" "$RELEASE_SHA" ||
      die "git worktree add failed."
  fi
  cd "$RELEASE_DIR" || die "cd $RELEASE_DIR failed."
  local actual
  actual="$(pubspec_version <pubspec.yaml)"
  [[ "$actual" == "$VERSION" ]] || die "Worktree pubspec.yaml says $actual, expected $VERSION."
  require_clean "The release worktree"
}

require_clean() {
  local dirty
  dirty="$(git status --porcelain --untracked-files=normal)"
  if [[ -n "$dirty" ]]; then
    err "$1 has changes, so no commit describes what would ship:"
    printf '%s\n' "$dirty" | sed 's/^/  /' >&2
    die "Anything source-controlled that must change is a new commit through CI and a new run."
  fi
}

host_tests() {
  step "Host tests: scripts/test.sh and the network-discovery suites (Step 2)"
  already_done HOST_TESTS_DONE_SHA "The host test suites" && return
  flutter pub get --enforce-lockfile || die "flutter pub get --enforce-lockfile failed."
  run_until_pass "./scripts/test.sh" ./scripts/test.sh
  run_until_pass "./scripts/ci-netdisco-tests.sh" ./scripts/ci-netdisco-tests.sh
  require_clean "The release worktree (after the test runs)"
  mark_done HOST_TESTS_DONE_SHA
}

# run_until_pass LABEL CMD... — a failure offers a retry (flaky hardware, a
# phone that locked) or a stop; it is never waved through.
run_until_pass() {
  local label="$1"
  shift
  while true; do
    log "$label"
    "$@" && return 0
    err "$label failed."
    confirm "Fix whatever is outside the source (phone, network, device) and retry?" y ||
      die "Stopped: $label failed. A failure is a stop, not a note."
  done
}

device_preflight() {
  step "$PLATFORM_NAME physical-phone preflight (Step 3)"
  already_done "PREFLIGHT_${PLATFORM_KEY}_DONE_SHA" "The $PLATFORM_NAME phone preflight" && return
  say "Needs: a $PLATFORM_NAME phone attached to this machine, on a LAN with at least" \
    "one supported device, and a connectable Bluetooth peripheral nearby." \
    "Watch the phone: a fresh install raises the Bluetooth and Local Network prompts."
  pause
  platform_device_tests
  require_clean "The release worktree (after the device runners)"
  mark_done "PREFLIGHT_${PLATFORM_KEY}_DONE_SHA"
}

create_local_tag() {
  if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then
    return
  fi
  step "Tag $TAG (local only, for now)"
  confirm "Every suite passed. Create the annotated tag $TAG on $SHORT_SHA?" y ||
    die "Stopped before tagging."
  git tag -a "$TAG" -m "Liberated Bread $VERSION" "$RELEASE_SHA"
  log "Tagged $TAG locally. It is pushed only after the artifact checks pass."
}

build_and_verify() {
  step "Build and inspect the $PLATFORM_NAME artifact (Step 4)"
  local built archived
  archived="$(recorded "${PLATFORM_KEY}_ARTIFACT")"
  if [[ -n "$archived" && -f "$archived" && "$(recorded "BUILD_${PLATFORM_KEY}_DONE_SHA")" == "$RELEASE_SHA" ]]; then
    log "Built earlier: $archived (build $(recorded "$BUILD_NUMBER_KEY"))."
    if confirm "Reuse it? (No if the store refused it: a re-upload needs a new build number)" y; then
      ARTIFACT="$archived"
      BUILD_NUMBER="$(recorded "$BUILD_NUMBER_KEY")"
      return
    fi
  fi
  if [[ -n "$(recorded "UPLOAD_${PLATFORM_KEY}_DONE_SHA")" ]]; then
    warn "A build of $TAG was already uploaded. Same tag is fine for a packaging"
    warn "retry with no source change; the new build number must be higher."
  fi

  BUILD_LOG="$RELEASE_HOME/logs/build-$PLATFORM-$(utc_stamp).log"
  platform_build
  [[ -n "${BUILD_NUMBER:-}" ]] || die "Could not read the build number from $BUILD_LOG."
  [[ -f "${ARTIFACT:-}" ]] || die "The build produced no artifact (see $BUILD_LOG)."
  platform_verify

  built="$ARTIFACT"
  local dest="$RELEASE_HOME/artifacts/$PLATFORM-$BUILD_NUMBER"
  mkdir -p "$dest"
  ARTIFACT="$dest/$(basename "$built")"
  cp -p "$built" "$ARTIFACT"
  local sum
  sum="$(sha256_of "$ARTIFACT")"
  printf '%s  %s\n' "$sum" "$(basename "$ARTIFACT")" >"$dest/SHA256SUMS"
  record "$BUILD_NUMBER_KEY" "$BUILD_NUMBER"
  record "$ARTIFACT_SHA_KEY" "$sum"
  record "${PLATFORM_KEY}_ARTIFACT" "$ARTIFACT"
  record "${PLATFORM_KEY}_BUILD_LOG" "$BUILD_LOG"
  mark_done "BUILD_${PLATFORM_KEY}_DONE_SHA"
  log "Artifact: $ARTIFACT"
  log "Build number: $BUILD_NUMBER   SHA-256: $sum"
}

push_tag() {
  [[ "$TAG_ON_REMOTE" == 1 ]] && return
  step "Publish the tag (Step 5)"
  say "The artifact passed its static checks. Pushing $TAG publishes it to GitHub;" \
    "it uploads nothing to either store. Once a build from it is uploaded the" \
    "tag is frozen: a source fix after that means a new version and a new tag."
  confirm "git push $REMOTE refs/tags/$TAG now?" y ||
    die "Stopped with $TAG local and the artifact built. Re-run with --from-tag $TAG to push and upload."
  git push "$REMOTE" "refs/tags/$TAG" || die "Pushing $TAG failed."
  TAG_ON_REMOTE=1
}

upload() {
  step "Upload to $PLATFORM_NAME closed testing (Step 5)"
  if [[ "$(recorded "UPLOAD_${PLATFORM_KEY}_BUILD")" == "$BUILD_NUMBER" ]]; then
    confirm "Build $BUILD_NUMBER was already uploaded. Skip the upload?" y && return
  fi
  platform_upload
  record "UPLOAD_${PLATFORM_KEY}_BUILD" "$BUILD_NUMBER"
  mark_done "UPLOAD_${PLATFORM_KEY}_DONE_SHA"
}

validate() {
  step "Validate the exact store artifact on a phone (Step 6)"
  already_done "VALIDATED_${PLATFORM_KEY}_${BUILD_NUMBER}_SHA" "Validation of build $BUILD_NUMBER" && return
  platform_closed_test
  say "" "On the phone, using the closed-testing install of build $BUILD_NUMBER" \
    "(not a debug build, a simulator, or another commit):"
  checklist \
    "Diagnostics shows exactly $TAG (no dev build, bare SHA, other tag or -dirty) and the store shows build $BUILD_NUMBER" \
    "A fresh launch presents the current Terms, and its privacy and disclaimer links open" \
    "Bluetooth permission, scan, connect and a safe read or control work on a real peripheral" \
    "Local-network permission and Wi-Fi discovery work, and a supported LAN device opens and is controllable" \
    "Location-based repeater suggestions and every feature changed since the last release were smoke-tested" \
    "For an upgrade: installing over the previous store version kept saved devices and credentials (answer yes for a first release)"
  record "VALIDATED_${PLATFORM_KEY}_${BUILD_NUMBER}_SHA" "$RELEASE_SHA"
}

publish() {
  step "Submit and publish on $PLATFORM_NAME (Step 7)"
  already_done "PUBLISHED_${PLATFORM_KEY}_DONE_SHA" "$PLATFORM_NAME publication" && return
  platform_publish
  mark_done "PUBLISHED_${PLATFORM_KEY}_DONE_SHA"
}

github_release() {
  step "GitHub Release for $TAG"
  if gh release view "$TAG" &>/dev/null; then
    log "A GitHub Release for $TAG already exists."
    return
  fi
  local notes="$RELEASE_HOME/github-release-notes.md"
  git show "$RELEASE_SHA:CHANGELOG.md" | changelog_section "$VERSION" >"$notes"
  [[ -s "$notes" ]] || die "CHANGELOG.md's [$VERSION] section is empty."
  log "Notes, from CHANGELOG.md's [$VERSION] section ($notes):"
  sed 's/^/   │ /' "$notes" | head -n 40 >&2
  say "Store uploads and App Review do not depend on this. Edit $notes now if" \
    "the notes need curating; it is read when you answer."
  if confirm "Publish GitHub Release 'Liberated Bread $VERSION' on the pushed $TAG?" y; then
    gh release create "$TAG" --verify-tag --title "Liberated Bread $VERSION" \
      --notes-file "$notes" || die "gh release create failed. Draft it by hand at $GITHUB_RELEASES_URL"
    record GITHUB_RELEASE_URL "$(gh release view "$TAG" --json url --jq .url)"
  else
    log "Skipped. Re-run, or draft it at $GITHUB_RELEASES_URL from $notes."
  fi
}

after_release() {
  step "Public smoke test and cleanup"
  say "Install the PUBLIC $PLATFORM_NAME store build on a real phone. Check Diagnostics for" \
    "$TAG, repeat a BLE and a LAN smoke test, and confirm the listing's version and" \
    "release notes. Then keep watching crash reports, vitals and bug reports."
  pause
  local today
  today="$(date +%F)"
  record "PRODUCTION_RELEASE_DATE_${PLATFORM_KEY}" "$(ask "Date the $PLATFORM_NAME release actually went public" "$today")"
  [[ -n "$(recorded PRODUCTION_RELEASE_DATE)" ]] ||
    record PRODUCTION_RELEASE_DATE "$(recorded "PRODUCTION_RELEASE_DATE_${PLATFORM_KEY}")"
  say "" "Archive $RELEASE_HOME (record, artifacts/, logs/) in the team's release archive."
  pause

  cd "$PROJECT_DIR" || die "cd $PROJECT_DIR failed."
  if confirm "Remove the release worktree $RELEASE_DIR? (No if the other platform still builds from it)" n; then
    git worktree remove "$RELEASE_DIR" ||
      warn "Not clean; inspect what remains rather than forcing it (keystore properties? artifacts?)."
  fi
}

# ── entry point ──────────────────────────────────────────────────────────────

release_main() {
  # set -e alone stops without a word when an unguarded command fails deep in
  # a function. Name the spot instead; -E carries the trap into functions.
  set -E
  trap 'err "Stopped by an unexpected failure (exit $?) at ${BASH_SOURCE[0]##*/}:$LINENO. The record keeps what finished; fix it and re-run."' ERR
  parse_args "$@"
  [[ -t 0 ]] || die "This script is interactive; run it from a terminal."
  check_tools
  cd "$PROJECT_DIR" || die "cd $PROJECT_DIR failed."

  platform_preflight

  log "git fetch $REMOTE main --tags"
  git fetch --quiet "$REMOTE" main --tags || die "git fetch $REMOTE failed."

  choose_mode
  if [[ "$MODE" == new ]]; then resolve_new_tag; else resolve_existing_tag; fi
  SHORT_SHA="${RELEASE_SHA:0:10}"
  log "Releasing $TAG = $SHORT_SHA for $PLATFORM_NAME."

  init_record
  ci_gate
  one_time_gates
  prepare_worktree
  host_tests
  device_preflight
  create_local_tag
  build_and_verify
  push_tag
  upload
  validate
  publish
  github_release
  after_release

  step "Done"
  log "$PLATFORM_NAME $TAG is out. Record: $RECORD"
}
