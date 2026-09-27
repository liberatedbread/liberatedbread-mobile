#!/usr/bin/env bash
# Copyright 2026 Pigs Can Fly Labs LLC
# SPDX-License-Identifier: Apache-2.0
#
# Drive scripts/verify_apk.sh's merged-manifest permission check through its
# outcomes on any machine, without an Android SDK, a build or a real APK.
#
# WHY THIS EXISTS
#
# The check listed only four permissions. ACCESS_COARSE_LOCATION (without it
# Android 12+ ignores the FINE request), CHANGE_WIFI_MULTICAST_STATE (mDNS)
# and the API 24-30 BLUETOOTH/BLUETOOTH_ADMIN pair were just as fatal when a
# dependency's tools:node="remove" stripped them from the merged manifest,
# and none was checked. The cases below pin each one, plus the pair's
# maxSdkVersion='30' cap.
#
# HOW
#
# A minimal zip stands in for the APK (a manifest entry and one ABI's two
# libraries, above the size floor), and $AAPT2 points at a stub that prints a
# canned `aapt2 dump permissions` listing from $STUB_PERMS.

set -uo pipefail

cd "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)" || exit 1

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

command -v zip >/dev/null 2>&1 || {
  echo "zip is required for this selftest" >&2
  exit 2
}

mkdir -p "$WORK/apk/lib/arm64-v8a"
: > "$WORK/apk/AndroidManifest.xml"
head -c 70000 /dev/zero > "$WORK/apk/lib/arm64-v8a/libliberated_bread_core.so"
head -c 70000 /dev/zero > "$WORK/apk/lib/arm64-v8a/libflutter.so"
(cd "$WORK/apk" && zip -qr "$WORK/app.apk" .) || exit 1

cat > "$WORK/aapt2" <<'STUB'
#!/usr/bin/env bash
cat "$STUB_PERMS"
STUB
chmod +x "$WORK/aapt2"

GOOD="package: ca.pigscanfly.liberatedbread
uses-permission: name='android.permission.BLUETOOTH_SCAN'
uses-permission: name='android.permission.BLUETOOTH_CONNECT'
uses-permission: name='android.permission.BLUETOOTH' maxSdkVersion='30'
uses-permission: name='android.permission.BLUETOOTH_ADMIN' maxSdkVersion='30'
uses-permission: name='android.permission.ACCESS_FINE_LOCATION'
uses-permission: name='android.permission.ACCESS_COARSE_LOCATION'
uses-permission: name='android.permission.INTERNET'
uses-permission: name='android.permission.CHANGE_WIFI_MULTICAST_STATE'"

status=0

# expect <label> <want-exit: 0|1> <needle in output, or ''> <perms text>
expect() {
  local label="$1" want="$2" needle="$3" perms="$4" out rc
  printf '%s\n' "$perms" > "$WORK/perms.txt"
  out="$(STUB_PERMS="$WORK/perms.txt" AAPT2="$WORK/aapt2" \
    ./scripts/verify_apk.sh "$WORK/app.apk" 2>&1)"
  rc=$?
  if [[ "$rc" -ne "$want" ]]; then
    echo "  FAIL  $label: exit $rc, wanted $want" >&2
    printf '%s\n' "$out" | sed 's/^/        /' >&2
    status=1
  elif [[ -n "$needle" && "$out" != *"$needle"* ]]; then
    echo "  FAIL  $label: output lacks '$needle'" >&2
    printf '%s\n' "$out" | sed 's/^/        /' >&2
    status=1
  else
    echo "  ok    $label"
  fi
}

without() { printf '%s\n' "$GOOD" | grep -v "name='$1'"; }

expect "every required permission present passes" 0 "" "$GOOD"
for perm in ACCESS_COARSE_LOCATION CHANGE_WIFI_MULTICAST_STATE \
  BLUETOOTH BLUETOOTH_ADMIN; do
  expect "a stripped $perm fails" 1 \
    "does not declare android.permission.$perm " \
    "$(without "android.permission.$perm")"
done
expect "an uncapped BLUETOOTH fails" 1 \
  "android.permission.BLUETOOTH without maxSdkVersion='30'" \
  "$(printf '%s\n' "$GOOD" \
    | sed "s/name='android.permission.BLUETOOTH' maxSdkVersion='30'/name='android.permission.BLUETOOTH'/")"

if [[ "$status" -eq 0 ]]; then
  echo "verify_apk selftest: all passed"
fi
exit "$status"
