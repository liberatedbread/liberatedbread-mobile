# Nuheara IQbuds / IQbuds Boost / IQbuds² MAX — Research Notes

## What it is
Nuheara (Perth, Australia) hearing-enhancement true-wireless earbuds: IQbuds (2017),
IQbuds Boost (2018, in-app hearing self-test / EarID), IQbuds² MAX (2020, ANC).
PSAP-class "intelligent hearing" products: world volume, SINC speech/noise balance,
location-based hearing profiles, tap-touch remapping, EQ. Companion app: "IQbuds".

## Why abandoned
- Suspended from ASX quotation 2024-03-01 for failure to lodge periodic report
  ([ASX notice, 2024-08-08](https://asxonline.com/content/asxonline/public/notices/2024/august/0916.24.08.html)).
- Directors appointed KPMG as voluntary administrators 2024-08-07
  ([Listcorp, 2024-08-07](https://www.listcorp.com/asx/nuh/nuheara-limited/news/appointment-of-voluntary-administrators-3066315.html));
  securities ceased/delisted July 2024
  ([deListed Australia](https://www.delisted.com.au/company/nuheara-limited/)).
- IQbuds² MAX marked discontinued ([Hearing Tracker, 2025-08-22](https://www.hearingtracker.com/hearing-aids/nuheara-iqbuds-max)).
- App last version 3.3.5 (Feb 2024 per Uptodown history). Buds keep last-configured
  profiles without the app, but all configuration and EarID require the app.

## APK provenance
- **Package**: `com.nuheara.iqbudsapp` ("IQbuds")
- **Version**: 3.3.5 (versionCode 967) — fetched via apkeep (apk-pure source) as XAPK, 2026-08-03
- **XAPK SHA-256**: `11f4457c92d8005ad9ff0e9bddd24c79c886154d8d23cb1f4d4b835db5944d6f`
- **Framework**: Kotlin + Dagger; packages largely unobfuscated
  (`com.nuheara.iqbudsapp.communication.*` fully readable).
- jadx output at `workspace/static/iqbuds/`.

## Key finding: control is Qualcomm GAIA, not BLE GATT
The buds' control channel in the app is `com.nuheara.gaialibrary` — Qualcomm GAIA
over Bluetooth Classic SPP/RFCOMM (SPP `00001101-...`, GAIA service UUID
`00001107-d102-11e1-9b23-00025b00a5a5` in `GaiaLink.java`). BLE in this app is used
only for the **IQstream TV** accessory:
- IQstream service `7cb85d00-15cc-48a2-ad50-3c59eb3a785d`
  (audio status `7cb85d01-...`, device link info `7cb85d02-...`, statistics `7cb85d05-...`)
- IQstream DFU service `35770300-5b07-48a8-80ce-a0ba81144276`
  (data request `35770301-...`, response `35770302-...`)

No BLE-GAIA GATT path was found in the app for the buds. So local control of the
buds means GAIA over classic — which is good news: GAIA is a publicly documented
Qualcomm protocol and open-source host-side implementations exist.
Whether IQbuds² MAX (BT 5.0) also exposes GAIA-over-BLE needs a live scan.

- Advertising/pairing name prefix: `"IQbuds"` (`IQBudsScanner.java`,
  device names iqbuds / iqbudsboost / iqbudsmax / iqbuds2max).
- Command model: `NuhearaCommands`, `NuhearaPacket`, `NuhearaPayloadParser`,
  payload classes for audiogram, live EQ, location profiles, tap-touch, favourites.

## Local feasibility
High, via GAIA. No cloud in the device-control path; the app's account/registration
is optional. Firmware update for gen-1 was USB+desktop utility; OTA manager exists
in-app for later models (`IQBudsOTAManager`).

## Prior art
- Qualcomm GAIA protocol documentation is public; multiple open-source GAIA host
  libraries exist (search "pygaia", GAIA in bluez ecosystem). No Nuheara-specific
  RE found — vendor command IDs (in `NuhearaCommands`) are the value-add here.

## Open questions
- GAIA vendor ID and the full vendor-command map (readable in `NuhearaCommands.java`).
- Does IQbuds² MAX expose a BLE control path at all? Needs nRF Connect scan.
- EarID self-fit may involve server-validated profiles? (Evidence says local.)

## Safety class
MODERATE — hearing-assistive PSAP products; audiogram-driven amplification in-ear.
Not medical devices, but gain/EQ writes affect hearing safety.
