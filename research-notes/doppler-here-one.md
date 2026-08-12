# Doppler Labs Here One — Research Notes

## What it is
Here One (2017) true-wireless "smart earbuds" from Doppler Labs: layered/active
listening (real-time ambient sound filtering), noise filters, directional hearing,
music EQ, ANC toggle. Successor to the Kickstarter Here Active Listening System.
~25,000 pairs sold.

## Why abandoned
- Doppler Labs shut down 2017-11-01 after failing to raise further funding
  ([TechCrunch, 2017-11-01](https://techcrunch.com/2017/11/01/smart-earbuds-startup-doppler-labs-shuts-down-after-raising-50m/)).
- Customer support ended 2017-12-01; a final "Here Plus" app was pushed to the App
  Store as a parting gift ([SlashGear, 2017-11-16](https://www.slashgear.com/here-one-earbuds-firm-doppler-labs-has-shut-down-01506342/)).
- No company, no servers, no firmware updates since 2017. Earbuds still work as
  Bluetooth audio devices, but every defining feature (filters, EQ, ANC, world
  volume) requires the app.

## APK provenance
- **Package**: `com.dopplerlabs.hereone` ("Here One")
- **Version**: 1.9.0 — fetched via apkeep (apk-pure source), 2026-08-03
  (apkpure also lists 1.8.2 from 2017-09-19)
- **APK SHA-256**: `2178416b489fdd50e14149192e4e300b56ec38cc1892266a7f239bd0367fcd05`
- **Framework**: Java, Bolts Tasks, Dagger, Otto bus; partly obfuscated but the BLE
  layer (`com.dopplerlabs.here.ble`) and model classes are readable.
- jadx output at `workspace/static/hereone/`; assets at `workspace/static/hereone-assets/`.

## BLE GATT layout
The full GATT table ships as a JSON asset (`assets/staticConfig/attributes/attributes.json`):

- Advertised service: `FE80`; OTA service: `FE7F`.
- **Main service "doppler"** `d973f2e0-b19e-11e2-9e96-0800200c9a66`
  (0800200C9A66 base, same family as TI SensorTag), characteristics
  `d973f2ex-b19e-11e2-9e96-0800200c9a66`:
  - `e2` Biquad (write/notify), `e3` EQ (write/notify), `e4` CodecDebug (rw/notify),
    `e5` printf (read/notify), `e6` DEBUG (rw/notify), `e7` VOLUME (rw/notify, 5 bytes),
    `e9` EFFECTS (rw/notify), `ea` BATTERY_DOPPLER (read/notify, 4 bytes),
    `eb` ONOFF (rw/notify), `ec` RED_EQ (write/notify), `ed` CsrControlCommand (rw/notify).
- Standard services: Device Info `180A` (2A23–2A29), Battery `180F`/`2A19`.

## Command protocol (from `HereBlePayloadGenerator.java`)
20-byte payloads; opcode constants recovered, e.g.:
TOGGLE_SPEAKER_EQ=0, TOGGLE_MIC_EQ=1, TOGGLE_HIGH_SPL=2, TOGGLE_ANC=3,
ADJUST_PGA_GAIN=4, TOGGLE_MIC_INPUT=5, WRITE_TRIM_VALUES=6, WRITE_CODEC_REGISTER=13,
SYSTEM_RESET=18, WRITE_GPP=21, READ_GPP=22, CLEAR_GPP=24,
ENABLE/DISABLE_ADAPTIVE_CONFIG=30/31, DIRECTIONALITY_CONFIG=32/33,
NOISE_REDUCTION_CONFIG=34/35, WRITE_CORRECTIONS_BIQUAD=36, OTA_PACKET=38,
WRITE_GOLDEN_MIC_DATA=39, BYPASS_BLE=40, ANALYTICS_EVENT=41,
DEVICE_STATE_DIGEST_REQUEST=42/RESPONSE=45, ENABLE_MUSIC_EQ=43, SET_MUSIC_EQ_GAIN=44,
NEW_DEVICE_STATE_READY=46, EFFECT_TOGGLE_OFFSET=128.
The `encrypted: true` flags in attributes.json appear to be metadata only — no crypto
code exists in the app layer; writes look plaintext. Verify with one capture.

## Local BLE feasibility
High in principle: everything is direct GATT, no cloud in the connection path
(app had no meaningful cloud service to begin with beyond analytics). The opcode
generator + EQ/biquad model classes give a running start; payload field layout
still needs confirmation via HCI snoop or deeper decompile.

## Prior art
None found. Greenfield, but the in-APK JSON GATT table + opcode table make this one
of the best-documented dead hearables.

## Open questions
- Bonding/pairing requirements; whether both buds are addressed separately
  (`HereOneBud` is per-bud, L/R addressed independently).
- Which characteristic carries the opcode payloads (likely ONOFF/EFFECTS or a
  dedicated target — `TargetIdentifier` enum in model).
- Here Active Listening (Kickstarter gen-1) GATT may differ.

## Safety class
MODERATE — active ambient-sound amplification in-ear (PSAP-adjacent); Doppler was
explicitly not a medical device, but output-level writes deserve care.
