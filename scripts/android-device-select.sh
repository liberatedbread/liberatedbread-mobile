#!/usr/bin/env bash
# Copyright 2026 Pigs Can Fly Labs LLC
# SPDX-License-Identifier: Apache-2.0
#
# The Android twin of scripts/ios-device-select.sh: find an attached PHYSICAL
# Android phone through `flutter devices --machine`. Sourced, not executed.
#
#   pick_android_device [serial-or-name]  prints the device id of the matching
#                                         phone, or the first one when no
#                                         filter is given. Exit 2 when none is
#                                         attached, with the reasons on stderr.
#   list_android_devices                  prints the attached phones.
#
# A phone is `targetPlatform` starting with "android" AND `emulator == false`;
# a running emulator reports the same platform with `emulator: true`.

pick_android_device() {
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

phones = [
    d for d in devices
    if str(d.get("targetPlatform", "")).startswith("android") and not d.get("emulator")
]

if not phones:
    sys.stderr.write("No physical Android phones found.\n")
    sys.stderr.write("Ensure the phone has USB debugging on, is plugged in, and\n")
    sys.stderr.write("has accepted this computer's debugging key (adb devices).\n")
    sys.exit(2)

if want:
    matches = [d for d in phones if d.get("id") == want or d.get("name") == want]
    if not matches:
        names = ", ".join(f"{d['name']} ({d['id']})" for d in phones)
        sys.stderr.write(f"No Android phone matching {want!r}. Available: {names}\n")
        sys.exit(2)
    print(matches[0]["id"])
    sys.exit(0)

print(phones[0]["id"])
PY
}

list_android_devices() {
  local json
  json="$(flutter devices --machine 2>/dev/null)"
  DEVICES_JSON="$json" python3 - <<'PY'
import json as _json, os, sys
try:
    devices = _json.loads(os.environ["DEVICES_JSON"])
except Exception:
    sys.exit(0)
phones = [
    d for d in devices
    if str(d.get("targetPlatform", "")).startswith("android") and not d.get("emulator")
]
if not phones:
    print("No physical Android phones found.")
else:
    print("Attached Android phones:")
    for d in phones:
        print(f"  {d['name']} ({d['id']})  [{d.get('sdk') or '?'}]")
PY
}
