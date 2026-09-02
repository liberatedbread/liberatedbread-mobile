# Silk'n Infinity / Silk'n 7

> **Status**: Complete (static analysis; not yet hardware-verified)
> **Protocol**: BLE
> **Manufacturer**: Home Skinovations (Silk'n)
> **Manufacturer Status**: Active

## Safety

!!! danger "IPL can permanently damage skin and eyes"
    This is an intense-pulsed-light hair-removal handset (a home-pulsed-light (HPL) handset). Improper use
    can cause permanent skin burns, blistering, discolouration or scarring, and
    serious eye injury. Patch-test first, match the intensity to your skin tone
    (IPL is unsafe on the darkest skin tones), never treat broken, tanned,
    tattooed or moled skin, and keep it away from the eyes. This project ships an
    **experimental, unaffiliated** third-party client — the manufacturer's own
    instructions govern.

- Manufacturer safety guidance: <https://www.manualslib.com/manual/2132171/Home-Skinovations-Silk-N-Infinity.html>
- Archived copy (web.archive.org), if the page above is offline: <https://web.archive.org/web/20260831005752/https://www.manualslib.com/manual/2132171/Home-Skinovations-Silk-N-Infinity.html>

## Overview

Home IPL (intense pulsed light) hair-removal devices: the **Infinity** family
(advertising as `Infinity` or `SilknV_F`) and the newer **Silk'n 7**
(advertising as `Silkn7_App`). Recovered by static analysis of the companion
app *Hair Removal – Silk'n* (`com.ewavemobile.silkn`) v6.1 (versionCode 38),
2026-08. Machine-readable spec: `device-specs/devices/silkn-infinity.yaml`.

The headline: **the device works fully without the app, and the BLE protocol
is unauthenticated** — no pairing, no bonding, no challenge, no paywall. The
app counts flashes via notifications, shows device errors, polls the
skin-color sensor, and has exactly one write: an opt-in **lock**. The app
itself is account-centric (a blocking no-network dialogue at startup, login
before the main screen), but none of that reaches the hardware — a cloud
shutdown strands the app, not the device.

The app **cannot fire flashes or set intensity** — no write path exists to
anything but the lock. Energy levels are physical-button only, so a
replacement client is telemetry-plus-lock, exactly like the vendor's.

## Hardware

| Property | Value |
|----------|-------|
| Model Number | Infinity family (`Infinity`, `SilknV_F`), Silk'n 7 (`Silkn7_App`) |
| Chipset | Unknown |
| Radio | BLE |
| FCC ID | Not established |

## Initial Setup

None — the device needs no provisioning and works standalone out of the box.
See [Initial Device Setup](../protocols/device-setup.md); mirrored into
`device.setup` in the spec.

| Property | Value |
|----------|-------|
| Setup required | No |
| Method | `ble_direct` (scan, connect, subscribe — nothing else) |
| Setup AP / advertised name | `Infinity`, `SilknV_F`, or `Silkn7_App` (exact match) |
| Passphrase protection | not_applicable |
| Confidence | medium (static analysis of the app's BLE layer, not replayed) |

**Factory reset**: unknown whether one exists. The app contains no reset
function and no write path to the on-device treatment counters; if a reset
exists at all it is an undocumented physical button procedure. In practice
there is almost nothing to reset: the lock clears with one documented write,
and the counters are cosmetic history, not an adoption barrier.

**Rebinding to a new phone/client**: trivial — no bond is stored on either
side, so a new client simply scans and connects. The only residue a previous
app install can leave is the opt-in lock: if the old client locked the device
on disconnect, write `30 30` (Released + Unlocked) to the lock characteristic
once and move on.

## Pairing

None. See [Pairing, Bonding and Unpairing](../protocols/pairing.md); mirrored
into `device.pairing`.

| Property | Value |
|----------|-------|
| Pairing required | No |
| Security mode | `none` (open GATT on a bare connection) |
| Bonding | `none` (nothing stored on either side) |
| PIN source | not_applicable |
| One central at a time | Unknown |
| One bond at a time | No (no bonds exist) |
| Confidence | medium (static analysis, not yet confirmed on hardware) |

**Entering pairing mode**: not applicable — the device advertises and accepts
connections whenever powered.

**Unpairing**: not applicable — there is no bond to drop. Adopting a
second-hand unit costs nothing but the optional lock-clearing write above.

**Recovery**: the worst case is the vendor app holding the connection in the
background — close it (or power-cycle the device) and connect again.

## Protocol Summary

One custom primary service with five synthetic characteristics sharing the
`12345678-9012-3456-7890-1234567890xx` prefix, plus standard DIS.

### BLE Services

| UUID | Name | Description |
|------|------|-------------|
| `720411ac-adfe-2015-0820-835742ad3835` | Silk'n Hair Removal Service | The whole application surface |
| `0000180a-0000-1000-8000-00805f9b34fb` | Device Information (standard) | Serial number string `0x2A25` |

### Characteristics (Hair Removal Service)

| UUID suffix | Name | Access | Payload |
|-------------|------|--------|---------|
| `…9011` | TreatmentDynamicInformation | read + notify | 20-byte frame, one per pulse (layout below) |
| `…9022` | DeviceErrors | read + notify | 5 × u8 error codes (range ~10–70: HV, temp, fan, ignition, color-sensor calibration, stuck buttons, checksum, micro-current) |
| `…9033` | LockUnlockDevice | read + write | 2 bytes — the **only** writable characteristic |
| `…9044` | DeviceIO | read | 1 byte: bit7 = trigger pressed, bit6 = function button |
| `…9055` | ColorMeasurements | read | 7 × u16: raw RGB + threshold RGB (+1 unknown), polled every 20 pulses; endianness unconfirmed |

### TreatmentDynamicInformation (20 bytes, notify per pulse)

Two layouts, selected by the advertised name the client connected to — keep
the scan-result name, not just the address.

**`Infinity` / `SilknV_F` — big-endian:**

| Offset | Length | Type | Description |
|--------|--------|------|-------------|
| 0 | 1 | u8 | opcode (1 = per-pulse event; 0 likely a status snapshot, unconfirmed) |
| 1 | 4 | u32 BE | max_pulses (lamp/cartridge lifetime capacity) |
| 5 | 4 | u32 BE | total_counter (lifetime flashes fired) |
| 9 | 1 | u8 | current_level (set by the physical button, never over BLE) |
| 10–18 | 5 × 2 | u16 BE | per-level counters, levels 1–5 |

**`Silkn7_App` — little-endian variant:** same header fields, little-endian,
with the per-level counters omitted from the payload; the app increments its
own per-level tallies on each opcode==1 notification, and a replacement
client must do the same. Byte 19 is unused/unknown in both layouts.

### Commands

#### Command: release_and_unlock (write to `…9033`)

`30 30` — mode Released + state Unlocked. Clears the app-managed lock and
sets the mode that keeps it cleared; a never-paired device ships in this
state. This is the one write a replacement client should issue on first
connect if the device reads back Locked.

#### Command: lock (write to `…9033`)

`31 31` — mode Lock + state Locked: what the app writes between sessions when
the user enabled lock mode (it unlocks from its treatment-start screen and
re-locks on disconnect). A local-control client has no reason to send it.

Read layout of `…9033`: byte 0 = mode (`0x30` Released / `0x31` Lock),
byte 1 = state (`0x30` Unlocked / `0x31` Locked). The lock is advisory and
app-managed, not a security feature — any client can clear it with a single
unauthenticated write.

## Cloud

Not required, and never on the device path. The phone app talks to
`https://ws.silknglobal.com/` (REST: signup/login, treatments CRUD,
pair-device telemetry, per-pulse data upload, malfunction reports) and gates
its main screen behind an account — but the pair-device call is telemetry
only and the hardware never contacts any of it. Data that leaves the device:
per-pulse treatment data, malfunction reports, and account identity — all
app-side, all optional once you stop using the vendor app.

## Tools Used

- Static analysis (decompile) of the Android companion app — no hardware, no
  capture yet. One HCI snoop of a treatment session would close the remaining
  gaps: opcode values beyond 1, the `Silkn7_App` frame on-air, the
  ColorMeasurements endianness, and the exact DeviceErrors code table.

## References

- [Hair Removal – Silk'n on Google Play](https://play.google.com/store/apps/details?id=com.ewavemobile.silkn) — the app this spec was recovered from (v6.1 / versionCode 38)
- [Silk'n vendor site](https://silkn.com/) — product pages and official user guides; the analysed app also bundles ~40 device user-manual PDFs in its assets
- Research notes: `research-notes/silkn-infinity.md`

## Contributors

- Liberated Bread research — static analysis and spec (2026-08)
