# MoTool Slacker

> **Status**: In Progress
> **Protocol**: BLE
> **Manufacturer**: Slacker LLC (formerly MoTool)
> **Manufacturer Status**: Active (subscription gates app cloud features only; device control is local)

## Overview

Digital motorcycle suspension sag measurement tool (V4/V5). Attaches to fork or shock and communicates over BLE to the companion Flutter app. Basic device control is NOT paywalled: the standalone "Slacker Virtual Remote" app is 100% free with full Reset/Auto Zero/display control, and the Service Assistant subscription (via RevenueCat) only gates cloud/notes/multi-bike features. The goal is to reverse engineer the BLE serial protocol so the device can be driven by any local client without the vendor app or cloud.

The device uses a standard HM-10/HM-19-style BLE UART module (CC2541/CC2640 based), so the protocol is serial pass-through over a single BLE characteristic. All command construction is in Dart AOT-compiled code (`libapp.so`), so exact command bytes need HCI snoop capture confirmation.

## Hardware

| Property | Value |
|----------|-------|
| Models | MoTool Slacker V4, V5 |
| Chipset | HM-10/HM-19 BLE UART module (CC2541/CC2640) |
| Radio | BLE 4.0+ |
| FCC ID | Unknown |

## Protocol Summary

### BLE Services

| UUID | Name | Description |
|------|------|-------------|
| `0000FFE0-0000-1000-8000-00805f9b34fb` | UART Service | Standard HM-10 serial pass-through service |

### Characteristics

| UUID | Name | Properties | Description |
|------|------|------------|-------------|
| `0000FFE1-0000-1000-8000-00805f9b34fb` | Serial Data | Read, Write, Write Without Response, Notify | Single bidirectional serial channel |

### Discovery

- **Scan filter**: Service UUID `0xFFE0` (app filters by service UUID, not device name)
- **CCCD**: Standard `0x2902` for enabling notifications
- **Pairing**: No bonding required (HM-10 modules use "Just Works" or no pairing)

### Known Commands (from Dart string analysis)

The app sends commands to the device via writes to `FFE1` and receives responses via notifications. From AOT binary string extraction (Service Assistant v7.1.0, `libapp.so`):

| Command | Description | Direction |
|---------|-------------|-----------|
| Reset | Reset the device/measurement | Phone -> Device |
| Auto Zero | Zero/tare the sensor reading | Phone -> Device |
| Display Mode Change | Switch between mm and percentage display | Phone -> Device |
| Travel Selection | Set fork/shock travel for percentage calculation | Phone -> Device |

Write path (derived from the snapshot string table): commands are assembled as hex strings (`buildTravelHex` / `hexBuilder` / `masterHexValue`; debug logs "Hex Builder Travel Hex String Data", "Wrote Travel Hex String Data"), decoded to bytes with the `package:convert` HexDecoder, and written to `FFE1` via flutter_blue. Device->app traffic arrives as `FFE1` notifications parsed into `deviceState` / `mtbMode` / `currentReadingInt`. The exact command byte sequences are NOT statically recoverable (see Next Steps) and are deliberately not listed here — do not invent opcodes.

### Data Model (from Dart strings)

The app tracks these measurement values:

| Field | Type | Description |
|-------|------|-------------|
| `currentReadingInt` | Integer | Current raw sag reading |
| `sagFS` | Float | Front static sag |
| `sagFR` | Float | Front rider sag |
| `sagRS` | Float | Rear static sag |
| `sagRR` | Float | Rear rider sag |
| `frontSagRiderPercent` | Float | Front sag as % of travel |
| `rearSagRiderPercent` | Float | Rear sag as % of travel |
| `travelFork` | Float | Fork travel setting (mm) |
| `travelShock` | Float | Shock travel setting (mm) |

### V4 vs V5 Differences

- **V4**: Displays raw measurement in mm
- **V5**: Adds percentage-of-travel display mode. Requires fork/shock travel settings to be configured in the app (`buildTravelHex` function constructs hex data for travel configuration)

### App Architecture

| Component | Technology |
|-----------|-----------|
| App analyzed | Service Assistant v7.1.0 (versionCode 710, targetSdk 35; XAPK, armeabi-v7a only) |
| Framework | Flutter (Dart AOT-compiled) |
| BLE Plugin | flutter_blue (pauldemarco) — confirmed via `plugins.pauldemarco.com/flutter_blue/methods` channel string |
| Subscription | RevenueCat (Google Play + Amazon IAP; paywall/customer-center activities in AndroidManifest.xml) |
| Backend | Firebase (Firestore, Auth, Messaging) |
| Firebase Project | motool-service-assistant |

### Subscription/Paywall

The Service Assistant subscription is gated by RevenueCat entitlements, but it only covers cloud/notes/multi-bike features — the standalone Slacker Virtual Remote app provides full basic device control for free. Subscription plans include: Weekly, Monthly, Bimonthly (2-month), Quarterly (3-month), Semiannual (6-month), Annual, and Lifetime.

The BLE protocol itself has no authentication or subscription check — the paywall is entirely app-side.

### Next Steps

1. **HCI snoop capture**: Record a BLE session during sag measurement to capture exact command bytes (practical route)
2. **Dart AOT snapshot analysis**: attempted 2026-08-18 — the snapshot is fully position-independent (no ELF relocations); heap objects in `.rodata` are serialized clusters and constants are referenced through the string table by index, so recovering the command-building logic needs a full Dart cluster deserializer. Existing tools (blutter, Doldrums) target ARM64 only, and this app ships armeabi-v7a only.
3. **BLE proxy**: Use nRF Connect or a BLE proxy to intercept and replay commands
4. **Protocol documentation**: Once command bytes are known, document the full serial protocol

## Tools Used

- [x] APK decompilation (jadx) -- BLE UUIDs, architecture, subscription system
- [x] Dart AOT string extraction (libapp.so) -- command names, data model, device name
- [ ] HCI snoop capture (needed for exact command bytes)
- [ ] BLE proxy / nRF Connect (needed for protocol verification)

## References

- [Google Play: MoTool](https://play.google.com/store/apps/details?id=co.motool.serviceassistant)
- [Slacker Website](https://getslacker.com) (legacy motool.com is dead; motool.co, used by the app's support links, 301-redirects to getslacker.com as of 2026-08-18)

## Contributors

- APK static analysis + Dart AOT string extraction
