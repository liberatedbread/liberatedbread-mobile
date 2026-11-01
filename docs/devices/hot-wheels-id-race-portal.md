# Hot Wheels id Race Portal (FXB53)

> **Status**: Spec Available (unverified; read-only)
> **Protocol**: BLE
> **Manufacturer**: Mattel
> **Manufacturer Status**: Abandoned — Hot Wheels id system discontinued 31 December 2023 (Mattel FAQ); apps delisted, cloud data deleted. Community dates the shutdown 2024-01-01.

## Overview

A rechargeable piece of Hot Wheels track with an NFC reader in the floor and
a BLE radio. Every Hot Wheels id car carries an NFC tag; the portal reads it
when a car is placed on or rolls through, and pushes the car's identity (NFC
UID, serial number, the tag's NDEF record) and a per-pass speed figure to a
connected phone as GATT indications. The vendor app turned those into speeds,
laps and a collection and synced them to Mattel's cloud, which is gone.

The portal still boots, advertises and reports cars with no cloud at all.
This spec is **read-only on purpose**: the portal also has an authentication
service, a data-transfer service, a writable control register and a command
channel, and nothing published says what to write to them. Lap counting was
never a portal feature — the vendor app and the open client both derive it
from successive speed indications.

Everything here rests on one open-source client,
[mtxmiller/hotwheels-portal](https://github.com/mtxmiller/hotwheels-portal)
(MIT), captured against one portal on firmware 1.2.5.

## Initial Setup

| Property | Value |
|----------|-------|
| Setup required | No |
| Method | `ble_direct` — connect, enable indications, wait for a car |
| Advertised | Local name `HWiD` (service UUIDs in the advertisement not recorded) |
| Passphrase protection | not_applicable |
| Confidence | medium (one open implementation) |

**Factory reset**: unknown. No instruction sheet for FXB53 could be found on
Mattel's service site or anywhere else, so buttons and LED behaviour are not
documented here. Nothing on the device is known to need clearing — no bond,
no account, no network. Do not invent a button sequence.

## Pairing

| Property | Value |
|----------|-------|
| Pairing required | No |
| Security mode | `none` at the link layer; an application-layer "authentication" service exists but is not needed for car or speed events |
| Bonding | `none` |
| One central at a time | Unknown |
| Confidence | medium |

**Recovery**: close any phone still connected to the portal before
connecting.

## Protocol Summary

All UUIDs are `af0a6ec7-XXXX-YYYY-84a0-91559fc6f0de`: `YYYY` is the service
(`000a` authentication, `000b` data transfer, `000c` control) and `XXXX` is
`0001` for the service, `0002` upward for its characteristics.

| UUID | Name | Properties | Description |
|------|------|------------|-------------|
| `af0a6ec7-0001-000a-84a0-91559fc6f0de` | Authentication service | | Wire facts only; unused by the read-only client |
| `af0a6ec7-0002-000a-84a0-91559fc6f0de` | Auth command | write, indicate | Unpublished |
| `af0a6ec7-0003-000a-84a0-91559fc6f0de` | Device key / certificate | read | 148 bytes, per unit, role unknown |
| `af0a6ec7-0004-000a-84a0-91559fc6f0de` | Auth response | write, indicate | Unpublished |
| `af0a6ec7-0001-000b-84a0-91559fc6f0de` | Data transfer service | | Wire facts only |
| `af0a6ec7-0002-000b-84a0-91559fc6f0de` | Data command | write, indicate | Unpublished |
| `af0a6ec7-0003-000b-84a0-91559fc6f0de` | Data fast transfer | write_without_response | Unpublished bulk channel |
| `af0a6ec7-0001-000c-84a0-91559fc6f0de` | Portal control service | | Everything below |
| `af0a6ec7-0002-000c-84a0-91559fc6f0de` | Firmware version | read | ASCII, e.g. `1.2.5` |
| `af0a6ec7-0003-000c-84a0-91559fc6f0de` | Car serial | read, indicate | ASCII digits of the car on the reader; empty when none |
| `af0a6ec7-0004-000c-84a0-91559fc6f0de` | Car NDEF record | indicate | URI record `https://www.pid.mattel/<token>`; empty on removal |
| `af0a6ec7-0005-000c-84a0-91559fc6f0de` | Car detection | indicate | `04` + 6-byte NFC UID; empty on removal |
| `af0a6ec7-0006-000c-84a0-91559fc6f0de` | Speed / timing | indicate | float32, little-endian, one per pass |
| `af0a6ec7-0007-000c-84a0-91559fc6f0de` | Control register | write, read, indicate | 5 bytes; byte 4 = `02` with a car present |
| `af0a6ec7-0008-000c-84a0-91559fc6f0de` | Command channel | write, indicate | Unpublished |

**Connect**: enable indications on `0003`, `0004`, `0005`, `0006` and `0007`
of the control service, read `0002` for the firmware. **Car placed**: control
register `00 fe 00 fe 02`, then serial, then `04`+UID, then the NDEF record.
**Car passes**: one speed indication. **Car removed**: NDEF, UID and serial
indicate empty values; control register `00 72 9b fe 00`.

**Speed** is an IEEE 754 binary32, little-endian (`b0 1c 14 3e` → 0.1446).
Its unit is unconfirmed: the source hedges between metres per second and a
passage time in seconds, and the "scale mph" its dashboard shows is the raw
value × 64 (1:64 scale) with a label, not a conversion. The spec reports the
raw value.

**Car ID**: the NDEF URI's token is 28 URL-safe base64 characters decoding to
21 bytes — 2-byte version (`01 00`), 4-byte model id, 4 bytes of flags, 5
bytes of extra data and the 6-byte NFC UID last. Mattel's model-id-to-name
table is not reproduced. The record header is `0x91` (Message-End clear), so
a further record the source calls a signature follows; its layout is
unpublished.

`scripts/test_hot_wheels_id_race_portal_spec.py` holds the spec's float
examples to `struct '<f'`, rebuilds the example NDEF URI record from the
invented car-ID token with the standard library, and checks the UUID scheme.

See `device-specs/devices/hot-wheels-id-race-portal.yaml` for the full
machine-readable spec.

## References

- [mtxmiller/hotwheels-portal](https://github.com/mtxmiller/hotwheels-portal) — MIT client; `PROTOCOL.md` has the captured layouts
- [Mattel: Hot Wheels id System Discontinuation FAQs](https://shop.mattel.com/pages/hot-wheels-id-faqs)
- [Mattel consumer service: FXB53 product page](https://service.mattel.com/us/productDetail.aspx?prodno=FXB53) — no instruction sheet is hosted
