# Ecosense / FTLab RadonEye RD200

> **Status**: Spec Available (source-derived; untested on hardware here)
> **Protocol**: BLE GATT, two incompatible generations
> **Manufacturer**: FTLab Co., Ltd. / Ecosense
> **Manufacturer Status**: Active

## Overview

The RadonEye RD200 is a mains-powered environmental radon monitor that works
directly with a phone over BLE. The vendor says it has no cloud/server service.
Two public clients establish two distinct protocol generations: older units
return little-endian float32 pCi/L values, while newer units return little-endian
uint16 Bq/m³ values with different framing.

This document covers **RD200 only**, not RadonEye Pro, RadonEye Plus, EcoQube or
EcoQube Flex. The newer Ecosense app for EcoQube Flex is not an RD200 protocol
client. No physical device or owner reading was used for this spec.

!!! warning "Environmental measurements"
    A numeric BLE value is not by itself a medical or radiation-safety
    determination. Device vibration/status can affect validity, and not all
    status values are decoded. Preserve malformed and unavailable values as
    unknown, follow the actual unit's manual and current local guidance, and do
    not use one reading as a sole safety interlock.

## Hardware and generation identification

| Property | Value |
|----------|-------|
| Model | RD200 |
| Radio | Bluetooth LE |
| Power | External 12 V supply in the reviewed manuals; no battery telemetry is established |
| Evidence | Public clients and manuals; no capture by this project |

Select a generation using **both** the advertised name and discovered GATT
shape. Never send a command merely to discover which generation is present.

| Generation | Name evidence | GATT evidence |
|---|---|---|
| V1 / older | `FR:R2*` | Custom service `00001523-1212-efde-1523-785feabcd123` |
| V2 / newer | `FR:RU*`, `FR:RE*`, `FR:GI*`, `FR:H*`, `FR:RD*`, `FR:GL*`, `FR:GJ*`, `FR:I*`, `FR:J*`, `FR:K*` | Write `00001524-0000-1000-8000-00805f9b34fb`; notify `00001525-0000-1000-8000-00805f9b34fb` |

The V2 parent service UUID is not established. Do not invent it from V1 or
treat every unknown `FR:` prefix as V2. A reported controller change around
November 2021 is not a universal manufacturing cutoff.

## Initial Setup

| Property | Value |
|----------|-------|
| Setup required | No account, Wi-Fi provisioning or application key |
| Method | `ble_direct`: identify generation, subscribe, then query |
| Passphrase protection | not_applicable |
| Confidence | medium — three working clients (rd200v2, radonpy, ESPHome) connect without pairing; OS bonding behaviour unrecorded |

Only one phone can connect at a time. Close the vendor app or previous client
before connecting. Neither public client implements an application PIN/key
exchange, but that does not prove every OS and firmware combination avoids
bonding; no fixed pairing code is documented.

**Factory reset**: no full factory reset or dedicated hardware reset button is
documented. The app data reset and V1 command `0xE0` erase stored measurements;
that is not a harmless reconnect operation and does not establish a full
settings/calibration reset.

**Rebinding**: close the previous client and reconnect directly. There is no
Wi-Fi network membership to migrate.

## V1 protocol

### GATT map

| UUID | Role |
|---|---|
| `00001523-1212-efde-1523-785feabcd123` | Custom service |
| `00001524-1212-efde-1523-785feabcd123` | Control writes |
| `00001525-1212-efde-1523-785feabcd123` | Normal command responses / measurement notifications |
| `00001526-1212-efde-1523-785feabcd123` | Separate history stream |

A simple query is one command byte. A parameterized write and a normal response
use:

```text
[command][payload_length][payload]
```

Subscribe to the response characteristic before writing a query. Check the
response command and complete declared payload before decoding. History uses
its own characteristic and does not follow the normal response path.

### Measurement response `0x50`

A complete response has a 16-byte payload (18 bytes including its two-byte
header). The payload structure is `<fffHH`:

| Payload offset | Type | Meaning |
|---:|---|---|
| 0–3 | float32 LE | Current concentration, pCi/L |
| 4–7 | float32 LE | One-day average, pCi/L |
| 8–11 | float32 LE | One-month average, pCi/L |
| 12–13 | uint16 LE | Pulse count |
| 14–15 | uint16 LE | Previous/10-minute pulse count |

Require all 16 payload bytes; one public client's shorter length guard is a
bug. NaN/infinity/sentinel policy is not established, so non-finite values must
not become numeric readings.

Constructed vector:

```text
50 10 00 00 20 40 00 00 60 40 00 00 90 40 32 00 3c 00
```

This decodes to current 2.5 pCi/L, daily 3.5, monthly 4.5, pulse count 50 and
previous count 60. It is a protocol vector, not a person's environmental data.

### Status response `0x51`

The 14-byte payload is `<BBIIf`: device status, vibration status, uint32 process
time (interpreted as uptime minutes by the other client), uint32 raw DC value,
and float32 peak pCi/L. Status enumerations and the DC conversion are unknown;
do not invent them.

### Other V1 commands

| Command | Operation |
|---:|---|
| `0xA1` | Clock write: six bytes for two-digit year, month, day, hour, minute, second; persistent calendar semantics unresolved |
| `0xA2` | Unit write: one byte, 0 pCi/L or 1 Bq/m³ |
| `0xA4` | Serial query; response includes owner-specific data and must be redacted |
| `0xA6` | Serial-type query; first three response-payload bytes are text |
| `0xA8` | Model-name query; first payload byte unknown, remaining bytes text |
| `0xAA` | Alarm write: `<BfB` = enabled/status, float32 threshold, interval (1 = 10 minutes, 6 = one hour, `0x24` = six hours); check units/limits first |
| `0xAC` | Configuration query: `<BBfB` = unit, alarm status, threshold, interval |
| `0xAD` | OLED uint32 query; the source says it does not seem to work |
| `0xAF` | Firmware query: 64 text bytes, then optional uint32 status |
| `0xB1` | Module configuration `<BIIf`; exact semantics unresolved |
| `0xB4` | Protection query; response command is `0xB3`, with two uint32 status fields |
| `0xBD` | Display calibration float32; not a generic concentration multiplier |
| `0xC1` | Product/process-mode `<BBH`; semantics unresolved |
| `0xE0` | **Erase long-term measurements** — advanced, destructive, no documented undelete |
| `0xE8` | History information query |
| `0xE9` | Start history transfer |

Parameterized writes include their payload length: `a1 06 <six clock bytes>`,
`a2 01 <unit>`, and `aa 06 <enabled><float32 threshold><interval>`.
Download and preserve history before `0xE0`.

### V1 history

1. Send `0xE8`. The first three response-payload bytes are a uint16 LE entry
   count and a signed byte labeled checksum. The checksum algorithm is unknown;
   do not claim to verify it.
2. Subscribe to the history characteristic and send `0xE9` to control.
3. Concatenate arbitrary notification chunks until `entry_count × 2` bytes have
   arrived. Reject truncation rather than padding.
4. Decode each entry as uint16 LE divided by 100. Its concentration unit is not
   established, so do not silently label it pCi/L or Bq/m³.

The vendor says data is recorded hourly but has no internal calendar timestamp
for a dated series. Preserve relative ordering and explicitly associate the
host's download time and any user-recorded start time.

## V2 protocol

Write one query byte to `00001524-0000-1000-8000-00805f9b34fb` after enabling
notifications on `00001525-0000-1000-8000-00805f9b34fb`. Wait for the response,
then stop notifications before the next query. Query measurement, identity and
uptime sequentially rather than concurrently.

| Query | Exact response length | Decode |
|---:|---:|---|
| `0x50` measurement | 12 bytes | Bytes 0–1 unknown header; five uint16 LE values at 2–3 current, 4–5 daily, 6–7 monthly, 8–9 pulse count, 10–11 previous count |
| `0x40` peak/identity | 68 bytes | Model text at 16–20, firmware text at 22–29, peak uint16 LE Bq/m³ at 51–52 |
| `0x51` uptime | 16 bytes | Uptime uint32 LE minutes at 4–7; no seconds field is established |

Concentrations in the V2 measurement are native **Bq/m³**, with no extra wire
multiplier. Require the exact length for each response and make its fields
unavailable on a wrong-length reply. Do not copy V1's command/length envelope
or history/configuration commands to V2.

Constructed V2 measurement vector:

```text
00 00 64 00 6e 00 78 00 0d 00 0e 00
```

It carries current 100 Bq/m³, daily 110, monthly 120, pulse count 13 and
previous count 14.

## Units and validation

Use the manuals' exact conversion **1 pCi/L = 37 Bq/m³**. Multiplying Bq/m³ by
0.027 is only a presentation approximation. Preserve native values and round
only when displaying them.

`scripts/test_ecosense_radoneye_rd200_spec.py` independently constructs and
parses both measurement generations, status, exact lengths, malformed/non-finite
inputs, unit conversion, and the advanced history-erase boundary. Passing these
checks does not establish hardware compatibility.

Remaining gaps include the V2 parent service and envelope, V2 history/settings,
V1 status enums and history-entry units, invalid/sentinel handling, firmware
update, and physical verification across hardware/firmware revisions.

See `device-specs/devices/ecosense-radoneye-rd200.yaml` for the complete
machine-readable commands, response formats and evidence limits.

## References

- [jdeath/rd200v2 (MIT)](https://github.com/jdeath/rd200v2), pinned at `ceb604c9809cd33ec61ffa58a60eea522ead816f`
- [lopsided98/radonpy (Apache-2.0)](https://github.com/lopsided98/radonpy), pinned at `17930248331eeebe5572177dd72fca0390b55d61`
- [Ecosense RD200 FAQ](https://ecosense.io/pages/rd200-faq-en)
- [RD200 operation manual (distributor PDF)](https://www.boehm-radon.ch/files/2-45-radon_eye.pdf)
- [RD200 quick guide, December 2021 (distributor PDF)](https://www.radonshop.com/mediafiles/Anleitungen/Radon/FTLab_RadonEye-RD200/FTLab_RadonEye_ManualEN.pdf)
