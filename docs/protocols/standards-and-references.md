# Standards Worth Citing

Most specs here document a protocol that some vendor made up. But not all of it
is bespoke. Every BLE device reuses a layer of published, stable standards —
UUID assignments, standard characteristic formats, advertisement structure — and
a surprising amount of the "custom" part (checksums, framing, data encoding) is a
named standard wearing a local disguise.

Citing those standards instead of re-deriving them has three payoffs:

1. **Less to get wrong.** A standard characteristic already has an authoritative
   decode. Re-typing "battery is a byte, 0–100" per spec invites the day someone
   types 0–255 instead.
2. **The reader can go to the source.** "CRC-16/MODBUS" is reproducible from a
   catalogue; "crc16" is one of about twenty different functions.
3. **Consumers can share code.** A UUID a consumer already knows how to decode is
   a UUID it does not need per-device handling for.

This page lists the standards this registry does — or should — lean on, and how to
cite each one in a spec.

## Bluetooth SIG assigned numbers

The Bluetooth SIG maintains the registry of 16-bit UUIDs (services,
characteristics, descriptors), Company Identifiers, GAP Appearance values and
Service Data types. Any UUID of the form `0000xxxx-0000-1000-8000-00805f9b34fb`
is a **SIG-assigned 16-bit UUID** `xxxx` expanded against the Bluetooth Base
UUID — it is not custom, and its meaning is published.

| Resource | What it is | Use it for |
|----------|-----------|-----------|
| [Assigned Numbers](https://www.bluetooth.com/specifications/assigned-numbers/) | The canonical registry (16-bit UUIDs, Company IDs, Appearance, AD types) | Resolving a short UUID to a name; identifying a manufacturer from `company_id` |
| [GATT Specification Supplement (GSS)](https://www.bluetooth.com/specifications/gss/) | Field-level format of every standard characteristic | Decoding a standard characteristic **exactly**, instead of guessing |
| [Nordic `bluetooth-numbers-database`](https://github.com/NordicSemiconductor/bluetooth-numbers-database) | An open JSON mirror of the SIG numbers | Vendoring UUID→name resolution into a consumer or CI, offline, without re-typing tables |

### The Base UUID shorthand rule

A 16-bit UUID `XXXX` is shorthand for:

```
0000XXXX-0000-1000-8000-00805F9B34FB
```

The registry stores full 128-bit UUIDs (the `uuid` pattern in `schema.json`
requires them), which is unambiguous and correct. But be precise about what the
suffix proves: `-0000-1000-8000-00805f9b34fb` marks a UUID as a **16-bit short
value**, *not* as a **SIG-assigned** one. Vendors squat on short UUIDs of exactly
this shape — CoolLEDX's custom `0xFFF0`/`0xFFF1` service and characteristic
(`coolledx-led-sign.yaml`) are indistinguishable from a standard service by suffix
alone. `0000180f-…-34fb` is known to be the standard Battery Service only because
`180F` is listed in
[Assigned Numbers](https://www.bluetooth.com/specifications/assigned-numbers/), not
because of its shape. **Always confirm `xxxx` in the registry before treating a
service or characteristic as standard.**

### Standard characteristics already in use here

These appear across the registry, currently re-described in prose per spec. Their
decode is fixed by the GSS — a spec does not need to invent it:

| UUID | Characteristic | GSS decode |
|------|---------------|-----------|
| `0x2A19` | Battery Level | `uint8`, 0–100, percent |
| `0x2A6E` | Temperature | `sint16`, unit 0.01 °C (value ×0.01) |
| `0x2A6F` | Humidity | `uint16`, unit 0.01 % |
| `0x2A29` | Manufacturer Name String | UTF-8 string |
| `0x2A24` | Model Number String | UTF-8 string |
| `0x2A26` | Firmware Revision String | UTF-8 string |

Standard services seen here: `0x1800` Generic Access, `0x180A` Device
Information, `0x180F` Battery, `0x181A` Environmental Sensing.

> **Convention.** When a service or characteristic is SIG-standard, say so and
> point at the GSS rather than restating the byte layout. A future schema field
> (`standard: true`) is proposed in
> [Spec Evolution Proposals](../contributing/spec-evolution.md#p2) to make this
> machine-readable; until then, a `notes` line naming the standard is enough.

## Advertisement structure and passive beacons

Many sensors here (Govee, Xiaomi/ATC, SwitchBot) never need a GATT connection —
they broadcast their state in the advertisement, to be read passively. Two
standards govern that data:

- **GAP advertising data types** — the AD structure format (Flags, Local Name,
  Service Data, Manufacturer Specific Data) defined in the
  [Core Specification Supplement (CSS), Part A](https://www.bluetooth.com/specifications/assigned-numbers/).
  Discovery matching on `manufacturer_data.company_id` and service-data UUIDs is
  reading these structures.
- **[BTHome v2](https://bthome.io/)** — an **open** advertisement payload format
  for sensor data, carried in service data under BTHome's own SIG-allocated UUID
  `0xFCD2` (not to be confused with a device's custom service data — the pvvx ATC
  firmware for the Xiaomi LYWSD03MMC can emit BTHome on `0xFCD2` *or* its own ATC
  format on `0x181A`). Consumed natively by Home Assistant. When a device speaks
  BTHome, a spec can name the format and the `0xFCD2` UUID and skip re-documenting
  the byte layout entirely.

Passive-beacon devices are currently modelled with a workaround (a `format`-less
characteristic plus a `notes` disclaimer). A first-class `advertisement` block is
proposed in [P6](../contributing/spec-evolution.md#p6).

## Checksums and framing

"XOR of the bytes", "sum mod 256" and "CRC-16" are the three most common integrity
schemes in this registry, and the third is a trap. **There is no single CRC-16.**
The width alone does not determine the function — polynomial, initial value, input
and output reflection, and final XOR all vary, and a mismatch on any one produces
a checksum that looks plausible and is rejected by the device.

Cite the parameters, not just the width:

| Resource | What it is |
|----------|-----------|
| [CRC RevEng catalogue](https://reveng.sourceforge.io/crc-catalogue/all.htm) (Greg Cook) | Named catalogue of CRCs with full parameters `{width, poly, init, refin, refout, xorout, check}` |
| [A Painless Guide to CRC Error Detection Algorithms](http://www.ross.net/crc/download/crc_v3.txt) (Ross Williams) | The reference explaining what those parameters mean |

A checksum is reproducible from the file only if the spec pins:

- **which bytes** are covered (and whether it differs by direction — the Bafang
  BBS02 sums differently on read vs write, which is the classic cause of a
  rejected write), and
- for a CRC, the **full parameter set** or a catalogue name (`CRC-16/MODBUS`,
  `CRC-8/MAXIM`, `CRC-32/ISO-HDLC`), plus a **known-good check value** so an
  implementer can verify before touching hardware.

A richer `checksum` descriptor carrying these is proposed in
[P1](../contributing/spec-evolution.md#p1).

## Automotive and bus standards

The OBD-II and `bus` specs already cite the right standards; they are collected
here for completeness. See [Common OBD-II Patterns](obd2-common.md) for the worked
detail.

| Standard | Covers |
|----------|--------|
| SAE J1979 | Legislated OBD-II PIDs (the `basic` command class) |
| ISO 14229 (UDS) | Diagnostic services `22`, `27`, `31`, `2E`… (the `advanced` class) |
| ISO 15765-2 (ISO-TP) | Multi-frame segmentation over CAN |
| ISO 11898 | Raw CAN physical/data-link layer (the `bus` CAN devices) |
| SAE J1939 | Higher-layer CAN used by some larger vehicles; worth naming where a bus uses it |
| SAE J1962 / ISO 19689 | The 16-pin car and 6-pin Euro-5 motorcycle diagnostic connectors |

## Data modelling and interchange

| Standard | Where it applies |
|----------|-----------------|
| [JSON Schema 2020-12](https://json-schema.org/) | The dialect `schema.json` is written in — keep citing it |
| [SemVer 2.0.0](https://semver.org/) | Proposed for versioning the spec schema itself ([P9](../contributing/spec-evolution.md#p9)) |
| [Home Assistant entity model](https://developers.home-assistant.io/docs/core/entity/) | The de-facto contract the `entities` block targets; naming it makes the mapping reviewable |
| [Protocol Buffers](https://protobuf.dev/) | The AdMore Light Bar's `setvalue` fields are protobuf; cite the wire format rather than paraphrasing it |
| [CBOR (RFC 8949)](https://www.rfc-editor.org/rfc/rfc8949) | For any device using CBOR-framed payloads |

## The general rule

If a piece of a protocol has a name in a published standard, **name it and link
it**. Reserve the registry's own words for the part the vendor actually invented —
that is the part nobody else has written down, and the reason this project exists.
