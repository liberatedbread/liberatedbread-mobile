# TrackR (bravo / pixel) — Research Notes

Coin-sized BLE item trackers (CR1616/CR2016, buzzer + button) from TrackR, Inc. — founded as Phone Halo, rebranded to **Adero** in Dec 2018 ([VentureBeat, 2018-12-03](https://venturebeat.com/technology/adero-formerly-trackr-launches-new-smart-tag-system-with-proactive-notifications)), then shut down entirely.

## Why it's abandoned
- Company dead; app and cloud services discontinued **2021-08-15**: "TrackR will no longer be supported on Apple or Android devices after August 15, 2021" ([Geek News Central, 2021-09-22](https://geeknewscentral.com/2021/09/22/farewell-trackr/)). Corroborated by a [kimola report](https://kimola.com/reports/trackr-pixel-unveiling-the-impact-of-app-discontinuation-amazon-en-us-151109) (app discontinued, company shutdown 2021).
- App delisted from Play; mirrors still host it (Uptodown lists `com.phonehalo.itemtracker` up to 4.1.0, Jan 2020 upload).
- Crowd-GPS network is gone forever, but that was always cloud-side; the device-to-phone BLE link is the interesting part and is fully local.

## Local BLE feasibility: HIGH
- Static pass over the companion APK (DEX strings) shows TrackR uses **standard Bluetooth GATT profiles** — no custom crypto visible:
  - `0x1802` Immediate Alert / `0x2A06` Alert Level — the "ring my tracker" feature. Writing 0x01/0x02 to 2A06 should ring any TrackR from any BLE host, no app, no pairing keys (typical for DA14580-class trackers; confirmed-in-app strings: "Immediate alarm START/STOP request received").
  - `0x1803` Link Loss — separation alerts.
  - `0x180F` Battery / `0x2A19`; `0x180A` Device Info / `0x2A26` firmware rev; `0x2A05` Service Changed.
- Hardware prior art: [TrackR Bravo teardown (diystuff.nl, 2024-07)](https://diystuff.nl/embedded/trackr-bravo-teardown/) — PCB/component analysis.
- No known open-source client for TrackR specifically (node-tile exists for Tile — greenfield but trivial given standard profiles).
- TrackR also worked as a "find your phone" button (press tracker → phone rings); the button-to-host path is likely a notify on a custom characteristic or HID — NOT yet identified. Open question.

## APK details
- **Package**: `com.phonehalo.itemtracker`
- **Source**: apkeep, apk-pure (2026-08-03) — downloaded OK
- **SHA-256**: `f3d67324150f1d89dcb57197a654586d812663ba5ef6b964818c6b565b4960ee` (62,885,521 bytes)
- Version: latest available on APKPure (Uptodown shows 4.1.0 as final, Jan 2020); multidex, Kotlin, Mapbox native libs (crowd-GPS maps), Crashlytics. BLE code under `com.thetrackr.ble` / `com.phonehalo.trackr` (TrackrService, TrackrItemAlertManager).
- Triage done via DEX `strings` only — full jadx not needed for the UUID set.

## Open questions
- Which characteristic carries the tracker's button-press event (reverse ring)?
- Whether newer Adero-era tags use the same GATT (Adero "smart tags" were a different, org-based system — likely out of scope).
- Advertising name prefix not yet extracted (scan filter builds `BluetoothLeScanFilter` with mDeviceName — needs one jadx look or an HCI scan; candidate names: "TrackR bravo", "TrackR pixel").
- Battery: bravo = CR1616, pixel = CR2016 (verify per model).

## Sources
- https://geeknewscentral.com/2021/09/22/farewell-trackr/ (shutdown, 2021)
- https://venturebeat.com/technology/adero-formerly-trackr-launches-new-smart-tag-system-with-proactive-notifications (Adero rebrand, 2018)
- https://kimola.com/reports/trackr-pixel-unveiling-the-impact-of-app-discontinuation-amazon-en-us-151109
- https://trackr.en.uptodown.com/android (package id + version history)
- https://diystuff.nl/embedded/trackr-bravo-teardown/ (hardware, 2024)
