# Beurer Series 800 (Premium 800 / BM92) Blood Pressure Monitor

> **Status**: Research
> **Protocol**: BLE
> **Manufacturer**: Beurer
> **Manufacturer Status**: Active (vendor in business; cloud strictly optional)

## Overview

The Beurer "Series 800" — sold as the "Premium 800", model **BM92** — is an
upper-arm Bluetooth blood-pressure monitor with voice output, a 2-user ×
120-reading memory, WHO risk classification, and cuff-position and arrhythmia
indicators. It belongs to Beurer's HealthManager family and pairs with the
"beurer HealthManager Pro" app (`com.beurer.healthmanager`).

The good news up front: the BM92 implements the **standard Bluetooth SIG Blood
Pressure Profile**, so there is no proprietary command protocol to liberate —
any generic BLE BP-profile client can read it, and the vendor cloud is optional
account sync, not a dependency. What this spec adds on top of the published
profile is the set of **Beurer quirks** in the record format (big-endian
SFLOATs, a kPa unit flag, appended user-slot and status bytes) recovered from
the vendor apps and corroborated by community work on the sister BM85.

## Hardware

| Property | Value |
|----------|-------|
| Model Number | BM92 (US "Series 800" / "Premium 800"); wrist sister BC54W advertises as `PREMIUM800W` |
| Chipset | Unknown (no teardown/FCC detail retrieved) |
| Radio | BLE only — no WiFi |
| FCC ID | Unknown — device.report lists a filing dated 2023-08-30 but is bot-blocked; the printed manual should carry it |
| BLE name | `PREMIUM800` |

## Initial Setup

Nothing to provision. The monitor is usable straight out of the box: scan,
connect, bond, enable indications, read.

| Property | Value |
|----------|-------|
| Setup required | No |
| Method | `ble_direct` |
| Advertised name | `PREMIUM800` (BM92), `PREMIUM800W` (BC54W) |
| Passphrase protection | not_applicable (no WiFi, no PIN found in app code) |
| Confidence | medium (app decompile; not replayed against hardware) |

The app requests Android bonding (`createBond()`). No app-level PIN exists for
blood-pressure devices, so bonding is expected to be JustWorks or Numeric
Comparison — unconfirmed until someone pairs one.

A typical sync session:

1. Wake the device (take a measurement) so it advertises.
2. Connect and bond.
3. Write standard Current Time (`0x2A2B` on service `0x1805`) so stored
   records carry correct timestamps.
4. Enable **indications** on `0x2A35` (CCCD write of `0x0002`).
5. The device streams one indication per stored record; parse per the format
   below.

**Factory reset**: unknown. Neither app contains a BP-monitor reset procedure
and no hardware was available. Check the printed manual; do not guess a button
sequence. A reset would presumably clear the measurement memory and user
configuration.

**Rebinding to a new phone**: just pair from the new phone. There is no network
credential to move. If the device stops accepting new bonds, remove the
OS-level bond on the old phone first (a common single-bond peripheral symptom,
not yet confirmed on this device).

## Protocol Summary

### BLE Services

| UUID | Name | Description |
|------|------|-------------|
| `0x1810` | Blood Pressure | Standard SIG service; the entire measurement surface |
| `0x1805` | Current Time | Clock sync via `0x2A2B` write (standard 10-byte CTS format) |
| `0x180A` | Device Information | Model `0x2A24`, firmware `0x2A26`, hardware `0x2A27` |
| `0x180F` | Battery | Standard level `0x2A19` (0–100 %) |

Characteristics of interest:

| UUID | Name | Properties | Notes |
|------|------|-----------|-------|
| `0x2A35` | Blood Pressure Measurement | indicate | Record stream; enable via CCCD |
| `0x2A49` | Blood Pressure Feature | read | Listed for the family; **presence on BM92 unverified** |
| `0x2A2B` | Current Time | write | Standard CTS write |

### Record format (`0x2A35` indication payload)

IEEE-11073-style, with Beurer quirks (from the classic app's BM85-family
parser, corroborated by smurfix/ble-stuff):

| Offset | Length | Description |
|--------|--------|-------------|
| 0 | 1 | Flags: bit0 = values in kPa (multiply by 7.50061683 → mmHg); bit1 = timestamp present |
| 1–2 | 2 | Systolic, SFLOAT **big-endian** (quirk — swap bytes before decoding) |
| 3–4 | 2 | Diastolic, SFLOAT big-endian |
| 5–6 | 2 | Mean arterial pressure, SFLOAT big-endian |
| 7–8 | 2 | Year, **little-endian** uint16 (only if flag bit1) |
| 9–13 | 5 | Month, day, hour, minute, second |
| 14–15 | 2 | Pulse, SFLOAT big-endian (high byte observed zero) |
| 16 | 1 | User slot (which of the 2 memories) |
| 17 | 1 | Unused in the BM85 layout |
| 18 | 1 | Status: bit2 (0x04) = irregular heartbeat; bits 6–7 = resting (HSD) indicator (00 = insufficient rest, 01 = sufficient) |

**Unverified for BM92 specifically**: the Pro app's measurement model also
tracks afib and triple-measurement flags, so BM92-era firmware may use extra
status bits or append bytes past 19. One btsnoop capture of a sync settles
this — it is the top open question.

### Commands

#### Command: Set Current Time

Write to `0x2A2B` (CTS), standard format:

| Offset | Length | Description |
|--------|--------|-------------|
| 0–1 | 2 | Year, little-endian uint16 |
| 2 | 1 | Month (1–12) |
| 3 | 1 | Day (1–31) |
| 4 | 1 | Hour (0–23) |
| 5 | 1 | Minute |
| 6 | 1 | Second |
| 7 | 1 | Day of week (1=Mon…7=Sun, 0=unknown) |
| 8 | 1 | Fractions (1/256 s; 0 is fine) |
| 9 | 1 | Adjust reason bitmask (0x01 = manual update) |

There is no other command surface: no OTA path exists for the BM92 in either
app (firmware update support exists only for the BF880/BF980/BF990 WiFi
scales).

## Cloud Dependency & Keep-Alive (Home Assistant)

**The device does not depend on the cloud at all.** It has no WiFi and never
phones home; all measurement transfer is local BLE. The Beurer cloud
(`hmpro.connect.beurer.com` EU / `hmpro-us.connect.beurer.com` US, plus SSO
and classic-sync hosts — all alive and responding as of 2026-08-18, with
Beurer actively shipping product) only provides optional account sync/backup
in the app, which itself works fully without registration.

Practical guidance:

- Any generic BLE Blood Pressure Profile client can read the BM92. In Home
  Assistant, an ESPHome Bluetooth proxy plus a small parser for the quirks
  above (big-endian SFLOATs, kPa flag) is enough; there is no dedicated HA
  integration yet, but none is strictly needed.
- Blocking or DNS-redirecting `hmpro*.connect.beurer.com` and
  `sync.connect-beurer.com` does not impair local BLE operation, if you want
  the vendor app but not its telemetry.
- smurfix/ble-stuff demonstrates fully cloud-free sync of the sister BM85
  over the identical `0x1810`/`0x2A35` path — the strongest evidence that
  nothing here dies with the vendor.

## Tools Used

- [ ] jadx decompiles of both vendor apps (Pro 1.17.2, classic 2.17)
- [ ] Live HTTPS probes of the cloud endpoints (2026-08-18)
- [ ] No packet capture yet — bonding type, 0x2A49 presence, and the exact
      BM92 record tail are open questions waiting on hardware

## References

- [Beurer Premium 800 product page](https://www.shop-beurer.com/products/copy-of-beurer-blood-pressure-arm-monitor-auto-400)
- [beurer HealthManager Pro (Google Play)](https://play.google.com/store/apps/details?id=com.beurer.healthmanager)
- [beurer HealthManager classic (Google Play)](https://play.google.com/store/apps/details?id=com.beurer.connect.healthmanager)
- [smurfix/ble-stuff — BM85 local reader](https://github.com/smurfix/ble-stuff)
- [openScale issue #111 — Beurer scale protocol notes](https://github.com/oliexdev/openScale/issues/111)
- [device.report BM92 page (FCC filing, bot-blocked)](https://device.report/beurer/bm92)
- [Bluetooth SIG Blood Pressure Profile](https://www.bluetooth.com/specifications/specs/blood-pressure-profile-1-1-1/)

## Contributors

- research/acquisition agent — app acquisition, decompile, protocol recovery (2026-08)
