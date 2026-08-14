# ThermoPro TP357 / TP358 / TP359 / TP393 Hygrometers

> **Status**: Complete (parser-library-derived; connected mode from single-project RE)
> **Protocol**: BLE (passive advertisements; connected history on TP357/TP357S)
> **Manufacturer**: ThermoPro (Adsmart)
> **Manufacturer Status**: Active

## Overview

Small battery BLE temperature/humidity sensors broadcasting readings in
advertisement manufacturer data — no connection needed for live values.
Covers the TP35x/TP39x family: TP357, TP357S, TP358, TP358S, TP359, TP393,
TP397. TempSpike BBQ probes (TP96x/TP97x) are a different family — see
spec `device-specs/devices/thermopro-tempspike-bbq.yaml`.
The TP357S additionally has a connected GATT history mode documented by
pytp357s; the original TP357 has a different one (pasky/tp357).

## Hardware

| Property | Value |
|----------|-------|
| Model Number | TP357(S), TP358(S), TP359, TP393, TP397 |
| Radio | BLE (legacy advertising, connectable) |
| Advertised name | `TP357 (2142)` style — model + last two MAC bytes in hex |
| Battery | 1× AAA (TP357), ~6 months |

## Initial Setup

| Property | Value |
|----------|-------|
| Setup required | No |
| Method | `ble_direct` (passive scan) |
| Setup AP / advertised name | `TP35*` / `TP39*` |
| Passphrase protection | not_applicable |
| Confidence | high for passive decode (capture-pinned parser), medium for connected mode |

**Factory reset**: none documented and none needed — no credentials or
bindings on the device. Note a battery pull appears to clear the stored
history buffer (pasky/tp357).

**Rebinding**: in place. Broadcast-only for live data; the connected history
mode requires no pairing, just a per-session datetime-sync write (TP357S).

## Protocol Summary

Advertisement quirk: like Inkbird's IBS-TH, there is **no real company ID** —
byte 1 of the temperature sits in the company-ID high byte, so every reading
surfaces under a different "manufacturer id" (clusters like 0xF1C2, 0xEEC2).
Match on the advertised name, never on a company id.

### Manufacturer data (6 bytes; 7 on TP357S)

| Offset | Length | Description |
|--------|--------|-------------|
| 0 | 1 | Per-unit prefix (0xC2 common, 0x82 seen) |
| 1 | 2 | Temperature, s16 LE, /10 °C (`f1 00` → 24.1 °C) |
| 3 | 1 | Humidity, uint8 % |
| 4 | 1 | Battery, low 2 bits: 0→1 %, 1→50 %, 2→100 % |
| 5 | 1-2 | 0x2C (6-byte models); 2-byte tail `0b 01` on TP357S |

`FF FF FF` in the temp/humidity bytes is an invalid-reading sentinel — drop
the packet. Example frame `82 f1 00 1d 02 2c` → 24.1 °C, 29 %, battery full.

### BLE Services (TP357S connected mode)

| UUID | Name | Description |
|------|------|-------------|
| `00010203-0405-0607-0809-0a0b0c0d1910` | Data service | Fixed across units; Nordic DFU 0xFE59 also present |
| `...2b11` | Command write | `0xa5` datetime sync (required each connection), then `0xcccc`-framed history commands |
| `...2b10` | Response notify | Live `0xc2` frames + streamed history ending in `66 66` |

Session: enable notify → write `a5 YY MM DD HH MM SS DOW CS` (CS = sum &
0xFF) → device replies with a live `c2` reading then `a5 01 13 5a` → send
the three history commands (~200 ms apart; third carries the wanted record
count as u16 LE) → reassemble notifications between `cc cc` and `66 66` →
records are temp×10 s16 LE + humidity triplets, most-recent-first, 1-minute
steps. Counts above 28800 (~20 days) are silently ignored — that is
presumably the buffer. The original (non-S) TP357 instead uses opcodes
0xa6/0xa7/0xa8 (year/week/day) — a different protocol, see pasky/tp357.

## Tools Used

- [ ] Bluetooth-Devices/thermopro-ble parser + tests; pytp357s; pasky/tp357 (no hardware capture done here)

## References

- [Bluetooth-Devices/thermopro-ble](https://github.com/Bluetooth-Devices/thermopro-ble)
- [giovannipizzi/pytp357s PROTOCOL.md](https://github.com/giovannipizzi/pytp357s/blob/main/PROTOCOL.md)
- [pasky/tp357](https://github.com/pasky/tp357)
- [ble_monitor](https://github.com/custom-components/ble_monitor)

## Contributors

- @kimi - spec from third-party parser/RE sources
