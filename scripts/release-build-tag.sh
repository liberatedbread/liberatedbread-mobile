#!/usr/bin/env bash
# Copyright 2026 Pigs Can Fly Labs LLC
# SPDX-License-Identifier: Apache-2.0
#
# release-build-tag.sh TAG SHA — run by .github/workflows/release-build.yml in
# the release commit's checkout (the current directory), before it builds.
#
# scripts/release.sh stamps a store build from the tag on HEAD and refuses an
# untagged one, but the guided release pushes the tag only AFTER the artifact
# passes its checks. So the workflow is handed the tag's name and commit, and
# this script makes them agree with the repository before tagging the commit
# in this checkout only (never pushed):
#
#   - SHA is a full commit id, and the checkout is at it;
#   - SHA is on origin/main (a store build comes from main, nothing else);
#   - TAG is v<pubspec.yaml's version> at SHA, as release.sh will demand;
#   - if TAG already exists (pushed by an earlier run), it names SHA: a tag is
#     never moved, and a build of the wrong commit under it would be worse.
#
# Exit 0 with HEAD tagged TAG; 1 with a ::error:: line saying what disagreed.

set -euo pipefail

TAG="${1:-}" SHA="${2:-}"
fail() { echo "::error::$*" >&2; exit 1; }

[[ -n "$TAG" && -n "$SHA" ]] || fail "usage: release-build-tag.sh vX.Y.Z <40-hex commit>"
[[ "$SHA" =~ ^[0-9a-f]{40}$ ]] || fail "sha must be a full 40-character lowercase commit id (got '$SHA')."
[[ "$TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$ ]] || fail "tag must be vX.Y.Z (got '$TAG')."
[[ "$(git rev-parse HEAD)" == "$SHA" ]] || fail "the checkout is at $(git rev-parse HEAD), not $SHA."

git fetch --quiet origin main
git merge-base --is-ancestor "$SHA" origin/main ||
  fail "$SHA is not on main. Store builds are cut from main only."

version="$(sed -n 's/^version:[[:space:]]*\([^+[:space:]]*\).*/\1/p' pubspec.yaml)"
[[ "$TAG" == "v$version" ]] || fail "pubspec.yaml at $SHA says $version, so its tag is v$version, not $TAG."

if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then
  tagged="$(git rev-parse "$TAG^{commit}")"
  [[ "$tagged" == "$SHA" ]] || fail "$TAG already names $tagged, not $SHA. Tags are never moved."
  echo "$TAG already names $SHA."
else
  git -c user.name="release-build" -c user.email="release-build@users.noreply.github.com" \
    tag -a "$TAG" -m "Liberated Bread $version" "$SHA"
  echo "Tagged $SHA as $TAG in this checkout only; the release script pushes the real tag."
fi
[[ "$(git describe --tags --exact-match HEAD)" == "$TAG" ]] ||
  fail "HEAD does not describe as $TAG after tagging."
