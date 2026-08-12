# Sphero Classic (1.0 / 2.0 / SPRK) — Research Notes

## What it is
The original Orbotix/Sphero rolling-ball robots: **Sphero 1.0** (2011), **Sphero 2.0** (2013), **Sphero SPRK Edition** (2015, Sphero 2.0 hardware in a clear shell). These are the **Bluetooth Classic (BR/EDR) SPP** generation — everything after (SPRK+, BB-8, Ollie, Mini, BOLT, RVR) is BLE and out of scope here (BB-8 line covered in `sphero-bb8`).

## Why it is abandoned / at-risk
- Sphero Inc. is alive but pivoted entirely to education; the whole consumer/legacy line is unsupported. The original apps ("Sphero" `com.orbotix.sphero`, "MacroLab" `com.orbotix.macro`, "Draw N' Drive" `com.orbotix.drawndrive`) are gone from Google Play — apkeep against APKPure (2026-08-03) returns an **empty version list** for all three; only `com.orbotix.spherocam` ("Sphero Cam", v1.2.1) is still mirrored.
- No cloud dependency ever existed for control — the ball is a plain SPP serial peer. Loss of the apps does not brick the hardware.

## Local Bluetooth Classic feasibility: EXCELLENT (confirmed)
- SPP UUID `00001101-0000-1000-8000-00805F9B34FB` confirmed in `com.orbotix.spherocam` v1.2.1 DEX (`orbotix/robot/internal/DeviceConnection.java:69`), connected via `createRfcommSocketToServiceRecord` (RFCOMM channel 1).
- Advertising name pattern `Sphero-XXX` (3-letter color code). Pairing is legacy/SSP; Linux bluez connects directly over RFCOMM (see sphero-linux-api).
- **Vendor published the protocol**: Orbotix "Sphero API" docs (e.g. `Sphero_API_1.20.pdf`, plus Locator, Collision-detection, Macros, orbBasic, Shell-commands references; S3 links preserved in [slock83/sphero-linux-api](https://github.com/slock83/sphero-linux-api) README). Packet format per [sphero_ros API doc](http://mmwise.github.io/sphero_ros/api.html) and sdk.sphero.com api-documents:
  - Command: `SOP1=0xFF, SOP2 (0xFF=answer / 0xFE=no answer), DID, CID, SEQ, DLEN, data..., CHK`
  - Response: `SOP1=0xFF, SOP2=0xFF, MSRP, SEQ, DLEN, data..., CHK`; CHK = bitwise-NOT of the sum of all bytes from DID through end of data.
  - Device IDs: `0x00` Core (ping 0x01, getVersion 0x02, setBluetoothName 0x10, getBluetoothInfo 0x11), `0x01` Bootloader, `0x02` Sphero (setHeading 0x01, setRGB 0x20, roll 0x30, setRawMotors, sensor streaming, macros/orbBasic).
- Community RE / SDKs: [pwnall/sphero-notes](https://github.com/pwnall/sphero-notes) (decompiled Android app; firmware/bootloader notes), [saphero/sphero-hack](https://github.com/saphero/sphero-hack) (dashboard; explicitly lists 1.0/2.0/SPRK as Bluetooth Classic), node `spheron`, Ruby `hybridgroup/sphero`.

## APK provenance
- **Fetched**: `com.orbotix.spherocam` v1.2.1 (versionCode 21), apkeep `-d apk-pure`, SHA-256 `f0ffdc748560a56ea11db700d38328cc99d34962b69623500a49274111393786`. Static pass (jadx) confirmed SPP UUID above.
- **Not fetchable**: `com.orbotix.sphero`, `com.orbotix.macro`, `com.orbotix.drawndrive` (delisted; would need device pull or archive.org).

## Open questions
- SPRK Edition firmware differences vs 2.0 (assumed identical hardware; verify version command response).
- Bootloader protocol spec ("Bootloader Protocol Specification") was never public — pwnall/sphero-notes has partial RE; not needed for normal control.

## Verdict
Document. Zero cloud, vendor-published protocol, mature open-source clients, SPP confirmable from the one surviving APK. Difficulty: trivial with the vendor doc.
