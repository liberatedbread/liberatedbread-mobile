# FlowMotion ONE — Research Notes

## What it is
FlowMotion ONE: 3-axis motorized smartphone gimbal stabilizer from FlowMotion
Technologies AS (Oslo, Norway). Kickstarter late 2016 (~$600k+), shipped 2017–2018.
App-controlled over BLE: joystick/virtual joystick, stabilization modes, motion
timelapse (multi-point), panoramas, auto-follow, firmware updates.

## Why abandoned
- Company filed for bankruptcy; CEO letter said no refunds and no further shipments
  ([CineD, edit dated 2019-07-01](https://www.cined.com/flowmotion-smartphone-gimbal-delayed-shipments/)).
- flowmotion.co is gone; no firmware/app updates since v1.4.1.release (vc 25).
- The gimbal stabilizes standalone (hardware buttons), but mode configuration,
  motion timelapse, panorama and virtual joystick all require the app.

## APK provenance
- **Package**: `co.flowmotion.android.flowmotion` ("FlowMotion App")
- **Version**: 1.4.1.release (versionCode 25) — fetched via apkeep (apk-pure) as XAPK, 2026-08-03
- **XAPK SHA-256**: `958371fb1a78c3481bec586b87f5b5a54e204517d76b5dda2483a48142fdf830`
- **Framework**: Kotlin, RxAndroidBle (Polidea), Dagger, kotlinx.serialization;
  protocol module `co.flowmotion.bluetooth.protocol` is essentially unobfuscated.
- jadx output at `workspace/static/flowmotion/`.

## BLE GATT layout (from `BTLEServices.java` / `BTLECharacteristics.java`)
UUID pattern: `B11C%04X-672A-8DAB-F442-A0DAB5063A98` ("fmCharacteristic").

- **Service FLOWMOTION** `b11c0001-672a-8dab-f442-a0dab5063a98`
- Characteristics:
  - `b11c0002-...` STATE (device state)
  - `b11c0003-...` SYSTEM_EVENT, `b11c0004-...` SYSTEM_LOGGER
  - `b11c0005-...` RECORDING_STATE
  - `b11c0006-...` JOYSTICK, `b11c0102-...` VIRTUAL_JOYSTICK
  - `b11c0007-...` BUTTON_EVENT, `b11c0008-...` BALANCING
  - `b11c0009-...` BOOTLOADER_VERSION
  - `b11c0101-...` STABILIZATION_MODE, `b11c0103-...` ON_MODE_CHANGE
  - `b11c0104-...` ORIENTATION, `b11c0110-...` CAMERA_BASE_ATTITUDE
  - `b11c0111-...` TIME_LAPSE_POINTS, `b11c0112-...` TIME_LAPSE_POINT_DETAILS
  - `b11c0113-...` PANORAMA
- DFU service: standard Nordic Secure DFU `0000fe59-0000-1000-8000-00805f9b34fb`
- Standard chars: Battery `2A19`, Serial `2A25`, FW rev `2A26`, SW rev `2A28`.

## Protocol notes
Payloads are kotlinx.serialization structures (`@Packed` annotation, `Vec3D`,
endpoint classes `FMControlEndpoint`, `FMSystemEndpoint`, `FMDeviceInfoEndpoint`,
`FMBatteryEndpoint`; message types: GimbalMode, StabilizationMode, GimbalOrientation,
Joystick, VirtualJoystick, TimeLapsePoint, PanoramaPoint, BalanceState, DeviceState,
RecordingState, SystemEvent...). The serialization format (custom packed binary vs
ProtoBuf/CBOR) is the main thing to pin down — `SerializerExtKt` + `Packed` suggest
a compact custom binary framing. No cloud anywhere in the control path; app uses
HTTP only for analytics/Crashlytics.

## Local BLE feasibility
Very high. A clean, enumerated GATT table with named message types; the app is the
only controller ever shipped. This is arguably a complete spec waiting to be
transcribed — deeper decompile of `co.flowmotion.bluetooth.protocol` yields the
full message set without any hardware capture.

## Prior art
None found. Greenfield.

## Open questions
- Exact binary framing (`@Packed` serialization) — readable from `SerializerExtKt`.
- Advertising name pattern (likely "FlowMotion" / "FM ONE"; not confirmed).
- Auto-follow (phone-vision) is app-side and does not affect gimbal control RE.

## Safety class
LOW — small motorized gimbal; joystick writes move motors (pinch/balance only).
