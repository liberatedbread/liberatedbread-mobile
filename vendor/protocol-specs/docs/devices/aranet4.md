# Aranet4 CO2 Sensor

> **Status**: Complete (protocol fully documented from cross-checked prior art; live unit observed, GATT not yet driven — old firmware requires bonding)
> **Protocol**: BLE
> **Manufacturer**: SAF Tehnika JSC
> **Manufacturer Status**: Active — fully local by design; cloud is an optional paid add-on

## Overview

The Aranet4 is a battery-powered e-ink CO2 / temperature / humidity / pressure
sensor with an exemplary local story: with firmware ≥ v1.2.0 and the "Smart
Home integrations" toggle enabled, it broadcasts every measurement in BLE
advertisements — no connection, no pairing, read by any passive scanner
(this is exactly how Home Assistant integrates it). GATT adds current
readings, full history download and settings. The same advertisement/GATT
skeleton covers the Aranet2, Aranet Radiation and Aranet Radon.

A real unit ("Aranet4 19385") was observed live 2026-08-14: it broadcast the
short 7-byte header-only payload decoding to firmware v0.4.14 — pre-v1.2.0,
so no measurements in adverts, and it dropped every unbonded GATT connection
during service discovery, exactly as the pairing rules predict. Full
verification needs the pairing PIN from its e-ink display (human present) or
a firmware update.

## Hardware

| Property | Value |
|----------|-------|
| Sensor | Senseair Sunrise NDIR CO2 (per teardowns) |
| Radio | Nordic BLE SoC, random static address; Nordic Secure DFU `0xFE59` present |
| Battery | 2×AA, ~1–2 years |
| Advertised name | `Aranet4 NNNNN` |

## Initial Setup

| Property | Value |
|----------|-------|
| Setup required | No (passive) / one-time toggle for broadcast measurements |
| Method | `ble_direct`; bonding (passkey shown on e-ink display) for history/settings and for everything on firmware < v1.2.0 |
| Passphrase protection | not_applicable (standard BLE passkey bonding) |
| Confidence | high (reference implementation ships in Home Assistant; official SAF Tehnika Homey app cross-checked) |

## Protocol Summary

- **Advertisement** (manufacturer ID `0x0702`): 7-byte short (header only) or
  22-byte long payload — CO2 u16@8, temp ×0.05 u16@10, pressure ×0.1 u16@12,
  humidity u8@14, battery u8@15, status color u8@16, interval u16@17,
  ago u16@19. Family devices (Aranet2/Radiation/Radon) use 24-byte payloads
  with a leading type byte.
- **GATT**: vendor service `f0cd1400-…` (fw < v1.2.0) or `0xFCE0`
  (fw ≥ v1.2.0). Current readings `f0cd3001` (13 B), command char `f0cd1402`
  (history requests `0x82`/`0x61`, interval `0x90`, integrations toggle
  `0x91`), history V1 notify `f0cd2003` / V2 poll-read `f0cd2005`.
- **Sentinels**: CO2/pressure bit15, temperature bit14 ⇒ invalid (seen during
  calibration).

See `device-specs/devices/aranet4.yaml` for byte-exact layouts, the history
protocol and the family differences.

## Tools Used

- BlueZ/bluetoothctl advertisement capture; bleak connection attempts

## References

- <https://github.com/Anrijs/Aranet4-Python>
- <https://github.com/Anrijs/Aranet4-ESP32>
- <https://github.com/SAF-Tehnika-Developer/com.aranet4>
- <https://www.home-assistant.io/integrations/aranet/>
