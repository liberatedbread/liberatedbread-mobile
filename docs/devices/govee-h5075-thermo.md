# Govee H5075 Thermometer/Hygrometer

> **Status**: Complete (hardware-verified 2026-08)
> **Protocol**: BLE (passive advertisements + optional GATT connection)
> **Manufacturer**: Govee (Shenzhen Intellirocks Tech Co., Ltd.)
> **Manufacturer Status**: Active

## Overview

Battery BLE thermometer/hygrometer that broadcasts temperature, humidity
and battery in its manufacturer advertisement — live readings need no
connection, no pairing and no account. Connecting adds three things
scanning cannot give: the reading at two decimals instead of one, the
stored record count, and the history buffer (about 20 days at the measured
record rate).

Verified end to end against one unit (`GVH5075_BBCC`, firmware 1.04.07,
hardware 1.03.02) from a Raspberry Pi 5 on BlueZ 5.82 with bleak 3.0.2, on
2026-08-12/13 (sub-zero sign-bit check 2026-08-16). Seventeen sibling
models (H5051/H5052, H5071/H5072/H5074, H5100–H5112 family, H5129,
H5174/H5177–H5179) are covered by the spec but were **not tested** — their
advertisement layouts differ and are carried from community parsers.

Machine-readable spec: `device-specs/devices/govee-h5075-thermo.yaml`.

## Hardware

| Property | Value |
|----------|-------|
| Model Number | H5075 (+ 17 untested sibling models, see spec `device.variants`) |
| Chipset | Telink TLSR8253F512 BLE SoC |
| Radio | BLE (legacy advertising, ~2.04 s interval) |
| FCC ID | 2AQA6-H5075 (grantee Shenzhen Intellirocks Tech, granted 2019-12-13) |
| Advertised name | `GVH5075_XXXX` (H5074 and H5179 use `Govee_<model>_XXXX`) |
| Advertised service | 16-bit UUID `0xEC88` (`0000ec88-0000-1000-8000-00805f9b34fb`) |
| Manufacturer company ID | `0xEC88` (60552) |

The scan response carries an iBeacon frame whose proximity UUID spells
`INTELLI_ROCKS_HW` in ASCII (`494e5445-…-4857`). A passive scanner never
sees it, and it is not advertised as a service UUID — though a GATT service
with that UUID does exist once connected. Note that btmon prints iBeacon
fields byte-swapped.

## Initial Setup

| Property | Value |
|----------|-------|
| Setup required | No |
| Method | `ble_direct` (passive scan) |
| Setup AP / advertised name | `GVH5075_XXXX` |
| Passphrase protection | not_applicable |
| Confidence | high (verified on hardware, correlated to the device LCD) |

Passive scan for company ID `0xEC88` and decode the 6-byte manufacturer
payload. Connect only when you want the two-decimal reading, the record
count, or history.

**Factory reset**: pull the batteries for 10+ seconds. There are no stored
credentials and no pairing state to clear (not executed on the test unit —
expected behaviour of a broadcast-only device).

**Rebinding**: trivial — no persistent connection state; just scan from the
new controller.

## Protocol Summary

### Advertisement (6-byte manufacturer payload under company ID 0xEC88)

| Offset | Length | Description |
|--------|--------|-------------|
| 0 | 1 | Reserved (`0x00` in every packet observed) |
| 1–3 | 3 | 24-bit big-endian packed value. Bit 23 = temperature sign flag; bits 22–0 hold `(temp × 10000) + (humidity × 10)` |
| 4 | 1 | Battery percent, 0–100 |
| 5 | 1 | Reserved (`0x00`; **not** the battery) |

Decode by splitting the decimal digits, not by dividing the whole value:

```
v = bits 22–0            # mask 0x7FFFFF, NOT 0x7FFFF
temperature °C = (v // 1000) / 10.0, negated if bit 23 set
humidity %     = (v % 1000) / 10.0
```

Two traps, both confirmed on hardware:

- Masking with 19 bits (`0x7FFFF`, as some community loggers do) agrees
  below 52.4 °C and **wraps** above it — at a true 52.6 °C it reads 0.1 °C
  and 87.7 % humidity.
- Computing `v / 10000.0` for temperature leaves the humidity digits inside
  the temperature, so the reading drifts with humidity.

Worked example: `00 04 18 87 61 00` → raw `0x041887` = 268423 → 26.8 °C,
42.3 %, battery 97. The payload is Celsius whatever the display is set to.
The encoding has no room for exactly 100.0 % humidity (would carry into the
temperature digits); clamp vs overflow is untested.

### BLE Services

| UUID | Name | Description |
|------|------|-------------|
| `494e5445-…-4857` | Govee INTELLI_ROCKS_HW Service | Main service; present without pairing |
| `494e5445-…-2011` | Device Data / Command (read/write/notify) | 20-byte command channel; byte 0 = `0xAA` read / `0x33` set, byte 1 = opcode, byte 19 = XOR of bytes 0–18 |
| `494e5445-…-2012` | History Download Request (read/write/notify) | Write `33 01` here to start a history transfer |
| `494e5445-…-2013` | History Download Response (read/notify) | Subscribe **before** writing `…2012`; subscribing afterwards yields nothing and is not recoverable |
| `00010203-…-1912` | Govee Auth Service | Carries only `…2b12` on this unit; **no handshake was required** — every command answered in the clear |
| `00010203-…-2b12` | Auth Config (read/write-without-response/notify) | Reads back a single `0x00` |
| `00001800-…-34fb` | Generic Access | Device name, appearance (unset), connection params |
| `0000180a-…-34fb` | Device Information | PnP ID only — no version strings; use `aa 0d`/`aa 0e` instead |

There is no standard Battery Service (`0x180F`) on this unit: battery comes
from advertisement byte 4 or `aa 08`.

### Commands (on `…2011`, 20-byte packets, XOR checksum at byte 19)

| Command | Purpose |
|---------|---------|
| `aa 0a` | Current reading at two decimals: temp as **signed** int16 LE hundredths at bytes 2–3, humidity uint16 LE hundredths at bytes 4–5 (unsigned decode of the temp reads 649.77 °C at −5.61 °C) |
| `aa ef` | Stored record count, uint32 BE at bytes 2–5 — exact, where a dump can be truncated; ask before requesting history |
| `aa 08` | Battery percent in byte 2 |
| `aa 0d` / `aa 0e` | Hardware / firmware revision, ASCII (the only route to version strings) |
| `aa 0c` / `aa 0f` | MAC (reversed byte order); `aa 0c` adds a further pair other sources call a serial |
| `aa 03` / `aa 04` | Humidity / temperature alarm thresholds (int16 LE hundredths, low then high) |
| `aa 06` / `aa 07` | Temperature / humidity calibration offsets |
| `aa fe` | A 16-character per-device string (serial or key material; not recorded) |
| `33 03/04/06/07` | Setters mirroring the alarm/calibration reads — **untested** (flagged `advanced` in the spec: they write persistent state; read and save current values first) |

Caveats confirmed on the bench: the first command after connecting is
dropped roughly two rounds in three — send a throwaway write or retry.
`aa 01`, listed elsewhere as the current measurement, never answered on
this unit. The device hangs up after ~11.9 s idle (writes stretch it to
~20 s; reconnecting costs ~8.4 s), and it keeps advertising while
connected.

### History download

Subscribe to `…2013`, **then** write `33 01 <first u32 LE> <last u32 LE>
00…<xor>` to `…2012`. Records stream back as 20-byte notifications on
`…2013`: a 2-byte big-endian offset followed by six 3-byte records in the
same 24-bit packed encoding as the advertisement. Byte 19 is record data,
**not** a checksum. Offset 0 is the newest record; the stream ends when the
offset reaches 0 — do not stop early at offset ≤ 6 (the final packet
carries real records) and do not wait for an end marker (`ee 01` was never
sent across five dumps). Padding past the buffer end is `ffffff`. The two
u32 arguments do not select a range: ask for the lot (`first=100` returned
a full buffer in every trial) and read the offsets you actually get.
Records are written every ~61.3 s (measured, one unit's crystal — take two
counts a few hours apart on the unit in front of you), not 60; at 60 s
assumed, the oldest record of a full buffer ends up ~10 hours adrift.

## Tools Used

- [x] Hardware verification: Raspberry Pi 5, BlueZ 5.82, bleak 3.0.2, against GVH5075_BBCC fw 1.04.07 (captures published with the spec)
- [ ] Community parsers (wcbonner/GoveeBTTempLogger, Bluetooth-Devices/govee-ble) — variant layouts

## References

- [wcbonner/GoveeBTTempLogger](https://github.com/wcbonner/GoveeBTTempLogger)
- [Bluetooth-Devices/govee-ble](https://github.com/Bluetooth-Devices/govee-ble)
- [Home Assistant Govee BLE integration](https://www.home-assistant.io/integrations/govee_ble)
- [H5105 protocol notes](https://github.com/NHaag87/govee-api/blob/main/API_documentation/H5105_protocol.md) — sibling model; source for the encrypted-handshake report (not reproduced on this unit)
- [Heckie75/govee-h5075-thermo-hygrometer](https://github.com/Heckie75/govee-h5075-thermo-hygrometer)
- [FCC ID 2AQA6-H5075](https://fccid.io/2AQA6-H5075)

## Contributors

- @kimi - hardware verification and spec
