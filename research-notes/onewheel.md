# Onewheel (Future Motion) — BLE Research Notes

## What it is
Future Motion's self-balancing single-wheel boards: Onewheel V1, +, +XR, Pint, Pint X,
GT, GT S-Series, XR Classic. Companion app: "Onewheel" (com.rideonewheel.onewheel).

## Cloud status — vendor alive but account-gated and hostile (cloud-at-risk)
- Future Motion is alive and selling (GT S-Series, Rally XL, XR Classic as of 2026),
  so this is an *at-risk / anti-owner* target rather than a dead one.
- The app requires an account and **internet access for board activation**
  ([support.onewheel.com "Issues With the Onewheel App"](https://support.onewheel.com/hc/en-us/articles/4406703863191-Issues-With-the-Onewheel-App)).
  Firmware updates (including the CPSC-recall "haptic buzz" update,
  [onewheel.com recall notice](https://onewheel.com/blogs/news/onewheel-cpsc-recall-haptic-buzz))
  are pushed via the app/cloud.
- Future Motion issued DMCA takedowns against the original **rewheel** community
  firmware tool; development continues in forks ([non-bin/rewheel](https://github.com/non-bin/rewheel))
  and guides ([fixmypev.com/diy/onewheel/rewheel](https://www.fixmypev.com/diy/onewheel/rewheel/)).
  Expect legal hostility toward RE artifacts — keep derived-facts-only documentation.

## Local BLE feasibility — HIGH (proven by multiple independent clients)
- Boards expose a single custom GATT service; telemetry and settings work offline.
  Third-party clients: [ponewheel/android-ponewheel](https://github.com/ponewheel/android-ponewheel) (open-source Android),
  [OnewheelCommunityEdition/OWCE_App](https://github.com/OnewheelCommunityEdition/OWCE_App),
  [TomasHubelbauer/onewheel-web-bluetooth](https://github.com/TomasHubelbauer/onewheel-web-bluetooth) (Web Bluetooth),
  rewheel (firmware patching over BLE, incl. GT-S unlock work in OWCE issue #121).
- Newer firmware requires writing a static 20-byte token to the serial-write
  characteristic on connect (and every ~15 s as keep-alive) before characteristics
  return real values — documented in ponewheel issues #86/#109 and OWCE issue #121.
  The token is a constant embedded in the stock app, so no cloud is involved.

## BLE map — service `e659f300-ea98-11e3-ac10-0800200c9a66` family
UUIDs confirmed present in the official APK DEX (string scan of
com.rideonewheel.onewheel v2.6.18): the full `e659f307`–`e659f31f` + `e659f3fe`/`e659f3ff`
range. Roles from prior art (ponewheel / onewheel-web-bluetooth / OWCE):
| UUID suffix | Role |
|---|---|
| e659f300 | main service |
| e659f3fe | UART serial read (notify) |
| e659f3ff | UART serial write (20-byte unlock token + keep-alive) |
| e659f307–e659f31c | telemetry/settings characteristics (battery, odometer, speed, ride mode, firmware, serial, pitch/roll — exact map in ponewheel `BluetoothLeService` / OWCE sources) |

## APK provenance
- Package `com.rideonewheel.onewheel` ("Onewheel", v2.6.18, Sep 2023 — per apkpure.net)
- apkeep (apk-pure), XAPK 161,165,600 bytes
- XAPK SHA-256: `08dcdfc4e4d472aa14cda6915225e2582700b4da7f7fbcbd7aa536ed510ccc66`
- Static pass: string-level only (UUID family confirmed); the app is a large
  React-Native-style bundle — full characteristic-name mapping is better taken from
  the open-source clients than from the bundle.

## What needs cloud
- Initial activation of a new board (internet round-trip) — the cloud-brick risk if FM folds.
- Firmware update delivery. Rider leaderboard/social features.
- Day-to-day telemetry, ride modes, custom shaping, and rewheel patching: all local BLE.

## Open questions
- Can a never-activated board be activated offline (token + activation frame replay)?
  Highest-value question for the "FM shuts down" scenario.
- GT/GT-S protocol deltas vs XR/Pint (OWCE issue #121 documents the token flow on GT-S).
- Whether FM rotates the static token in future firmware.

## Safety
Self-balancing vehicle; nosedive injury history (CPSC recall). Shaping/mode writes and
firmware patching are safety-relevant. safety_class: HIGH.
