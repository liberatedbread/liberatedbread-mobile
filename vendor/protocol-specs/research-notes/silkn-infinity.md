# Silk'n Infinity / Silk'n 7 (IPL) — Research Notes

## What This Is

Silk'n (Home Skinovations) IPL devices — the **Infinity** family and the newer
**Silk'n 7** — have BLE telemetry. Companion app: **Hair Removal – Silk'n**
(`com.ewavemobile.silkn`), analyzed at version **6.1 (versionCode 38)**,
targetSdk 33.

Headline: **the device works fully without the app, and the BLE protocol is
unauthenticated** — no bonding, no challenge, no paywall. The app counts
flashes via notifications, shows device errors, polls the skin-color sensor,
and has one write: an opt-in **lock** characteristic (the app locks the device
between sessions if the user enabled lock mode, and unlocks it from the
treatment-start screen). The app itself is account-centric (a blocking
no-network dialog at startup; login before the main screen) but none of that
reaches the hardware — the pairing call to the cloud is telemetry only.

## Transport

- BLE GATT, no bonding, no auth. Scan filter = exact advertised name match:
  **`Infinity`**, **`SilknV_F`** (Infinity variant, likely "Fast"), or
  **`Silkn7_App`** (Silk'n 7).
- Standard DIS service `0x180A` with serial number string `0x2A25`.

## GATT map

Primary service **`720411AC-ADFE-2015-0820-835742AD3835`** with synthetic
sequential characteristics:

| UUID | Name | Access | Payload |
|---|---|---|---|
| `12345678-9012-3456-7890-123456789011` | TreatmentDynamicInformation | read + notify | 20 bytes (layout below) |
| `12345678-9012-3456-7890-123456789022` | DeviceErrors | read + notify | 5 × u8 error codes (10–70: HV, temp, fan, ignition, color-sensor cal, stuck buttons, checksum, micro-current) |
| `12345678-9012-3456-7890-123456789033` | LockUnlockDevice | read + write | 2 bytes: mode `0x30`=Released / `0x31`=Lock; state `0x30`=Unlocked / `0x31`=Locked |
| `12345678-9012-3456-7890-123456789044` | DeviceIO | read | 1 byte: bit7=trigger pressed, bit6=function button |
| `12345678-9012-3456-7890-123456789055` | ColorMeasurements | read | 7 × u16: raw RGB + threshold RGB (polled every 20 pulses) |

(All five characteristics are synthetic constants sharing the
`12345678-9012-3456-7890-1234567890xx` prefix, ending 11/22/33/44/55.)

### TreatmentDynamicInformation (20 bytes, notify per pulse)

Two layouts chosen by advertised name:

- `Infinity` / `SilknV_F` — big-endian: `u8 opcode @0`, `u32 maxPulses @1`,
  `u32 totalCounter @5`, `u8 currentLevel @9`, `u16 levelCounter[1..5] @10–18`.
- `Silkn7_App` — little-endian variant; per-level counters omitted from the
  payload and incremented app-side when opcode==1 (per-pulse event).

## Behaviour

- On connect the app reads LockUnlock and, if the user enabled lock mode,
  writes Locked; it writes Unlocked from the treatment-start/finish screens
  and re-locks on disconnect. Default (never-paired device) is
  Released/Unlocked — a replacement app can write `{0x30, 0x30}` (Released +
  Unlocked) once and the lock never re-engages.
- **The app cannot fire flashes or set intensity** — no write path exists to
  anything but LockUnlock. Energy levels are physical-button only.
- Cloud: `https://ws.silknglobal.com/` REST (signup/login, treatments CRUD,
  pair-device telemetry, per-pulse data upload, malfunction reports).
- No billing/purchase code anywhere — **no paywall**.

## Feasibility

- **Trivial to replace.** Scan for name `Infinity`/`SilknV_F`/`Silkn7_App`,
  connect, subscribe to `…9011` and `…9022`, optionally clear the lock via
  `…9033`. All parsing layouts above are fully recovered.

## Evidence

- App: Hair Removal – Silk'n 6.1 (38), `com.ewavemobile.silkn` (APKPure via
  apkeep, 2026-08-29). Decompile: `~/research/ipl/static/silkn/` (not
  committed).
- App bundles ~40 device user-manual PDFs in assets — useful manual source.

## Open questions

- Opcode values beyond 1 (likely 0 = status snapshot) — needs one HCI capture.
- `SilknV_F` identity (Infinity "Fast"?) inferred from name only.
- Whether lock mode=Released truly makes firmware ignore lock state on all
  Infinity firmware revisions.
