# Qualcomm GAIA audio ecosystem (CSR86xx / QCC30xx / QCC51xx) — Research Notes

Date researched: 2026-08-03. Researcher: BT-Classic audio swarm.

## Verdict
**Ecosystem note — CONFIRMED generic local-control path.** GAIA (Generic
Application Interface Architecture) is Qualcomm/CSR's standard sideband
control+DFU channel on a huge population of Bluetooth Classic audio devices
(headphones, earbuds, speakers, receivers). The transport and framing are
public in Qualcomm's own sample source; per-device command tables are the only
device-specific work. When a vendor app vanishes, the GAIA channel remains.

## What GAIA is
- CSR invention, now Qualcomm; no public NDA-free spec, but Qualcomm published
  the full Android sample app source (see below).
- Transport: **BR/EDR RFCOMM with SDP UUID `00001107-d102-11e1-9b23-00025b00a5a5`**
  on Android/desktop; iOS uses a BLE GATT service (reported as
  `00001100-d102-11e1-9b23-00025b00a5a5`) because iOS can't do SPP.
  Pattern confirmed by diyAudio CSR8675 devs and cweiske.de
  ([cweiske.de/tagebuch/bluetooth-gaia.htm](https://cweiske.de/tagebuch/bluetooth-gaia.htm)).
- Uses: battery/version queries, EQ, ANC settings, button config, TWS pairing,
  and DFU firmware upgrade (`vmupgrade`).

## Framing (from Qualcomm sample source, `GaiaPacketBREDR.java`)
- SOF (0xFF), version, flags (bit0 = checksum present), length, 2-byte
  vendor ID (little-endian; Qualcomm = 0x000A), 2-byte command ID, payload,
  optional checksum.
- Constants: MAX_PACKET = 270, MAX_PAYLOAD = 254, FLAG_CHECK_MASK = 0x01.
- Command IDs are 15-bit + top bit = notification mask; responses echo command
  with status byte. Standard GAIA commands (battery RSSI, API version,
  DFU/upgrade) are common across devices; vendors add their own ranges.

## Open-source implementations (all verified to exist 2026-08)
- [KunYi/droid_gaia_ctrl](https://github.com/KunYi/droid_gaia_ctrl) — **Qualcomm's
  official "GAIA Control" Android sample source** (com.qualcomm.qti.gaiacontrol
  v3.3.0.28): full gaialibrary (BR/EDR + BLE transports) + vmupgradelibrary (DFU).
  This is the reference implementation.
- [qiu-yongheng/GAIAControl](https://github.com/qiu-yongheng/GAIAControl) — BLE GAIA debug tool.
- [Liberations/Flutter-GAIAControl](https://github.com/Liberations/Flutter-GAIAControl) — Dart/Flutter GAIA OTA port (Android/iOS).
- [MarcoLimaSistemas/GAIAEqualizerReactNative](https://github.com/MarcoLimaSistemas/GAIAEqualizerReactNative) — GAIA equalizer over Bluetooth Classic.
- [krishnakorambil-11/Sennheiser-Accentum-SmartControlPlus-Windows](https://github.com/krishnakorambil-11/Sennheiser-Accentum-SmartControlPlus-Windows) — Windows GAIA client for Sennheiser Accentum.
- [pubglite55/SpaceTravel-Protocol](https://github.com/pubglite55/SpaceTravel-Protocol) — full RE of Moondrop Space Travel TWS (GAIA V3 over BLE: ANC, EQ, firmware).
- Nura devices (GAIA + AES layer) — see `nuraphone` note; Nuheara IQbuds —
  already covered in `nuheara-iqbuds`.

## Device sightings (SDP UUID in Linux bug reports, via cweiske.de)
- Libratone Zipp (speaker), KEF MUO (speaker), OnePlus Buds, OnePlus Buds Z2,
  Microsoft Surface Earbuds.
- Plus effectively the whole CSR8670/8675/QCC300x module market: thousands of
  no-name speakers/receivers/earbuds whose vendor apps are abandonware.
  Presence of UUID `00001107-d102-...` in `bluetoothctl info` = GAIA device.

## Abandoned / at-risk relevance
- GAIA is the control channel for many dead-brand gadgets: Nura (defunct 2023,
  separate note), Microsoft Surface Earbuds (discontinued; Surface Audio app
  retired), and the long tail of Kickstarter TWS earbuds on QCC chips.
- For devices where the vendor app is gone, strategy: detect GAIA UUID → open
  RFCOMM → try standard GAIA commands (get API version, battery, DFU) →
  map vendor commands from any surviving APK.
- One-time cloud dependencies are vendor-specific (Nura's key provisioning is
  the documented example), NOT inherent to GAIA.

## Next steps
1. Standalone spec page: GAIA BR/EDR framing + standard command set from
   droid_gaia_ctrl's gaialibrary (all public source).
2. Discovery guide: `bluetoothctl info` / SDP scan for the GAIA UUID.
3. DFU section from vmupgradelibrary (brick-risk warnings).
4. Per-device command tables: Nuraphone (done), Nuheara (done), Surface Earbuds
   (open), Sennheiser Accentum (community repo), KEF MUO / Libratone Zipp (open).

## Open questions
- GAIA versions (V2/V3) differences across chip generations.
- Which QCC51xx devices moved GAIA to BLE-only (dropping RFCOMM entirely).
