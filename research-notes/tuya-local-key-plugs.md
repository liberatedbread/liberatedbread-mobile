# Generic Tuya Wi-Fi Smart Plugs (pre-2.0 / local-key era) — Research Notes

## What it is
The enormous ecosystem of Tuya-based Wi-Fi smart plugs sold under hundreds of
white-label brands (Gosund, Teckin, Avatar, Nooie, older Meross, etc.),
controlled by the Smart Life / Tuya Smart apps. Tuya the company is alive;
"pre-2.0 era" here means devices whose local-key LAN protocol (protocol
versions 3.1/3.3/3.4) is fully understood and controllable without the cloud
at runtime.

## Local protocol — confirmed
Reference implementations: [codetheweb/tuyapi](https://github.com/codetheweb/tuyapi),
[jasonacox/tinytuya](https://github.com/jasonacox/tinytuya),
HA `localtuya` custom integration, and the
[housetuya protocol writeup](https://github.com/pascal-fb-martin/housetuya):

- **Discovery**: devices broadcast UDP on **6666** (and 6667); payload begins
  `0x000055aa`, ends `0x0000aa55`, contains device id, product key and
  protocol version.
- **Control**: TCP **6668**, framed messages (55aa header, sequence, command
  byte, length, CRC32, aa55 trailer) wrapping AES-encrypted JSON. Encryption:
  AES-128-ECB keyed by the per-device **local key** (16-char string, set at
  factory/pairing); protocol 3.4 adds session-key negotiation.
- **Data model**: DPS (data points). For a plug, dp 1 = switch bool;
  metering plugs add dp 17-20 (current mA, power 0.1W, voltage 0.1V —
  varies per product; tinytuya's scanner dumps them).

## The one cloud step: local-key extraction
Local control itself needs zero cloud, but obtaining the local key
historically did. Options, best first:

1. **Tuya IoT developer account + tinytuya/tuya-cli "wizard"** (one-time):
   pair the plug in Smart Life, link the app account to a free Tuya IoT
   project, wizard pulls device id + local key. This is a **one-time cloud
   dependency**; afterwards the device can be WAN-blocked forever. Tuya has
   threatened/broken this flow several times — verify current status.
2. **Sniff the pairing exchange** with older app versions (key was
   observable on the LAN during initial pairing; largely closed in newer
   app/fw).
3. **tuya-convert** (pre-2019 firmware only): fake-OTA flash to Tasmota —
   replaces the whole problem; target firmware is rare now.
4. Root/uart extraction on ESP82xx or BK7231 units (or flash
   OpenBeken/ESPHome) — cloud-free but hardware surgery.

## Rating
Confirmed for control (massive deployed base of tinytuya/localtuya users);
the honest caveat is the one-time provisioning/key-extraction cloud step for
stock firmware.

## APK
Not fetched — the Smart Life app is a cloud client; the LAN protocol is
documented by the libraries above.

## Safety
LOW. Mains relay; local key is the only auth — treat it as a password, and
LAN-segment plugs since any holder of the key controls the load.
