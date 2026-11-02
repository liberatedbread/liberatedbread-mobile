# QardioArm (A100) Blood Pressure Monitor

> **Status**: Spec Available (unverified)
> **Protocol**: BLE (standard Blood Pressure Service + one vendor command)
> **Manufacturer**: Qardio, Inc. (OEM Ya Horng Electronic, Taiwan)
> **Manufacturer Status**: Shutdown — cloud down 2025-04-29, apps delisted, company bankrupt

## Overview

The QardioArm is an upper-arm blood-pressure cuff that folds around its own
pump unit. It has no screen and no button: unwrapping the cuff switches it on,
wrapping it back switches it off, and every measurement is started from a phone
over BLE. That made it entirely dependent on the vendor app, which would not
show its START button without a signed-in Qardio account — so when the Qardio
servers went down for good on 29 April 2025 the cuff stopped working, although
nothing on the device had changed.

The protocol is almost entirely standard. The cuff implements the Bluetooth SIG
**Blood Pressure Service** (`0x1810`) and delivers results as **Blood Pressure
Measurement** (`0x2a35`) records; the one vendor addition is a control
characteristic in the same service that takes a two-byte command to inflate or
cancel. Two open-source clients, LibreArm (iOS) and its Android port, drive it
daily with no cloud or account, and this spec is read from them.

!!! warning "Medical device"
    Starting a measurement inflates the cuff on whoever is wearing it; only do
    so for a consenting adult who is ready, and stay with them. Readings from a
    third-party client are a personal log, not a clinical measurement, and
    must never be the sole basis for a medication decision. The spec carries
    a `safety_advisory` saying so.

## Hardware

| Property | Value |
|----------|-------|
| Model Number | A100 (FDA 510(k) K140067); the manual also lists an A101 |
| Radio | Bluetooth 4.0 LE; chipset not established (the vendor app bundles a Nordic DFU library) |
| FCC ID | 2ABF2-888ARM (IC 11885A-888ARM00) |
| Power | 4 × AAA alkaline; the manual excludes rechargeables |
| Measurement range | 40–250 mmHg, 40–200 bpm, 1 mmHg / 1 bpm resolution; cuff 22–37 cm |

## Initial Setup

| Property | Value |
|----------|-------|
| Setup required | No — no account, no network, no cloud |
| Method | `ble_direct`: unwrap, connect, bond, enable notifications, write start |
| Advertised | Service `00001810-0000-1000-8000-00805f9b34fb`; name believed to begin `Qardio` |
| Passphrase protection | not_applicable |
| Confidence | medium (two working open clients; not replayed here) |

The cuff advertises **only while unwrapped**; wrapped, or after a few idle
minutes, it is off. A client that cannot find it should tell the user to
unwrap it, not to press anything.

**Factory reset**: the only reset the cuff has is the pairing reset. With the
cuff unwrapped (on), press the button behind the pinhole on the **battery
compartment hatch** with a straightened paper clip; a **green light** shines
through the hatch. Then forget the QardioArm in the old phone's Bluetooth
settings. From the vendor manual (v2.4, page 15) and LibreArm's recovery
advice; not replayed.

**Rebinding to a new phone**: the pairing reset above. There is no network,
and the cuff stores nothing but the bond.

## Pairing

| Property | Value |
|----------|-------|
| Pairing required | Yes |
| Security mode | `just_works` (inferred: code-free prompt, ATT auth/encryption errors when unbonded) |
| Bonding | `required` |
| One central at a time | Unknown |
| One bond at a time | Yes — a second phone cannot bond until the pinhole clears the first |
| Confidence | medium |

**Entering pairing mode**: nothing to do; the cuff is pairable whenever it is
on. The first secured operation (enabling notifications on `0x2a35`) raises
the OS pairing prompt.

**Unpairing**: the pinhole press, which is the whole factory reset.

**Recovery**: an ATT error `0x05`, `0x08`, `0x0c` or `0x0f` on the
notification enable or the start write means the bond on one side no longer
matches the other. Forget the cuff on the phone, press the pinhole, reconnect.

## Protocol Summary

### BLE Services

| UUID | Name | Properties | Description |
|------|------|-----------|-------------|
| `00001810-0000-1000-8000-00805f9b34fb` | Blood Pressure Service | | Standard SIG service plus one vendor characteristic |
| `00002a35-0000-1000-8000-00805f9b34fb` | Blood Pressure Measurement | notify | Standard SIG record; both clients enable notifications (CCCD `01 00`) |
| `583cb5b3-875d-40ed-9098-c39eb0c1983d` | QardioArm control | write | Two-byte command, first byte `f1` |
| `0000180f-0000-1000-8000-00805f9b34fb` | Battery Service | | Standard; "when the cuff exposes it" |
| `00002a19-0000-1000-8000-00805f9b34fb` | Battery Level | read | 0–100 %; LibreArm blocks a start at ≤ 10 % |

### Commands

Written to `583cb5b3-875d-40ed-9098-c39eb0c1983d`:

| Bytes | Meaning |
|-------|---------|
| `f1 01` | Start measurement — the cuff inflates and streams `0x2a35` records |
| `f1 02` | Cancel measurement — stops inflating, releases pressure |

No reply comes back on the control characteristic; the response to a start is
the stream of measurement records.

### Blood Pressure Measurement record (`0x2a35`)

The standard SIG layout, little-endian, no vendor quirk:

| Offset | Length | Field |
|--------|--------|-------|
| 0 | 1 | Flags: bit0 unit (0 mmHg, 1 kPa); bit1 timestamp; bit2 pulse; bit3 user ID; bit4 measurement status; bits 5–7 reserved |
| 1 | 2 | Systolic, SFLOAT |
| 3 | 2 | Diastolic, SFLOAT |
| 5 | 2 | Mean arterial pressure, SFLOAT |
| 7 | 7 | Timestamp (year uint16 LE, month, day, hour, minute, second) — if bit1 |
| … | 2 | Pulse rate, SFLOAT, bpm — if bit2 |
| … | 1 | User ID (255 = unknown) — if bit3 |
| … | 2 | Measurement status, uint16 LE: bit0 body movement, bit1 cuff loose, bit2 irregular pulse, bits 3–4 pulse range, bit5 position — if bit4 |

**SFLOAT**: low 12 bits two's-complement mantissa, high 4 bits two's-complement
exponent, value = mantissa × 10^exponent. Mantissas `0x07ff` (NaN), `0x0800`
(NRes), `0x07fe` (+INF), `0x0802` (−INF) and `0x0801` (reserved) carry no
value. kPa × 7.500617 = mmHg.

Records arrive **while the cuff inflates and deflates**. A record is a result
only when systolic and diastolic both decode finite and above zero with
systolic greater than diastolic; both clients debounce 1.5 s after the last
notification and keep that record. Worked example:
`04 78 00 50 00 5f 00 48 00` = mmHg, pulse present: 120 / 80, MAP 95, pulse 72.

Which optional fields the cuff actually sets has not been published, which is
why pulse is documented but not bound as an entity. One captured record would
settle it.

`scripts/test_qardio_arm_spec.py` transcribes the SFLOAT rule and the record
walk from the standard library and holds the spec's worked examples to them.

### Firmware update

The vendor Android app bundles a Nordic legacy DFU client, but nothing ties it
to the cuff rather than the QardioBase scale or QardioCore patch the same app
served, and neither open client finds a DFU service on the cuff. The spec
declares a `firmware_update` feature at `verification: hypothesis` with no
entry command, so a GATT explorer knows to leave
`00001530-1212-efde-1523-785feabcd123` alone if it ever appears. No new image
will ever ship.

See `device-specs/devices/qardio-arm.yaml` for the full machine-readable spec.

## References

- [ptylr/LibreArm (iOS, MIT)](https://github.com/ptylr/LibreArm)
- [agreenbhm/LibreArm_Android (MIT)](https://github.com/agreenbhm/LibreArm_Android)
- [LibreArm: breathing new life into QardioArm devices (2025-09-28)](https://ptylr.com/posts/2025-09-28-librearm-breathing-new-life-into-qardioarm-devices)
- [QardioArm user manual v2.4 (PDF, MedM mirror)](https://www.medm.com/assets/files/sensors/manuals/qardioarm.pdf)
- [What happened to Qardio? (technodabbler.com, 2026-05-19)](https://www.technodabbler.com/what-happened-to-qardio-when-connected-health-devices-stop-working/)
- [Apple Support Community: Qardio servers down](https://discussions.apple.com/thread/256006237)
- [Bluetooth SIG Blood Pressure Service 1.1.1](https://www.bluetooth.com/specifications/specs/blood-pressure-service-1-1-1/)
- [FDA 510(k) K140067 — QardioArm A100](https://fda.innolitics.com/device/K140067)
