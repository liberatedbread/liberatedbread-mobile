# Quicklynks BM2 Battery Monitor

> **Status**: Spec Available (source-derived; untested on hardware here)
> **Protocol**: BLE GATT and passive advertisements
> **Manufacturer**: Quicklynks
> **Manufacturer Status**: Active

## Overview

The BM2 / Battery Monitor 2 can report voltage, percentage and status locally
without an account or cloud. Two public clients establish an active FFF4
notification format and two advertisement generations. This project did not
connect to a physical BM2 or validate electrical accuracy.

This spec is **BM2-only**. Do not apply it to BM6 or assume other battery
monitors share its protocol. History, configuration, chemistry selection,
cranking/charging-test history, firmware and alarm writes are outside its
read-only scope.

## Initial Setup and Pairing

No provisioning, account, pairing key or application credential is needed.
Advertised-name leads are `Battery Monitor`, `Li Battery Monitor` and `ZX-1689`;
the active service is `0000fff0-0000-1000-8000-00805f9b34fb`.

No genuine BM2 manual or factory-reset procedure was found. There is no
passive-client state to reset; reconnect or resume scanning to recover a client.

The protocol uses a published shared AES key and zero IV. These are wire-format
constants, **not owner credentials, secure pairing or sender authentication**.

## Active FFF4 telemetry

1. Discover `0000fff4-0000-1000-8000-00805f9b34fb` and subscribe.
2. Wait for a fresh notification without writing FFF3.
3. Require exactly 16 ciphertext bytes and decrypt AES-128-CBC with:

   - Key: `6c656167656e64fffe31383832343636`
   - IV: `00000000000000000000000000000000`

4. Require plaintext type `0xf5`, then decode:

| Offset | Meaning |
|---:|---|
| 0 | Packet type `f5` |
| 1–2 | Big-endian packed word: voltage = `(word >> 4) / 100` V; status = `word & 0x0f` |
| 3 | Battery percentage, 0–100 |
| 4 onward | No additional read-only telemetry established |

Status values are 0 Critical, 1 Low, 2 Normal, 4 Charging and 8 Floating.
Other values are unknown. The reference charging flag is status ≥ 4, but retain
the raw status rather than treating that flag as a complete state model.

Active validation accepts 5.0–20.0 V and 0–100 %. These are **client sanity
bounds, not verified electrical ratings**. Missing FFF4 is incompatible; a
timeout is inconclusive. Always stop notifications and disconnect afterward,
including on failure.

Constructed vector:

```text
Plaintext:  f5 50 82 50 00 00 00 00 00 00 00 00 00 00 00 00
Ciphertext: cd 9d a1 bf c3 eb 13 1c 59 90 df 26 5d 06 4d c4
```

It represents 12.88 V, 80 % and Normal.

## Passive advertisements

### Enhanced

A 14-byte manufacturer body is preceded by its two-byte manufacturer ID in
little-endian order, reconstructing one encrypted 16-byte block. Decrypt it and
read voltage as big-endian uint16 / 100 at bytes 6–7 and percentage at byte 8.
Status is unavailable.

The example in the YAML uses manufacturer ID 43248 and body
`aa0a2e42b2a68aafdd2e23559079`, reconstructing ciphertext
`f0a8aa0a2e42b2a68aafdd2e23559079`. Its plaintext is
`00000000000005085000000000000000`: 12.88 V and 80 %. The manufacturer ID was
derived from the ciphertext's first two bytes, not chosen arbitrarily.

### Legacy

Company ID `0x004c` carries a 23-byte body:

| Offset | Meaning |
|---:|---|
| 0–17 | Fixed prefix `0215655f83caae16a10a702e31f30d58dd82` |
| 18–19 | Major bytes, no established telemetry meaning |
| 20–21 | Minor bytes, no established telemetry meaning |
| 22 | Battery percentage, 0–100 |

Voltage and status are unavailable. Do not invent values from major/minor.
When enhanced data is followed by legacy data, refresh percentage but retain
enhanced voltage/generation and clear status.

## Freshness and limits

Prefer a fresh FFF4 notification. Use the latest valid advertisement only if
active access fails or no connectable path exists. If neither path supplies
valid data, report unavailable rather than a healthy default. Timestamp cached
advertisements and expose staleness; the upstream cache has no demonstrated
expiry.

`scripts/test_quicklynks_bm2_spec.py` independently decrypts the constructed
vectors, checks packed fields and both advertisement generations, and rejects
malformed values. These checks do not prove firmware coverage, electrical
accuracy or safe installation.

See `device-specs/devices/quicklynks-bm2.yaml` for the complete machine-readable
formats and evidence limits.

## References

- [KrystianD/bm2-battery-monitor (MIT)](https://github.com/KrystianD/bm2-battery-monitor), pinned at `494a39c5edfbf5c76906469f0da545e42882b28c`
- [andystewart999/ha_bm2monitor (MIT)](https://github.com/andystewart999/ha_bm2monitor), pinned at `cbd9630b2204c91c9ab3b555774fb431f749dbed`
