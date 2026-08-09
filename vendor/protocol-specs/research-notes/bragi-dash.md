# Bragi Dash / Dash Pro / The Headphone — Research Notes

## What it is
Bragi GmbH's "hearables": The Dash (2016, Kickstarter ~$3.4M), The Dash Pro (2017),
The Dash Pro tailored by Starkey, and The Headphone. True-wireless earbuds with
optical HR, 9-axis IMU, activity tracking (run/cycle/swim), 4 GB onboard music storage,
and a BLE control/sensor link to the companion app.

## Why abandoned
- Bragi exited the consumer hardware business and sold the hardware unit to an unnamed
  third party on 2019-04-01 ([TechCrunch, 2019-04-01](https://techcrunch.com/2019/04/01/bragi-sells-off-hardware-business-will-focus-on-licenses-and-software/);
  [Voicebot, 2019-04-02](https://voicebot.ai/2019/04/02/bragi-sells-dash-to-continue-focus-on-software/)).
- Bragi pivoted to software licensing (Bragi OS); the Dash line has had no firmware or
  app updates since. App last version 3.2.1 (Android, versionCode 115).
- Devices remain functional as plain Bluetooth earbuds, but all configuration
  (touch controls, head gestures, transparency, EQ) and sensor/activity data require
  the app.

## APK provenance
- **Package**: `com.bragi.thedash.app` ("Bragi" app)
- **Version**: 3.2.1 (versionCode 115) — fetched via apkeep (apk-pure source), 2026-08-03
- **APK SHA-256**: `23926d59e95551e5461f474526f9d3e8dc60569d769289e5cabd3052b8b5746e`
- **Framework**: Java + Kotlin; light obfuscation in `com.bragi.*` (UUID enums intact);
  bundles Mimi hearing SDK (`io.mimi.sdk`), Amazon Alexa, iTranslate hooks.
- jadx output at `workspace/static/bragi/`.

## BLE GATT layout (from `com.bragi.a.c.d/e/g.java`)
UUIDs are constructed from 16-bit codes on the standard BLE base plus two custom
128-bit families:

- Standard services: Battery `180F`/char `2A19`, Device Info `180A` (mfr `2A29`,
  model `2A24`, serial `2A25`, hw `2A27`, fw `2A26`, sw `2A28`), Heart Rate `180D`/`2A37`,
  Running Speed & Cadence `1814`/`2A53`, User Data `181C` (name/email/DoB/gender/
  weight `2A98`/height `2A8E`/language `2AA2`).
- **DATA_EXCHANGE service** `0000fe7b-0000-1000-8000-00805f9b34fb` with
  characteristics on base `3be6316f-XXXX-4695-8c2b-6bb47d83e02f`:
  `-0002` DATA_REQUEST, `-0003` DATA_AVAILABLE, `-0004` DATA_SUBSCRIPTION, `-0005` DATA_WRITE.
  This is the main command/config channel (device-state enum in `com.bragi.a.c.c`:
  STATE_INFORMATION_L/R, NAME, USER_CONFIGURATION, VOLUMES_AND_CONTROLS, EQUALIZER,
  ACTIVITY_STATE, ACTIVITY_MEASUREMENT, HEAD_GESTURE, CALIBRATION_STATUS, TOUCH_LOCK,
  DES_TUNNEL, UI_EVENT, EXTERNAL_ASSISTANT_ACTION, MIMI_*, FEATURE_FLAGS, ...).
- **RAW_MOTION service** `b211d28b-0001-4d53-9555-a8cf7478b7a4` with
  `-0002` ACCELEROMETER, `-0003` MAGNETOMETER, `-0004` GYROSCOPE, `-0005` QUATERNION.
- CCCD `2902`, `2904`; odd codes 0x010D/0x010E also defined (purpose TBD).

## Local BLE feasibility
High. All control paths evidenced in the app are direct GATT operations — no cloud
round-trip in the connection flow. Cloud features (iTranslate translation, Alexa, Bragi
account sync) are optional add-ons. What needs RE: the payload framing written to
DATA_WRITE / returned via DATA_AVAILABLE for each device-state ID (config read/write,
EQ, touch config), and the activity-report download format.

## Prior art
None found (no Gadgetbridge/HA/GitHub driver). Greenfield but the GATT skeleton above
plus the unobfuscated device-state enum make this a tractable HCI-snoop target.

## Open questions
- Does the Dash require an app-level handshake before accepting GATT writes (pairing/bonding)?
- Advertising name pattern (likely contains "Dash"; not confirmed statically).
- Payload framing for DATA_EXCHANGE and RAW_MOTION (multi-packet reassembly?).
- DES_TUNNEL suggests an encrypted tunnel exists for some operations — scope unknown.

## Safety class
LOW — fitness/HR readings are indicative only; in-ear audio volume caution.
