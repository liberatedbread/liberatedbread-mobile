# Tuya Bluetooth Soil Tester (zwjcy / SGS01 family)

> **Status**: Research
> **Protocol**: BLE (Tuya BLE single-point, encrypted GATT session)
> **Manufacturer**: Tuya (platform) / Shenzhen HaiHao Electronic (canonical SGS01) + white-label clones
> **Manufacturer Status**: Active

## Overview

The "Tuya Smart Bluetooth Soil Tester / Smart Plant Soil Tester" listings on
Amazon/AliExpress are one Tuya OEM family. The canonical hardware is the
**SGS01** (a.k.a. HZ-SL05, "Connected Home PLANT MONITOR") by Shenzhen HaiHao
Electronic — a 2×AAA probe measuring soil moisture and temperature, marketed as
"works with Alexa & Google". Tuya device category `zwjcy` (soil sensor / plant
monitor) has **no official public DP documentation**; everything below is
community-derived. Near-identical units are certified under category `wsdcg`
with different DP numbering.

It is reverse engineered because Tuya publishes nothing, the stock device only
speaks an encrypted session keyed by cloud-issued credentials, and a full
cloud-free replacement firmware (SGS01BTHome) exists for the SGS01 revision.

## Hardware

| Property | Value |
|----------|-------|
| Model Number | SGS01 / HZ-SL05 (canonical); product ids `gvygg3m8` (current), `aao3yzhs` (older) |
| Chipset | Tuya BT3L module (Telink TLSR8250, 512 KB flash) + separate measurement MCU |
| Radio | BLE (single-point, connectable; NOT mesh, NOT passive beacon) |
| FCC ID | None at device level for the white-label goods |

Internals per the haraldapp/SGS01BTHome teardown: the BT3L owns the radio and
runs stock Tuya BLE firmware; a third-party MCU owns measurement, button and
LED, linked to the BT3L by UART running the standard Tuya MCU serial protocol.
Flashing pads: Vcc/GND/SWS (Telink single-wire, chip type B85); flash above
0x70000 holds factory MAC/calibration — preserve it when reflashing.

## Initial Setup

| Property | Value |
|----------|-------|
| Setup required | Yes (pairing is mandatory; nothing is readable unpaired) |
| Method | `ble_provisioning` (vendor app + Tuya cloud account), then `ble_direct` with extracted keys |
| Setup AP / advertised name | BLE advertisement with service-data `0xA201` + manufacturer data `0x07D0` |
| Passphrase protection | not_applicable (BLE; session key derived from device uuid + cloud local key) |
| Confidence | medium (community implementations + Smart Life SDK decompile; not replayed by this project) |

Stock pairing happens in Smart Life / Tuya Smart with a Tuya cloud account; the
cloud issues the device id + 16-char local key that the encrypted BLE session
is derived from. For third-party local access, extract those credentials once
via a Tuya IoT developer account (tuya-iot-py-sdk / ha_tuya_ble automate it).

**Factory reset**: remove the device in the vendor app — the app drives an
UNBIND (function code `0x0005`) or DEVICE_RESET (`0x0006`) frame over GATT and
the device returns to pairing-mode advertising. A physical button-hold reset
likely exists (generic Tuya BLE behavior) but is undocumented for this family —
unverified. The nuclear option is flashing SGS01BTHome over SWS, which removes
all Tuya state; it does NOT support the 2026 SGS01B revision.

**Rebinding to a new account**: unbind + re-pair; a new device id / local key
pair is issued. There are no network credentials to rotate (the device is
BLE-only).

## Protocol Summary

Advertisements carry device identity only — never sensor readings (ble_monitor
confirms SGS01 cannot be supported passively). All state moves as encrypted
Tuya DP frames over GATT:

### BLE Services

| UUID | Name | Description |
|------|------|-------------|
| `0xFD50` | Tuya BLE service | The whole protocol lives here |
| `0x2B11` | Write | Host→device commands (pair, DP query, unbind/reset, OTA) |
| `0x2B10` | Notify | Device→host DP reports, command responses, time requests |

Default ATT MTU 20; frames are chunked/reassembled by the protocol layer. The
full packet framing (sequence numbers, ACKs, encryption) is implemented in
[python-tuya-ble](https://github.com/PlusPlus-ua/python-tuya-ble) and is
deliberately not restated here — treat it as the executable reference.

### Commands

Commands are function codes inside the encrypted frame:

| Code | Direction | Meaning |
|------|-----------|---------|
| `0x0000` | host→device | DEVICE_INFO |
| `0x0001` | host→device | PAIR — establishes session keys from device uuid + local key |
| `0x0002` | host→device | DPS (DP query/set); `0x0027` = DPS_V4 |
| `0x0003` | host→device | DEVICE_STATUS |
| `0x0005` / `0x0006` | host→device | UNBIND / DEVICE_RESET |
| `0x000C..0x0010` | host→device | OTA block transfer |
| `0x8001` / `0x8006` | device→host | DP report / DP report V4 |
| `0x8011` / `0x8012` | device→host | Time requests (answer them) |

DP types: RAW=0, BOOL=1, VALUE=2 (32-bit big-endian), STRING=3, ENUM=4,
BITMAP=5. A DP report is a list of `[dp id u8][type u8][length u16be][payload]`.

### DP map (zwjcy, product `gvygg3m8`) — reported, not byte-verified

| DP | Cloud code | Type | Meaning |
|----|-----------|------|---------|
| 3 | `humidity` | value 0–100 % | Soil moisture |
| 5 | `temp_current` | value, ÷10 | Temperature, °C |
| 14 | `battery_state` | enum low/normal/high | Coarse battery |
| 15 | `battery_percentage` | value % | Battery |

`wsdcg`-category variants: `ojzlzzsw` uses temp DP 1 (÷10), moisture DP 2,
battery-state DP 3, battery-% DP 4; `tv6peegl` uses temp DP 101, moisture
DP 102, no documented battery DPs.

## Hub / cloud

Phone nearby: direct BLE, no hub. Remote access / Alexa / Google / cloud
automations: requires a Tuya Bluetooth (or multi-mode) gateway. Without Tuya
cloud, stock firmware cannot be (re)paired — the local key is cloud-issued —
but an already-paired unit with extracted keys keeps working locally forever
(ha_tuya_ble). The SGS01BTHome replacement firmware (BTHome v2 passive
broadcast, optionally encrypted) removes keys, pairing and cloud entirely on
the SGS01 revision.

## Tools Used

- [ ] jadx decompile of Smart Life 7.9.0 (BLE SDK transport constants)
- [ ] Community sources: python-tuya-ble, garnser/ha_tuya_ble, haraldapp/SGS01BTHome, Home Assistant Tuya integration

## References

- [python-tuya-ble — protocol reference implementation](https://github.com/PlusPlus-ua/python-tuya-ble)
- [garnser/ha_tuya_ble — local BLE integration with DP maps](https://github.com/garnser/ha_tuya_ble)
- [haraldapp/SGS01BTHome — teardown + BTHome replacement firmware](https://github.com/haraldapp/SGS01BTHome)
- [ble_monitor issue #1161 — no passive broadcast](https://github.com/custom-components/ble_monitor/issues/1161)
- [HA issue #93536 — zwjcy cloud schema](https://github.com/home-assistant/core/issues/93536)
- [HA discussion #949 — product id lineage](https://github.com/home-assistant/core/discussions/949)

## Contributors

- Liberated Bread clean-room research — initial spec
