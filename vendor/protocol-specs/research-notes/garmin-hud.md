# Garmin HUD / HUD+ head-up display — Research Notes

## What it is
Small dashboard VFD projector HUD (2013) that received turn-by-turn arrows,
speed, ETA and traffic from a **Bluetooth Classic SPP** link to Garmin's
smartphone nav apps (Garmin StreetPilot, NAVIGON). HUD and HUD+ discontinued
**2015**; both companion apps delisted years ago. Garmin the company is alive —
this is an abandoned *product*, fully local by design.

Sources:
- https://support.garmin.com/en-US/?faq=xgAlyUFAi81F73NWoSZ2Y5 ("discontinued in 2015")
- https://hackaday.com/2022/10/30/garmin-hud-got-discontinued-but-not-trashed/

## Community RE: protocol is public and implemented
- `github.com/andydoswell/ESP32-Garmin-Hud` — working ESP32 master that pairs
  with the HUD and drives speed/time/compass/direction from a bare GPS module,
  no phone at all. Credits upstream RE by **gabonator, Frank Huebenthal and
  skyforce Shen** (Gabonator's original C# write-up is the root document).
- Third-party Android app by skyforce Shen also drove the HUD standalone.

## Pairing (verified from ESP32 implementation)
- Discovery name `GARMIN HUD+`, PIN `1234`, standard SPP/RFCOMM
  (ESP32 `BluetoothSerial` master connects by name — no auth beyond PIN).
- Any SPP-capable host (Linux `rfcomm`, pyserial-over-rfcomm, ESP32) can drive it.

## Wire protocol (from ESP32-Garmin-Hud source)
Frame = DLE-stuffed packet over the SPP stream:
```
0x10 0x7B  <len=payload+6>  <payloadLen> 0x00 0x00 0x00  0x55 0x15  <payload...>
<checksum>  0x10 0x03
```
- `0x10` bytes inside payload are escaped as `0x10 0x10`; if len == 0x0A an
  extra 0x10 is inserted.
- checksum = `-(0xEB + 2*payloadLen + sum(payload)) & 0xFF`.
- First payload byte = command:
  - `0x01` turn arrow/direction (angle bitmask: 0x10 straight, 0x04 right, ...,
    roundabout in/out encoding)
  - `0x02` lane guidance (arrow + outline)
  - `0x03` distance to turn (4 digits + decimal flag + units enum
    0=none 1=m 3=km 5=mi)
  - `0x05` clock (with traffic/colon flags)
  - `0x06` speed / speed-limit (digits, speeding + slash + icon flags)
- Digit encoding: digit value, with 0 rendered as `0x0A`.
- Brightness/config frames use sub-header `0x56 0x15` (e.g. auto-brightness:
  `10 7B 0E 08 00 00 00 56 15 02 00 00 00 00 00 00 00 02 10 03`).

## APK provenance
- Companion apps (`com.navigon.navigator`, `com.garmin.android.apps.streetpilot`)
  both delisted; **not fetchable** via apkeep/apk-pure (tried 2026-08-04).
- Irrelevant for local control: protocol is fully specified by the open-source
  implementations above.

## Local feasibility: CONFIRMED (easy)
No cloud ever involved. ESP32 port is a complete, compilable reference client.

## Safety
Display-only VFD; no vehicle bus connection. LOW.
