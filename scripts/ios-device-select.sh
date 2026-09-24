#!/usr/bin/env bash
# Copyright 2026 Pigs Can Fly Labs LLC
# SPDX-License-Identifier: Apache-2.0
#
# Shared by scripts/run-ios-device.sh and scripts/run-ios-device-tests.sh:
# find a paired PHYSICAL iPhone through `flutter devices --machine`. Sourced,
# not executed — it defines two functions and nothing else.
#
#   pick_ios_device [udid-or-name]   prints the UDID of the matching iPhone,
#                                    or of the first one (USB before wireless)
#                                    when no filter is given. Exit 2 when no
#                                    physical iPhone is paired, with the
#                                    reasons on stderr; exit 3 when a phone IS
#                                    paired but none matches the filter. The
#                                    two are different answers: --if-present
#                                    means "skip if there is no phone", not
#                                    "skip if the phone you named is absent",
#                                    and reporting the second as the first
#                                    told an unattended run that a suite it
#                                    never ran had passed.
#   list_ios_devices                 prints the paired iPhones, one per line.
#
# A phone is `targetPlatform == "ios"` AND `emulator == false`. A BOOTED
# simulator also reports "ios" (only a shut-down one says "ios-simulator"),
# so the platform alone is not enough — the picker used to offer a running
# simulator as "the first paired iPhone". The Mac itself reports "darwin".
# `connectionInterface` is null in this Flutter, so USB-before-wireless is
# best-effort and the listing shows the SDK string instead.
#
# The device JSON travels in an environment variable rather than on stdin:
# stdin carries the heredoc Python program, so json.load(sys.stdin) would read
# the script itself.

pick_ios_device() {
  local want="${1:-}" json
  json="$(flutter devices --machine 2>/dev/null)"
  DEVICES_JSON="$json" python3 - "$want" <<'PY'
import json as _json, os, sys

want = sys.argv[1] if len(sys.argv) > 1 else ""
try:
    devices = _json.loads(os.environ["DEVICES_JSON"])
except Exception as e:
    sys.stderr.write(f"Failed to parse flutter devices output: {e}\n")
    sys.exit(1)

iphones = [
    d for d in devices
    if d.get("targetPlatform") == "ios" and not d.get("emulator")
]

if not iphones:
    sys.stderr.write("No physical iPhones found.\n")
    sys.stderr.write("Ensure your iPhone is:\n")
    sys.stderr.write("  - Trusted on this Mac (plugged in and 'Trust' tapped)\n")
    sys.stderr.write("  - OR paired wirelessly (Xcode -> Window -> Devices -> Connect via network)\n")
    sys.exit(2)

if want:
    matches = [d for d in iphones if d.get("id") == want or d.get("name") == want]
    if not matches:
        names = ", ".join(f"{d['name']} ({d['id']})" for d in iphones)
        sys.stderr.write(f"No iPhone matching {want!r}. Available: {names}\n")
        sys.exit(3)
    print(matches[0]["id"])
    sys.exit(0)

# No filter: first one, USB preferred over wireless.
iphones.sort(key=lambda d: (0 if d.get("connectionInterface") == "usb" else 1))
print(iphones[0]["id"])
PY
}

list_ios_devices() {
  local json
  json="$(flutter devices --machine 2>/dev/null)"
  DEVICES_JSON="$json" python3 - <<'PY'
import json as _json, os, sys
try:
    devices = _json.loads(os.environ["DEVICES_JSON"])
except Exception:
    sys.exit(0)
iphones = [
    d for d in devices
    if d.get("targetPlatform") == "ios" and not d.get("emulator")
]
if not iphones:
    print("No physical iPhones found.")
else:
    print("Paired iPhones:")
    for d in iphones:
        detail = d.get("connectionInterface") or d.get("sdk") or "?"
        print(f"  {d['name']} ({d['id']})  [{detail}]")
PY
}
