#!/usr/bin/env bash
# Copyright 2026 Pigs Can Fly Labs LLC
# SPDX-License-Identifier: Apache-2.0
#
# Point Flutter at a Gradle-compatible JDK. Sourced by setup.sh (configures it
# once) and run-android.sh (a safety net before every Android build). Defines
# `ensure_gradle_jdk`; idempotent and safe to call repeatedly.
#
# Why this is needed: this project's Gradle wrapper (8.11.1) runs on Java 17-23,
# and CI pins 17 — but Flutter chooses the JDK it hands Gradle from its OWN
# `jdk-dir` config first, which it auto-points at Android Studio's bundled JBR.
# A recent Android Studio ships a Java 25 JBR, which Gradle refuses with
# "Unsupported class file major version 69"; and exporting JAVA_HOME does NOT
# override Flutter's jdk-dir. So when Flutter's chosen JDK is out of range, we
# repoint its jdk-dir at a compatible JDK on the system. LB_JDK_AUTO=0 skips it.

# Fall back to a plain logger if the sourcing script did not define one.
command -v warn >/dev/null 2>&1 || warn() { printf '\033[1;33m[jdk]\033[0m %s\n' "$*" >&2; }

GRADLE_JDK_MIN=17
GRADLE_JDK_MAX=23

_jdk_major() {  # echo the major Java version of the JDK at $1, or nothing
  [[ -x "$1/bin/java" ]] || return
  "$1/bin/java" -version 2>&1 | head -n1 \
    | sed -E 's/.*version "([0-9]+)\.([0-9]+).*/\1 \2/' \
    | awk '{ print ($1 == 1 ? $2 : $1) }'
}

_jdk_in_range() { [[ -n "$1" ]] && (( $1 >= GRADLE_JDK_MIN && $1 <= GRADLE_JDK_MAX )); }

# The JDK Flutter will actually hand Gradle, resolved the way Flutter does:
# jdk-dir config, then Android Studio's JBR, then JAVA_HOME, then PATH.
_flutter_effective_jdk() {
  local cfg jdkdir asdir
  cfg="$(flutter config --machine 2>/dev/null || echo '{}')"
  jdkdir="$(python3 -c 'import sys,json; print(json.load(sys.stdin).get("jdk-dir") or "")' <<<"$cfg" 2>/dev/null || true)"
  [[ -n "$jdkdir" && -x "$jdkdir/bin/java" ]] && { echo "$jdkdir"; return; }
  asdir="$(python3 -c 'import sys,json; print(json.load(sys.stdin).get("android-studio-dir") or "")' <<<"$cfg" 2>/dev/null || true)"
  [[ -n "$asdir" && -x "$asdir/jbr/bin/java" ]] && { echo "$asdir/jbr"; return; }
  [[ -n "${JAVA_HOME:-}" && -x "$JAVA_HOME/bin/java" ]] && { echo "$JAVA_HOME"; return; }
  command -v java >/dev/null && (cd "$(dirname "$(readlink -f "$(command -v java)")")/.." && pwd)
}

_find_compatible_jdk() {  # newest JDK in [MIN,MAX] on the system, or nothing
  local best="" best_v=0 dir v
  for dir in /usr/lib/jvm/* "$HOME"/.sdkman/candidates/java/* \
             /Library/Java/JavaVirtualMachines/*/Contents/Home; do
    [[ -d "$dir" ]] || continue
    v="$(_jdk_major "$dir" 2>/dev/null || true)"
    [[ -n "$v" ]] || continue
    if _jdk_in_range "$v" && (( v > best_v )); then best="$dir"; best_v="$v"; fi
  done
  [[ -n "$best" ]] && echo "$best"
}

# If Flutter's Gradle JDK is outside 17-23, repoint flutter config --jdk-dir at
# a compatible one. No-op when it is already fine, or when LB_JDK_AUTO=0.
ensure_gradle_jdk() {
  [[ "${LB_JDK_AUTO:-1}" == "0" ]] && return 0
  command -v flutter >/dev/null 2>&1 || return 0
  local eff v good
  eff="$(_flutter_effective_jdk || true)"
  v="$(_jdk_major "$eff" 2>/dev/null || true)"
  _jdk_in_range "$v" && return 0   # already compatible

  good="$(_find_compatible_jdk || true)"
  if [[ -n "$good" ]]; then
    warn "Flutter's Gradle JDK is Java ${v:-unknown} (${eff:-?}); the Gradle wrapper needs ${GRADLE_JDK_MIN}-${GRADLE_JDK_MAX}."
    warn "Pointing Flutter at $good (Java $(_jdk_major "$good"))."
    warn "  (LB_JDK_AUTO=0 to skip; undo with: flutter config --jdk-dir \"\")"
    flutter config --jdk-dir "$good" >/dev/null 2>&1 \
      || warn "  flutter config --jdk-dir failed; set it by hand."
  else
    warn "Flutter's Gradle JDK is Java ${v:-unknown}, outside the ${GRADLE_JDK_MIN}-${GRADLE_JDK_MAX} the"
    warn "Gradle wrapper needs, and no compatible JDK was found. Install one, e.g.:"
    warn "  sudo apt-get install -y openjdk-21-jdk"
    warn "then: flutter config --jdk-dir /path/to/that/jdk"
  fi
}
