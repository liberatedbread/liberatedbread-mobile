# 94Fifty Smart Sensor Basketball — Research Notes

## What it is
94Fifty Smart Sensor Basketball (InfoMotion Sports Technologies, 2013, ~$300): the first
smart basketball. Nine in-ball sensors (accel/gyro/magnetometer) sampled by an onboard DSP
at ~6,000 pts/s; shot arc, backspin, dribble force/speed classified in-ball and streamed
over Bluetooth (TI dual-mode SoC) to the "94Fifty Basketball" app.
[Design News](https://www.designnews.com/gadget-freak/smart-basketball-analyzes-shooting-dribbling),
[engineering.com](https://www.engineering.com/fire-the-coach-94fifty-basketball-uses-sensors-to-measure-basketball-skills/).

## Why it is abandoned
- InfoMotion Sports Technologies filed for Chapter 11 bankruptcy protection
  ([American Bankruptcy Institute feed](https://www.abi.org/feed-item/maker-of-%E2%80%98smart%E2%80%99-basketball-files-for-bankruptcy-protection);
  WSJ, "Maker of 'Smart' Basketball Files for Bankruptcy Protection" — exact filing date
  TBD, mid-2010s). Company is defunct; 94fifty.com is gone.
- App removed from stores; single Android version 1.4 survives on mirrors
  ([APKPure](https://apkpure.net/tw/94fifty%C2%AE-basketball/com.spectrumdt.ist/versions)).
- Package name `com.spectrumdt.ist` (Spectrum was the dev shop; IST = InfoMotion Sports Tech).

## Local BLE feasibility
- All skill classification is on the ball's DSP; the app is a display/coaching shell.
  Core function is inherently local — no cloud needed for metrics.
- Dex shows a structured protocol layer: `com/_94fifty/protocol/ProtocolInfo` and
  BLE classes (`BleDirectAdvertisingTestRequest`, `BluetoothDeviceBridge`).
- **No UUID literals in dex strings** — GATT/SPP identifiers are likely built from byte
  arrays in code. One stray UUID literal: `32e5fcfc-52ee-41b0-827a-f18929716fef` (role TBD).
- Ball used a TI dual-mode (classic + BLE) SoC, so Android may use classic SPP rather
  than BLE GATT — check jadx for `createRfcommSocket` vs `connectGatt`.

## APK details (apkeep, apk-pure)
- Package: `com.spectrumdt.ist`, version 1.4 (only version on mirror)
- SHA-256: `dbf839265ca16a4edee78815854610d774a2d2934e5b3df01514733ad1b91415`

## Open questions
- BLE GATT vs classic SPP for the Android path (determines repo fit: BLE vs BR/EDR).
- Whether the app gates drills behind an account server (dead) — and if practice mode
  works offline in v1.4.
- Very old app (2015-era, API ~19): verify it still runs on modern Android.
