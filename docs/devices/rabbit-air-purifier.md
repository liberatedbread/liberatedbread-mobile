# Rabbit Air Purifiers (MinusA2 / A3 / BioGS 2.0)

> **Status**: Complete (LAN protocol fully documented from the vendor's own library; Wi-Fi provisioning flow partial)
> **Protocol**: WiFi (mDNS + encrypted JSON over UDP 9009)
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
| mDNS discovery | `_rabbitair._udp.local.` | none | Optional (IP works too) |
| Rabbit Air cloud | AWS IoT Core MQTTS 8883 (`au32ip2ri54us-ats.iot.us-east-1.amazonaws.com`), device shadow `$aws/things/<thingName>/shadow/…` | Per-thing X.509 certificate | No — remote access / account / OTA only |
| Firmware OTA | `ota.rabbitair.com` | — | No |

If Rabbit Air's cloud disappeared tomorrow, local control would be unaffected.

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
| Setup required | Yes — one-time Wi-Fi provisioning via the official app |
| Method | `ble_provisioning` (preferred in Rabbit Air 2 app) or `softap_http`-shaped AP mode (fallback) — **neither on-wire exchange captured** |
| Setup identity | Serial-number QR scan; AP mode resolves fixed hostname `rabbitair-setup.local` via mDNS |
| Passphrase protection | unknown (provisioning exchange uncaptured) |
| Confidence | medium (app-binary evidence; not replayed) |

**What provisioning produces** (confirmed): the purifier on your LAN with a
**Thing ID** — which is also its mDNS hostname, e.g.
`abcdef1234_123456789012345678.local` — and a **user key**: a 16-byte AES key
shown as 32 hex characters. Retrieve both from the app: device page →
three-dot menu → *Rename* → tap the device name to expand the hidden section.
If the unit predates user keys, the app offers "Tap for setup user key" to
generate one on-device.

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

- **Provisioning exchange** (BLE GATT layout / AP-mode transport) — not
  captured. HCI snoop or an AP-mode packet capture would close this.
- Plaintext (tokenless) operation exists in the vendor client but is
  unverified against production units — treat as hypothesis.
- First-generation MinusA2 protocol — entirely undocumented.

## Tools Used

- jadx decompile of `com.rabbitair.rabbitair_flutter` v1.2.1 (XAPK SHA-256
  `04c22fc1…c556`; base APK SHA-256 `d3eeb80c…abb9`) — Java side + manifest
- `strings` on the Flutter Dart AOT binary `libapp.so` — field names, AWS IoT
  endpoint, shadow topics, mDNS setup hostname
- Source read of rabbit-air/python-rabbitair 0.0.8 (vendor library)

## References

- [rabbit-air/python-rabbitair](https://github.com/rabbit-air/python-rabbitair) — vendor's own LAN client (Apache-2.0), the reference implementation
- [Home Assistant Rabbit Air integration](https://www.home-assistant.io/integrations/rabbitair/) — vendor-authored, local_polling
- [python-rabbitair on PyPI](https://pypi.org/project/python-rabbitair/) — 0.0.8 pinned by HA
- Machine-readable spec: `device-specs/devices/rabbit-air-purifier.yaml`
