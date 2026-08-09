# Motorola VerveOnes / VerveRider / VerveLoop (VerveLife) — Research Notes

Date researched: 2026-08-03. Researcher: BT-Classic audio swarm.

## Verdict
**CONFIRMED GAIA + SPP local control exists; app is cloud-flavored.** The
VerveLife/Motorola wireless audio line (VerveOnes, VerveOnes+, VerveOnes ME,
VerveRider, VerveLoop — 2016–2019, made under license by Binatone/Hubble) is
controlled locally over Bluetooth Classic: the app bundles CSR's GAIA library
and an Airoha SPP stack (different chip generations across models). App was
unpublished from Google Play 2024-10-15. Device settings (EQ etc.) are local;
the Hubble cloud account layer (device locator, check-in) is dead weight.

## Cloud / company status
- "Hubble Connect for VerveLife" (`com.hubbleconnected.vervelife`) was
  **unpublished from Google Play on 2024-10-15**
  ([AppBrain app stats](https://www.appbrain.com/app/hubble-connect-for-vervelife/com.hubbleconnected.vervelife)).
- Motorola's own support answer confirms the app wanted a **Hubble Connect
  Cloud account** for locator/sharing features
  ([Motorola support, a_id=136689](https://en-us.support.motorola.com/app/answers/detail/a_id/136689/)).
- Motorola mobile-audio licensing via Binatone/Hubble wound down; product pages
  are legacy. Treat the cloud as dead/at-risk; local control unaffected.

## Companion app / APK provenance
- **Package**: `com.hubbleconnected.vervelife` ("Hubble Connect for VerveLife")
- **Version**: 2.00.83 (versionCode 20083)
- **Source**: apkeep, apk-pure
- **APK SHA-256**: `7d46fc1df3089c84408ae586ce5060ebbeaa7b54a77b22ec7505c98d5cb3bd36`
- **Decompiled**: jadx → `$REPO/workspace/static/verveones/`
  (Java, mostly readable; old dagger-injection era code)

## Transport (from static analysis)
- **CSR GAIA**: `com.csr.gaia.android.library.GaiaLink` — GAIA over RFCOMM
  (older CSR-based Verve models). See `qualcomm-gaia-audio-ecosystem` note for
  framing.
- **Airoha SPP**: `com.airoha.android.lib.physical.spp.AirohaSppController` —
  Airoha-chip models (later VerveLoop/VerveOnes ME generations) use vendor SPP
  protocol instead. Airoha's Android "lib" source circulates publicly.
- BLE also present (`BleServiceUuids`, `BleCharacteristicUuids`) — used for
  alerts/locator; out of scope for this note.
- `BtServiceUuids.java` enumerates classic profile UUIDs incl. SPP `00001101`.

## App feature surface
- Native EQ (`NativeEqualizerActivity`, `NativeEqSettingCard`) — device-side,
  almost certainly GAIA/SPP commands.
- Device locator (map of last-connected location) — cloud-dependent, dead.
- Account/check-in/gallery UI — cloud-dependent, dead.

## Next steps
1. Map GAIA vs Airoha per model (chip ID via GAIA get-API-version).
2. Extract EQ command table from `com.hubble.loop` + GAIA/airoha libs.
3. Verify the app runs without login (or patch around it) — protocol itself
   has no auth.
- safety_class: LOW.

## Open questions
- Which Verve model ↔ which chip/transport (needs device or deeper DEX read).
- Hubble backend status (locator features) — irrelevant to local control.
