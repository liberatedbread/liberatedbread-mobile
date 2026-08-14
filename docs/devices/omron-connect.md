# Omron BLE Blood Pressure Monitors (OMRON connect family)

> **Status**: Complete (hardware-verified by upstream RE projects, not by us)
> **Protocol**: BLE GATT (custom split-channel sync protocol)
> **Manufacturer**: Omron Healthcare
> **Manufacturer Status**: Active

## Overview

Omron's Bluetooth blood pressure monitors (HEM-7xxx upper-arm, HEM-6xxx
wrist; retail names M2/M3/M4/M7 Intelli IT, RS2/RS7 Intelli IT, EVOLV,
Complete, Platinum, BP5xxx/BP7xxx) store measurements in on-device EEPROM
and sync them to the OMRON connect app over BLE. The sync protocol is fully
local — no cloud account on the wire — and has been reverse engineered
independently three times: userx14/omblepy (Python CLI + per-model drivers),
ichernev/omron-rs7-intelli-it (HCI-snoop protocol notes), and
eigger/hass-omron (Home Assistant integration, 12 models verified).

## Hardware

| Property | Value |
|----------|-------|
| Model Number | HEM-6161T/6232T/7142T2/7155T/7322T/7361T/7600T/… |
| Radio | BLE 4.2+ |
| Advertised name | `HEM-*`; also service `0xFE4A` and manufacturer id 0x020E |

## Initial Setup

| Property | Value |
|----------|-------|
| Setup required | Yes (one-time pairing before record download) |
| Method | `button_pairing` (hold BT button → blinking `-P-`) |
| Passphrase protection | not_applicable (no Wi-Fi); 16-byte client-chosen BLE key |
| Confidence | high (working open implementations against hardware) |

Pairing: hold the monitor's Bluetooth button 3-5 s until `-P-` blinks;
connect and enable notify on RX channel 0 (triggers OS-level BLE bonding);
write `02 ‖ 16×00` to the unlock characteristic (response `8200` = key
programming mode); write `00 ‖ <16-byte key>` (response `8000`). The key is
chosen by the client. Later sessions just write `01 ‖ key` → `8100`.

**Factory reset**: not documented in the RE sources, and not needed — the
single stored key is simply overwritten by pairing again.

**Rebinding to a new client**: in place — re-enter pairing mode and program
a new key. The hardware holds exactly ONE key: rebinding evicts the previous
client, including the official app (unpair/forget it at OS level on the old
host). Using the vendor app and a local client simultaneously is impossible.

## Protocol Summary

### BLE Services

| UUID | Name | Description |
|------|------|-------------|
| `ecbe3980-c9a2-11e1-b1bd-0002a5d5c51b` | Omron Sync Service | Parent service (legacy 4-channel set) |
| `49123040/4d0bf320/5128ce60/560f1420-aee8-…` | RX channels 0-3 | Client→device writes, 16-byte chunks in channel order |
| `db5b55e0/e0b8a060/0ae12b00/10e1ba60-aee7/8-…` | TX channels 0-3 | Device→client notifies, reassembled via length byte |
| `b305b680-aee7-11e1-a730-0002a5d5c51b` | Unlock | Key programming (02/00) and session unlock (01) |

Newer models may use a different/single-channel UUID set (per-model drivers
in omblepy and hass-omron).

### Message framing

| Offset | Length | Description |
|--------|--------|-------------|
| 0 | 1 | Total message length (incl. CRC) |
| 1 | 2 | Command type: `0000` start, `0100` EEPROM read, `01c0` write, `0f00` end (responses set the high bit: `8000`/`8100`/`81c0`/`8f00`) |
| 3 | 2 | EEPROM address (big-endian) |
| 5 | 1 | Payload size |
| 6 | n | Payload |
| last | 1 | XOR checksum (all bytes XOR to 0) |

Session: start (`08 0000 0000 10 00 18`) → EEPROM reads → optional writes
(unread-counter reset, time sync — *only these*; stray EEPROM writes can
destroy pressure calibration) → end (`08 0f00 0000 00 00 07`, status byte 0
= OK).

### Record layout (HEM-7322T, 14-byte record, bit-packed big-endian)

| Bits | Description |
|------|-------------|
| 0-7 | Diastolic mmHg |
| 8-15 | Systolic − 25 mmHg |
| 16-23 | Year − 2000 |
| 24-31 | Pulse bpm |
| 32 / 33 | Body-movement / irregular-heartbeat flags |
| 34-37, 38-42, 43-47, 52-57, 58-63 | Month, day, hour, minute, second |

Per-user ring buffers (HEM-7322T: users at 0x02AC / 0x0824, 100 records
each); settings region at 0x0260 (write-back at 0x0286) holds the
unread-record counters and the clock. Other models have their own layouts
(omblepy `deviceSpecific/*.py`).

Known limits: HEM-7196T encrypts its traffic (unsupported); HEM-7380T1 /
HEM-7377T1 read out without pairing; HEM-7530T EKG records undecoded;
battery changes can reset the clock (re-run time sync).

## Tools Used

- [ ] omblepy, ichernev's RS7 notes, hass-omron (no hardware capture done here)

## References

- [userx14/omblepy](https://github.com/userx14/omblepy)
- [ichernev/omron-rs7-intelli-it](https://github.com/ichernev/omron-rs7-intelli-it)
- [eigger/hass-omron](https://github.com/eigger/hass-omron)
- [LazyT/ubpm](https://github.com/LazyT/ubpm)

## Contributors

- @kimi - spec from third-party RE sources
