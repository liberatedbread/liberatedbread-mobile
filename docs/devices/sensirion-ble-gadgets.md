# Sensirion SHT3x / SHT4x / MyCO2 BLE Gadgets

> **Status**: Research; source-documented, hardware-untested
> **Protocol**: BLE passive advertisements plus generation-specific GATT history
> **Manufacturer**: Sensirion AG
> **Manufacturer Status**: Active

## Overview and scope

This page covers the **newer** environmental gadget protocol used by:

- SHT3x-based gadgets emitting advertisement `00 04`;
- SHT40 Gadget and SHT43 DemoBoard / SHT43-DB emitting `00 06`;
- SCD4x CO2 Gadget, also called MyCO2 Gadget or CO2 Minion, emitting `00 08`.

It does **not** cover the legacy SHT31 Smart Gadget / **Smart Humigadget**.
That board uses float32 GATT values and the `f234` logger; see
[Sensirion SHT31 Smart Gadget](sensirion-sht31-smart-gadget.md). Do not apply
this page's tick conversions or `00008000-…` logger to that board.

Current readings are local and passive: no account, Wi-Fi, cloud, connection,
or pairing is needed. Sensirion's current protocol also says that a gadget
**stops advertising while one GATT client is connected** and is consequently
invisible to other clients. Passive readers must tolerate that gap and resume
after disconnect rather than substitute zero or stale measurements.

## Setup, pairing, reset, and moving phones

Passive reception has no setup or pairing step. Scan for Bluetooth company ID
`0x06D5`, check the two type bytes, and validate the payload length.

There is no honest family-wide answer for GATT bonding yet. Product- and
firmware-specific pairing behavior was not exercised, so the spec leaves it
`unknown`; it does not generalize the passive answer to settings, history, or
update surfaces. One connected central at a time is documented. If a scan
cannot find the gadget, disconnect another app that holds its GATT link.

No family-wide factory reset or unpair procedure is established. Changing a
writable logging interval **erases history**, but is a destructive settings
write, not a factory reset. Moving a passive reader to a new phone needs only
a new scan; no network credentials or factory reset are involved.

## Passive advertisement protocol

Match AD type `0xff` manufacturer data with company ID `0x06D5` (decimal
1749). Offsets below start **after** the two-byte company ID, as exposed by
common BLE scanner APIs. All measurement integers are unsigned 16-bit
little-endian.

| Offset | Type `00 04` | Type `00 06` | Type `00 08` |
|---:|---|---|---|
| 0 | Advertisement type `00` | Advertisement type `00` | Advertisement type `00` |
| 1 | Sample type `04` | Sample type `06` | Sample type `08` |
| 2–3 | Opaque device ID | Opaque device ID | Opaque device ID |
| 4–5 | Temperature ticks | Temperature ticks | Temperature ticks |
| 6–7 | Humidity ticks | Humidity ticks | Humidity ticks |
| 8–9 | — | — | CO2, direct ppm |
| 10–11 | — | — | Reserved, ignored when present |

Types `04` and `06` are exactly **8 bytes**. Type `08` accepts **10 or 12
bytes**: the 2022 PDF shows the reserved word, while the current definition
permits omitting it and says receivers ignore it. Reject truncation and
unexpected extra bytes rather than decoding a partial sample.

The two device-ID bytes are **opaque**. Preserve them as four hexadecimal
digits; do not byte-swap them into a model number or use them as a stable
identity. Exact local names and model mappings still need physical captures.

### Exact conversions

Use the full tick range denominator `2^16 - 1 = 65535`, not 65536:

```text
all types:       temperature_C = -45 + 175 * temperature_ticks / 65535
types 04 / 08:   humidity_%    = 100 * humidity_ticks / 65535
type 06:         humidity_%    = -6 + 125 * humidity_ticks / 65535
type 08:         co2_ppm       = transmitted_uint16_le
```

Do not clamp or round as part of decoding. Display precision and physical
validity are separate choices. Type `06` deliberately differs from the SHT3x
humidity transfer function.

The spec carries exact rational expected values for these **invented**
vectors; they identify no real unit:

| Type | Payload after company ID | Expected result |
|---|---|---|
| `00 04` | `00 04 a5 5a 34 12 cd ab` | ID `a55a`; T `-426715/13107` C (about −32.5563); RH `879620/13107`% (about 67.1107) |
| `00 06` | `00 06 5a a5 ef be 57 13` | ID `5aa5`; T `373650/4369` C (about 85.5230); RH `45133/13107`% (about 3.4434) |
| `00 08` | `00 08 10 32 00 60 55 55 f4 01 00 00` | ID `1032`; T `90115/4369` C (about 20.6260); RH `100/3`%; CO2 500 ppm |

`scripts/test_sensirion_gadgets.py` independently transcribes the layouts and
uses `fractions.Fraction` so the checks do not bake in floating-point rounding.

## Newer data logger (`00008000-…`)

Only offer this service when the connected newer gadget actually exposes it.
The current public application note explicitly excludes Smart Humigadget even
though individual logger rows use broad “all devices” wording.

| Characteristic | UUID suffix | Common purpose |
|---|---|---|
| Logging interval | `00008001-b38d-4985-720e-0f993a68ee41` | uint32 LE milliseconds |
| Available samples | `00008002-b38d-4985-720e-0f993a68ee41` | uint16 LE count |
| Requested samples | `00008003-b38d-4985-720e-0f993a68ee41` | Optional partial-download count |
| Data transfer | `00008004-b38d-4985-720e-0f993a68ee41` | 20-byte header and sample frames |

A full download needs **no requested-count write**: subscribe to `…8004`,
then accept a header followed by samples. When a supported requested count is
smaller than the available count, older samples are omitted; zero/unset means
all available samples.

### Current versus 2022 PDF behavior

These differences are real interoperability boundaries, not details to hide:

- **Interval:** the PDF lists read-only; current definitions and the official
  Arduino implementation allow writes. Current writes erase logged samples,
  so the spec marks the command **advanced**.
- **Requested count:** the PDF lists write-only uint16; the current web table
  says read/write uint16; the current Arduino handler consumes **four**
  little-endian bytes. There is deliberately **no universal requested-count
  command** in the spec. Use the all-samples path until the generation is
  known, and do not rely on read-back everywhere.
- **Transfer UUID and delivery:** the PDF and Arduino source use `…8004`.
  The current web table accidentally repeats `…8003` for Data Transfer. The
  PDF says notifications; the current Arduino implementation sends
  indications. Select the mode exposed by the discovered generation:
  notifications use CCCD `01 00`, while current-Arduino indications use `02 00`.
  The duplicate `…8003` is not an alias.
- **MyCO2:** type `00 08` is now deprecated in favor of type 10, and its
  reserved advertisement word may be omitted. Logger type 7 retains a
  reserved word; current logger type 9 has no reserved word. The PDF's type-9
  diagram misprints type `0x0002`; current official definitions confirm
  `0x0009`.

### Current Arduino transfer framing

The following offsets are scoped to official Arduino library 1.5.0 at the
pinned source commit, not asserted for every PDF-generation product.

The first 20-byte frame is a header:

| Offset | Type | Meaning |
|---:|---|---|
| 0–3 | Reserved | Zero-initialized by the implementation |
| 4–5 | uint16 LE | Download sample type: 0 SHT3x, 5 SHT4x, 7 legacy MyCO2, 9 current MyCO2 |
| 6–9 | uint32 LE | Interval in milliseconds |
| 10–13 | uint32 LE | Age of latest sample in milliseconds |
| 14–15 | uint16 LE | Number of samples in this transfer |
| 16–19 | Reserved | Zero-initialized by the implementation |

Each later 20-byte frame starts with an int16-le sequence number at offset 0,
starting at 1, followed by sample bytes at offset 2 and zero padding. Samples
are sent **oldest-to-newest** within the selected range:

```text
latest_epoch_ms ≈ header_received_epoch_ms - age_of_latest_sample_ms
sample_epoch_ms[i] = latest_epoch_ms - (N - 1 - i) * interval_ms
```

Here `i` is zero-based and `N` is the header's sample count. Host reception
time necessarily omits radio latency.

Sample widths are 4 bytes for SHT3x/SHT4x, 8 bytes for deprecated MyCO2 type
7 (including its reserved word), and 6 bytes for current MyCO2 type 9. Tick
conversions match the corresponding passive formulas.

## Firmware updates and remaining gaps

No DFU capability or update command is declared. Product-specific reboot/OTA
strings and services are not a family-wide update protocol, and none was
exercised. Calibration, settings/Wi-Fi services, other sample types, exact
retail names, per-product pairing/reset behavior, and shipping-unit logger
widths remain open.

No hardware scan, logger download, pairing, reset, or OTA operation was run.
All byte-level behavior is **reported** from official documentation/source;
the new tests validate invented fixtures only.

## References

- [Sensirion BLE Services](https://sensirion.github.io/ble-services/) — current protocol and advertising-connection behavior.
- [Pinned current protocol definitions](https://github.com/Sensirion/ble-services/tree/423a74c7adb593e7880387a6f0f782734363c19c/sensirion-ble/src/resources) — official YAML sample/service tables.
- [August 2022 BLE Communication Protocol 1.0.1](https://github.com/akx/sensirion-ble/blob/0c2c04b2c64690c7045c07e2a2dc8253ca1cb4be/reference/Sensirion_BLE_communication_protocol.pdf) — preserved official PDF.
- [Official Arduino BLE Gadget implementation](https://github.com/Sensirion/arduino-ble-gadget/tree/9c1660405aee63024f8decf38c8f9d4447e41f91) — pinned 1.5.0 source.
- [Independent passive parser](https://github.com/akx/sensirion-ble/tree/0c2c04b2c64690c7045c07e2a2dc8253ca1cb4be) — cross-check only, not hardware verification.
