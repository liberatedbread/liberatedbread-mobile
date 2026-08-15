# Bluetti Power Station (EP500 family)

> **Status**: Complete (V1 read path hardware-verified; writes and V2/encrypted documented from prior art)
> **Protocol**: BLE (MODBUS-RTU over GATT)
> **Manufacturer**: Bluetti (Shenzhen Poweroak Newener Co., Ltd.)
> **Manufacturer Status**: Active — cloud-independence spec, not an abandonment rescue

## Overview

Bluetti portable power stations (EP500, EP500P, AC200M, AC300, AC500, AC60,
EP600, EB3A and kin) expose full telemetry and output control over plain local
BLE — no pairing, no authentication, no cloud. The vendor app routes telemetry
through Bluetti's IoT cloud, but every reading and switch below is local GATT.
Three mature open implementations (bluetti_mqtt, bluetti-bt-lib /
hassio-bluetti-bt, Bluetti_ESP32_Bridge) drive these units offline.

The read path of this spec was **verified against real EP500 hardware
(2026-08-14)**: the model string read from register 10 and the serial from
register 17 matched the unit's advertised name `EP500<serial>` exactly, and
the status block returned live telemetry (SOC 50 %, AC output on under a
1 kW load) with valid CRCs.

## Hardware

| Property | Value |
|----------|-------|
| Model verified | EP500 (2 kW inverter / 5.1 kWh LiFePO4) |
| BT module | OUI `00:15:83` (IVT Corporation stack vendor); advertises 16-bit service `0xFF00` |
| Radio | BLE 4.x GATT, public address |
| Advertised name | `<MODEL><serial>`, e.g. `EP5002142000061564` |

## Initial Setup

| Property | Value |
|----------|-------|
| Setup required | No |
| Method | `ble_direct` — connect, subscribe `0xFF01`, write MODBUS frames to `0xFF02` |
| Passphrase protection | not_applicable (no pairing, no authentication on the plain protocol) |
| Confidence | high (verified live + three working open implementations) |

**Factory reset**: nothing BLE-relevant to clear — no bonds, no credentials.

**Rebinding**: single-connection peripheral; any client may connect once the
previous central (including the vendor app) disconnects.

## Protocol Summary

MODBUS-RTU frames over GATT: address byte `0x01`, function `0x03` (read
holding registers) / `0x06` (write single register), registers big-endian,
CRC-16/MODBUS appended little-endian. Requests fit one ATT write; responses
fragment across `0xFF01` notifications — reassemble to `2*qty+5` bytes, then
CRC-check. One command in flight at a time.

### Protocol generations

| Generation | Detection | Identity registers |
|-----------|-----------|--------------------|
| Plain V1 (EP500 class) | silence on `0xFF01` after subscribe | type @ 10 (ASCII), serial @ 17, SOC @ 43 |
| Plain V2 (AC70/AC180/EL30 class) | same silence, V1 identity reads fail | type @ 110 (byte-swapped), serial @ 116, SOC @ 102 |
| Encrypted (newer firmware) | unsolicited `2A 2A` push right after subscribe | AES/ECDH handshake, not covered |

### Key registers (EP500 / V1)

| Register | Field | Notes |
|----------|-------|-------|
| 10 (×6) | model string | hardware-verified |
| 17 (×4) | serial (u64, low word first) | hardware-verified |
| 36–39 | DC-in / AC-in / AC-out / DC-out power (W) | hardware-verified |
| 43 | battery SOC % | hardware-verified |
| 48 / 49 | AC / DC output state | hardware-verified |
| 3007 / 3008 | AC / DC output **control** (write 1/0) | prior art; switches real loads |
| 91–121 | pack voltages, per-cell voltages | prior art |

See `device-specs/devices/bluetti-power-station.yaml` for the full map,
polling ranges and safety notes.

## Tools Used

- bleak/BlueZ probe driving frames straight from the spec document

## References

- <https://github.com/warhammerkid/bluetti_mqtt>
- <https://github.com/Patrick762/bluetti-bt-lib>
- <https://github.com/Patrick762/hassio-bluetti-bt>
- <https://github.com/mariolukas/Bluetti_ESP32_Bridge>
