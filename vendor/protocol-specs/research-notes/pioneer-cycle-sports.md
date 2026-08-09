# Pioneer Cycle Sports (SGX-CA500/CA600 + SGY Power Meters) — Research Notes

## What it is
- Pioneer Cycle Sports: SGX-CA500 / SGX-CA600 GPS cycle computers and the SGY-PM900/
  910/930 dual-leg power meter line. Companion Android app: "Cyclo-Sphere Control".
- Covers two device roles: (1) the head units (BLE-configured by app; Wi-Fi/USB sync)
  and (2) the power meters (BLE/ANT+ broadcast sensors, BLE-configurable).

## Why abandoned (dated sources)
- 2020-02: Pioneer exits the market; sales of power meters and cycle computers ceased
  2020-03-31; some assets transferred to Shimano
  ([Bicycle Retailer](https://www.bicycleretailer.com/industry-news/2020/02/04/pioneer-exits-powermeter-market), 2020-02-04).
- 2021-05-24: Pioneer announces Cyclo-Sphere web service termination
  ([Pioneer notice](https://global.pioneer/en/support/oshirase_etc/cycle/info210524.php));
  service ended **2021-06-18** with a forced migration to Shimano's platform
  ([DC Rainmaker](https://www.dcrainmaker.com/2021/06/pioneers-computers-possible.html), 2021-06-10;
  [Pioneer FAQ](https://global.pioneer/en/support/oshirase_etc/cycle/faq/210524.php)).
- The successor, **Shimano Connect Lab, itself ends 2027-03-31**
  ([cycling-review.net](https://www.cycling-review.net/92/shimano-connect-lab-to-replace-pioneer-cyclo-sphere/)),
  so even migrated users face a second shutdown.
- Cyclo-Sphere Control app is delisted from Google Play (checked 2026-08-04); last
  version 1.9.3 (built 2022-10), still on APKPure mirrors.

## Local BLE feasibility
- **Power meters**: broadcast standard ANT+ and BLE. BLE side exposes the standard
  Bluetooth SIG **Cycling Power Service (0x1818)** — readable by any head unit or
  phone with zero vendor cloud. Zero-offset calibration is a standard CPS control-
  point write. Nothing is cloud-dependent for day-to-day use. Pedaling-force-vector
  metrics are Pioneer-proprietary extensions (only shown by Pioneer head units/app).
- **Head units (SGX-CA500/CA600)**: work standalone; record FIT to internal storage,
  export via USB mass storage / Wi-Fi. The app configures Wi-Fi, pages, sensors, maps
  and firmware over BLE — with the app delisted and the cloud dead, new BLE
  configuration requires RE of that GATT channel (or using the head unit's own menus).
  Firmware updates were delivered via cloud + app; the CA600 could also update over
  Wi-Fi. No community RE located.

## APK Provenance
- **Package**: `jp.pioneer.cyclesports.devicecontrol` ("Cyclo-Sphere Control")
- **Version**: 1.9.3 (versionCode 19216), APK internal build date 2022-10-07
- **Source**: apkeep, apk-pure mirror, 2026-08-04
- **SHA-256**: `6752afc0e09e1dc38bb33467458b66398282a29ef7c17555e9d6f1f4e9ef8e7f`
- jadx to `workspace/static/pioneer-cyclosphere/`. **Xamarin.Forms app** — BLE logic
  is in .NET IL (`assemblies/DeviceApp.dll`, `DeviceApp.Android.dll`) using
  Plugin.BLE + Nordic DFU library, not in DEX.

## BLE UUIDs
- **Not recovered** in the cheap static pass: GATT UUIDs live in Xamarin IL, not as
  plain strings in the DLLs (checked UTF-16/ASCII string heaps — nothing). Needs
  ILSpy/dotPeek on `DeviceApp.dll` (~10-30 min) or an HCI snoop against a CA600.
- Standard services expected on the power meters: Cycling Power 0x1818, Battery 0x180F,
  Device Info 0x180A, plus Nordic DFU for firmware.

## What needs cloud
- Ride upload/analysis (Cyclo-Sphere → dead; Shimano Connect Lab → dies 2027-03-31),
  map downloads, firmware distribution, initial account/wizard setup.
- Not needed: recording rides, FIT export (USB), sensor pairing on-device, power meter
  broadcast data and zero-offset via standard CPS.

## Open questions
- CA600 GATT UUID map (extract `DeviceApp.dll` with ILSpy — likely quick).
- Whether the CA600 Wi-Fi sync speaks plain WebDAV/HTTP (FIT push) that can be
  self-hosted; traffic capture needed.
- Force-vector proprietary BLE characteristics on SGY power meters.
- safety_class: LOW (fitness telemetry only).
