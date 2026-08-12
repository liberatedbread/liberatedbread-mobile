# HYDRAO Smart Shower Head (Smart & Blue) — Research Notes

## What it is
Water-powered (no battery) BLE shower head that measures flow volume, temperature,
and shower duration, with LED color thresholds to nudge water saving. Models:
HYDRAO First, HYDRAO Aloe (and B2B variants for social housing). Made by French
startup Smart & Blue (SIREN 814 127 148, Moirans/Grenoble).

## Why it's abandoned (confirmed, dated source)
Per [societe.com company record](https://www.societe.com/societe/smart-and-blue-814127148.html)
(fetched 2026-08-04), Tribunal de Commerce de Grenoble:
- **2025-06-12**: cessation des paiements (insolvency date)
- **2025-07-02**: redressement judiciaire (receivership) opened
- **2025-12-23**: observation period extended to 2026-06-30
- **2026-06-02**: converted to **liquidation judiciaire** (company being wound up)

The companion app/cloud therefore has no maintainer; devices in the field are
unsupported. The hardware itself is fully self-powered and cloud-independent.

## APK Provenance
- **Package**: `com.smartandblue.hydrao` ("HYDRAO"), version 1.7.3 (latest on APKPure)
- **Source**: apkeep, `-d apk-pure` → bare APK
- **APK SHA-256**: `6c74dc2cb623e5aa45fe8db7b37591d274a453e362f4c312322d0a15140a97c3`
- **App framework**: Native Java (2015-era, android.support), unobfuscated.

## BLE details recovered (jadx, `GattAttributes.java`)
Advertising name filter: **`HYDRAO_SHOWER`** (also `OTAServiceMgr` during DFU).
The vendor reused standard service UUID `180f` as the main HYDRAO service, with
custom characteristics in the `ca1c`–`ca30` range.

| UUID | Role |
|------|------|
| `0000180f-...` | HYDRAO service (repurposed Battery Service UUID) |
| `00002a26-...` | Firmware version (read) |
| `0000ca1c-...` | Litrage — total & current volume (read/notify) |
| `0000ca1d-...` | Thresholds (seuils) — LED volume alerts (read/write) |
| `0000ca1e-...` | Ask FOTA (write) |
| `0000ca1f-...` | Ask reset (write) |
| `0000ca20-...` | End shower (write) |
| `0000ca21-...` | History index min/max (read) |
| `0000ca22-...` | Ask history (write) |
| `0000ca23-...` | History record (read) |
| `0000ca24-...` | Hardware version (read) |
| `0000ca25-...` | Reset (write) |
| `0000ca26-...` | Rotation/turbine counter → shower duration (read) |
| `0000ca27-...` | VMOT — turbine voltage (read) |
| `0000ca28-...` | Device UUID (read) |
| `0000ca30-...` | Calibration (read/write) |
| `8a97f7c0-8506-11e3-baa7-0800200c9a66` | OTA service (Cypress-style OTA bootloader) |

(All `0000xxxx-0000-1000-8000-00805f9b34fb` form; OTA characteristics:
`122e8cc0-...`, `210f99f0-...`, `2691aa80-...`, `2bdc5760-...` on the same
`...8508-11e3-baa7-0800200c9a66` base.)

## Prior community reverse engineering (mature)
- [kamaradclimber/hydrao-dump](https://github.com/kamaradclimber/hydrao-dump) —
  original RE; Python script pushing shower data to MQTT/Home Assistant.
- [adizanni/hydrao](https://github.com/adizanni/hydrao) — Home Assistant custom
  integration (BLE, works with Aloe; verified temperature, current/total volume,
  duration). Includes a ready-made **ESPHome `ble_client` config**.
- Known decodings (from the HA integration): `ca1c` = two uint16-LE (total,
  current volume in L); `ca32`-style temperature char (value/2 = °C; app uses
  `ca1c`/`ca26`/`ca30` family — note the community found temp at `ca32`, app
  GattAttributes tops out at `ca30`, so firmware added chars after app 1.7.3);
  duration = rotation counter / 50 seconds.

## Local feasibility verdict
**Confirmed — fully local, easy.** Device needs no account and no cloud: connect,
enable notifications, read characteristics. Complete GATT map + working open-source
clients exist. The only cloud-dependent bits were app-side statistics/sharing.

## Open questions
- Exact `ca1d` threshold write format (LED alert levels) — partially RE'd.
- History record format on `ca23`.
- Firmware later than app 1.7.3 added at least one characteristic (`ca32` temp);
  worth enumerating services on real hardware.
- Whether remaining company assets (brand/app) were sold during liquidation.

## Safety class
LOW — passive measurement; no control of water temperature or flow beyond
indication LEDs.
