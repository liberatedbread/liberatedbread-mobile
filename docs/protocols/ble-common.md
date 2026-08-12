# Common BLE Patterns

## Setup: usually none

Most BLE devices need no provisioning at all — they advertise the moment they
have power and accept a connection from any central in range. That is a
genuine advantage over WiFi hardware and worth stating explicitly in a device
spec (`setup.required: false`) rather than leaving blank.

The exception is BLE used as the *provisioning channel* for a WiFi device
(Vector, Chef iQ Sense). Both cases, plus pairing/bonding pitfalls and the
one-central-at-a-time problem, are covered in
[Initial Device Setup](device-setup.md).

The failure that looks like a protocol bug but is not: a device that refuses to
connect is usually already connected to something else — a phone with the
vendor app open in the background, or an OS-cached bond quietly reconnecting.
Close the other client or power-cycle the device before debugging further.

## Standard GATT Services

| UUID | Service | Purpose |
|------|---------|---------|
| `0x1800` | Generic Access | Device name, appearance |
| `0x180A` | Device Information | Manufacturer, model, firmware |
| `0x180F` | Battery Service | Battery level |

## Common Custom Service Patterns

### Single-Service Command Interface

Many IoT devices use one write characteristic and one notify characteristic.

### Command Structure

Common packet format:
```
[Header] [Command ID] [Payload Length] [Payload...] [Checksum]
```

Common checksums: XOR of all bytes, sum mod 256, CRC-8.

## Authentication Patterns

- **No auth**: Just connect and write (common in cheap devices)
- **Simple PIN**: Write PIN to auth characteristic first
- **Challenge-response**: Read challenge, compute response with shared key
- **First-writer claim**: Reads work for anyone, but writes are rejected until
  a client has claimed the device by writing a key characteristic (the Ember
  Mug's UDSK). Easily mistaken for a broken write path.

These are per-connection handshakes, not onboarding. In a device spec they
belong in `initialization`, not `setup`.
