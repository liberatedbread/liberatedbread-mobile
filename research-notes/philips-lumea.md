# Philips Lumea (IPL) — Research Notes

## What This Is

Philips Lumea is the other big home-IPL family. Companion app: **Philips
Lumea IPL** (`com.philips.platform.lumea`), analyzed at the current 6.x build.

Headline finding: **the current Lumea app contains no Bluetooth code at all.**
Zero Bluetooth permissions in the manifest; no GATT, scan, or socket usage
anywhere. Philips dropped the old Bluetooth link (Lumea Prestige BRI95x era,
app ≤5.x) — the 9900-series "real-time smart features" are delivered by the
**phone's camera and microphone** watching/listening to the treatment, plus an
on-device TensorFlow Lite flash-counting model downloaded from the cloud.

Consequences:

- **The device is fully standalone and never locked.** Intensity, skin sensor,
  flashing: all on-device, no radio involved.
- There IS an "unlock" — but it gates **app features**, not the device: SkinAI
  features (flash counter, skin analysis) unlock by scanning a QR code on the
  device handle or entering its serial number, validated **server-side**
  against a Philips anti-counterfeit API (`apps.api.it.philips.com`, token via
  `login.microsoftonline.com`). Nothing is written to the device. Offline
  bypass is not applicable — the gated features themselves (cloud ML model
  download, image-upload hair analysis) are inherently cloud features.
- Guest mode exists; account (Philips IAM OAuth) optional. Zuora subscription
  code is present but only displays Try&Buy (device rental plan) status — **no
  paywall on device or app features**.

## Transport

- None between app and device (current app). Camera + mic are the "link".
- Historical: Lumea Prestige BRI95x had BLE with the ≤5.x app; that protocol
  is NOT in this build. If ever needed, decompile an old APK version.

## Feasibility

- Nothing to liberate on the device side — a Lumea never phones home and never
  locks. Replacement-app scope would be reimplementing coaching/scheduling,
  which is generic app work, not protocol RE.

## Evidence

- App: Philips Lumea IPL 6.x (`com.philips.platform.lumea`, APKPure via
  apkeep, 2026-08-29). Decompile: `~/research/ipl/static/lumea/` (not
  committed).
- The 128-bit UUIDs visible in dex strings are false positives (ANTLR
  serializer constants, androidx.work marker, OAuth redirect scheme, Zuora
  client id, HSDP config key) — verified by usage context.

## Open questions

- If a BRI95x Prestige ever becomes a target: fetch Lumea app ≤5.x and RE its
  BLE protocol separately.
