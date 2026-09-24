#!/usr/bin/env bash
# Copyright 2026 Pigs Can Fly Labs LLC
# SPDX-License-Identifier: Apache-2.0
#
# Mirror CI locally — run dart format, flutter analyze, the FRB binding
# freshness check, flutter test, then cargo fmt/clippy/test. Exit non-zero on
# the first failure.

set -euo pipefail

# Read from .github/workflows/ci.yml, the same way scripts/setup.sh and the
# Claude Code session hook do — a different codegen version rewrites the
# generated bindings differently and would report a spurious (or miss a real)
# drift. This used to be a third hardcoded copy of the pin, which meant a bump
# in ci.yml made setup.sh install the new codegen while this script compared
# against the old one, took its "not the pinned version" skip path, and quietly
# stopped running the drift check that CI still enforces — green locally, red in
# CI, which is the exact gap this script exists to close.
SCRIPT_DIR_EARLY="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=ci-versions.sh
source "$SCRIPT_DIR_EARLY/ci-versions.sh"
FRB_VERSION="$CI_FRB_VERSION"

FLUTTER_HOME="${FLUTTER_HOME:-$HOME/.flutter-sdk}"
export PATH="${FLUTTER_HOME}/bin:$HOME/.cargo/bin:$PATH"
SCRIPT_DIR="$SCRIPT_DIR_EARLY"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# Every stage line carries the wall clock since the script started and the
# time the PREVIOUS stage took, so a run profiles itself: "which of these is
# slow" is answered by the log rather than by a stopwatch.
_t0=$SECONDS
_tprev=$SECONDS
# Computed in the caller's shell, not in a `$(...)`: a subshell could not
# advance _tprev, and the per-stage delta would have measured from the start
# every time. Two `local`s, because a value set by one `local` is not yet in
# scope for the next assignment on the same line (SC2318).
_stamp() {
  local now=$SECONDS
  local tot=$((now - _t0)) d=$((now - _tprev))
  _tprev=$now
  STAMP="$(printf '%3dm%02ds (+%3ds)' $((tot / 60)) $((tot % 60)) "$d")"
}
log()  { _stamp; printf '\033[1;32m[test]\033[0m %s %s\n' "$STAMP" "$*"; }
warn() { _stamp; printf '\033[1;33m[test]\033[0m %s %s\n' "$STAMP" "$*"; }

# CI regenerates the flutter_rust_bridge bindings and fails if the committed
# ones differ, so a change to rust/src/api/ that was never re-generated is a
# green local run and a red CI run. Do the same check here.
#
# Skipped (with a warning) rather than fatal when the pinned codegen isn't
# installed: it is a large `cargo install` that ./scripts/setup.sh handles, and
# a missing dev tool shouldn't look like a failing test suite.
check_frb_bindings() {
  if ! command -v flutter_rust_bridge_codegen &>/dev/null; then
    warn "SKIPPING FRB binding check: flutter_rust_bridge_codegen not installed."
    warn "  Install it with: cargo install --locked flutter_rust_bridge_codegen@${FRB_VERSION}"
    warn "  (or run ./scripts/setup.sh). CI still runs this check."
    return 0
  fi
  local installed
  installed="$(flutter_rust_bridge_codegen --version 2>/dev/null \
    | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)"
  if [[ "$installed" != "$FRB_VERSION" ]]; then
    warn "SKIPPING FRB binding check: codegen ${installed:-unknown} != pinned ${FRB_VERSION}."
    warn "  Re-pin with: cargo install --locked --force flutter_rust_bridge_codegen@${FRB_VERSION}"
    return 0
  fi
  flutter_rust_bridge_codegen generate
  # -I exempts exactly one hunk: flutter_rust_bridge's header comment listing
  # the trait methods it declined to bind takes its names from derive
  # expansions, so `#[derive(Eq)]` reads as `assert_receiver_is_total_eq` under
  # rustc 1.94 and `assert_fields_are_eq` under 1.97. Nothing in the bindings
  # changes with it, and CI floats on stable, so without the exemption a rustc
  # release fails this check for a comment. A hunk carrying anything else still
  # fails. Keep in sync with .github/workflows/ci.yml.
  git diff --exit-code \
    -I '^// These function are ignored because they are on traits' \
    lib/src/rust/ rust/src/frb_generated.rs
  # `git diff` is blind to brand-new (untracked) files, so a first-ever
  # generated file would pass the check above.
  local untracked
  untracked="$(git status --porcelain --untracked-files=all lib/src/rust rust/src/frb_generated.rs | grep '^??' || true)"
  if [[ -n "$untracked" ]]; then
    echo "FRB generated files that are not committed:" >&2
    echo "$untracked" >&2
    return 1
  fi
}

cd "$PROJECT_DIR"

# CI runs pub get before format/analyze/test; without it a fresh clone or a
# dependency bump fails here with a confusing "Target of URI doesn't exist".
# Cheap, and it is what this script provisioned itself from a moment ago: if
# ci.yml's env: block has stopped being readable, THIS run is already using the
# stale fallback pins, and so is every other dev environment. CI's gate job runs
# the same command.
log "ci-versions.sh --strict (toolchain pins still readable from ci.yml?)"
./scripts/ci-versions.sh --strict > /dev/null

# Also cheap, also no network, and it catches the two ways the vendored subtree
# goes wrong without anything failing: a path pubspec.yaml bundles that stopped
# existing (a runtime rootBundle error, not a build one), and a spec edited
# here instead of upstream (reverted by the next refresh). Same command as
# CI's gate job.
log "update-specs.sh --check (vendored protocol-specs still intact?)"
./scripts/update-specs.sh --check > /dev/null

log "flutter pub get --enforce-lockfile"
# --enforce-lockfile, as CI's gate runs it: a pubspec.lock drifted from
# pubspec.yaml resolved silently here and failed only on the runner.
flutter pub get --enforce-lockfile

log "dart format (tracked Dart files)"
./scripts/ci-format.sh

# WHICH files that formats — the app's, and not the vendored cargokit copy
# under rust_builder/. Both directions of that set are silent when wrong.
log "ci-format selftest"
./scripts/ci-format-selftest.sh

log "flutter analyze --fatal-infos"
flutter analyze --fatal-infos

# CI's `analyze` job lints scripts/ too. Skipped with a warning rather than
# fatal when shellcheck is absent, for the same reason the FRB check below is:
# a missing dev tool should not look like a failing test suite. CI still runs
# it. The version is CI's, fetched once by the installer (a hash-verified
# tarball into ~/.cache); if that cannot happen here — no network, say — the
# lint falls back to PATH's shellcheck and warns when it is not the pin.
log "shellcheck ${CI_SHELLCHECK_VERSION} (install if missing)"
./scripts/ci-install-shellcheck.sh \
  || warn "could not install the pinned shellcheck; linting with whatever is on PATH"
if ./scripts/ci-install-shellcheck.sh --print-path >/dev/null || command -v shellcheck &>/dev/null; then
  log "shellcheck (scripts/)"
  ./scripts/ci-shellcheck.sh
else
  warn "SKIPPING shellcheck: not installed and could not be fetched. CI still runs this check."
fi

# BEFORE the build, not after. `generate` rewrites rust/src/frb_generated.rs,
# which is an input to the crate — running it second leaves the freshly built
# library looking older than its own sources, so the next thing to ask "is this
# up to date?" (test/helpers/host_rust_lib.dart, and cargo itself) answers no
# and rebuilds work that was just done. Generating first also means the library
# below is built from the bindings this run actually checked.
log "flutter_rust_bridge_codegen generate (bindings up to date?)"
check_frb_bindings

log "host Rust library (FFI-backed tests load it by path)"
./scripts/ensure-rust-lib.sh


# ── The three long legs, in parallel ─────────────────────────────────────────
#
# Everything above is a gate the legs depend on (the bindings the library is
# built from, the library the Dart suite loads). Everything below is
# independent of everything else below: the Dart suite does not read the
# crate's test results, cargo does not read lcov, and the selftests drive stub
# binaries. Run one after another they took the sum of their times on a
# machine with eight cores idle; run together they take the longest of them.
# Each leg's output goes to its own file and is replayed in a fixed order once
# all three are done, so the log reads as it always did and a failure is
# attributed to its leg. LB_TEST_SERIAL=1 runs them one after another — the
# old order — for a run whose interleaving needs ruling out.

leg_selftests() {
# Drives scripts/ci-ios-tests.sh through its whole retry loop against stub
# binaries. Needs no Mac and no simulator, which is the point — it is the only
# way that logic gets exercised outside a real iOS CI failure.
log "ci-ios-tests.sh self-test"
./scripts/ci-ios-tests-selftest.sh

# The device runner's wall-clock bound on `xcodebuild test`: that its perl
# alarm survives the exec and kills a hang, and that the runner uses it.
log "run-ios-device-tests selftest"
./scripts/run-ios-device-tests-selftest.sh

# The bundle-verifier's own selftest, exactly as CI's gate runs it. It was
# CI-only, which is how the gate went red on a commit this script had
# blessed — the one gap this mirror exists to close.
log "verify-ios-app selftest"
./scripts/verify-ios-app-selftest.sh

# The emulated-network responder answers only what was asked — the property the
# netdisco suites' "the app sent the right query" claims rest on. No sockets,
# so it runs here rather than in the netdisco job.
if command -v python3 &>/dev/null; then
  log "net_virtual_device selftest"
  python3 ./scripts/net_virtual_device_selftest.py
else
  warn "SKIPPING net_virtual_device selftest: no python3. CI still runs it."
fi

# The emulator job's retry loop, against stub binaries: an attempt that ignores
# SIGTERM has to be escalated to SIGKILL, or the retry the whole script exists
# for never runs. Seconds here; otherwise only a 40-minute emulator job ever
# exercises it. Skips its `timeout` cases on a Mac without coreutils.
log "ci-emulator-tests selftest"
./scripts/ci-emulator-tests-selftest.sh
log "ci-install-shellcheck selftest"
./scripts/ci-install-shellcheck-selftest.sh

# The device pickers behind run-ios-device*.sh and run-android-device-tests.sh,
# against canned `flutter devices` output: a booted simulator reports the
# same platform as a phone, and the picker once offered one as "the first
# paired iPhone".
log "device-select selftest"
./scripts/device-select-selftest.sh
}

leg_dart() {
# --exclude-tags=netdisco mirrors CI: those suites bind ports 5353 and 1900 for
# real multicast, which a machine running avahi-daemon or systemd-resolved
# cannot spare. Run them with ./scripts/ci-netdisco-tests.sh.
#
# No LD_LIBRARY_PATH/DYLD_FALLBACK_LIBRARY_PATH here, and their absence is the
# fix rather than an omission. They used to be set on this command and never
# reached it: the line continuation ran into a comment, so bash read the two
# assignments as a command of their own — setting a pair of shell variables
# nothing exported — and then ran `flutter test` as a separate, unprefixed
# command. The suites passed anyway, which is the tell: test/helpers/
# host_rust_lib.dart opens rust/target/debug/<lib> by relative path precisely
# because the macOS hardened runtime strips DYLD_* from the `dart` binary, so
# neither variable was ever what made this work.
# One test isolate per core. The runner's default is half the cores, and on
# this suite that is 150 s → 133 s with coverage on, measured alone on an
# 8-core Mac (131 s → 116 s without) — and 161 s → 146 s measured HERE, with
# the Cargo and selftest legs running on the same cores at the same time, so
# the gain survives the contention. Coverage itself costs ~19 s and stays:
# the audit below needs it, and a mirror that skips what CI measures is not a
# mirror. LB_TEST_JOBS overrides the count.
jobs="${LB_TEST_JOBS:-$( (sysctl -n hw.ncpu 2>/dev/null || nproc 2>/dev/null || echo 4) | head -1)}"
# The runner picks its reporter by whether ITS stdout is a terminal, and under
# run_legs it is a log file: that is the `expanded` reporter, one line per
# test, thousands of lines replayed onto the terminal where the compact
# status line used to be. Asked for compact when the replay is going to a
# terminal (LEG_STDOUT_IS_TTY, read by run_legs before the fork); a run whose
# stdout is a pipe gets the default it always got.
reporter=""
[[ "${LEG_STDOUT_IS_TTY:-0}" == "1" ]] && reporter="--reporter=compact"
log "flutter test --coverage --exclude-tags=netdisco --concurrency=$jobs ${reporter}"
flutter test --coverage --exclude-tags=netdisco --concurrency="$jobs" ${reporter:+"$reporter"}

# A file no test imports is ABSENT from lcov rather than reported as zero, so
# it silently leaves the percentage alone. Both reports are offered when the
# netdisco run has left one behind, since a library only those suites reach is
# legitimately missing from the run above.
log "coverage audit (every lib/ file measured?)"
coverage_reports=(coverage/lcov.info)
if [[ -s coverage/netdisco-lcov.info ]]; then
  coverage_reports+=(coverage/netdisco-lcov.info)
fi
./scripts/ci-coverage-audit.sh "${coverage_reports[@]}"
}

leg_cargo() {
log "cargo fmt --all -- --check"
(cd rust && cargo fmt --all -- --check)

# --locked on both cargo runs, as CI passes it: an edited Cargo.toml whose
# lock was not regenerated is green here without it and red there.
log "cargo clippy --locked --all-targets --all-features -- -D warnings"
(cd rust && cargo clippy --locked --all-targets --all-features -- -D warnings)

log "cargo test --locked --all-features"
(cd rust && cargo test --locked --all-features)
}

run_legs() {
  local -a names=(selftests cargo dart)
  local -a pids=()
  local name
  if [[ "${LB_TEST_SERIAL:-0}" == "1" ]]; then
    for name in "${names[@]}"; do "leg_$name"; done
    return 0
  fi
  local dir; dir="$(mktemp -d)"
  # Read here, before the fork: inside a leg stdout is its log file, and
  # leg_dart needs to know where that log is going to end up.
  LEG_STDOUT_IS_TTY=0
  [[ -t 1 ]] && LEG_STDOUT_IS_TTY=1
  # Job control on, so each leg is its own process group. Without it a `&`
  # job in a script starts with SIGINT ignored — and flutter, dart, cargo and
  # rustc inherit that — so ^C killed this script at `wait` and left all three
  # legs running unattended, and a group has to exist for the trap below to
  # have something to signal. stdin from /dev/null, as bash gives a job
  # without job control: a leg that read the terminal would be stopped
  # (SIGTTIN) and this script would wait on it forever.
  set -m
  for name in "${names[@]}"; do
    # The leg closes its own log with the time it took: the header printed
    # below is written when the leg is REPLAYED, and the interval between
    # two replays is the wait, not the work.
    ( t=$SECONDS; "leg_$name"; rc=$?
      printf '\033[1;32m[test]\033[0m %s leg took %ds\n' "$name" $((SECONDS - t)); exit "$rc" ) \
      < /dev/null > "$dir/$name.log" 2>&1 &
    pids+=("$!")
  done
  set +m
  # Group-killed, not pid-killed: the pid is the subshell, and TERM to it alone
  # orphans the flutter or cargo it is waiting on.
  # shellcheck disable=SC2064  # $dir and pids are meant to expand now
  trap "trap - INT TERM; kill -TERM -- $(printf -- '-%s ' "${pids[@]}") 2>/dev/null; rm -rf '$dir'; exit 130" INT TERM
  local i failed=()
  for i in "${!names[@]}"; do
    if ! wait "${pids[$i]}"; then failed+=("${names[$i]}"); fi
    # No (+delta) on this line, on purpose: it would measure the gap between
    # replays. The leg's duration is the last line of its log.
    printf '\033[1;32m[test]\033[0m %3dm%02ds ── %s leg ──\n' \
      $(((SECONDS - _t0) / 60)) $(((SECONDS - _t0) % 60)) "${names[$i]}"
    cat "$dir/${names[$i]}.log"
  done
  trap - INT TERM
  rm -rf "$dir"
  if (( ${#failed[@]} )); then
    printf '\033[1;31m[test]\033[0m FAILED: %s\n' "${failed[*]}" >&2
    return 1
  fi
}

run_legs

log "All checks passed."
