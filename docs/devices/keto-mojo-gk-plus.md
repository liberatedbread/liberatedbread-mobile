# Keto-Mojo GK+ Blood Glucose and Ketone Meter

> **Status**: Spec Available (unverified)
> **Protocol**: BLE (vendor service, read-only data sync)
> **Manufacturer**: Keto-Mojo (built by VivaChek)
> **Manufacturer Status**: Active — protocol closed, vendor app in the stores

## Overview

The GK+ is a handheld fingerstick meter that reads blood glucose and blood
beta-ketone from two kinds of test strip, stores up to 1000 dated results and
syncs them to the Keto-Mojo phone app over Bluetooth LE. Over BLE it is a
read-only data logger. A client asks for the glucose unit, the serial number
and the whole stored history, and the meter answers with notifications.
Nothing starts a test or changes a setting.

It does not use the Bluetooth SIG Glucose Profile (`0x1808`). It speaks a
small vendor (VivaChek) framing on its own service. That framing was worked
out independently by the author of an open-source Home Assistant integration
announced on 2026-10-17, and this spec is read from that integration.

!!! warning "Medical device"
    Readings synced from the meter are a personal log. They must never be
    used to decide an insulin or other medication dose. Control-solution
    tests (type bytes `0x22` and `0x66`) are strip and solution checks, not
    blood readings, and must never be shown as readings. The spec carries a
    `safety_advisory` that says so.

## Hardware

| Property | Value |
|----------|-------|
| Model | Keto-Mojo GK+ Blood Glucose and β-Ketone Meter |
| Radio | Bluetooth LE (4.2 per the vendor's Canadian product page) |
| Power | 2 × AAA LR03; auto-off 2 minutes after the last action |
| Memory | 1000 results with date and time; the oldest is overwritten first |
| Ranges | Glucose 1.1–33.3 mmol/L; ketone 0.1–8.0 mmol/L |
| Firmware seen | `SW2071323011A001` (the integration author's meter) |

## Initial Setup

| Property | Value |
|----------|-------|
| Setup required | No. There is no account, network or bond |
| Method | `ble_direct`: connect, enable notifications, write three fixed frames |
| Advertised | Local name beginning `Keto-Mojo` (may carry trailing NULs) |
| Passphrase protection | not_applicable |
| Confidence | medium (one working open client; not replayed here) |

The meter advertises while it is switched on. Press the main button, or
insert a strip. The vendor app's sync also sets the meter's clock, but the
command it uses is not known. Without the app, set the clock on the meter in
set-up mode: with the meter off, hold the main button for 3 seconds.

**Factory reset**: unknown. The manual describes no reset and no way to
clear memory, and stored results survive a battery change.

**Rebinding to a new phone**: nothing to rebind. Close the vendor app so it
releases the connection.

## Pairing

| Property | Value |
|----------|-------|
| Pairing required | No (the open client never pairs or bonds) |
| Security mode | `none` |
| Bonding | `none` |
| One central at a time | Yes. Close the Keto-Mojo app first |
| Confidence | medium |

## Protocol Summary

### BLE Services

| UUID | Name | Properties | Description |
|------|------|-----------|-------------|
| `0003cdd0-0000-1000-8000-00805f9b0131` | VivaChek meter service | | Vendor service (from the integration's README) |
| `0003cdd1-0000-1000-8000-00805f9b0131` | Reply | notify | Every reply, as notifications |
| `0003cdd2-0000-1000-8000-00805f9b0131` | Command | write without response | Request frames |

These UUIDs are not on the Bluetooth SIG base. The last group is
`00805f9b0131`, not `00805f9b34fb`, so they are full 128-bit vendor UUIDs
and cannot be shortened to 16-bit forms.

### Frame

```
7b | 01 | src | 01 | dst | cmd | status | len (u16 BE) | data | c0 c1 c2 c3 | 7d
```

The client's address is `0x10` and the meter's is `0x20`. The status byte is
`0x55` on a request, `0xaa` on a reply that carries data and `0x66` on the
end-of-records frame. The check is a **CRC-16/MODBUS** over bytes 1 through
the last data byte. It is sent low byte first, and each CRC byte is split
into two bytes that hold its high nibble and then its low nibble, so the
check can never contain `7b` or `7d`. The integration only sends fixed
frames. This project derived the check rule, and it reproduces all four
literal frames.

### Commands

Written to `0003cdd2-0000-1000-8000-00805f9b0131`, in this order. Wait for
each answer before sending the next:

| Frame | Meaning | Answer |
|-------|---------|--------|
| `7b 01 10 01 20 aa 55 00 00 02 01 0d 08 7d` | Get glucose unit | `7b 01 20 01 10 aa aa 00 01 <code> …`; `0x11` mg/dL, `0x22` mmol/L |
| `7b 01 10 01 20 77 55 00 00 01 0b 0b 04 7d` | Get serial | `7b 01 20 01 10 77 aa 00 10` + 16 ASCII bytes, NUL/space padded |
| `7b 01 10 01 20 dd 55 00 00 03 0a 06 0c 7d` | Fetch all records | One record frame per result, then `7b 01 20 01 10 d1 66 00 00 0b 09 03 04 7d` |

The integration enables notifications, waits 0.5 s, and allows 8 s each for
the unit and the serial and 30 s for the record dump. A record frame is
23 bytes, longer than a default 20-byte notification. Concatenate
notifications before you cut frames at `7b … 7d`.

### Stored record (bytes 9–17 of a record frame)

| Byte | Field |
|------|-------|
| 9 | Year − 2000 (binary) |
| 10–13 | Month, day, hour (24 h), minute; no seconds; meter-local time |
| 14–15 | Value as two base-100 digits: raw = byte14 × 100 + byte15 (**not** a uint16) |
| 16 | High nibble: meal marker. `1` pre-meal, `2` post-meal, else general |
| 17 | Type: `0x11` glucose, `0x12` glucose (GKI pair), `0x55` ketone, `0x56` ketone (GKI pair), `0x22` glucose control, `0x66` ketone control |

Ketone values are raw / 100 mmol/L. Glucose values are raw mg/dL, or
raw / 10 mmol/L on a meter set to mmol/L. Worked example:
`7b 01 20 01 10 dd aa 00 09 1a 0a 11 07 1e 00 5f 10 11 0e 09 0b 07 7d` is a
pre-meal glucose of 95 mg/dL taken on 2026-10-17 at 07:30. The integration
does not check header bytes 5–6 or the length of a record frame. The example
fills them in by analogy with the unit and serial replies.

GKI-mode pairs (`0x12` next to `0x56`) give a Glucose Ketone Index: glucose in
mmol/L (mg/dL ÷ 18) divided by ketone in mmol/L, floored to one decimal.

The spec binds no entities. Every reply arrives on one characteristic, and a
"last glucose" sensor would need three steps: pick one record type out of a
dump of up to 1000 records, decode the base-100 value and pick the newest
timestamp. The schema cannot express any of them, so a client implements
`payload_formats.RecordFrame` and keeps its own history.

`scripts/test_keto_mojo_gk_plus_spec.py` transcribes the frame check and the
record decode with the standard library. It pins the four frames that appear
literally in the integration, and it decodes every worked example in the
spec.

See `device-specs/devices/keto-mojo-gk-plus.yaml` for the full machine-readable spec.

## References

- [gjg4000-debug/ha-keto-mojo (Home Assistant integration, MIT)](https://github.com/gjg4000-debug/ha-keto-mojo)
- [Home Assistant community: Keto-Mojo GK+ integration announcement (2026-10-17)](https://community.home-assistant.io/t/new-integration-keto-mojo-gk-glucose-ketone-meter-over-bluetooth/1029313)
- [Keto-Mojo GK+ user's manual, Canadian English/French edition (PDF)](https://keto-mojo.com/wp-content/uploads/2026/08/Keto-Mojo-GK-Meter-Users-Manual-En-Fr-CAN-WEB.pdf)
- [Keto-Mojo user guides and manuals](https://keto-mojo.com/help-docs/user-guides-manuals/)
