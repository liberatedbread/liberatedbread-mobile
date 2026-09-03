#!/usr/bin/env bash
# Copyright 2026 Pigs Can Fly Labs LLC
# SPDX-License-Identifier: Apache-2.0
#
# Liberated Bread Mobile — verify the CONTENTS of a built iOS bundle.
#
# WHY THIS EXISTS
#
# The iOS CI job was compile-only: `flutter build ios --debug --no-codesign
# --simulator` and nothing else. A compile cannot see the two things that
# actually broke on device:
#
#   1. Info.plist regressions. The BLE usage strings are what make CoreBluetooth
#      raise the system prompt at all — lib/services/real_ble_service.dart
#      deliberately relies on that instead of asking permission_handler. Drop
#      NSBluetoothAlwaysUsageDescription and iOS kills the app the moment it
#      touches CBCentralManager; drop NSLocalNetworkUsageDescription or
#      NSAllowsLocalNetworking and every http:// Home Assistant call fails.
#      All of it compiles perfectly.
#   2. The Rust library not actually being linked in. cargokit builds the crate
#      as a static archive and rust_builder/ios/liberated_bread_core.podspec
#      force-loads it (OTHER_LDFLAGS = -force_load .../libliberated_bread_core.a).
#      If that silently no-ops, the app links, launches, and dies on the first
#      flutter_rust_bridge call. Checking that the .a exists in the build
#      intermediates would NOT catch this — the archive can be present and
#      simply never linked. The only meaningful assertion is whether the FFI
#      entry points survived into a shipped Mach-O.
#
# Accepts either a built .app directory or an .ipa, so the same checks cover the
# CI simulator build and the ad-hoc IPA that goes on a real iPhone.
#
# Usage:
#   ./scripts/verify_ios_app.sh <path-to-Runner.app | path-to.ipa> [--skip-symbols]
#
# Options:
#   --skip-symbols   Only verify Info.plist. Use for release/profile artifacts,
#                    whose binaries are stripped — see the note on the symbol
#                    check below.
#
# Environment:
#   PLISTBUDDY   Path to PlistBuddy (default /usr/libexec/PlistBuddy)
#   NM           Path to nm (default: nm on PATH)
#   RUST_TARGET_DIR  Where to look for cargokit's staticlib when reporting a
#                    failure (default rust/target)
#
# macOS only: PlistBuddy and nm are the tools that can read a built bundle.
# Both are required rather than optional — a runner that lacks them must make
# this script fail, not quietly skip and report success.

set -euo pipefail

EXPECTED_BUNDLE_ID="ca.pigscanfly.liberatedbread"

# Non-empty string keys the app cannot work without. Checked in the BUILT
# bundle, not ios/Runner/Info.plist, so an Xcode build-setting or plist
# preprocessing regression is caught too.
REQUIRED_STRING_KEYS=(
  "NSBluetoothAlwaysUsageDescription"
  "NSBluetoothPeripheralUsageDescription"
  "NSLocalNetworkUsageDescription"
)

# The FFI dispatcher entry points flutter_rust_bridge 2.9 exports from the
# crate and resolves by name at runtime. Apple prefixes C symbols with an
# underscore, hence the optional leading _ in the pattern.
FRB_SYMBOL_PATTERN='_?frb_(pde_ffi_dispatcher_primary|get_rust_content_hash)$'

PLISTBUDDY="${PLISTBUDDY:-/usr/libexec/PlistBuddy}"
NM="${NM:-nm}"
# Where the failure path looks for what cargokit built. Relative to the repo
# root, which is where CI invokes this from. Overridable so
# scripts/verify-ios-app-selftest.sh can drive each branch of the CONCLUSION
# from a fixture instead of from whatever happens to be on the machine.
RUST_TARGET_DIR="${RUST_TARGET_DIR:-rust/target}"

TARGET=""
SKIP_SYMBOLS=0

log()  { printf '\033[1;32m[verify-ios]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[verify-ios]\033[0m %s\n' "$*"; }

# Everything a missing-FFI failure needs somebody to know, printed at the
# moment it fails.
#
# WHY THIS EXISTS. This job runs on macOS, which bills at 10x, and `flutter
# build ios` swallows cargokit's output entirely, so when the symbol check goes
# red the evidence is not in the log either. Twice in a row that meant a full
# red run taught nothing and the only way forward was another one.
#
# WHAT THE FIRST VERSION GOT WRONG, because the shape of it is the lesson. It
# reported "3642 matching frb_" for a binary the check had just called empty,
# and that number is worthless: nearly every one of those is a MANGLED Rust
# symbol whose module path happens to be `frb_generated`
# (__ZN20liberated_bread_core13frb_generated...), not an exported C entry
# point. A reader who trusts it concludes the library is linked and the
# verifier is broken; a reader who dismisses it concludes the opposite. It
# could not settle the question either way, and it disagreed with the verdict
# because the two were computed by different code — one of which had a
# SIGPIPE bug the other did not.
#
# So this version does not recompute anything. It reports the SAME scan the
# verdict was reached from (the SCAN_* arrays), splits frb_ mentions into C
# exports versus mangled noise, names every C export it did find, says whether
# the staticlib on disk exports the entry points, and ends with a one-line
# conclusion naming the cause instead of leaving three possibilities for the
# reader to pick between at 10x.
#
# Only runs on the failure path, so a green run pays nothing for it.

# Symbols whose name BEGINS with frb_ are C entry points by construction; a
# mangled Rust symbol mentions frb_generated but never starts with it. That
# distinction is the whole difference between "linked but not exporting" and
# "exporting under another name", so it gets its own pattern.
FRB_C_EXPORT_PATTERN='^_?frb_[A-Za-z0-9_]*$'

# Plain text (no ANSI), so the same report can go to stderr and to the job
# summary. Written to a file rather than echoed twice.
REPORT=""

r() { printf '%s\n' "$*" >>"$REPORT"; }

diagnose_missing_ffi() {
  REPORT="$WORK/ffi-report.txt"
  : >"$REPORT"

  local i n macho_seen=0 frb_total=0 cexp_total=0 mangled_total=0
  r "FFI diagnostics — why no flutter_rust_bridge entry point was found"
  r ""
  r "Looking for: /$FRB_SYMBOL_PATTERN/"
  r ""

  n=${#SCAN_BIN[@]}
  if [[ "$n" -eq 0 ]]; then
    r "  No candidate binaries at all."
  fi

  for ((i = 0; i < n; i++)); do
    if [[ "${SCAN_MACHO[$i]}" -ne 1 ]]; then
      continue
    fi
    macho_seen=$((macho_seen + 1))
    frb_total=$((frb_total + SCAN_FRB[i]))
    cexp_total=$((cexp_total + SCAN_CEXP[i]))
    mangled_total=$((mangled_total + SCAN_MANGLED[i]))

    r "  ${SCAN_BIN[$i]#"$APP/"}"
    r "    ${SCAN_ARCH[$i]}"
    r "    ${SCAN_TOTAL[$i]} global symbols"
    # The line the old report needed and did not have.
    r "    ${SCAN_FRB[$i]} symbols mention frb_: ${SCAN_CEXP[$i]} C export(s), ${SCAN_MANGLED[$i]} mangled Rust symbol(s)"
    r "      (mangled ones carry the frb_generated module path and are NOT entry points)"
    if [[ "${SCAN_CEXP[$i]}" -gt 0 ]]; then
      r "    frb_ C exports present:"
      local line shown=0
      while IFS= read -r line; do
        shown=$((shown + 1))
        if [[ "$shown" -le 12 ]]; then
          r "      $line"
        fi
      done <"$WORK/cexp.$i"
      if [[ "$shown" -gt 12 ]]; then
        r "      ... and $((shown - 12)) more"
      fi
    else
      r "    frb_ C exports present: none"
    fi
    r "    matching /$FRB_SYMBOL_PATTERN/: ${SCAN_STRICT[$i]}"
  done

  if [[ "${SCAN_SKIPPED:-0}" -gt 0 ]]; then
    r ""
    r "  ($SCAN_SKIPPED file(s) in the bundle were not Mach-O objects and were skipped:"
    r "   Info.plists, headers, and bundled assets. That is expected.)"
  fi

  # What cargokit actually produced, and — the part that discriminates — whether
  # it exports the entry points itself. A staticlib that HAS them while the
  # bundle does not is a linking failure and nothing else; a staticlib that
  # lacks them means the problem is upstream of the linker entirely.
  r ""
  r "  Rust staticlibs under $RUST_TARGET_DIR:"
  local lib libstrict staticlib_seen=0 staticlib_exports=0
  if [[ -d "$RUST_TARGET_DIR" ]]; then
    while IFS= read -r lib; do
      staticlib_seen=$((staticlib_seen + 1))
      libstrict=0
      if command -v "$NM" >/dev/null 2>&1; then
        libstrict="$("$NM" -g "$lib" 2>/dev/null | grep -cE "$FRB_SYMBOL_PATTERN" || true)"
      fi
      [[ "$libstrict" -gt 0 ]] && staticlib_exports=$((staticlib_exports + 1))
      r "    $lib ($(wc -c <"$lib" | tr -d ' ') bytes)"
      if command -v lipo >/dev/null 2>&1; then
        r "      $(lipo -info "$lib" 2>/dev/null || echo 'lipo failed')"
      fi
      r "      exports the entry points: $([[ "$libstrict" -gt 0 ]] && echo yes || echo no)"
    done < <(find "$RUST_TARGET_DIR" -name 'libliberated_bread_core.a' 2>/dev/null)
    [[ "$staticlib_seen" -gt 0 ]] || r "    none — cargokit produced no staticlib"
  else
    r "    $RUST_TARGET_DIR does not exist here"
  fi

  # ── the conclusion ────────────────────────────────────────────────────────
  # Three causes need three different fixes. Say which one this is.
  r ""
  r "  CONCLUSION:"
  if [[ "$macho_seen" -eq 0 ]]; then
    r "    Nothing in this bundle is a Mach-O object. This is not a usable app"
    r "    bundle at all — check the artifact path the workflow passed in."
  elif [[ "$cexp_total" -gt 0 ]]; then
    r "    The Rust library IS linked in and DOES export frb_ C entry points,"
    r "    but none of them match the expected names. flutter_rust_bridge most"
    r "    likely renamed them. Fix FRB_SYMBOL_PATTERN at the top of this"
    r "    script to match the names listed above — do not go looking at the"
    r "    podspec or at cargokit."
  elif [[ "$mangled_total" -gt 0 ]]; then
    r "    The Rust library IS linked in — mangled symbols from the crate are"
    r "    present — but it exports no frb_ C entry point whatsoever. The"
    r "    no_mangle exports were stripped or hidden after linking. Look at"
    r "    STRIP_STYLE / DEAD_CODE_STRIPPING on the pod target, not at whether"
    r "    the crate was built."
  elif [[ "$staticlib_seen" -eq 0 ]]; then
    r "    No binary carries any of the crate's code, and cargokit produced no"
    r "    staticlib. The Rust build did not run or failed silently — start at"
    r "    the 'Build Rust library' script phase in the pod."
  elif [[ "$staticlib_exports" -gt 0 ]]; then
    r "    The staticlib exists and exports the entry points, but none of the"
    r "    crate's code reached the bundle. The -force_load in"
    r "    rust_builder/ios/liberated_bread_core.podspec did not take effect."
  else
    r "    A staticlib was produced but it exports no entry points either, so"
    r "    the problem is upstream of the linker: the crate built without the"
    r "    flutter_rust_bridge boilerplate. Check rust/src/frb_generated.rs."
  fi

  # stderr, one colored prefix per line.
  printf '\033[1;33m[verify-ios] --- FFI diagnostics ---\033[0m\n' >&2
  while IFS= read -r line; do
    printf '\033[1;33m[verify-ios]\033[0m %s\n' "$line" >&2
  done <"$REPORT"
  printf '\033[1;33m[verify-ios] --- end diagnostics ---\033[0m\n' >&2

  # And onto the run summary page when there is one. The whole point of this
  # block is that somebody reads it; buried at line 900 of a macOS job log is
  # the one place it reliably is not read.
  if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
    {
      printf '### iOS bundle: no flutter_rust_bridge FFI entry point\n\n'
      printf '```\n'
      cat "$REPORT"
      printf '```\n'
    } >>"$GITHUB_STEP_SUMMARY" 2>/dev/null || true
  fi
}

# Same rationale as scripts/verify_apk.sh: collect every failure so one CI run
# shows the whole picture instead of one problem per push.
FAILURES=0
fail() {
  printf '\033[1;31m[verify-ios] FAIL:\033[0m %s\n' "$*" >&2
  FAILURES=$((FAILURES + 1))
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-symbols) SKIP_SYMBOLS=1; shift ;;
    # So the CI summary step can grep for the SAME symbols this script checks,
    # instead of keeping a second copy of the regex that drifts the first time
    # flutter_rust_bridge renames an entry point.
    --print-symbol-pattern) printf '%s\n' "$FRB_SYMBOL_PATTERN"; exit 0 ;;
    -h|--help)
      echo "Usage: $0 <path-to-Runner.app | path-to.ipa> [--skip-symbols]"
      echo "       $0 --print-symbol-pattern"
      exit 0 ;;
    -*)
      echo "Unknown option: $1" >&2; exit 2 ;;
    *)
      [[ -z "$TARGET" ]] || { echo "Only one bundle path may be given" >&2; exit 2; }
      TARGET="$1"; shift ;;
  esac
done

if [[ -z "$TARGET" ]]; then
  echo "Usage: $0 <path-to-Runner.app | path-to.ipa> [--skip-symbols]" >&2
  exit 2
fi

# A workflow typo in the artifact path would otherwise make every check below
# vacuously pass on nothing.
if [[ ! -e "$TARGET" ]]; then
  fail "Bundle not found: $TARGET"
  exit 1
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# ── resolve the .app ────────────────────────────────────────────────────────
APP=""
case "$TARGET" in
  *.ipa)
    command -v unzip >/dev/null 2>&1 || { echo "unzip is required to read an .ipa" >&2; exit 2; }
    log "Unpacking IPA: $TARGET"
    unzip -q "$TARGET" -d "$WORK/ipa" || { fail "Not a readable .ipa: $TARGET"; exit 1; }
    APP="$(find "$WORK/ipa/Payload" -maxdepth 1 -name '*.app' -type d 2>/dev/null | head -1)"
    if [[ -z "$APP" ]]; then
      fail "No Payload/*.app inside $TARGET — this is not an iOS application archive."
      exit 1
    fi
    ;;
  *)
    if [[ ! -d "$TARGET" ]]; then
      fail "Not a .app directory and not an .ipa: $TARGET"
      exit 1
    fi
    APP="$TARGET"
    ;;
esac

log "Verifying bundle: $APP"

PLIST="$APP/Info.plist"
if [[ ! -f "$PLIST" ]]; then
  fail "$APP has no Info.plist — the build did not produce a usable bundle."
  exit 1
fi

if [[ ! -x "$PLISTBUDDY" ]]; then
  fail "PlistBuddy not found at '$PLISTBUDDY' (macOS only). Cannot read the built Info.plist, so no plist check can be trusted."
  exit 1
fi

# ── 1. Info.plist ───────────────────────────────────────────────────────────
# PlistBuddy exits non-zero when a key is absent, so a missing key is a real
# failure rather than an empty string that compares equal to another empty
# string.
plist_get() { "$PLISTBUDDY" -c "Print :$1" "$PLIST" 2>/dev/null; }

for key in "${REQUIRED_STRING_KEYS[@]}"; do
  value="$(plist_get "$key" || true)"
  if [[ -z "$value" ]]; then
    fail "Info.plist key $key is missing or empty — iOS terminates the app when the matching API is used without it."
  else
    log "  ok  $key = $value"
  fi
done

# usesCleartextTraffic has no iOS equivalent; NSAllowsLocalNetworking is what
# lets the app reach a plain-http Home Assistant on the LAN. A bare
# NSAppTransportSecurity dict with the flag flipped to false compiles fine and
# breaks every local connection at runtime, so assert the value, not the key.
ats_local="$(plist_get "NSAppTransportSecurity:NSAllowsLocalNetworking" || true)"
if [[ "$ats_local" != "true" ]]; then
  fail "NSAppTransportSecurity:NSAllowsLocalNetworking is '${ats_local:-<absent>}', expected 'true' — plain-http Home Assistant servers on the LAN would be blocked by ATS."
else
  log "  ok  NSAppTransportSecurity:NSAllowsLocalNetworking = true"
fi

# iOS 14+ withholds mDNS answers for a service type absent from this array, and
# does it silently, so a truncated list is a set of devices that simply never
# appear. The exact contents are cross-checked against the bundled catalogue by
# test/platform/ios_bonjour_catalogue_test.dart; what can only be checked here
# is that the array survived into the BUILT bundle at all.
bonjour_count="$("$PLISTBUDDY" -c "Print :NSBonjourServices" "$PLIST" 2>/dev/null | grep -c '_' || true)"
if [[ "$bonjour_count" -eq 0 ]]; then
  fail "NSBonjourServices is missing or empty in the built Info.plist — iOS delivers no mDNS answers for undeclared service types, so the Wi-Fi scan finds nothing over mDNS and reports it as an empty network."
else
  log "  ok  NSBonjourServices declares $bonjour_count service type(s)"
fi

bundle_id="$(plist_get "CFBundleIdentifier" || true)"
if [[ "$bundle_id" != "$EXPECTED_BUNDLE_ID" ]]; then
  fail "CFBundleIdentifier is '${bundle_id:-<absent>}', expected '$EXPECTED_BUNDLE_ID' — a mismatch invalidates the provisioning profile and orphans existing installs."
else
  log "  ok  CFBundleIdentifier = $bundle_id"
fi

# ── 2. Entitlements (device builds only) ────────────────────────────────────
# The multicast entitlement is the one thing this app needs that neither
# compiles nor signs into existence by accident: Apple grants it by manual
# request, it lives on the App ID, and it reaches the binary only if the
# provisioning profile used for THIS build carries it. A profile generated
# before the grant produces a perfectly valid, installable IPA whose Wi-Fi scan
# finds nothing at all, and nothing in the build log says so.
#
# Gated on embedded.mobileprovision because only a device build has one. A
# simulator bundle is signed ad-hoc or not at all and has no profile-derived
# entitlements, so asserting there would fail for the wrong reason — the same
# rule the symbol check below follows for stripped binaries.
if [[ -f "$APP/embedded.mobileprovision" ]]; then
  if ! command -v codesign >/dev/null 2>&1; then
    fail "codesign not found. This is a device build (it has an embedded.mobileprovision), so its entitlements cannot be verified and a silently unentitled IPA would pass."
  else
    ENTITLEMENTS="$WORK/entitlements.plist"
    # `--entitlements -`, not `:-`. The colon form is the old way of saying
    # "write to this path", and codesign now answers it with
    #   warning: Specifying ':' in the path is deprecated and will not work
    #            in a future release
    # on stderr (verified on Xcode 26.3) while still working. Since that
    # stderr is discarded below, the warning was invisible here and the
    # eventual removal would have arrived as this check silently failing to
    # read any entitlements at all — which is the branch that then reports a
    # bundle it could not inspect, on the one artifact that reaches a phone.
    #
    # `--xml` stays. Without it codesign prints a human-readable [Dict]/[Key]
    # tree that PlistBuddy cannot parse, so dropping it is not the fix for the
    # deprecation even though the two often get changed together.
    if codesign -d --entitlements - --xml "$APP" >"$ENTITLEMENTS" 2>/dev/null &&
       [[ -s "$ENTITLEMENTS" ]]; then
      multicast="$("$PLISTBUDDY" -c "Print :com.apple.developer.networking.multicast" "$ENTITLEMENTS" 2>/dev/null || true)"
      if [[ "$multicast" != "true" ]]; then
        fail "com.apple.developer.networking.multicast is '${multicast:-<absent>}' in the signed entitlements, expected 'true'. iOS 14+ blocks raw multicast without it, so every mDNS query and SSDP M-SEARCH this app sends is dropped and the Wi-Fi scan finds nothing. Usually this means the provisioning profile predates the entitlement being granted on the App ID — regenerate it on developer.apple.com and update IOS_PROVISIONING_PROFILE. See docs/ios-from-linux.md."
      else
        log "  ok  com.apple.developer.networking.multicast = true"
      fi
    else
      fail "Could not read the code signature's entitlements from $APP. A device build that cannot be inspected cannot be shown to carry the multicast entitlement, and an IPA without it discovers nothing over Wi-Fi."
    fi
  fi
else
  warn "No embedded.mobileprovision in the bundle — skipping the entitlements check (simulator builds carry no profile-derived entitlements)."
fi

# ── 3. Rust FFI entry points ────────────────────────────────────────────────
if [[ "$SKIP_SYMBOLS" -eq 1 ]]; then
  warn "Skipping the Rust symbol check (--skip-symbols)."
else
  if ! command -v "$NM" >/dev/null 2>&1; then
    fail "nm not found ('$NM'). Cannot verify that the Rust library was linked in."
  else
    executable="$(plist_get "CFBundleExecutable" || true)"
    candidates=()
    if [[ -n "$executable" && -f "$APP/$executable" ]]; then
      candidates+=("$APP/$executable")
    else
      fail "CFBundleExecutable ('${executable:-<absent>}') does not name a file inside the bundle."
    fi
    # Whether the pod links as a static library straight into Runner or as a
    # framework under Frameworks/ depends on the Podfile's use_frameworks!
    # setting, so search both. Either location is a pass; nowhere is a failure.
    if [[ -d "$APP/Frameworks" ]]; then
      while IFS= read -r f; do
        candidates+=("$f")
      done < <(find "$APP/Frameworks" -type f 2>/dev/null)
    fi

    # macOS ships bash 3.2, where expanding an empty array under `set -u` is an
    # "unbound variable" error rather than an empty expansion — so never index
    # into `candidates` without checking the count first.
    #
    # ONE pass over the candidates, recording every fact the verdict OR the
    # failure report could want. The old code scanned here and scanned again in
    # the diagnostics, and the two disagreed — the report insisted the symbols
    # were there while the verdict said they were not. Two scans can drift;
    # one cannot. Everything below reads these arrays, including the verdict.
    #
    # Bash 3.2 has no associative arrays; parallel indexed ones are the
    # portable stand-in.
    SCAN_BIN=(); SCAN_MACHO=(); SCAN_ARCH=(); SCAN_TOTAL=()
    SCAN_FRB=(); SCAN_CEXP=(); SCAN_MANGLED=(); SCAN_STRICT=()
    SCAN_SKIPPED=0

    found=""
    found_syms=""
    macho_list=""
    if [[ ${#candidates[@]} -gt 0 ]]; then
      idx=0
      for bin in "${candidates[@]}"; do
        symfile="$WORK/syms.$idx"
        cexpfile="$WORK/cexp.$idx"
        : >"$symfile"; : >"$cexpfile"

        # nm exits non-zero on anything that is not an object file; that is the
        # filter, so no dependency on `file` is needed. `|| nm_status=$?` rather
        # than a bare `; nm_status=$?` because `set -e` would take the failure.
        nm_status=0
        "$NM" -g "$bin" >"$symfile" 2>/dev/null || nm_status=$?

        if [[ "$nm_status" -ne 0 ]]; then
          SCAN_SKIPPED=$((SCAN_SKIPPED + 1))
          SCAN_BIN+=("$bin");  SCAN_MACHO+=(0); SCAN_ARCH+=("");  SCAN_TOTAL+=(0)
          SCAN_FRB+=(0);       SCAN_CEXP+=(0);  SCAN_MANGLED+=(0); SCAN_STRICT+=(0)
          idx=$((idx + 1))
          continue
        fi

        # NEVER write the match as `"$NM" -g "$bin" | grep -qE ...`. grep -q
        # exits at its FIRST match, nm then dies of SIGPIPE (141), and the
        # `set -o pipefail` at the top of this file makes the whole pipeline
        # non-zero — so a binary that DOES export the entry points reads as one
        # that does not. The bigger the binary the more reliably it misfires:
        # liberated_bread_core.framework carries ~39k global symbols, so nm is
        # still writing long after grep has seen what it needs. That false
        # failure is exactly what this check exists to rule out, and it accused
        # the podspec's -force_load of no-oping when the library had been
        # linked in correctly all along. Every count below reads a FILE.
        total="$(wc -l <"$symfile" | tr -d ' ')"
        strict="$(grep -cE "$FRB_SYMBOL_PATTERN" "$symfile" || true)"
        frb="$(grep -c 'frb_' "$symfile" || true)"
        awk '{ print $NF }' "$symfile" 2>/dev/null \
          | grep -E "$FRB_C_EXPORT_PATTERN" | sort -u >"$cexpfile" || true
        cexp="$(wc -l <"$cexpfile" | tr -d ' ')"

        arch="not available"
        if command -v lipo >/dev/null 2>&1; then
          arch="$(lipo -info "$bin" 2>/dev/null || echo 'lipo failed')"
        fi

        SCAN_BIN+=("$bin");   SCAN_MACHO+=(1);    SCAN_ARCH+=("$arch")
        SCAN_TOTAL+=("$total"); SCAN_FRB+=("$frb"); SCAN_CEXP+=("$cexp")
        SCAN_MANGLED+=($((frb - cexp))); SCAN_STRICT+=("$strict")
        macho_list="$macho_list ${bin#"$APP/"}"

        # The verdict reads the same number the report will print.
        if [[ -z "$found" && "$strict" -gt 0 ]]; then
          found="$bin"
          found_syms="$(grep -E "$FRB_SYMBOL_PATTERN" "$symfile" | awk '{ print $NF }' | sort -u | tr '\n' ' ')"
        fi
        idx=$((idx + 1))
      done
    fi

    if [[ -n "$found" ]]; then
      log "  ok  flutter_rust_bridge FFI entry points present in ${found#"$APP/"}"
      # Name them. "ok" alone cannot tell a bundle exporting both entry points
      # from one scraping past on a single symbol, and the next person to debug
      # an FRB version bump needs to know which names were actually there.
      log "      ${found_syms% }"
    else
      # Diagnostics FIRST, so they sit above the failure in the log rather than
      # scrolled off below it.
      diagnose_missing_ffi
      # The old message asserted a cause — "the Rust static library was not
      # linked in (podspec -force_load no-op, or cargokit produced nothing)" —
      # and both halves of that guess were wrong the one time it fired, sending
      # the reader after a podspec that was fine. It states the observation
      # now; the CONCLUSION line above names the cause from evidence.
      #
      # It also used to end by listing every candidate path, which on a real
      # bundle is ~150 lines of Info.plists, headers and bundled .yaml assets
      # scrolling the actual failure off the screen. Only the Mach-O ones can
      # possibly have carried the symbols, so only those are worth naming.
      fail "No symbol matching /$FRB_SYMBOL_PATTERN/ in any Mach-O in the bundle, so the app would crash on its first Rust call. Scanned ${#candidates[@]} file(s), of which $((${#candidates[@]} - SCAN_SKIPPED)) were Mach-O:${macho_list:- none}. See the CONCLUSION in the diagnostics above for the cause."
    fi
  fi
fi

# ── result ──────────────────────────────────────────────────────────────────
if [[ "$FAILURES" -gt 0 ]]; then
  printf '\033[1;31m[verify-ios] %d check(s) FAILED for %s\033[0m\n' "$FAILURES" "$APP" >&2
  exit 1
fi

log "All iOS bundle checks passed for $APP"
