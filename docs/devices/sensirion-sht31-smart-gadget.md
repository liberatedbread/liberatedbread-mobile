# Sensirion SHT31 Smart Gadget (Smart Humigadget)

> **Status**: Research; official legacy source documented, hardware-untested
> **Protocol**: BLE GATT live values and local history
> **Manufacturer**: Sensirion AG
> **Manufacturer Status**: Abandoned legacy design

## Overview

The SHT31 Smart Gadget Reference Design advertises the exact name **Smart
Humigadget**. It measures temperature and relative humidity, stores history
on the board, and exposes both directly over BLE without a cloud account.
The official Smart Gadget Android app is deprecated; its source and the legacy
firmware preserve the protocol.

This is a **different protocol generation** from
[Sensirion's newer BLE gadgets](sensirion-ble-gadgets.md):

- no company-`0x06D5` passive `00 04` decoding is claimed for this board;
- live values are four-byte floats, not 16-bit ticks;
- its logger is `0000f234-…`, not `00008000-…`.

Sensirion's current cross-family protocol explicitly excludes Smart
Humigadget from the newer logger. That page's humidity row says uint8, but
the official legacy firmware writes a four-byte float. The pinned legacy
firmware is the authority for this spec.

## Setup, pairing, reset, and moving phones

Bluetooth needs no credential provisioning, but the radio can be off:

1. With the board powered, hold its switch button for **more than one second**.
2. The Bluetooth symbol blinks and a device ID appears briefly. Scan for the
   exact name `Smart Humigadget` and connect.
3. A steady Bluetooth symbol indicates a connection. Subscribe to both
   measurement characteristics for live values.

The guide uses “pair” in the ordinary connect-to-a-phone sense. The official
firmware defines no PIN or persistent bonding workflow and exposes
unencrypted GATT operations, so this spec reports **no link-layer pairing and
no bond**, with medium source confidence rather than a hardware security
claim. Disconnect the previous central before trying another phone; the exact
maximum central count remains unknown.

There is no established full factory-reset or bond-clearing procedure. The
long button press toggles Bluetooth, not a factory reset. Changing the logger
interval erases history, but is not a reset either. No reset procedure is
invented here. Moving phones needs no Wi-Fi rejoin or factory reset; reconnect
and, before changing intervals, download any history worth keeping.

## Live measurement services

| Quantity | Service | Characteristic | Live encoding |
|---|---|---|---|
| Relative humidity | `00001234-b38d-4985-720e-0f993a68ee41` | `00001235-b38d-4985-720e-0f993a68ee41` | 4-byte float32 LE, percent RH |
| Temperature | `00002234-b38d-4985-720e-0f993a68ee41` | `00002235-b38d-4985-720e-0f993a68ee41` | 4-byte float32 LE, degrees C |

Read and notify are supported. For example, `00 00 36 42` is binary32 45.5,
so it means 45.5% RH on the humidity characteristic. Do not apply the newer
family's integer-tick formulas.

**Length is part of the protocol.** During history download, those same two
characteristics also carry history. Only an exact four-byte packet is a live
measurement.

## Legacy logger (`0000f234-b38d-4985-720e-0f993a68ee41`)

| Characteristic | UUID suffix | Width and role |
|---|---|---|
| Synchronize Time | `0000f235-b38d-4985-720e-0f993a68ee41` | Write 8-byte uint64-le Unix epoch **milliseconds** |
| Oldest Sample Time | `0000f236-b38d-4985-720e-0f993a68ee41` | Read/write 8-byte uint64-le epoch ms; optional range start |
| Newest Sample Time | `0000f237-b38d-4985-720e-0f993a68ee41` | Read/write 8-byte uint64-le epoch ms; range end and timestamp anchor |
| Start Download / Completion | `0000f238-b38d-4985-720e-0f993a68ee41` | Write nonzero byte to start; zero-valued notification on completion |
| Logger Interval | `0000f239-b38d-4985-720e-0f993a68ee41` | Read/write uint32-le milliseconds; default 600000 ms |

The time values are **not seconds**, **not uint32**, and **not history
sequence numbers**. For example, the invented timestamp 1700000123456 ms is
encoded as `40 4a e7 cf 8b 01 00 00`. The interval 600000 ms is
`c0 27 09 00`.

### Download flow

1. Read `…f239` for the interval in milliseconds.
2. Write current Unix epoch milliseconds to `…f235` as uint64 LE. The device
   computes the available range and initial download selection.
3. Read `…f236` and `…f237`. Optionally write one or both to narrow the next
   transfer. Firmware clamps out-of-range values; the oldest boundary is
   rounded upward and the newest downward to the logging grid. These writes
   change selection, not stored samples.
4. Subscribe to humidity `…1235`, temperature `…2235`, and completion `…f238`.
5. Write `01` to `…f238` (any nonzero byte triggers). A repeated start while
   active has no extra effect.
6. Receive independent humidity and temperature history streams on their
   measurement characteristics. Four-byte live values can still interleave at
   reduced cadence.
7. Finish when `…f238` sends a zero-valued notification. Disconnecting cancels
   an active download. Do not change synchronization or interval mid-transfer.

### Live versus history packet lengths

| Packet length | Meaning |
|---:|---|
| 4 bytes | One live float32 measurement |
| 8 bytes | uint32-le sequence + 1 float32 historical value |
| 12 bytes | uint32-le sequence + 2 float32 historical values |
| 16 bytes | uint32-le sequence + 3 float32 historical values |
| 20 bytes | uint32-le sequence + 4 float32 historical values |

Reject other lengths. The sequence is one-based and identifies the first
value in that packet's download order. Humidity and temperature maintain
**independent** sequences, each starting at 1. Values are sent
**newest-to-oldest**, both within a packet and across packets.

History packets carry no absolute timestamp. For zero-based value slot `j`
inside a packet:

```text
sample_epoch_ms = selected_newest_epoch_ms
                  - (sequence - 1 + j) * logger_interval_ms
```

`selected_newest_epoch_ms` is the read-back `…f237` value after sync and any
range narrowing. The invented spec vector uses newest 1700000123456 ms,
sequence 3, slot 1, and interval 600000 ms, yielding 1699998323456 ms.
Absolute alignment still needs comparison with a physical download.

For example, this invented humidity history packet is 12 bytes, sequence 7,
and values 50.0% then 49.5%:

```text
07 00 00 00  00 00 48 42  00 00 46 42
```

Do not parse its sequence prefix as a live float.

### Interval writes are destructive and advanced

`…f239` accepts uint32-le milliseconds. Every write:

- rounds the requested value down to a whole-second multiple;
- substitutes 1000 ms when the rounded result is zero (including 1–999 ms);
- **erases every stored humidity and temperature value**;
- resets the internal time and synchronization counters.

Download wanted history first, then change the interval, read back the
accepted value, and synchronize again before the next download. This command
is marked `advanced` in the spec. There is no separate history-clear command
to simulate with other writes.

## Firmware updates and remaining gaps

No OTA/DFU interface, image format, entry command, or recovery path is
asserted. The legacy sources reviewed here do not justify a generic Nordic
DFU claim.

No hardware connection, notification, history download, interval write, or
reset was performed. Packet lengths, byte order, timestamp arithmetic, and
side effects are **reported** from official legacy firmware/profile/app
sources; the tests use invented fixtures. Physical timestamp alignment,
central-count behavior, invalid-float handling, power-cycle persistence,
completion timing, and full reset behavior remain open.

## References

- [SHT31 Smart Gadget User Guide](https://sensirion.com/media/documents/429F0DF6/61643DC1/Sensirion_Humidity_Sensors_SHT3x_Smart-Gadget_User-Guide_1.pdf) — button, display, local logging, and historical app use.
- [Legacy Smart Gadget Profile](https://github.com/Sensirion/SmartGadget-Firmware/blob/0fca4bb74585b576a5d25e05ef89a22b69b701a8/Simple_BLE_Profile_Description.pdf) — official UUID map.
- [Official legacy firmware](https://github.com/Sensirion/SmartGadget-Firmware/tree/0fca4bb74585b576a5d25e05ef89a22b69b701a8) — float32 values, history packets, ordering, timestamps, and interval side effects.
- [Official legacy Android app](https://github.com/Sensirion/SmartGadget-Android/tree/f1bfb86baf6154be4bd94258aab7f7bf6accb6d4) — deprecated local client source.
- [Current Sensirion BLE Services](https://sensirion.github.io/ble-services/) — newer-family comparison and explicit legacy logger exclusion.
