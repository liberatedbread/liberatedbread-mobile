# Flowtoys Connect Props (capsule 2 / vision) via Connect Bridge

> **Status**: Research
> **Protocol**: BLE (to bridge) + WiFi/OSC (to bridge) + proprietary nRF24 RF (bridge to props)
> **Manufacturer**: Flowtoys
> **Manufacturer Status**: Active

## Overview

Flowtoys LED flow-arts props — capsule 2.0/2.C light engines (podpoi,
capsule poi, staffs, batons) and vision props (vision poi/staff/club/wand) —
do not speak BLE directly. They use a proprietary 2.4 GHz "flowtoys connect"
radio protocol that runs on nRF24L01+-compatible radios. A hardware "connect
bridge" (ESP32 + nRF24, sold as USB or pocket bridge) translates between the
official "flowtoys connect" mobile app and the props. The app talks to
**groups**, not individual props: every prop in a group shares one 16-bit
radio group ID.

Flowtoys commissioned and published the bridge firmware
([benkuper/FlowtoysConnectBridge](https://github.com/benkuper/FlowtoysConnectBridge))
and a companion app
([benkuper/FlowtoysConnect](https://github.com/benkuper/FlowtoysConnect)),
so most of the protocol is documented by open source; the production app's
newer BLE service UUIDs were recovered from the official APK
(`com.flowtoys.app`).

## Hardware

| Property | Value |
|----------|-------|
| Model Number | capsule 2.0 / 2.C, vision core props, connect bridge (USB / pocket) |
| Chipset | Bridge: ESP32 + nRF24L01+ (props: nRF24-compatible 2.4 GHz radio) |
| Radio | BLE 4.x (bridge↔phone), WiFi 802.11n (bridge), proprietary 2.4 GHz nRF24 (bridge↔props) |
| FCC ID | — |

## Initial Setup

| Property | Value |
|----------|-------|
| Setup required | No (BLE to bridge); grouping required before props are addressable |
| Method | `ble_direct` |
| Setup AP / advertised name | BLE: `FlowConnect <name>`; WiFi fallback AP: `FlowConnect <name>` (WPA2, password `findyourflow`) |
| Passphrase protection | plaintext (WiFi credentials sent cleartext over unencrypted BLE) |
| Confidence | medium (published source; not exercised against hardware here) |

**Grouping props**: from off, hold the prop button ~10 seconds until the
LEDs flash or turn white. Every prop needs a group, even a single one.
There are 5 fixed "public" groups (IDs 1–5) plus private groups with other
16-bit IDs. To have the bridge learn a private group, put the props on their
sync page/mode (page 2 mode 1 on older firmware; the current app says page 5
mode 1) and start sync from the app/bridge.

**Factory reset**: the bridge stores WiFi credentials, its name and learned
group IDs in ESP32 NVS — clearing NVS (reflash) resets it. A prop's group
membership is overwritten by re-grouping (the ~10 s button hold).

**Rebinding to a new network**: in place — send the `n<ssid>,<password>`
command over BLE or the `/wifiSettings` OSC message; no reset needed.

## Protocol Summary

Three hops, any of the first two can drive the third:

1. **BLE → bridge.** Open firmware: Nordic UART Service
   `6E400001-B5A3-F393-E0A9-E50E24DCCA9E`; write ASCII commands to
   `6E400002-…`, notifications on `6E400003-…`; the app requests MTU 48.
   Production app: service `49550001-AAD5-59BD-934C-023D807E01D5` with
   characteristics `49550002-…`, `49550003-…`, `49550005-…` (roles
   unverified — recovered from the APK's compiled Dart library).
2. **WiFi/OSC → bridge.** Bridge mDNS-advertises `_osc._udp`
   (instance `flowtoysconnect`) and listens for OSC over UDP (firmware
   port 9000; the early app sent to 8888).
3. **nRF24 RF → props.** 250 kbps, channel 2, 3-byte address
   `{0x01, 0x07, 0xF1}`, CRC-16, no auto-ack; a 20-byte packed sync packet
   per group broadcast at ~30 ms cadence. Any nRF24 node can drive props
   directly with these parameters.

### BLE Services

| UUID | Name | Description |
|------|------|-------------|
| `6E400001-B5A3-F393-E0A9-E50E24DCCA9E` | Nordic UART (open bridge firmware) | ASCII command channel |
| `6E400002-B5A3-F393-E0A9-E50E24DCCA9E` | NUS RX | Write commands (write / write-no-response) |
| `6E400003-B5A3-F393-E0A9-E50E24DCCA9E` | NUS TX | Notifications |
| `49550001-AAD5-59BD-934C-023D807E01D5` | Flowtoys Connect service (production) | Vendor service used by com.flowtoys.app; characteristic roles unverified |

### Commands

Commands are ASCII strings, decimal comma-separated fields, terminated by
`\n` or `0xFF`. Capital letters target public groups 1–5; lowercase target
private (learned) groups; group 0 = all groups.

#### Command: set pattern

`p<group>,<page>,<mode>,<actives>,<hue>,<sat>,<brightness>,<speed>,<density>,<lfo1>,<lfo2>,<lfo3>,<lfo4>`
(`P` for public groups).

| Field | Description |
|-------|-------------|
| group | Group ID (0 = all) |
| page, mode | Effect selector (modes are numbered within pages; mode metadata ships in the app as base_modes.json) |
| actives | Bitmask: bit0 LFO, bit1 hue, bit2 sat, bit3 brightness, bit4 speed, bit5 density |
| hue, sat, brightness, speed, density, lfo1–4 | uint8 0–255 |

Solid color: page 2, mode 7, actives 255, with HSV hue/sat/brightness.

#### Command: wake / power off

`w<group>` / `W<group>` wake; `z<group>` / `Z<group>` power off.

#### Command: sync

`s<timeout_seconds>` starts RF sync (learn private groups); `S` stops;
`a` forgets all private groups.

#### Command: configuration

`n<ssid>,<password>` sets WiFi credentials; `g<name>,<mode>` sets bridge
name and radio mode (0 = WiFi, 1 = BLE, 2 = both; bridge reboots);
`r` restarts the bridge.

#### OSC equivalents (UDP)

`/wakeUp` (int group, int isPublic), `/powerOff`, `/sync` (float timeout),
`/stopSync`, `/resetSync`, `/pattern` (14 ints: group, isPublic, page, mode,
actives, hue, sat, brightness, speed, density, lfo1–4), `/wifiSettings`
(2 strings), `/globalConfig` (string name, int mode), `/play`, `/stop`,
`/pause`, `/resume`, `/seek` (float), `/rgb/brightness` (float).

#### RF sync packet (bridge → props, 20 bytes, packed)

| Offset | Length | Description |
|--------|--------|-------------|
| 0 | 2 | group ID (uint16, byte-swapped on the wire) |
| 2 | 4 | padding/sequence counter (incremented per change) |
| 6 | 4 | LFO values 1–4 |
| 10 | 5 | global hue, saturation, value, speed, density |
| 15 | 1 | active flags (bit per parameter: lfo/hue/sat/val/speed/density) |
| 16 | 2 | reserved |
| 18 | 1 | page |
| 19 | 1 | mode + command bit flags packed in the final byte region (adjust, wakeup, poweroff, force_reload, save, delete, alternate) |

## Tools Used

- [x] jadx (official APK decompile) + strings on Flutter `libapp.so`
- [x] Source review of the vendor-published bridge firmware and companion app
- [ ] BLE capture against a production bridge (to pin down the `4955000x` characteristic roles)

## References

- [benkuper/FlowtoysConnectBridge — bridge firmware (ESP32/nRF24)](https://github.com/benkuper/FlowtoysConnectBridge)
- [benkuper/FlowtoysConnect — companion Flutter app](https://github.com/benkuper/FlowtoysConnect)
- [jonglissimo/Flowtoy-Connect-Bridge-OSC-Module — Chataigne OSC module](https://github.com/jonglissimo/Flowtoy-Connect-Bridge-OSC-Module)
- [flowtoys support: bridge & app FAQ](https://flowtoys.com/pages/bridge-app)

## Contributors

- Liberated Bread clean-room pipeline — initial research
