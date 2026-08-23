# Govee H5080 Smart Plug

> **Status**: Spec Available (wire-verified by third parties, untested by us)
> **Protocol**: BLE (local control); Wi-Fi + cloud binding also present
> **Manufacturer**: Govee (Shenzhen Intellirocks Tech / iHoment)
> **Manufacturer Status**: Active

## Overview

WiFi + BLE smart plug family. Local BLE control uses the classic Govee
20-byte binary packet — `[2-byte command][17-byte payload][1-byte XOR
checksum]` — wire-verified by two independent implementations (egold555's
H5080 notes and virtuald/govee-ble-plugs), and works with no WiFi and no
cloud. BLE switching is gated by an application-layer token auth: the
plug's static 16-byte key can only be read while the physical button is
held.

Machine-readable spec: `device-specs/devices/govee-h5080-plug.yaml`.

## Hardware

| Property | Value |
|----------|-------|
| Model Number | H5080 (single); family: H5081, H5082/H5083 (dual), H5085 (Pro, Matter), H5086 (Pro Energy Monitoring), H5089/H5160/H5161 (triple) |
| Radio | BLE + 2.4 GHz WiFi (802.11 b/g/n, 2412–2462 MHz per FCC 2AQA6-H5080) |
| Rating | 15 A / 1800 W max, ETL + FCC certified |
| Advertised name | `ihoment_H5080_…` (duals `ihoment_H5082_…`, Pro `GVH5086…`) |
| Advertised service | `00010203-0405-0607-0809-0a0b0c0d1910` (whether the 128-bit UUID is in the ADV packet is unverified — needs one capture) |
| Manufacturer company ID | `0xEC88` (60552) when the `88 EC` bytes lead the payload; newer firmware prepends a version byte so hosts report `0x88XX` (e.g. `0x8803`) — match `88 EC` at payload offset 0 or 1. goodsType 2 bytes BE after the company bytes (43=single, 50 & 307=dual, 90=triple); last manufacturer-data byte carries on/off state |

Firmware seen: 1.00.21 and 1.02.00 (RE captures), 1.00.22 in the wild; the
app treats firmware ≤ 1.00.08 as a reduced-feature "old H5080". OTA is
in-app only — no public firmware downloads.

## Initial Setup

| Property | Value |
|----------|-------|
| Setup required | No (but BLE control needs a one-time, button-gated key retrieval) |
| Method | `ble_direct` |
| Setup AP / advertised name | `ihoment_H5080_…` |
| Passphrase protection | unknown (no WiFi passphrase crosses the BLE control link) |
| Confidence | high (auth flow wire-verified by two independent implementations) |

No BLE bonding/pairing, but there is an application-layer token auth:

1. Power the plug and scan for the `ihoment_H5080_` name prefix.
2. Connect; subscribe to notifications on `…2b10`.
3. Press and hold the physical button on the plug.
4. Send `AAB1` while the button is held to read the 16-byte auth key;
   store it. Without the button held, the plug returns a random decoy.
5. Authenticate the connection with `33B2 <key>`, then write control
   commands (e.g. `3301`). Unauthenticated switch commands are silently
   ignored.

The key is static and never rotatable, so after first retrieval it can be
reused without further physical access. Note the residual risks: the key
travels in cleartext during a legitimate session and cannot be rotated.

**Factory reset**: not established — no source covers a reset procedure.
The plug is not stateless (it holds WiFi credentials, a cloud binding and
the static BLE auth key), so a real reset would have something to clear;
cutting mains power is not known to clear anything.

**Rebinding**: in place. The plug accepts one BLE client at a time; any
client holding the auth key can reconnect and re-authenticate once the
previous client disconnects. WiFi/cloud state is unaffected.

## Protocol Summary

All commands are 20-byte packets written to `…2b11`; responses echo the
command id and arrive on `…2b10`. The plug also sends unsolicited `3301`
state notifications on physical-button presses.

### BLE Services

| UUID | Name | Description |
|------|------|-------------|
| `00010203-…-1910` | Govee H5080 Plug Service | Shared `00010203` GATT family with the legacy bulbs |
| `00010203-…-2b11` | Control Write (read, write-without-response) | Primary control channel; requires `33B2` auth before `3301` is honored |
| `00010203-…-2b10` | State Notify (read, notify) | Command responses (id echoed) and unsolicited state notifications |

### Commands

| Command (bytes 0–1) | Purpose |
|---------------------|---------|
| `33 01 <byte>` | Set on/off. Single-plug H5080: `0xFF` on / `0xF0` off (all-ports selector) |
| `AA 01` | Query on/off state |
| `AA 06` / `AA 20` / `AA 21` | Firmware version (ASCII in payload) |
| `AA 07` | Hardware version |
| `AA 00` | Power metrics (H5086 only → `EE19` response: seconds-on, Wh ×0.1, voltage/current/power ×0.01, power factor %) |
| `AA B1` | Read the static 16-byte auth key (valid only while the physical button is pressed) |
| `33 B2 <key>` | Authenticate this connection (sent immediately before every switch command) |

Full frames (verified): on = `33 01 ff 00×16 cd`; off = `33 01 f0 00×16
c2`; state query = `aa 01 00×17 ab`; auth-key read = `aa b1 00×17 1b`.

**On/off byte encoding** (multi-plug units): bits 0–3 carry the on-state
per port (1=port0, 2=port1, 4=port2, 15=all), bits 4–7 the port selector
(`0x10`=port0, `0x20`=port1, `0x40`=port2, `0xF0`=all). E.g. `0x11` =
port 0 on, `0x22` = port 1 on, `0x10` = port 0 off. On the H5082 dual,
port0 is the right outlet and port1 the left. The single-plug H5080 is
driven with the all-ports `0xFF`/`0xF0` form.

## Tools Used

- [ ] Static analysis of the Govee Home Android app (jadx)
- [ ] egold555/Govee-Reverse-Engineering H5080 notes (third-party wire capture)
- [ ] virtuald/govee-ble-plugs (working third-party client)

## References

- [virtuald/govee-ble-plugs](https://github.com/virtuald/govee-ble-plugs)
- [egold555/Govee-Reverse-Engineering](https://github.com/egold555/Govee-Reverse-Engineering)
- [LaggAt/hacs-govee](https://github.com/LaggAt/hacs-govee) — cloud-API plugs; no HA integration speaks this BLE protocol directly yet

## Contributors

- @kimi - spec from app static analysis + third-party wire verification
