# Xiaomi / Roborock (miio generation) Robot Vacuums — Research Notes

## What it is
First Xiaomi Mi Robot Vacuum (rockrobo.vacuum.v1, 2016) and the miio-based
generation of Xiaomi-ecosystem vacuums: Roborock S5/S5 Max/S6/S7, Xiaomi 1C/1T,
Mi Robot Vacuum-Mop series, Viomi, and many Dreame models on stock firmware.
All speak the Xiaomi "miIO" LAN protocol.

## Local protocol (community-documented, stable since 2017)
- Transport: UDP port 54321, binary protocol, magic `0x2131`.
- Discovery: broadcast "hello" handshake packet
  (`0x2131 0x0020 0xFFFFFFFF...`) to 255.255.255.255:54321; device replies
  with its device ID. mDNS not used by this generation.
- Encryption: payload is JSON encrypted AES-128-CBC with a per-device
  128-bit "token"; key = MD5(token), IV = MD5(MD5(token) + token).
  (python-miio `miio/protocol.py`.)
- Commands are JSON-RPC-ish: `miIO.info`, `app_start`, `app_pause`,
  `app_stop`, `app_charge`, `app_spot`, `app_zoned_clean`, `get_status`,
  `get_consumable`, `get_map_v1`, `set_fan_power`, ...
- Reference implementations: python-miio (`mirobo`/`miiocli`),
  Home Assistant core `xiaomi_miio` (iot_class: local_polling),
  openHAB miio binding, ioBroker mihome-vacuum.

## The token problem — what needs cloud, what doesn't
Once you hold the token, operation is 100% LAN (WAN can be blocked; the
robot only phones home for maps/app features it no longer needs). Getting
the token:
1. **Account-free (rooted robot)**: SSH in and
   `printf $(cat /mnt/data/miio/device.token) | xxd -p` — no account ever,
   but requires a rooted/Valetudo unit (see valetudo note).
2. **Legacy app artifacts (needs prior Mi Home pairing)**: Mi Home 5.4.49
   Android logs leak tokens; Mi Home ≤5.0.19 stores tokens in the local
   SQLite DB — extract via `adb backup -noapk com.xiaomi.smarthome` +
   `miio-extract-tokens`, or iOS unencrypted backup (`*_mihome.sqlite`,
   AES-128-ECB with an all-zero key decrypts stored tokens).
3. **Cloud lookup (needs Mi account)**: `miiocli cloud` / Xiaomi Cloud
   Tokens Extractor pulls tokens for all devices on the account.

Note: the token rotates whenever the robot is re-provisioned; initial
Wi-Fi provisioning on stock firmware goes through the Mi Home app (i.e. a
Mi account) unless the robot is rooted first.

## APK
- **Package**: `com.xiaomi.smarthome` (Mi Home) — XAPK already fetched via
  apkeep on 2026-08-03 (repo workspace).
- XAPK SHA-256: `12aecd77fd18531e23c7bf43b91ba06b36a8cf7005b31d2fed7645d744ac63b6` (231 MB)
- Protocol itself needs no further RE — python-miio is the reference.

## Caveats
- Viomi vacuums (viomi.vacuum.v7/v8) speak a miio dialect; use `miiocli
  viomivacuum`, not `mirobo`. v8 units brick if rooted (Valetudo docs).
- Newer Roborock models (S7 MaxV onward) dropped miio for a different local
  protocol — see roborock-local-api note.

## Open questions
1. Per-model command dialect tables belong in the spec (python-miio has the
   vacuum-specific classes for rockrobo, dreame, viomi, ijai, 3irobotix).
2. Map parsing (RRMap format) is a separate documented format
   (github.com/PiotrMachowski/Home-Assistant-custom-components-Xiaomi-Cloud-Map-Extractor).
