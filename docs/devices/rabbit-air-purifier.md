# Rabbit Air Purifiers (MinusA2 / A3 / BioGS 2.0)

> **Status**: Complete and hardware-verified (2026-08-15): LAN protocol from the vendor's own library; BLE provisioning recovered from a full decompile of the Rabbit Air 2 app AND replayed end-to-end against a real MinusA2 — cleartext setup commands, client-generated user key, encrypted LAN + BLE control all confirmed
> **Protocol**: WiFi (mDNS + encrypted JSON over UDP 9009) and BLE (GATT provisioning channel, also usable for local control)
> **Manufacturer**: Rabbit Air
> **Manufacturer Status**: Active — and unusually cooperative: Rabbit Air published the LAN client library itself

## Overview

Rabbit Air's Wi-Fi purifiers — MinusA2 second generation (SPA-700A/SPA-780A),
A3 (SPA-1000N) and BioGS 2.0 (SPA-550A/SPA-625A) — speak a fully local,
encrypted JSON-over-UDP protocol on port 9009. This is not an abandonment
rescue: Rabbit Air is active, and it *published the protocol's reference
implementation itself* — the Apache-2.0
[python-rabbitair](https://github.com/rabbit-air/python-rabbitair) library —
and authored the [Home Assistant core
integration](https://www.home-assistant.io/integrations/rabbitair/)
(`local_polling`, codeowner `@rabbit-air`). Everything in this page is read
from that library and cross-checked against the Rabbit Air 2 Android app
binary (`com.rabbitair.rabbitair_flutter` v1.2.1).

The one hard boundary: **first-generation MinusA2** units (older hardware
revision) do not speak this protocol. The app says "your device is not
supported" and Home Assistant cannot connect to them.

### Local vs cloud

| Path | Transport | Auth | Required for control? |
|------|-----------|------|----------------------|
| **LAN protocol** | UDP 9009 (or TCP 9009, length-prefixed) | AES-128-CBC with a per-device 16-byte user key | Yes — this is the control plane |
| **BLE** | GATT service `366048ae-…`, characteristic `53ef7d7d-…` | Cleartext during setup; same user-key AES after | Alternate control transport + provisioning channel. Hardware note: the characteristic is write + **indicate** (ATT indications, not notifications) |
| mDNS discovery | `_rabbitair._udp.local.` | none | Optional (IP works too) |
| Rabbit Air cloud | AWS IoT Core MQTTS 8883 (`au32ip2ri54us-ats.iot.us-east-1.amazonaws.com`), device shadow `$aws/things/<thingName>/shadow/…` | Per-thing X.509 certificate | No — remote access / account / OTA only |
| Firmware OTA | `ota.rabbitair.com` | — | No |

If Rabbit Air's cloud disappeared tomorrow, local control would be unaffected
— and, since the user key is minted client-side during provisioning (see
below), even *first-time setup* can be done cloud-free.

## Hardware

| Property | Value |
|----------|-------|
| Models | MinusA2 gen2 SPA-700A / SPA-780A; A3 SPA-1000N; BioGS 2.0 SPA-550A / SPA-625A |
| State `model` field | 1 = MinusA2, 2 = BioGS, 3 = A3 |
| Radio | Wi-Fi (plus BLE, used by the app during provisioning) |
| Not covered | First-generation MinusA2 (different, undocumented interface) |

## Initial Setup

| Property | Value |
|----------|-------|
| Setup required | Yes — one-time Wi-Fi provisioning |
| Method | `ble_provisioning` (preferred, **verified against hardware 2026-08-15**), `softap_udp` AP mode (fallback, unreplayed), or WPS (unreplayed) — the first two fully documented below |
| Setup identity | BLE name `RabbitAirSetup` + service `366048ae-…`; AP mode: open `rabbitair_*` SSID, device at `192.168.10.1` (mDNS `rabbitair-setup.local`) |
| Passphrase protection | none — setup commands are cleartext JSON; encryption starts only after the user key is pushed |
| Confidence | high (BLE path replayed against a real MinusA2; AP-mode path still decompile-only) |

The BLE and AP-mode paths speak the **same cleartext JSON command envelope**
as the LAN protocol (`{"id":…,"cmd":…,"data":{…}}` — no `ts`, no AES during
setup), carried over GATT or over UDP/TCP 9009 to `192.168.10.1`:

1. **cmd 255 + cmd 4** — device info / state sanity check (retry 5×, 1 s).
2. **cmd 0** — read network settings; doubles as the device's own Wi-Fi scan
   (`data.networks[]` = `{ssid, security}`, one entry per visible BSSID —
   dedupe SSIDs). Re-poll until non-empty.
3. **cmd 1** — join network: `data {"ssid","passphrase","security"}` with
   `security` echoed from the chosen `networks[]` entry (hardware-observed:
   **3 = WPA2-PSK**).
4. **cmd 5, type 4** — push the **user key**: 32 uppercase hex chars
   (16 bytes) generated *client-side*. Firmware gate: `mcu` ≥ 24 (ESP32) /
   ≥ 2.2 (Inventek). This key is all local control needs — the vendor app's
   other certificate pushes (cmd 5 types 0–3, AWS IoT material) bind the
   unit to the cloud and can be skipped.
5. **cmd 3** — set module name (optional).
6. **cmd 2** — leave setup mode; the unit joins Wi-Fi and appears on the LAN
   advertising `_rabbitair._udp.local.`. **Allow minutes**: the verified unit
   held `ip 0.0.0.0` in cmd 0 for ~4 minutes after cmd 2 before associating
   and taking a DHCP lease.

Hardware notes from the 2026-08-15 replay (MinusA2 gen2, Wi-Fi module
mcu 2.2.8): replies to the write commands are bare `{"id":<echo>}` acks;
commands that are out of phase come back `{"id":<echo>,"error":true}`
(e.g. cmd 1/2 re-sent after setup completed). A **keyed** unit (already
provisioned, not in setup mode) answers no cleartext command and
intermittently rejects writes with ATT application error `0x87` — that
signature means "hold the wireless button and retry", not a broken link.

Provisioning produces the purifier on your LAN. With the vendor cloud flow
it has a **Thing ID** — also its mDNS hostname, e.g.
`abcdef1234_123456789012345678.local`. With the local-only flow above the
unit never gets a Thing ID (cmd 255 `data.name` stays empty) and its mDNS
hostname falls back to **`RabbitAir-<WIFI MAC>`** (e.g.
`RabbitAir-A1B2C3D4E5F6.local`, TXT record `id=A1B2C3D4E5F6`) — verified on
hardware. The **user key** works the same either way. On a unit set up by
the official app, retrieve both from the app: device page → three-dot menu
→ *Rename* → tap the device name to expand the hidden section (older app
versions: *Edit* screen, tap "Serial Number" repeatedly).

On BLE the framed payload is prefixed with a 2-byte little-endian length and
split into (MTU − 5)-byte chunks — the app negotiates MTU 515, so 510-byte
chunks — written with response to characteristic
`53ef7d7d-c244-42bd-9064-a1569a521ca9`; **indications** on the same
characteristic carry the chunked reply (7 s timeout). See the
`rabbit_air_ble` block of the spec for the byte-level framing.

**Factory reset**: clears Wi-Fi credentials and cloud binding; the exact
button procedure is per-model in the printed manuals (low confidence here —
not captured). **Rebinding**: no documented in-place network change; treat a
router swap as reset-and-reprovision.

## Protocol Summary

### Discovery

Browse `_rabbitair._udp.local.` (this is exactly how Home Assistant
auto-discovers the device), or resolve `<thing-id>.local`. Then UDP to port
9009.

### Framing and encryption

- One JSON message per UDP datagram, minified (`{"id":…,"cmd":…}`), UTF-8.
- TCP variant: 2-byte little-endian length prefix, same payloads.
- Encryption (once a user key is set): **AES-128-CBC, PKCS7 padding**, key =
  the 16-byte user key. IV is random per message and **appended as the last
  16 bytes** of the datagram: `ciphertext || IV`.
- Reliability: responses are matched by echoed `id`; unknown datagrams are
  ignored. The vendor client retries 3× at 2 s (UDP) / 5 s (TCP).

### Handshake (clock sync)

There is no session. Before the first authenticated command, send `cmd 9` and
read `data.ts` (device clock, seconds). Every subsequent request must carry
`ts` extrapolated from that offset — a lightweight anti-replay measure.
Re-sync whenever the socket is re-created.

### Commands

| cmd | Name | Description |
|----:|------|-------------|
| 9 | time_sync | Response `data.ts` = device clock |
| 4 | state_get | No `data` in request → full state object in response |
| 4 | state_set | Request `data` carries only the fields to change |
| 255 | get_info | Thing ID, firmware versions (Wi-Fi + main board), MAC, uptimes, RSSI stats |
| 0 | read_network_settings | Setup, cleartext: network config + Wi-Fi scan list (`data.networks[]`) |
| 1 | join_network | Setup, cleartext: `data {"ssid","passphrase","security"}` |
| 2 | leave_ap_mode | Setup, cleartext: end setup mode, join the network |
| 3 | module_name | Setup, cleartext: get/set the module name (`data.name`) |
| 5 | set_certificate | Setup, cleartext: `data {"type","value"}` — type 4 = push the user key; 0–3 = cloud certificates |
| 7 | get_current_mode | Setup, cleartext: `data.mode` (0–5) |

cmds 0–7 run unencrypted before a user key exists (over BLE or the setup
AP); cmds 4/9/255 are the same commands as post-setup, just plaintext.

### State fields (cmd 4)

Readable/writable unless noted. Enums: `mode` 0 Auto / 1 Pollen / 2 Manual ·
`speed` 1 Silent … 5 Turbo (0 SuperSilent is read-only, auto modes only) ·
`quality` 0–4 (BioGS reports 1–5; subtract 1) · `sensitivity` 0 High /
1 Medium / 2 Low · `moodlight` 0 Off / 1 On / 2 Auto / 3-4 presets ·
`all_light_off` 0/1/2 (Off/On/Auto) · `gas` 0 preheat, 1–4 levels ·
`error` 0 none, 1 dust, 2 gas, 3 both, 4 fan-low, 5 NFC tag, 8 hall sensor ·
`filter_type` 1–4 (ToxinAbsorber/OdorRemover/GermDefense/PetAllergy, from the
filter's NFC tag — `tag_uid`/`tag_state` expose the tag itself).

- Control: `power`, `mode`, `speed`, `sensitivity`, `ionizer`, `moodlight`,
  `color` (9-element 0–40 palette), `all_light_off`, `lsens_ctl`, `buzzer`,
  `lock` (child lock), `timer_mode` (0/1/2), `timer` (minutes, ≤1440),
  `schedule` (24 chars, one per hour UTC, `1`-`5`/`A`).
- Filter management: `filter_life` / `filter_timer` (minutes; clear
  `filter_cleaning` / `filter_replacement` flags by writing them),
  `filter_ctl` (notifications on/off).
- Read-only telemetry: `quality`, `particulate_sensor`, `pm_sensor` (extended,
  A3), `gas`, `light_sensor`, `open` (panel), `idle`, `sleep`, `rssi`,
  `firmware`, `v`, `error`, `tag_uid`, `filter_type`, `model`.

### Example (plaintext view)

```json
→ {"id":1234567,"cmd":9,"ts":1700000000}
← {"id":1234567,"data":{"ts":1700000123}}
→ {"id":1234568,"cmd":4,"ts":1700000123}
← {"id":1234568,"data":{"model":3,"power":true,"mode":0,"speed":1,"quality":1, ...}}
→ {"id":1234569,"cmd":4,"ts":1700000124,"data":{"power":false}}
```

On the wire each message is AES-128-CBC(user_key) with the IV appended.
Key/IV values must come from your own device — never from this documentation.

## Cloud surface (for completeness)

The Rabbit Air 2 app additionally mirrors state through AWS IoT device
shadows (`$aws/things/<thingName>/shadow/get|update(/accepted)`, confirmed as
strings in the app binary), uses a GraphQL account API (serial ↔ MAC lookup
during setup), and pulls firmware from `ota.rabbitair.com`. None of it is
needed for local control; do not build on it.

## Open gaps

- ~~**Hardware verification**~~ — done for the BLE path (2026-08-15): the
  full cleartext provisioning conversation, the client-side user key, and
  the encrypted LAN/BLE control channels were all replayed against a real
  MinusA2. The **softap_udp** AP-mode and **WPS** methods remain
  decompile-only (`verified: false` in the YAML).
- The integer `security` enum in cmd 0/1 is partially mapped (3 = WPA2-PSK,
  hardware-observed); other values (open/WEP/WPA3) unconfirmed — echo the
  `networks[]` entry rather than constructing one.
- TCP (9009) response framing has one unresolved inconsistency in the
  decompiled client; UDP is the reference transport.
- First-generation MinusA2 protocol — entirely undocumented.

## Tools Used

- **blutter** decompile of the Flutter Dart AOT binary `libapp.so` (Dart
  3.10.3, arm64) from `com.rabbitair.rabbitair_flutter` v1.2.1 (XAPK
  SHA-256 `04c22fc1…c556`; base APK SHA-256 `d3eeb80c…abb9`) — the BLE GATT
  layout, framing/chunking, setup command set, and AP-mode transport
- jadx decompile of the same APK — Java side + manifest
- `strings` on `libapp.so` — field names, AWS IoT endpoint, shadow topics,
  mDNS setup hostname
- Source read of rabbit-air/python-rabbitair 0.0.8 (vendor library)

## References

- [rabbit-air/python-rabbitair](https://github.com/rabbit-air/python-rabbitair) — vendor's own LAN client (Apache-2.0), the reference implementation
- [Home Assistant Rabbit Air integration](https://www.home-assistant.io/integrations/rabbitair/) — vendor-authored, local_polling
- [yepher/RabbiteAirProtocol](https://github.com/yepher/RabbiteAirProtocol) — independent 2021 iOS-app research; corroborates the BLE UUID roles and `192.168.10.1:9009`
- [python-rabbitair on PyPI](https://pypi.org/project/python-rabbitair/) — 0.0.8 pinned by HA
- Machine-readable spec: `device-specs/devices/rabbit-air-purifier.yaml`
