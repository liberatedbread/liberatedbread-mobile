#!/usr/bin/env bash
# Copyright 2026 Pigs Can Fly Labs LLC
# SPDX-License-Identifier: Apache-2.0
#
# Drive scripts/verify_ios_app.sh through its outcomes on any machine, without
# a Mac, a bundle, or a build.
#
# WHY THIS EXISTS
#
# verify_ios_app.sh only ever runs on the macOS job — the one that bills at 10x
# — and against an artifact that takes ten minutes to produce. So its own bugs
# surface the most expensive way there is: as a red run on somebody's branch,
# blaming the build for something the verifier got wrong.
#
# That is not hypothetical. The symbol check was written as
#
#     nm -g "$bin" | grep -qE "$FRB_SYMBOL_PATTERN"
#
# which is wrong under the `set -o pipefail` at the top of the file. grep -q
# exits at its FIRST match; nm, still writing, takes a SIGPIPE and exits 141;
# pipefail promotes that to a failed pipeline; the `if` reads "no match". A
# bundle that exported the entry points perfectly was reported as one where
# "the Rust static library was not linked in", and the message sent the reader
# after the podspec's -force_load, which had never been the problem. The bigger
# the binary, the more reliable the misfire — liberated_bread_core.framework
# carries ~39k global symbols, so nm is a long way from done when grep leaves.
#
# The diagnostics printed alongside that failure used `grep -c`, which consumes
# all of nm's output and so never trips the same wire. They cheerfully reported
# thousands of frb_ symbols in the very binary the check had just called empty.
#
# So the case that matters below is SYMBOLS PRESENT, BEHIND A LOT OF OUTPUT.
# A stub that prints the entry point and stops would pass against the broken
# code and prove nothing. NOISE_LINES is what gives this teeth: the match comes
# early, tens of thousands of lines come after it, and the stub — like real nm
# — dies of SIGPIPE when the reader walks away.
#
# HOW
#
# Stub `nm` and PlistBuddy as real executables on PATH, both driven by the
# environment, and point the script at a fake .app tree. Both stubs are honest
# about the one behaviour the script's control flow leans on: nm exits non-zero
# on anything that is not an object file, and PlistBuddy exits non-zero on a
# key that is absent.
#
# Usage: ./scripts/verify-ios-app-selftest.sh

set -uo pipefail

cd "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)" || exit 1

UNDER_TEST="scripts/verify_ios_app.sh"
# Enough output that grep -q is certain to leave before the stub is done. Real
# nm on the framework prints ~39k lines; this is the same order of magnitude.
NOISE_LINES="${NOISE_LINES:-40000}"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

PASS=0
FAIL=0

ok()   { printf '\033[1;32m  PASS\033[0m %s\n' "$*"; PASS=$((PASS + 1)); }
bad()  { printf '\033[1;31m  FAIL\033[0m %s\n' "$*"; FAIL=$((FAIL + 1)); }

# `cond && ok ... || bad ...` is the shape shellcheck's SC2015 warns about and
# it is worth avoiding for real here: `ok` runs at the end of the && chain, so
# anything that made IT return non-zero would silently also run `bad`. These
# take the condition as an already-evaluated status instead.
want_pass() { if [[ "$1" -eq 0 ]]; then ok "$2"; else bad "$2 — exited $1 instead"; fi; }
want_fail() { if [[ "$1" -ne 0 ]]; then ok "$2"; else bad "$2 — but the run passed"; fi; }

# ── stubs ───────────────────────────────────────────────────────────────────
BIN="$WORK/bin"
mkdir -p "$BIN"

# PlistBuddy, backed by a KEY<TAB>VALUE sidecar next to the plist it is asked
# to read. Absent key => non-zero exit, which is what lets the script tell a
# missing key from an empty one.
cat > "$BIN/PlistBuddy" <<'STUB'
#!/usr/bin/env bash
# usage: PlistBuddy -c "Print :KEY" /path/to/Info.plist
key=""; plist=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -c) key="${2#Print :}"; shift 2 ;;
    *)  plist="$1"; shift ;;
  esac
done
kv="$plist.kv"
# No sidecar? Read the file itself. The entitlements plist the script extracts
# with codesign is written by our codesign stub in this same KEY<TAB>VALUE
# form, so one reader serves both without the stub needing to know the
# script's private temp path.
[[ -f "$kv" ]] || kv="$plist"
[[ -f "$kv" ]] || exit 1
# A value may span lines (arrays); blank-line terminated in the sidecar.
awk -F'\t' -v k="$key" '
  $1 == k { found = 1; print $2; next }
  found && $1 == "" && $2 != "" { print $2; next }
  found && $1 != "" { exit }
  END { exit !found }
' "$kv"
STUB
chmod +x "$BIN/PlistBuddy"

# codesign, so the ENTITLEMENTS branch is exercised at all.
#
# That branch only runs when the bundle carries an embedded.mobileprovision,
# i.e. on a signed device build — which exists nowhere but the ad-hoc workflow,
# on a 10x-billed macOS runner, behind repository secrets. So the one check
# standing between a profile that predates the multicast grant and an IPA that
# installs, launches, and silently discovers nothing over Wi-Fi had never been
# executed by anything. Stubbing codesign lets every case below run on Linux,
# which is where this selftest runs.
#
# CODESIGN_MODE picks the behaviour:
#   granted   entitlements XML with the multicast key true
#   denied    entitlements XML with the key false (a profile predating the grant)
#   absent    entitlements XML with no multicast key at all
#   unreadable  non-zero exit, as codesign does on an unsigned bundle
#   empty     exit 0 but write nothing (the -s guard's case)
cat > "$BIN/codesign" <<'STUB'
#!/usr/bin/env bash
# usage: codesign -d --entitlements :- --xml <app>
# The script redirects our stdout into its own entitlements plist and reads it
# back with PlistBuddy, so emit the KEY<TAB>VALUE form that stub understands.
case "${CODESIGN_MODE:-granted}" in
  unreadable) exit 1 ;;
  empty)      exit 0 ;;
  denied)     printf 'com.apple.developer.networking.multicast\tfalse\n' ;;
  absent)     printf 'some.other.entitlement\ttrue\n' ;;
  *)          printf 'com.apple.developer.networking.multicast\ttrue\n' ;;
esac
STUB
chmod +x "$BIN/codesign"

# nm, driven by a per-file manifest so one case can say "the framework exports
# the entry points, the staticlib does not" — which is exactly the kind of
# split the CONCLUSION logic has to tell apart. NM_MANIFEST holds
# `<basename><TAB><mode>` lines; NM_DEFAULT_MODE covers everything else.
#
#   entry    the real flutter_rust_bridge C entry points, among mangled noise
#   renamed  frb_ C exports under DIFFERENT names — the FRB-version-bump case
#   mangled  mangled frb_generated symbols only, no C export at all
#   bare     no frb_ symbol of any kind
#
# Anything ending in .plist is treated as not-an-object-file, exactly as real
# nm does, since the script uses nm's exit status as that filter.
cat > "$BIN/nm" <<'STUB'
#!/usr/bin/env bash
bin=""
for a in "$@"; do case "$a" in -*) ;; *) bin="$a" ;; esac; done
[[ -f "$bin" ]] || exit 1
case "$bin" in *.plist) exit 1 ;; esac

n="${NM_NOISE_LINES:-40000}"
name="$(basename "$bin")"
mode="${NM_DEFAULT_MODE:-mangled}"
if [[ -n "${NM_MANIFEST:-}" && -f "${NM_MANIFEST:-}" ]]; then
  while IFS=$'\t' read -r k v; do
    [[ "$k" == "$name" ]] && mode="$v"
  done < "$NM_MANIFEST"
fi

# Plain C++/Rust symbols with no frb_ anywhere, so `bare` is genuinely bare.
noise_bare() { awk -v n="$1" 'BEGIN { for (i = 0; i < n; i++)
  printf "%016x T __ZN20liberated_bread_core4core%dE\n", i, i }'; }

# Mangled Rust symbols carrying the frb_generated module path. These match a
# loose /frb_/ grep and are NOT C entry points — the exact pair that made the
# original diagnostics disagree with the verdict.
noise_mangled() { awk -v n="$1" 'BEGIN { for (i = 0; i < n; i++)
  printf "%016x T __ZN20liberated_bread_core13frb_generated%dE\n", i, i }'; }

case "$mode" in
  bare) noise_bare 50 ;;
  *)    noise_mangled 50 ;;
esac

case "$mode" in
  entry)
    printf '%016x T _frb_get_rust_content_hash\n' 1
    printf '%016x T _frb_pde_ffi_dispatcher_primary\n' 2
    ;;
  renamed)
    printf '%016x T _frb_v3_dispatcher_primary\n' 1
    printf '%016x T _frb_v3_content_hash\n' 2
    ;;
esac

# The tail that makes the SIGPIPE real. If the reader has gone, this stub dies
# of it — which is the point.
case "$mode" in
  bare) noise_bare "$n" ;;
  *)    noise_mangled "$n" ;;
esac
STUB
chmod +x "$BIN/nm"

# ── fixture ─────────────────────────────────────────────────────────────────
# $1: dir to build the .app in. Produces a bundle that passes every non-symbol
# check, so a case can change exactly one thing.
make_app() {
  local app="$1/Runner.app"
  mkdir -p "$app/Frameworks/liberated_bread_core.framework"
  : > "$app/Info.plist"
  printf 'x' > "$app/Runner"
  printf 'x' > "$app/Frameworks/liberated_bread_core.framework/liberated_bread_core"
  printf 'x' > "$app/Frameworks/Flutter.framework_stub"
  cat > "$app/Info.plist.kv" <<KV
NSBluetoothAlwaysUsageDescription	Liberated Bread needs Bluetooth.
NSBluetoothPeripheralUsageDescription	Liberated Bread needs Bluetooth.
NSLocalNetworkUsageDescription	Liberated Bread finds IoT devices.
NSPhotoLibraryUsageDescription	Liberated Bread prints your photos.
NSCameraUsageDescription	Liberated Bread prints your photos.
NSAppTransportSecurity:NSAllowsLocalNetworking	true
CFBundleIdentifier	ca.pigscanfly.liberatedbread
CFBundleExecutable	Runner
NSBonjourServices	Array {
	    _http._tcp
	    _googlecast._tcp
	}
KV
  printf '%s\n' "$app"
}

# Write an nm manifest and echo its path.
#   manifest <dir> <basename>=<mode> ...
manifest() {
  local dir="$1"; shift
  local f="$dir/nm.manifest" entry
  : >"$f"
  for entry in "$@"; do
    printf '%s\t%s\n' "${entry%%=*}" "${entry#*=}" >>"$f"
  done
  printf '%s\n' "$f"
}

# A fake cargokit output tree, so the CONCLUSION's staticlib branches are
# driven by a fixture rather than by whatever is in this checkout's
# rust/target — which differs between a dev machine and the CI runner and would
# make these assertions flap.
staticlib_dir() {
  local d="$1/rust-target/debug"
  mkdir -p "$d"
  [[ "${2:-}" == "empty" ]] || printf 'x' > "$d/libliberated_bread_core.a"
  printf '%s\n' "$1/rust-target"
}

# Run the script under the stubs. Echoes combined output; returns its status.
#   NM_MANIFEST / NM_DEFAULT_MODE / RUST_TARGET_DIR come from the environment.
run_verify() {
  PATH="$BIN:$PATH" PLISTBUDDY="$BIN/PlistBuddy" NM="$BIN/nm" \
    NM_NOISE_LINES="$NOISE_LINES" \
    RUST_TARGET_DIR="${RUST_TARGET_DIR:-$WORK/no-such-target}" \
    bash "$UNDER_TEST" "$@" 2>&1
}

# Set SELFTEST_DUMP=1 to see what a case actually printed. The reason this
# script exists is that nobody could see the report without a 10x macOS run;
# not being able to see it from here would be a poor trade.
dump() {
  [[ -n "${SELFTEST_DUMP:-}" ]] || return 0
  printf '%s\n' "$1" | sed 's/^/       | /'
}

printf '\033[1;36m[selftest]\033[0m %s (noise: %s lines)\n' "$UNDER_TEST" "$NOISE_LINES"

# ── 1. the regression ───────────────────────────────────────────────────────
# The entry points ARE exported, from the framework, with a great deal of nm
# output after them. This is the case the pipefail bug failed.
c="$WORK/c1"; mkdir -p "$c"; app="$(make_app "$c")"
out="$(NM_MANIFEST="$(manifest "$c" liberated_bread_core=entry)" run_verify "$app")"; st=$?
if [[ $st -eq 0 ]]; then
  ok "entry points in a framework, behind $NOISE_LINES lines of nm output => exit 0"
else
  bad "entry points present but the script exited $st (the grep -q/pipefail SIGPIPE bug is back)"
  printf '%s\n' "$out" | sed 's/^/       /'
fi

# A green run must still say WHICH symbols it found. "ok" on its own cannot
# tell a bundle exporting both entry points from one scraping past on a single
# symbol, and an FRB version bump is debugged from these names.
if grep -q 'frb_pde_ffi_dispatcher_primary' <<<"$out" &&
   grep -q 'frb_get_rust_content_hash' <<<"$out"; then
  ok "a passing run names the entry points it matched"
else
  bad "a passing run did not name the matched symbols"
  dump "$out"
fi

# Same thing, exported from the main executable instead: either location is a
# pass, and the loop must not stop at the first candidate it cannot match.
c="$WORK/c2"; mkdir -p "$c"; app="$(make_app "$c")"
out="$(NM_MANIFEST="$(manifest "$c" Runner=entry)" run_verify "$app")"; st=$?
want_pass "$st" "entry points in the main executable => exit 0"

# ── 2. genuinely missing ────────────────────────────────────────────────────
# No binary exports them. Must fail, and must print the diagnostics.
c="$WORK/c3"; mkdir -p "$c"; app="$(make_app "$c")"
out="$(run_verify "$app")"; st=$?
dump "$out"
if [[ $st -ne 0 ]]; then
  ok "no entry points anywhere => non-zero exit"
else
  bad "no entry points anywhere but the script passed — the check asserts nothing"
fi
grep -q 'FFI diagnostics' <<<"$out"
want_pass $? "a missing-FFI failure prints the diagnostics block"

# The line the original report was missing. Thousands of frb_ mentions that are
# all mangled Rust symbols is the exact reading that sent the last
# investigation after an innocent podspec, so the split has to be stated, not
# left as one loose count for the reader to misread.
if grep -qE '[0-9]+ symbols mention frb_: [0-9]+ C export\(s\), [0-9]+ mangled' <<<"$out"; then
  ok "the report splits frb_ mentions into C exports vs mangled Rust symbols"
else
  bad "the report gives no C-export/mangled split — a bare frb_ count misleads"
  dump "$out"
fi

# The whole point of the rewrite: do not make somebody infer the cause at 10x.
grep -q 'CONCLUSION:' <<<"$out"
want_pass $? "a missing-FFI failure prints a CONCLUSION"

# The failure line must not repeat the old guess about -force_load, and must
# not dump every Info.plist and bundled .yaml in the bundle.
if grep -q 'force_load no-op' <<<"$out"; then
  bad "the failure message still asserts a cause it has not established"
else
  ok "the failure message states the observation, not a guessed cause"
fi

# ── 3. each cause reaches a different conclusion ────────────────────────────
# mangled symbols but no C export at all: linked, then stripped.
c="$WORK/c8"; mkdir -p "$c"; app="$(make_app "$c")"
out="$(NM_DEFAULT_MODE=mangled run_verify "$app")"; st=$?
if grep -q 'stripped or hidden' <<<"$out"; then
  ok "mangled symbols but no C exports => 'linked, then stripped' conclusion"
else
  bad "mangled-only bundle did not reach the stripped/hidden conclusion"
  dump "$out"
fi

# C exports present under other names: an FRB rename, fixed in this script.
c="$WORK/c9"; mkdir -p "$c"; app="$(make_app "$c")"
out="$(NM_MANIFEST="$(manifest "$c" liberated_bread_core=renamed)" run_verify "$app")"; st=$?
if grep -q 'renamed them' <<<"$out" && grep -q 'frb_v3_dispatcher_primary' <<<"$out"; then
  ok "frb_ C exports under other names => 'renamed' conclusion, and names them"
else
  bad "a renamed-entry-point bundle did not reach the rename conclusion"
  dump "$out"
fi

# Nothing of the crate anywhere, and no staticlib either: the build never ran.
c="$WORK/c10"; mkdir -p "$c"; app="$(make_app "$c")"
out="$(NM_DEFAULT_MODE=bare RUST_TARGET_DIR="$(staticlib_dir "$c" empty)" run_verify "$app")"; st=$?
if grep -q 'did not run or failed silently' <<<"$out"; then
  ok "no crate code and no staticlib => 'the Rust build never ran' conclusion"
else
  bad "an empty rust/target did not reach the 'build never ran' conclusion"
  dump "$out"
fi

# Staticlib on disk exporting the entry points, none of it in the bundle: the
# one case where -force_load really is the suspect. The old message said this
# every time, including when it was wrong; it has to be earned now.
c="$WORK/c11"; mkdir -p "$c"; app="$(make_app "$c")"
rt="$(staticlib_dir "$c")"
out="$(NM_DEFAULT_MODE=bare \
       NM_MANIFEST="$(manifest "$c" libliberated_bread_core.a=entry)" \
       RUST_TARGET_DIR="$rt" run_verify "$app")"; st=$?
if grep -q 'force_load' <<<"$out" && grep -q 'exports the entry points: yes' <<<"$out"; then
  ok "staticlib exports them but the bundle has nothing => '-force_load' conclusion"
else
  bad "a linked-but-not-loaded staticlib did not reach the -force_load conclusion"
  dump "$out"
fi

# Staticlib present but exporting nothing: upstream of the linker.
c="$WORK/c12"; mkdir -p "$c"; app="$(make_app "$c")"
out="$(NM_DEFAULT_MODE=bare RUST_TARGET_DIR="$(staticlib_dir "$c")" run_verify "$app")"; st=$?
if grep -q 'upstream of the linker' <<<"$out"; then
  ok "a staticlib exporting nothing => 'upstream of the linker' conclusion"
else
  bad "a symbol-less staticlib did not reach the upstream conclusion"
  dump "$out"
fi

# ── 4. the job summary ──────────────────────────────────────────────────────
# On GitHub the report has to land somewhere it will be read, not at line 900
# of a macOS log.
c="$WORK/c13"; mkdir -p "$c"; app="$(make_app "$c")"
summary="$c/summary.md"; : >"$summary"
out="$(GITHUB_STEP_SUMMARY="$summary" run_verify "$app")"; st=$?
if grep -q 'CONCLUSION:' "$summary"; then
  ok "the diagnostics are written to \$GITHUB_STEP_SUMMARY when CI sets it"
else
  bad "nothing reached \$GITHUB_STEP_SUMMARY — the report stays buried in the log"
fi

# ── 5. --skip-symbols ───────────────────────────────────────────────────────
c="$WORK/c4"; mkdir -p "$c"; app="$(make_app "$c")"
out="$(run_verify "$app" --skip-symbols)"; st=$?
want_pass "$st" "--skip-symbols passes a bundle with no entry points"

# ── 6. the plist checks still bite ──────────────────────────────────────────
# Guards the fixture as much as the script: if make_app produced a bundle that
# passes for the wrong reason, these would not fail either.
c="$WORK/c5"; mkdir -p "$c"; app="$(make_app "$c")"
mf="$(manifest "$c" liberated_bread_core=entry)"
grep -v 'NSBluetoothAlwaysUsageDescription' "$app/Info.plist.kv" > "$app/Info.plist.kv.t"
mv "$app/Info.plist.kv.t" "$app/Info.plist.kv"
out="$(NM_MANIFEST="$mf" run_verify "$app")"; st=$?
if [[ $st -ne 0 ]] && grep -q 'NSBluetoothAlwaysUsageDescription' <<<"$out"; then
  ok "a missing NSBluetoothAlwaysUsageDescription fails the run, and says which key"
else
  bad "a missing BLE usage string did not fail the run by name (exit $st)"
fi

c="$WORK/c6"; mkdir -p "$c"; app="$(make_app "$c")"
mf="$(manifest "$c" liberated_bread_core=entry)"
# -i.bak, not bare -i: BSD sed takes the next word as the backup suffix, and
# the header says "on any machine" — a Mac is where the tool under test runs.
sed -i.bak 's|^\(NSAppTransportSecurity:NSAllowsLocalNetworking\t\).*|\1false|' "$app/Info.plist.kv"
rm -f "$app/Info.plist.kv.bak"
out="$(NM_MANIFEST="$mf" run_verify "$app")"; st=$?
want_fail "$st" "NSAllowsLocalNetworking=false fails the run"

c="$WORK/c7"; mkdir -p "$c"; app="$(make_app "$c")"
mf="$(manifest "$c" liberated_bread_core=entry)"
sed -i.bak 's|^\(CFBundleIdentifier\t\).*|\1com.example.wrong|' "$app/Info.plist.kv"
rm -f "$app/Info.plist.kv.bak"
out="$(NM_MANIFEST="$mf" run_verify "$app")"; st=$?
want_fail "$st" "a drifted CFBundleIdentifier fails the run"

# ── 7. a missing bundle is not a vacuous pass ───────────────────────────────
out="$(run_verify "$WORK/does-not-exist.app")"; st=$?
want_fail "$st" "a nonexistent bundle path fails"

# ── 8. the pattern, against the real crate ──────────────────────────────────
# Everything above runs on stubs, which proves the LOGIC and nothing about the
# names. FRB_SYMBOL_PATTERN is a claim about what flutter_rust_bridge actually
# exports, and the only thing that would have caught a rename was the 10x macOS
# job going red for a reason it could not explain.
#
# So when this machine has a real staticlib lying around — a dev box, or the
# Linux job that builds the crate anyway — check the claim against it. Same
# symbol names on both platforms, modulo the leading underscore Mach-O adds,
# which is why the pattern allows it. Skipped, loudly, when there is nothing to
# check: a silent skip here would be indistinguishable from a pass.
real_lib=""
for cand in rust/target/*/libliberated_bread_core.a rust/target/*/libliberated_bread_core.so; do
  [[ -f "$cand" ]] && { real_lib="$cand"; break; }
done

if [[ -z "$real_lib" ]]; then
  printf '\033[1;33m  SKIP\033[0m no rust/target staticlib here — build the crate to check the real symbol names\n'
elif ! command -v nm >/dev/null 2>&1; then
  printf '\033[1;33m  SKIP\033[0m no real nm on PATH — cannot check the symbol names\n'
else
  pattern="$(bash "$UNDER_TEST" --print-symbol-pattern)"
  real_syms="$(nm -g "$real_lib" 2>/dev/null || true)"
  strict="$(grep -cE "$pattern" <<<"$real_syms" || true)"
  if [[ "$strict" -gt 0 ]]; then
    ok "FRB_SYMBOL_PATTERN still matches the real crate ($real_lib)"
  else
    bad "FRB_SYMBOL_PATTERN matches nothing in $real_lib — flutter_rust_bridge renamed its entry points; the iOS job would go red blaming the build"
    printf '       the frb_ C exports it DOES have:\n'
    awk '{ print $NF }' <<<"$real_syms" \
      | grep -E '^_?frb_[A-Za-z0-9_]*$' | sort -u | sed 's/^/         /'
  fi

  # And the reading that started all this: a loose frb_ grep is dominated by
  # mangled symbols carrying the frb_generated module path, so it can never
  # stand in for the export check. Assert the gap is real on a real binary, so
  # nobody "simplifies" the diagnostics back to one number.
  loose="$(grep -c 'frb_' <<<"$real_syms" || true)"
  cexp="$(awk '{ print $NF }' <<<"$real_syms" | grep -cE '^_?frb_[A-Za-z0-9_]*$' || true)"
  if [[ "$loose" -gt "$cexp" ]]; then
    ok "on the real crate a loose frb_ grep counts $loose but only $cexp are C exports"
  else
    bad "expected mangled frb_generated symbols to outnumber the C exports on a real binary ($loose vs $cexp)"
  fi
fi

# ── entitlements on a signed device build ───────────────────────────────────
# The branch this covers is the one that decides whether an IPA carrying a
# provisioning profile older than the multicast grant reaches a tester. Its
# failure mode is not a crash: the app installs, launches, scans, and reports
# "nothing answered on this network" forever. Until now nothing exercised it,
# because it needs both a codesign and an embedded.mobileprovision and so only
# ever ran on the signed ad-hoc build — which is gated behind secrets on a
# 10x-billed runner, and skipped the check anyway when they were absent.
#
# `signed_app` adds the profile marker to the standard fixture; CODESIGN_MODE
# drives the stub.
signed_app() {
  local app
  app="$(make_app "$1")"
  printf 'profile' > "$app/embedded.mobileprovision"
  printf '%s\n' "$app"
}

c="$WORK/ent-granted"; mkdir -p "$c"; app="$(signed_app "$c")"
out="$(CODESIGN_MODE=granted NM_MANIFEST="$(manifest "$c" liberated_bread_core=entry)" run_verify "$app")"; st=$?
want_pass "$st" "signed bundle whose entitlements grant multicast => exit 0"
if grep -q 'com.apple.developer.networking.multicast = true' <<<"$out"; then
  ok "a granted run says so, rather than passing silently"
else
  bad "a granted run did not name the entitlement it checked"
  dump "$out"
fi

c="$WORK/ent-denied"; mkdir -p "$c"; app="$(signed_app "$c")"
out="$(CODESIGN_MODE=denied NM_MANIFEST="$(manifest "$c" liberated_bread_core=entry)" run_verify "$app")"; st=$?
want_fail "$st" "multicast entitlement present but false => non-zero"
if grep -q 'provisioning profile predates' <<<"$out"; then
  ok "the failure names the usual cause (a profile predating the grant)"
else
  bad "the failure did not point at the provisioning profile"
  dump "$out"
fi

c="$WORK/ent-absent"; mkdir -p "$c"; app="$(signed_app "$c")"
out="$(CODESIGN_MODE=absent NM_MANIFEST="$(manifest "$c" liberated_bread_core=entry)" run_verify "$app")"; st=$?
want_fail "$st" "multicast entitlement missing entirely => non-zero"

# An unsigned or unreadable signature must not pass quietly: a device build
# that cannot be inspected cannot be shown to carry the entitlement.
c="$WORK/ent-unreadable"; mkdir -p "$c"; app="$(signed_app "$c")"
out="$(CODESIGN_MODE=unreadable NM_MANIFEST="$(manifest "$c" liberated_bread_core=entry)" run_verify "$app")"; st=$?
want_fail "$st" "codesign cannot read the signature => non-zero"

c="$WORK/ent-empty"; mkdir -p "$c"; app="$(signed_app "$c")"
out="$(CODESIGN_MODE=empty NM_MANIFEST="$(manifest "$c" liberated_bread_core=entry)" run_verify "$app")"; st=$?
want_fail "$st" "codesign exits 0 but writes nothing => non-zero (the -s guard)"

# The skip path is a pass, and has to stay one: the simulator bundle CI builds
# has no profile, and asserting there would fail for the wrong reason.
c="$WORK/ent-unsigned"; mkdir -p "$c"; app="$(make_app "$c")"
out="$(NM_MANIFEST="$(manifest "$c" liberated_bread_core=entry)" run_verify "$app")"; st=$?
want_pass "$st" "no embedded.mobileprovision => entitlements check skipped, not failed"
if grep -q 'skipping the entitlements check' <<<"$out"; then
  ok "the skip is announced rather than silent"
else
  bad "the skip was silent, so a simulator bundle looks like a verified device build"
  dump "$out"
fi

# ── result ──────────────────────────────────────────────────────────────────
printf '\033[1;36m[selftest]\033[0m %d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
