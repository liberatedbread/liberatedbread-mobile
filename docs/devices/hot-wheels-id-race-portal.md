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
This spec is **read-only on purpose**. A community client supplies a working
unauthenticated event stream. Analysis of the recovered official 3.9.0 app
adds a separate MPID session layer and signed-image OTA service, but not a
safe complete command sequence to offer here. Lap counting was never a portal
feature — the vendor app and the open client both derive it from successive
speed indications.

The community path comes from
[mtxmiller/hotwheels-portal](https://github.com/mtxmiller/hotwheels-portal)
(MIT), captured against one portal on firmware 1.2.5. MPID, OTA and the
richer application model were independently recovered from the official app
on 2026-10-31. Keep those evidence classes separate: the official app does
not contain the community client's `000c` service map.

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
documented here. The recovered application model names reset and clear-bond
commands, but their outer envelope and safety sequence are unresolved. Do not
send them on the community control channel or invent a button sequence.

## Pairing

| Property | Value |
|----------|-------|
| Pairing required | No for the read-only event stream |
| Security mode | No link-layer pairing on the community path; the official path uses an application-layer MPID session |
| Bonding | Unknown |
| One central at a time | Unknown |
| Confidence | medium |

**Recovery**: close any phone still connected to the portal before
connecting.

## Protocol Summary

All UUIDs are `af0a6ec7-XXXX-YYYY-84a0-91559fc6f0de`: `YYYY` is the service
(`000a` MPID session, `000b` OTA, `000c` community control) and `XXXX` is
`0001` for the service, `0002` upward for its characteristics.

| UUID | Name | Properties | Description |
|------|------|------------|-------------|
| `af0a6ec7-0001-000a-84a0-91559fc6f0de` | MPID session service | | Official encrypted-session path |
| `af0a6ec7-0002-000a-84a0-91559fc6f0de` | MPID packets | write, indicate | Encrypted packets in both directions |
| `af0a6ec7-0003-000a-84a0-91559fc6f0de` | Manufacturing token | read | Reading starts session setup; variable-length, per unit |
| `af0a6ec7-0004-000a-84a0-91559fc6f0de` | Session public key and salt | write, indicate | Written after parsing the token |
| `af0a6ec7-0001-000b-84a0-91559fc6f0de` | OTA service | | Vendor-confirmed signed-image path |
| `af0a6ec7-0002-000b-84a0-91559fc6f0de` | OTA commands | write, indicate | Start, block, complete and error messages |
| `af0a6ec7-0003-000b-84a0-91559fc6f0de` | OTA payload | write_without_response | Signed-image chunks |
| `af0a6ec7-0001-000c-84a0-91559fc6f0de` | Portal control service | | Community read-only path |
| `af0a6ec7-0002-000c-84a0-91559fc6f0de` | Firmware version | read | ASCII, e.g. `1.2.5` |
| `af0a6ec7-0003-000c-84a0-91559fc6f0de` | Car serial | read, indicate | ASCII digits of the car on the reader; empty when none |
| `af0a6ec7-0004-000c-84a0-91559fc6f0de` | Car NDEF record | indicate | URI record `https://www.pid.mattel/<token>`; empty on removal |
| `af0a6ec7-0005-000c-84a0-91559fc6f0de` | Car detection | indicate | `04` + 6-byte NFC UID; empty on removal |
| `af0a6ec7-0006-000c-84a0-91559fc6f0de` | Speed / timing | indicate | float32, little-endian, one per pass |
| `af0a6ec7-0007-000c-84a0-91559fc6f0de` | Control register | write, read, indicate | 5 bytes; byte 4 = `02` with a car present |
| `af0a6ec7-0008-000c-84a0-91559fc6f0de` | Command channel | write, indicate | No safe write sequence established |

**MPID setup** reads the manufacturing token, parses its version, serial,
compressed public key, manufacturing key id, signature and salt, then writes
the phone's public key and salt on `0004`. Per the app analysis,
generation-one tokens are 136 bytes and other formats vary, at least 182
bytes. The community client's protocol notes separately record a 148-byte
read on its unit. That observation matches neither format and is unexplained
(a third format, a truncated read or a firmware difference), so a parser goes
by the token's own version and lengths, never a fixed size.
Later packets on `0002` are encrypted. The complete session state machine and
outer official command envelope remain out of scope.

**OTA** requests MTU 247 in the recovered app and verifies an image signature
before sending it. Commands cover new image, request/response, block, chunk,
complete, error and stop. No firmware or update is offered without a
hardware compatibility check.

**Connect**: enable indications on `0003`, `0004`, `0005`, `0006` and `0007`
of the control service, read `0002` for the firmware. **Car placed**: control
register `00 fe 00 fe 02`, then serial, then `04`+UID, then the NDEF record.
**Car passes**: one speed indication. **Car removed**: NDEF, UID and serial
indicate empty values; control register `00 72 9b fe 00`.

**Speed** is an IEEE 754 binary32, little-endian (`b0 1c 14 3e` → 0.1446),
decoded by the schema's `float32` field type. Its unit is unconfirmed: the
community source hedges between metres per second and a passage time, while
the official descriptor proves only a float named speed. The dashboard's
"scale mph" is raw value × 64 with a label, not a settled conversion.

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
