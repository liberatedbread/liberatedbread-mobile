# iRobot Roomba (WiFi models) — Local MQTT Research Notes

## What it is
iRobot Roomba WiFi-connected models: 690/890, 960/980 (first with local
API), e5/e6, i3–i8, j7/j9, s9, plus Braava jet m6. All run a local TLS
MQTT broker on the robot itself — the same channel the official app uses on
the LAN. iRobot filed Chapter 11 on 2025-12-14 and was acquired by
Shenzhen Picea Robotics (completed 2026-01-23) — the local path matters
more than ever.

## Local protocol (dorita980 / roombapy, community-confirmed)
- Discovery: UDP 5678 — robots announce via broadcast ("irobot" msg with
  robotname, IP, MAC, BLID); mDNS 5353 also seen in traffic captures.
- Control: MQTT over TLS, TCP 8883 on the robot. Auth: username = BLID
  (80-bit robot id), password = per-device 7+ char secret.
- Publish command topics (`cmd` JSON: `{"command":"start"...}` /
  `{"command":"dock"}`), robot publishes full state on `$aws/things/...`-like
  shadow topics. Libraries: koalazak/dorita980 (Node), rest980 (REST shim),
  pschmitt/roombapy (Python, used by HA core `roomba`, iot_class
  local_polling), homebridge-roomba2.

## Password extraction — no cloud required
- **Local method (account-free)**: put the robot in password-disclosure
  mode (hold the Home button ~2 s until the tone on 900/i/s series; robot
  must be on the dock, app/cloud NOT connected), then run
  `get-roomba-password <ip>` (dorita980) or roombapy's discovery — the tool
  connects to 8883 and reads BLID+password directly. Works fully offline.
- **Cloud fallback**: `get-roomba-password-cloud <email> <pass>` via the
  iRobot account. Password reportedly changes on factory reset only.
- Gotchas: the robot accepts only ONE local MQTT client at a time (a new
  client kicks the old); HA/polling tools must use non-continuous mode or
  the app stops working locally.

## Model-level dud: 2025+ Roombas
The 2025 reboot line (Roomba 105/205/Combo 405 etc., "V4 protocol")
actively refuses local MQTT connections on 8883 — connection refused, not
timeout (HA community, 2026-04, Roomba 105 firmware p25-105). Cloud
credentials still retrievable but local broker is gone. Stick to ≤2024
models for local control.

## APK
- iRobot app `com.irobot.home` — not fetched (protocol fully documented by
  dorita980/roombapy). Fetchability unverified.

## Open questions
1. Whether Picea-era firmware updates disable the local broker on older
   models (no evidence as of 2026-08; worth monitoring).
2. j7 local quirks: getpassword occasionally fails with TLS resets on some
   firmware (homebridge-roomba issue #81) — retry loop / different button
   timing documented in issue trackers.
