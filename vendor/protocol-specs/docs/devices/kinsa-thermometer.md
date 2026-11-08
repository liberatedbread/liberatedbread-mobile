# Kinsa Smart Thermometers

> **Status**: Spec Available (untested)
> **Protocol**: BLE GATT (ASCII on first Smart Ear; binary on newer families)
> **Manufacturer**: Kinsa Inc. (active)

## Health and privacy warning

Readings obtained through this unverified protocol are a personal wellness
log, not a diagnosis or a basis for medication or treatment. Check the value
against the thermometer's own display and use a clinically appropriate device
and technique when a decision matters. Never dose medication from a reading
obtained through this spec alone.

The vendor app associates readings with family-member profiles and uploads
them. A local client need not do that. Keep reading history, serial numbers
and owner identifiers out of public captures and logs.

## Overview

The spec covers the first-generation Smart Ear, second-generation ear,
QuickCare sticks and QuickScan/CareScan forehead models:
`device-specs/devices/kinsa-thermometer.yaml`. Identify the family by its
advertised service UUID rather than retail packaging. The file maps the
vendor's internal family labels to retail models, records the uncertainty and
provides complete command and reply layouts.

## Setup and pairing

### Newer binary-opcode families

1. Fit the correct batteries and tap power/start.
2. Connect to the advertised `00000000-00XX-746c-6165-4861736e694b` service;
   do not bond.
3. Subscribe to `00000002-00XX-746c-6165-4861736e694b`.
4. Run the service's initialization sequence one request at a time: firmware,
   serial if needed, measurement site where supported, clock, battery and
   error state.
5. Drain cached readings until the returned index is zero, then set the clock
   in UTC. Preserve records before any cache-clearing operation.

These families use big-endian multi-byte fields. Infrared models report
hundredths of a degree Celsius; stick models report tenths. Confusing those
layouts produces readings ten times off.

### First-generation Smart Ear

1. Fit two AAA batteries and tap power/start.
2. Connect to `2893b28b-c868-423a-9dc2-e9c2fcb4ebb5` and complete the Just
   Works pairing prompt. To add another phone, first hold the side Bluetooth
   pairing button for three seconds.
3. Subscribe to Response `28930001-c868-423a-9dc2-e9c2fcb4ebb5` and Events
   `28930002-c868-423a-9dc2-e9c2fcb4ebb5`.
4. Write `RSTS` to `28930000-c868-423a-9dc2-e9c2fcb4ebb5` and retain the
   returned clock value for timestamp conversion.
5. Read software revision and serial from Device Information, then pull the
   cache with `RC`. Only write `CE` after every record is safely stored.

Older firmware uses bonding and slower request pacing; current app behaviour
is described fully in the spec.

## Factory reset and rebinding

No factory reset is established. Neither the FCC-filed manuals nor the app
provides one. Removing batteries for about 30 seconds is only an unverified
candidate, not a promise to clear bonds, clock, cache or configuration. Do
not experiment with the protocol's reset or clear-configuration opcodes.

For QuickScan/CareScan, the manual's transfer route is to forget the
thermometer in the original phone's app before connecting a new phone. Smart
Ear uses its three-second pairing-button procedure for an additional phone.
There is no Wi-Fi network to rejoin.

## Protocol summary

Smart Ear uses short ASCII commands and 18-character reading records. Newer
families write one opcode plus payload to `0000000[4]` and receive an
opcode-led reply on `0000000[2]`. The YAML declares initialization, cache
semantics, timestamp conversion, units, signedness, scaling, error flags and
firmware-update boundaries.

## References

- [Kinsa Smart Ear instructions (FCC exhibit)](https://fccid.co/api/files/s1/2afeoe1_usersmanual_2760044_3c434d9492.pdf)
- [Kinsa CareScan instructions (FCC exhibit)](https://fccid.co/api/files/s1/2afeonc1_usersmanual_5076918_6077823510.pdf)
- [Kinsa on Google Play](https://play.google.com/store/apps/details?id=com.kinsa.polaris.app)
