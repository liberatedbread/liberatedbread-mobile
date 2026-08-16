#!/usr/bin/env bash
# Copyright 2026 Pigs Can Fly Labs LLC
# SPDX-License-Identifier: Apache-2.0
#
# Refresh — or verify — the vendored protocol-specs subtree.
#
# WHY THIS IS A SCRIPT AND NOT A DOCUMENTED COMMAND
#
# `vendor/protocol-specs/` is the single source of truth for both the device
# specs and the IEEE/SIG number registries, and pubspec.yaml bundles paths
# inside it directly — no copy in assets/, no sync step. That makes the pull
# cheap and makes a *wrong* pull invisible: nothing in the Dart build fails
# when `registries/ieee-oui36.tsv` stops existing, because a missing asset is a
# runtime rootBundle error on a code path most tests never reach. The app just
# quietly stops naming vendors.
#
# So the refresh is a script: it runs the ordinary `git subtree pull`, then
# asserts that everything pubspec.yaml promises to bundle actually arrived.
# The git plumbing is stock git-subtree throughout — this wrapper adds the
# preflight, the assertions and the error triage, and nothing else. Anything
# it does can be done by hand with `git subtree`.
#
# Usage:
#   ./scripts/update-specs.sh                     # main, from the canonical remote
#   ./scripts/update-specs.sh some-branch         # a branch, tag or SHA
#   ./scripts/update-specs.sh some-branch --from ../liberatedbread-protocol-specs
#   ./scripts/update-specs.sh --from /path/to/checkout
#   ./scripts/update-specs.sh --check             # verify only: no network, no pull
#   ./scripts/update-specs.sh --rebuild-index     # build the spec index from the
#                                                 # vendored specs, here, now
#   ./scripts/update-specs.sh --no-rebuild-index  # never build it, whatever the source
#
# `--from` takes any git remote: a URL, or a path to a local checkout. Pulling
# from a local checkout is for iterating on a spec change alongside an app
# change without pushing first — see the warning it prints.
#
# `--check` is the half of this script that has nothing to do with pulling: it
# asserts the vendored tree still satisfies pubspec.yaml and that nobody has
# hand-edited it in this repo. It touches no network and works on a shallow
# clone, which is what makes it usable from CI.
#
# THE LOCAL INDEX REBUILD
#
# `device-specs/index.json` is the list the app's loader reads: a spec missing
# from it is a spec the app never loads. Upstream generates it in CI and commits
# it on main *after* a spec merges, so any upstream tree that is not a merged
# main commit — a spec branch, a local checkout with an uncommitted spec — has
# an index that predates the spec you are testing. Pull that and the new device
# simply is not there, which is a confusing way to spend an evening.
#
# So when the source is a local checkout, this script rebuilds the index from
# the specs it just vendored, by running upstream's own generator out of the
# subtree. `--rebuild-index` forces it for any source (useful right after a
# spec merges, before upstream CI has published the rebuilt index);
# `--no-rebuild-index` suppresses it.
#
# The rebuild is deliberately left UNCOMMITTED. It is local-iteration state,
# not a change to this repo: committing it would make the next `git subtree
# pull` merge our index against upstream's and conflict on a generated file,
# which is the exact problem upstream moved the build into CI to end. The
# checks below tolerate that one file being dirty as long as it is byte-for-byte
# what the vendored specs generate, and a later pull silently discards it.

set -uo pipefail

cd "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)" || exit 1

PREFIX="vendor/protocol-specs"
DEFAULT_REMOTE="https://github.com/liberatedbread/liberatedbread-protocol-specs.git"

REF="main"
REMOTE="$DEFAULT_REMOTE"
saw_ref=0
check_only=0
# auto: rebuild when the source is a local checkout. 1/0: forced on/off.
rebuild_index="auto"
INDEX_REL="device-specs/index.json"
INDEX_PATH="$PREFIX/$INDEX_REL"

# Print the header's usage block. Deliberately keyed off the "# Usage:" line
# rather than off line numbers: the previous `sed -n '5,28p'` silently started
# printing the wrong paragraph the first time anyone added a sentence above it.
usage() { awk '/^# Usage:/ {p=1} p && /^#/ {sub(/^# ?/, ""); print; next} p {exit}' "$0"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --from)
      [ $# -ge 2 ] || { echo "::error::--from needs a URL or path" >&2; exit 2; }
      REMOTE="$2"; shift 2 ;;
    --from=*)
      REMOTE="${1#--from=}"; shift ;;
    --check)
      check_only=1; shift ;;
    --rebuild-index)
      rebuild_index=1; shift ;;
    --no-rebuild-index)
      rebuild_index=0; shift ;;
    -h|--help)
      usage; exit 0 ;;
    -*)
      echo "::error::unknown option $1" >&2; exit 2 ;;
    *)
      [ "$saw_ref" -eq 0 ] || { echo "::error::only one ref may be given" >&2; exit 2; }
      REF="$1"; saw_ref=1; shift ;;
  esac
done

log()  { printf '\033[1;32m[update-specs]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[update-specs]\033[0m %s\n' "$*"; }

# The newest `git subtree ... --squash` commit in this history. `--grep` alone
# cannot find it: it matches anywhere in a message, so a squash-merged PR whose
# description quotes the trailer (any subtree bump reviewed as a PR does) is
# picked over the real squash commit. Only a commit carrying git-subtree-split
# in its *trailer block* — the last paragraph, the one git-subtree itself
# writes and reads back — counts, so use --grep merely to gather candidates
# and let git's trailer parser make the call.
newest_subtree_squash() {
  local c
  while IFS= read -r c; do
    [ -n "$(git log -1 --format='%(trailers:key=git-subtree-split,valueonly)' "$c" 2>/dev/null)" ] || continue
    printf '%s\n' "$c"
    return 0
  done < <(git log --format=%H --grep='^git-subtree-split:' 2>/dev/null)
  return 1
}

# The upstream commit the vendored tree is supposed to be at, read out of the
# newest squash commit. This is the same trailer git-subtree itself looks for,
# so if this comes back empty git-subtree is about to be unhappy too — except
# on a shallow clone, where the squash commit is simply not in the fetched
# history and nothing is wrong.
recorded_split() {
  local squash
  squash="$(newest_subtree_squash)" || return 0
  git log -1 --format='%(trailers:key=git-subtree-split,valueonly)' "$squash" | head -n1
}

# ---------------------------------------------------------------------------
# The spec index. Generated upstream, read by the app's loader, and the one
# vendored file this script is willing to write.
# ---------------------------------------------------------------------------

# An interpreter that can actually run upstream's generator. Both imports are
# upstream's, not ours: the generator validates every spec against schema.json
# on its way to building the index, which is why jsonschema is not optional.
python_for_specs() {
  local candidate
  for candidate in "${PYTHON:-}" python3 python; do
    [ -n "$candidate" ] || continue
    command -v "$candidate" >/dev/null 2>&1 || continue
    "$candidate" -c 'import yaml, jsonschema' >/dev/null 2>&1 || continue
    printf '%s\n' "$candidate"
    return 0
  done
  return 1
}

no_python_error() {
  echo "::error::the vendored spec index needs upstream's generator to build, and that" >&2
  echo "::error::needs a python3 with pyyaml + jsonschema. Install them with:" >&2
  echo "::error::  python3 -m pip install -r $PREFIX/requirements.txt" >&2
  echo "::error::(or set PYTHON=/path/to/python). Nothing else in this repo needs them." >&2
}

# Build the index from the specs sitting in the subtree right now, in place.
# Left uncommitted on purpose — see the header.
rebuild_vendored_index() {
  local py before after err
  py="$(python_for_specs)" || { no_python_error; return 1; }

  before="$(git hash-object "$INDEX_PATH" 2>/dev/null || echo absent)"
  err="$(mktemp)"
  if ! "$py" "$PREFIX/scripts/generate_index.py" >/dev/null 2>"$err"; then
    echo "::error::upstream's generate_index.py failed over the vendored specs:" >&2
    sed 's/^/::error::  /' "$err" >&2
    rm -f "$err"
    return 1
  fi
  rm -f "$err"

  after="$(git hash-object "$INDEX_PATH")"
  if [ "$before" = "$after" ]; then
    log "spec index already matched the vendored specs; nothing rebuilt."
  else
    warn "rebuilt $INDEX_PATH from the vendored specs."
    warn "Deliberately left uncommitted: it is local-iteration state, and the next"
    warn "refresh discards it in favour of the index upstream CI publishes."
  fi
}

# Is the index on disk exactly what the vendored specs generate? Returns 0 yes,
# 1 no, 2 cannot tell (no usable interpreter). Restores the file either way, so
# asking the question never changes the answer.
index_is_generated_output() {
  local py saved rc=0
  py="$(python_for_specs)" || return 2
  [ -f "$INDEX_PATH" ] || return 1

  saved="$(mktemp)"
  cp "$INDEX_PATH" "$saved"
  if ! "$py" "$PREFIX/scripts/generate_index.py" >/dev/null 2>&1; then
    rc=1
  elif ! cmp -s "$saved" "$INDEX_PATH"; then
    rc=1
  fi
  cp "$saved" "$INDEX_PATH"
  rm -f "$saved"
  return "$rc"
}

# The `path` values the index lists, one per line, sorted.
indexed_spec_paths() {
  grep -o '"path"[[:space:]]*:[[:space:]]*"[^"]*"' "$INDEX_PATH" \
    | sed 's/^.*:[[:space:]]*"//; s/"$//' \
    | sort
}

# The spec files actually vendored, in the same repo-relative form the index
# uses. Same recursive view of device-specs/ that upstream's generator takes.
vendored_spec_paths() {
  find "$PREFIX/device-specs" \( -name '*.yaml' -o -name '*.yml' \) -print \
    | sed "s|^$PREFIX/||" \
    | sort
}

# ---------------------------------------------------------------------------
# Assertions. These run after a pull and are the whole of `--check`.
# ---------------------------------------------------------------------------

# The paths pubspec.yaml bundles out of the subtree, read from pubspec.yaml
# rather than repeated here. The list used to be hardcoded, which meant the
# assertion covered whatever was true on the day it was written: a registry
# added to `assets:` afterwards was bundled by Flutter and checked by nobody,
# which is exactly the hole this script exists to close.
pubspec_subtree_assets() {
  awk '
    /^flutter:/ { in_flutter = 1; next }
    # Any other top-level key ends the flutter: block.
    /^[^[:space:]#]/ { in_flutter = 0; in_assets = 0; next }
    in_flutter && /^[[:space:]]+assets:[[:space:]]*$/ { in_assets = 1; next }
    # A sibling key at any indent ends the asset list.
    in_assets && /^[[:space:]]*[A-Za-z_-]+:/ { in_assets = 0 }
    in_assets && /^[[:space:]]*-[[:space:]]*[^[:space:]#]/ {
      sub(/^[[:space:]]*-[[:space:]]*/, "")
      sub(/[[:space:]]+#.*$/, "")
      gsub(/^["'\'']|["'\'']$/, "")
      if ($0 != "") print
    }
  ' pubspec.yaml | grep "^$PREFIX/"
}

check_bundled_assets() {
  local missing=0 path count specs assets
  assets="$(pubspec_subtree_assets)"

  # An empty list is a failure, not a pass. If pubspec.yaml is restructured so
  # this parse stops matching, a check that silently asserts nothing is worse
  # than no check at all — it reports success over an unexamined tree.
  if [ -z "$assets" ]; then
    echo "::error file=pubspec.yaml::no $PREFIX/ paths found under flutter: assets: — either the" >&2
    echo "::error file=pubspec.yaml::subtree stopped being bundled, or this script can no longer read the list." >&2
    return 1
  fi

  while IFS= read -r path; do
    case "$path" in
      */)
        # Flutter bundles a directory as whatever it contains at build time, so
        # a directory that has become empty ships as nothing at all rather than
        # as an error. Under device-specs/ the contents have to be YAML for the
        # catalogue loader to find anything.
        if [ ! -d "$path" ]; then
          echo "::error file=pubspec.yaml::$path is missing, but pubspec.yaml bundles it." >&2
          missing=1
        elif case "$path" in */device-specs/*) true ;; *) false ;; esac; then
          if [ -z "$(find "$path" -name '*.yaml' -print -quit 2>/dev/null)" ]; then
            echo "::error file=pubspec.yaml::$path has no specs, but pubspec.yaml bundles it." >&2
            missing=1
          fi
        elif [ -z "$(find "$path" -type f ! -empty -print -quit 2>/dev/null)" ]; then
          echo "::error file=pubspec.yaml::$path is empty, but pubspec.yaml bundles it." >&2
          missing=1
        fi ;;
      *)
        if [ ! -s "$path" ]; then
          echo "::error file=pubspec.yaml::$path is missing or empty, but pubspec.yaml bundles it." >&2
          missing=1
        fi ;;
    esac
  done <<< "$assets"

  [ "$missing" -eq 0 ] || return 1

  count=$(printf '%s\n' "$assets" | wc -l | tr -d ' ')
  specs=$(find "$PREFIX/device-specs" -name '*.yaml' 2>/dev/null | wc -l | tr -d ' ')
  log "$specs spec(s) vendored; all $count bundled path(s) present."
}

# The subtree is vendored *unmodified* — that is the property that lets the app
# read the upstream index.json as-is and lets a refresh be one `git subtree
# pull`. An edit made under the prefix here breaks it silently: the change is
# invisible upstream, and the next pull either conflicts with it or quietly
# reverts it. Catch it in the gate instead, where the fix is still "move the
# change upstream" rather than "work out which of these two trees is right".
#
# This compares CONTENT, not commits. A squash commit's tree *is* the subtree's
# content — `git subtree` builds it with `commit-tree` over the upstream rev's
# tree — so one hash comparison answers the question for every way the prefix
# can drift. Walking the commits that touched the prefix does not: a conflict
# resolved during the subtree merge is recorded in the merge commit itself, and
# a later merge can carry a change that belongs to neither parent. Both leave
# the prefix disagreeing with upstream while every individual commit looks
# innocent, which is the whole failure this is here to prevent.
check_subtree_pristine() {
  local squash merge want have edits dirty
  squash="$(newest_subtree_squash)" || squash=""
  if [ -z "$squash" ]; then
    warn "no subtree squash commit in this history (shallow clone?); skipping the pristine check."
    return 0
  fi

  want="$(git rev-parse --verify --quiet "$squash^{tree}")"
  have="$(git rev-parse --verify --quiet "HEAD:$PREFIX")"
  if [ -z "$want" ] || [ -z "$have" ]; then
    warn "could not read $PREFIX or squash commit ${squash:0:9}; skipping the pristine check."
    return 0
  fi

  if [ "$want" != "$have" ]; then
    echo "::error::$PREFIX no longer matches the upstream commit it was vendored from:" >&2
    git diff --stat "$want" "$have" | sed 's/^/::error::  /' >&2
    # A hint, not the check. The merge that brought the squash commit in is the
    # point after which nothing should have touched the prefix — but an edit
    # made *while resolving* that merge lives in the merge commit, which no
    # range starting after it can name. Say so rather than printing an empty
    # list and leaving someone hunting for a commit that is not there.
    merge="$(git rev-list --parents HEAD | awk -v s="$squash" '$3 == s { print $1; exit }')"
    edits=""
    [ -n "$merge" ] && edits="$(git log --no-merges --oneline "$merge..HEAD" -- "$PREFIX")"
    if [ -n "$edits" ]; then
      echo "::error::Commits since the subtree merge that touch it:" >&2
      printf '%s\n' "$edits" | sed 's/^/::error::  /' >&2
    else
      echo "::error::No later commit touches it, so the change is in the subtree merge" >&2
      echo "::error::itself — a conflict resolved by editing the spec rather than by" >&2
      echo "::error::taking upstream's side." >&2
    fi
    echo "::error::The subtree is vendored unmodified. Make the change in" >&2
    echo "::error::liberatedbread-protocol-specs and re-run this script — or, while" >&2
    echo "::error::iterating, pull the branch you are writing it on with --from." >&2
    return 1
  fi

  # HEAD is right; the files on disk still might not be. Untracked counts: an
  # unstaged YAML dropped into device-specs/devices/ is bundled by Flutter at
  # build time exactly like a real one.
  dirty="$(git status --porcelain -- "$PREFIX")"
  [ -n "$dirty" ] || return 0

  # One exception, and it is narrow: the spec index, rebuilt from the specs
  # vendored right here. That is not an edit to upstream's content — it is
  # upstream's own generator run over upstream's own specs, which is why it can
  # be verified rather than trusted. Anything else under the prefix, including
  # an index that merely looks plausible, still fails.
  if [ "$(printf '%s\n' "$dirty" | cut -c4-)" = "$INDEX_PATH" ]; then
    index_is_generated_output
    case $? in
      0)
        warn "$INDEX_PATH is locally rebuilt (uncommitted) and matches the vendored specs."
        warn "Fine while iterating; do not commit it — the next refresh discards it."
        return 0 ;;
      2)
        echo "::error::$INDEX_PATH is modified and cannot be verified here." >&2
        no_python_error
        echo "::error::Or discard it: git checkout -- $INDEX_PATH" >&2
        return 1 ;;
    esac
  fi

  echo "::error::$PREFIX has uncommitted changes:" >&2
  printf '%s\n' "$dirty" | sed 's/^/::error::  /' >&2
  echo "::error::Spec changes belong upstream, not in this working copy." >&2
  return 1
}

# The index is the list the app's loader reads, so a spec it does not name is a
# spec the app does not have. Upstream publishes the rebuilt index from CI a
# beat after the spec merges, so a refresh can legitimately land on a main whose
# index is one commit behind — and the app would ship without the device.
# Cheap, exact, and no interpreter required: compare the two path lists.
check_index_covers_specs() {
  local indexed on_disk missing extra
  if [ ! -f "$INDEX_PATH" ]; then
    echo "::error::$INDEX_PATH is missing; the app's catalogue loader has nothing to read." >&2
    return 1
  fi

  indexed="$(indexed_spec_paths)"
  on_disk="$(vendored_spec_paths)"
  [ "$indexed" != "$on_disk" ] || return 0

  missing="$(comm -13 <(printf '%s\n' "$indexed") <(printf '%s\n' "$on_disk"))"
  extra="$(comm -23 <(printf '%s\n' "$indexed") <(printf '%s\n' "$on_disk"))"
  echo "::error::$INDEX_REL disagrees with the specs vendored beside it:" >&2
  [ -z "$missing" ] || printf '%s\n' "$missing" | sed 's/^/::error::  vendored but unindexed (never loads): /' >&2
  [ -z "$extra" ] || printf '%s\n' "$extra" | sed 's/^/::error::  indexed but not vendored (loader skips): /' >&2
  echo "::error::Usually this means the index upstream published predates these specs —" >&2
  echo "::error::a branch, or a main commit whose index CI has not committed yet. Either" >&2
  echo "::error::refresh again once it has, or build it here: ./scripts/update-specs.sh --rebuild-index" >&2
  return 1
}

run_checks() {
  local rc=0
  check_bundled_assets || rc=1
  check_index_covers_specs || rc=1
  check_subtree_pristine || rc=1
  return "$rc"
}

# ---------------------------------------------------------------------------
# --check: verify the tree we already have. No network, no pull, no git state.
# ---------------------------------------------------------------------------
if [ "$check_only" -eq 1 ]; then
  [ "$saw_ref" -eq 0 ] || { echo "::error::--check takes no ref" >&2; exit 2; }
  split="$(recorded_split)"
  if [ -n "$split" ]; then
    log "vendored at upstream ${split:0:9}"
  else
    warn "no recorded upstream commit found in this history."
  fi
  # `--check --rebuild-index` is the "make this tree consistent without
  # touching the network" combination: the specs are already here, so the index
  # for them can be built from them. Explicitly asked for, so it is not a
  # surprise write from a command that otherwise only reads.
  if [ "$rebuild_index" = "1" ]; then
    rebuild_vendored_index || exit 1
  fi
  run_checks || exit 1
  exit 0
fi

# ---------------------------------------------------------------------------
# The pull.
# ---------------------------------------------------------------------------

# git-subtree ships in contrib/, so it is packaged separately or omitted
# entirely on some installs (Apple's git being the one people actually hit).
# Without this the failure is `git: 'subtree' is not a git command`, which
# reads like a typo in this script rather than a missing package.
if [ ! -x "$(git --exec-path)/git-subtree" ] && ! command -v git-subtree >/dev/null 2>&1; then
  echo "::error::git-subtree is not installed. It ships with git on most distros;" >&2
  echo "::error::on macOS use Homebrew's git (Apple's does not include it)." >&2
  exit 1
fi

# A locally rebuilt index is this script's own doing, and the pull is about to
# overwrite it with upstream's anyway. Dropping it here is what keeps the
# rebuild from ever becoming a merge: the tree that meets `git subtree pull` is
# the tree upstream last gave us. Only when it verifies as generator output —
# anything else is someone's edit, and the clean-tree check below should say so.
if [ -n "$(git status --porcelain -- "$INDEX_PATH")" ]; then
  if index_is_generated_output; then
    git checkout -- "$INDEX_PATH" \
      && log "discarded the locally rebuilt index; the pull brings upstream's."
  else
    warn "$INDEX_PATH is modified and is not what the vendored specs generate."
    warn "If it is a stale local rebuild: git checkout -- $INDEX_PATH"
  fi
fi

# `git subtree pull` merges, so it refuses to start on a dirty tree — and it
# refuses *after* fetching, with a message about the merge rather than about
# the working copy. Say it plainly first.
if [ -n "$(git status --porcelain)" ]; then
  echo "::error::working tree is not clean; commit or stash before refreshing the subtree." >&2
  git status --short >&2
  exit 1
fi

# A local checkout can be at a commit that exists nowhere else. The subtree
# squash records that SHA in its message, so a teammate who tries to trace the
# vendored content back finds nothing. Fine while iterating, worth saying.
local_source=0
case "$REMOTE" in
  *://*|git@*) ;;
  *) local_source=1
     warn "pulling from a local checkout ($REMOTE) — the recorded upstream"
     warn "commit will not exist for anyone else until that branch is pushed." ;;
esac

# With --squash we keep none of upstream's objects, so the previously recorded
# split commit is usually absent locally — and git-subtree needs it to write
# the "changes from X..Y" message. git 2.42+ fetches it itself; older git dies
# with "could not rev-parse split hash" and no hint that the fix is a fetch.
# Doing it here makes the script work on the git people actually have, and
# turns "upstream rewrote history and dropped that commit" into a warning
# printed before the pull rather than a cryptic failure during it.
BEFORE_SPLIT="$(recorded_split)"
if [ -n "$BEFORE_SPLIT" ] && ! git cat-file -e "${BEFORE_SPLIT}^{commit}" 2>/dev/null; then
  if ! git fetch --no-tags "$REMOTE" "$BEFORE_SPLIT" >/dev/null 2>&1; then
    warn "$REMOTE no longer has the recorded upstream commit ${BEFORE_SPLIT:0:9};"
    warn "if the pull fails on it, see the recovery note it prints."
  fi
fi

BEFORE="$(git rev-parse HEAD)"
log "pulling $PREFIX from $REMOTE @ $REF"

# Stock `git subtree pull --squash`. Everything above is preflight and
# everything below is triage; the pull itself is the command you would type.
# Output is tee'd rather than swallowed so it still scrolls past live — the
# copy is only read to tell the failure modes apart.
pull_log="$(mktemp)"
trap 'rm -f "$pull_log"' EXIT
if ! git subtree pull --prefix="$PREFIX" "$REMOTE" "$REF" --squash \
     -m "Update vendored protocol-specs

Refreshed from $REF via scripts/update-specs.sh." 2>&1 | tee "$pull_log"; then
  # Three very different failures reach here and the advice differs for each,
  # so ask git which one it was rather than guessing. An unresolved merge
  # leaves MERGE_HEAD behind; a fetch that never got that far leaves the tree
  # untouched, and telling someone to resolve conflicts they do not have sends
  # them looking for a merge that is not there.
  if [ -e "$(git rev-parse --git-dir)/MERGE_HEAD" ]; then
    echo "::error::subtree pull hit conflicts. Resolve them, 'git add' them," >&2
    echo "::error::and commit — the merge is in progress." >&2
  elif grep -q 'could not rev-parse split hash' "$pull_log"; then
    # Upstream force-pushed or garbage-collected the commit we recorded, so
    # there is no common point to diff against any more. Re-adding is the
    # documented way out and it is not destructive: the next commit records a
    # fresh baseline and the vendored files are unchanged by it.
    echo "::error::the recorded upstream commit is gone from $REMOTE — history there" >&2
    echo "::error::was rewritten. Re-baseline the subtree with the ordinary commands:" >&2
    echo "::error::  git rm -r --quiet $PREFIX && git commit -m 'Re-baseline vendored specs'" >&2
    echo "::error::  git subtree add --prefix=$PREFIX $REMOTE $REF --squash" >&2
  else
    echo "::error::subtree pull failed before merging; the tree is unchanged." >&2
    echo "::error::Check that '$REF' exists on $REMOTE." >&2
    case "$REMOTE" in
      *://*|git@*) ;;
      # The one that actually bites: git refuses to fetch a branch out of a
      # shallow clone, and says so in terms of "shallow roots" rather than in
      # terms of the thing you asked for.
      *) echo "::error::A shallow local checkout cannot be fetched from — push" >&2
         echo "::error::the branch and pull from the remote instead." >&2 ;;
    esac
  fi
  exit 1
fi

changed=1
if [ "$(git rev-parse HEAD)" = "$BEFORE" ]; then
  changed=0
  log "already at that ref; checking the bundled paths anyway."
fi

AFTER_SPLIT="$(recorded_split)"
if [ -n "$AFTER_SPLIT" ]; then
  if [ "$AFTER_SPLIT" != "$BEFORE_SPLIT" ] && [ -n "$BEFORE_SPLIT" ]; then
    log "upstream ${BEFORE_SPLIT:0:9} -> ${AFTER_SPLIT:0:9}"
  else
    log "vendored at upstream ${AFTER_SPLIT:0:9}"
  fi
fi

# Build the index the specs we just vendored actually deserve. A local checkout
# is the case that needs it by default: its index is whatever upstream CI last
# published on main, so on any branch — or on any tree with an uncommitted spec
# — it predates the spec being iterated on, and the app would load a catalogue
# without it. Forced with --rebuild-index for the same situation on a remote
# ref, which is the window between a spec merging and CI committing the index.
if [ "$rebuild_index" = "1" ] || { [ "$rebuild_index" = "auto" ] && [ "$local_source" -eq 1 ]; }; then
  rebuild_vendored_index || exit 1
fi

# Run even when the pull was a no-op: the question these answer is "does the
# tree satisfy pubspec.yaml", and that can stop being true without the subtree
# moving at all.
run_checks || exit 1

# Rebuild the LOCAL index-temp.json so a build off THIS checkout sees every
# vendored spec even though the committed index.json lags (CI rebuilds it on
# main; a local-checkout pull cannot). Gitignored; the app prefers it. The
# run-*.sh scripts also regenerate it, so this just makes a bare `update-specs`
# self-sufficient. See scripts/regen-spec-index.sh.
# shellcheck source=regen-spec-index.sh
source "$(dirname "$0")/regen-spec-index.sh"
regen_spec_index

if [ "$changed" -eq 1 ]; then
  log "Now run ./scripts/test.sh — the catalogue feeds the matcher, the iOS"
  log "Bonjour list and the registries, and each has a test that reads it."
fi
