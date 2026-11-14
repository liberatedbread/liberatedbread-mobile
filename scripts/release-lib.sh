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
#   --new-tag          cut vX.Y.Z (pubspec.yaml's version) on the CI-green tip
#                      of origin/main: tests, phone preflight, local tag,
#                      build, static checks, THEN push the tag.
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
ask_required() {
  local answer=""
  while [[ -z "$answer" ]]; do answer="$(ask "$1")"; done
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
Usage: $(basename "$0") [--new-tag | --from-tag vX.Y.Z]

Guided $PLATFORM_NAME store release (docs/RELEASE.md). Asks which of the two
modes when neither flag is given:
  --new-tag          tag pubspec.yaml's version on CI-green $REMOTE/main,
                     build, check, then push the tag
  --from-tag vX.Y.Z  build an existing tag (pushing it first if only local)
EOF
}

parse_args() {
  MODE="" TAG=""
  while (($#)); do
    case "$1" in
      --new-tag) MODE=new ;;
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
  case "$(choose "How is this release being made?" \
    "Cut a NEW tag from $REMOTE/main (tag is pushed after the build checks pass)" \
    "Build from an EXISTING tag (already cut, e.g. by the other platform's script)")" in
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

    local problems="" heading
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

    if [[ -z "$problems" ]]; then
      confirm "Release $REMOTE/main (${RELEASE_SHA:0:10}) as $TAG?" y ||
        die "Stopped before doing anything."
      break
    fi

    err "Not ready to cut $TAG from $REMOTE/main:"
    printf '%s' "$problems" | sed 's/^/   - /' >&2
    say "" \
      "Step 1 of docs/RELEASE.md: bump pubspec.yaml's version if it is changing," \
      "move CHANGELOG.md's Unreleased entries under '## [X.Y.Z] - $(date +%F)'," \
      "leave a new empty Unreleased section, and get that commit onto $REMOTE/main" \
      "(through a PR as usual). This script re-checks $REMOTE/main afterwards."
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
  local row id status conclusion url
  while true; do
    row="$(gh run list --workflow ci.yml --commit "$RELEASE_SHA" --limit 1 \
      --json databaseId,status,conclusion,url \
      --jq '.[0] | select(.) | [.databaseId, .status, .url, .conclusion] | @tsv')" ||
      die "gh run list failed."
    if [[ -z "$row" ]]; then
      warn "No CI run for $RELEASE_SHA yet. CI runs on every push to main."
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
      die "CI for $RELEASE_SHA concluded '$conclusion': $url" \
        "A failed or cancelled job is a stop, not something to explain in the notes."
    fi
    break
  done
  log "CI green: $url"
  record CI_RUN_URL "$url"
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
