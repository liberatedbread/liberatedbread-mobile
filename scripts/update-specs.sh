#!/usr/bin/env bash
# Copyright 2026 Pigs Can Fly Labs LLC
# SPDX-License-Identifier: Apache-2.0
#
# Refresh the vendored protocol-specs subtree.
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
# So the refresh is a script: it does the pull, then asserts that everything
# pubspec.yaml promises to bundle actually arrived.
#
# Usage:
#   ./scripts/update-specs.sh                     # main, from the canonical remote
#   ./scripts/update-specs.sh some-branch         # a branch, tag or SHA
#   ./scripts/update-specs.sh some-branch --from ../liberatedbread-protocol-specs
#   ./scripts/update-specs.sh --from /path/to/checkout
#
# `--from` takes any git remote: a URL, or a path to a local checkout. Pulling
# from a local checkout is for iterating on a spec change alongside an app
# change without pushing first — see the warning it prints.

set -uo pipefail

cd "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)" || exit 1

PREFIX="vendor/protocol-specs"
DEFAULT_REMOTE="https://github.com/liberatedbread/liberatedbread-protocol-specs.git"

REF="main"
REMOTE="$DEFAULT_REMOTE"
saw_ref=0

while [ $# -gt 0 ]; do
  case "$1" in
    --from)
      [ $# -ge 2 ] || { echo "::error::--from needs a URL or path" >&2; exit 2; }
      REMOTE="$2"; shift 2 ;;
    --from=*)
      REMOTE="${1#--from=}"; shift ;;
    -h|--help)
      sed -n '5,28p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*)
      echo "::error::unknown option $1" >&2; exit 2 ;;
    *)
      [ "$saw_ref" -eq 0 ] || { echo "::error::only one ref may be given" >&2; exit 2; }
      REF="$1"; saw_ref=1; shift ;;
  esac
done

log()  { printf '\033[1;32m[update-specs]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[update-specs]\033[0m %s\n' "$*"; }

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
case "$REMOTE" in
  *://*|git@*) ;;
  *) warn "pulling from a local checkout ($REMOTE) — the recorded upstream"
     warn "commit will not exist for anyone else until that branch is pushed." ;;
esac

BEFORE="$(git rev-parse HEAD)"
log "pulling $PREFIX from $REMOTE @ $REF"
if ! git subtree pull --prefix="$PREFIX" "$REMOTE" "$REF" --squash \
     -m "Update vendored protocol-specs

Refreshed from $REF via scripts/update-specs.sh."; then
  echo "::error::subtree pull failed. Resolve the conflicts, 'git add' them," >&2
  echo "::error::and commit — the merge is already in progress." >&2
  exit 1
fi

changed=1
if [ "$(git rev-parse HEAD)" = "$BEFORE" ]; then
  changed=0
  log "already at that ref; checking the bundled paths anyway."
fi

# The assertion this script exists for. Run even when the pull was a no-op:
# the question it answers is "does the tree satisfy pubspec.yaml", and that
# can stop being true without the subtree moving at all. Every path here is one pubspec.yaml
# lists under `assets:`; Flutter resolves those at build time, and a directory
# that has become empty is bundled as nothing at all rather than as an error.
missing=0
for path in \
  "$PREFIX/device-specs/index.json" \
  "$PREFIX/registries/ieee-oui.tsv" \
  "$PREFIX/registries/ieee-oui28.tsv" \
  "$PREFIX/registries/ieee-oui36.tsv" \
  "$PREFIX/registries/bluetooth-company-ids.tsv" \
  "$PREFIX/registries/bluetooth-service-uuids.tsv"
do
  if [ ! -s "$path" ]; then
    echo "::error file=pubspec.yaml::$path is missing or empty after the pull, but pubspec.yaml bundles it." >&2
    missing=1
  fi
done
for dir in "$PREFIX/device-specs/devices" "$PREFIX/device-specs/examples"; do
  if [ -z "$(find "$dir" -name '*.yaml' -print -quit 2>/dev/null)" ]; then
    echo "::error file=pubspec.yaml::$dir has no specs after the pull, but pubspec.yaml bundles it." >&2
    missing=1
  fi
done
[ "$missing" -eq 0 ] || exit 1

specs=$(find "$PREFIX/device-specs/devices" "$PREFIX/device-specs/examples" \
        -name '*.yaml' | wc -l | tr -d ' ')
log "$specs spec(s) vendored; every bundled asset path present."
if [ "$changed" -eq 1 ]; then
  log "Now run ./scripts/test.sh — the catalogue feeds the matcher, the iOS"
  log "Bonjour list and the registries, and each has a test that reads it."
fi
