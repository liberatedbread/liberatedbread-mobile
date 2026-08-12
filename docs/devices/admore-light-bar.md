# AdMore Light Bar Pro

> **Status**: Complete (Protobuf schema fully extracted via blutter Dart AOT disassembly; HCI capture pending for wire format validation)
> **Protocol**: BLE (Nordic UART Service + Protobuf)
> **Manufacturer**: AdMore Lighting Inc.
> **Manufacturer Status**: Active (app-dependent — settings require AdMore Connect app)

## Overview

The AdMore Light Bar Pro is a Bluetooth-enabled motorcycle brake light bar that provides
tail light, brake light, progressive amber turn signals, hazard flasher, and license plate
illumination. The PRO model includes an accelerometer for deceleration-triggered brake light
activation and a BLE interface for configuring settings via the free AdMore Connect app.

The app communicates with the light bar over a **Nordic UART Service (NUS)** BLE profile,
sending **Protocol Buffer (protobuf)** encoded messages. The device runs an nRF-based
chipset with Nordic DFU support for firmware updates.

## Hardware

| Property | Value |
|----------|-------|
| Model | Light Bar Pro (8") |
| SKU | LED8020-BT (clear) / LED8020-BT-SMK (smoked) |
| LEDs | 81 bi-color (red/amber) Cree + 3 center amber strobe + 3 white (plate) |
| Dimensions | 7.9 x 1.3 x 0.7 in (20 x 3.2 x 1.8 cm) |
| Housing | Weatherproof aluminum, powder-coated bracket |
| Voltage | 12V DC (motorcycle electrical system) |
| Wiring | 5-wire: brake, taillight, left signal, right signal, ground |
| Radio | BLE (Nordic nRF-based chipset — exact part TBD via FCC filing) |
| FCC ID | TBD |
| Compatibility | All 12V motorcycles/scooters; CANBUS compatible |
| Origin | Calgary, Alberta, Canada |

## BLE Discovery

| Property | Value |
|----------|-------|
| Advertised Name | `AdMore Light Bar` |
| DFU Mode Name | `AdMore Light Bar DFU` |

Related devices (same app):

| Device | Advertised Name |
|--------|----------------|
| Armband (unprovisioned) | `AdMore Armband` |
| Armband (left) | `AdMore Armband Left` |
| Armband (right) | `AdMore Armband Right` |

## Protocol Summary

### BLE Services — Nordic UART Service (NUS) Variants

The device uses customized variants of the Nordic UART Service. The base UUID follows
the NUS pattern (`6E4000xx-B5A3-F393-E0A9-E50E24DCCAxx`) with different suffixes for
different device types.

#### Light Bar NUS Service

| UUID | Name | Properties | Description |
|------|------|------------|-------------|
| `6E400001-B5A3-F393-E0A9-E50E24DCCA9E` | NUS Service | — | Primary UART service |
| `6E400002-B5A3-F393-E0A9-E50E24DCCA9E` | NUS RX | write, write-no-response | App writes commands here |
| `6E400003-B5A3-F393-E0A9-E50E24DCCA9E` | NUS TX | notify | Device sends responses here |
| `00002902-0000-1000-8000-00805f9b34fb` | CCCD | read, write | Enable/disable TX notifications |

#### Additional NUS Services (other device types)

| UUID Suffix | Likely Device |
|-------------|---------------|
| `...DCCAAE` | Armband |
| `...DCCABE` | Unknown (possibly signals accessory) |
| `...DCCACE` | Unknown (possibly diagnostic) |

### Message Encoding

Messages are serialized using **Protocol Buffers** (protobuf), defined in
`package:messaging_common/build_dart/lightbar.pb.dart`. The protobuf bytes are sent
as a byte stream over the NUS RX characteristic.

The internal message bus uses **KMsg** (`package:messaging_common/kmessaging.dart`) for
source/destination routing between components (app, device, backend, diagnostics).
KMsg uses a publish/subscribe socket pattern:
- `CmdSinkSocket` / `CmdSourceSocket` — command request/response
- `EvtSinkSocket` / `EvtSourceSocket` — event subscriptions
- Reply mechanism: `kmsgCmdSourcePublishReply()` with timeout

### Protobuf Message Schema

Protobuf field numbers and types extracted via blutter (Dart AOT snapshot disassembly,
Dart SDK 3.3.3). Each command message is dispatched by the `e_CMD` enum value.

#### Command Messages (app → device)

| `e_CMD` | Protobuf Type | Field 1 | Field 2 |
|---------|---------------|---------|---------|
| 0 | `t_cmdAppNop` | *(empty)* | |
| 3 | `t_cmdAppInjectEvent` | `e_APP_EVT appEvent = 1` | |
| 4 | `t_cmdAppSetDstEvt` | `e_SKT sktDstEvt = 1` | |
| 5 | `t_cmdAppSetDstEvtDiag` | `e_SKT sktDstEvt = 1` | |
| 6 | `t_cmdAppQuery` | `e_APP_QUERY query = 1` | |
| 7 | `t_cmdAppWriteString` | *(string — no class in snapshot)* | |
| 8 | `t_cmdDssOperation` | `e_DSS_OPERATION operation = 1` | |
| 9 | `t_cmdDssSetData` | `e_CONFIG config = 1` | `int32 setvalue = 2` |
| 10 | `t_cmdDssGetData` | `e_CONFIG config = 1` | |
| 16 | `t_cmdLosSetLight` | `e_LIGHT_OUTPUT setLight = 1` | `bool lightOn = 2` |

#### Response / Event Messages (device → app)

| Protobuf Type | Purpose | Fields |
|---------------|---------|--------|
| `t_cmdAppQuery_Reply` | Query response | `string queryReply = 1` |
| `t_cmdDssGetData_Reply` | Setting read response | `int32 getvalue = 1` |
| `t_evtAppEvent` | State event notification | `e_APP_EVT appEvent = 1` |
| `t_evtDiagMmsDecelData` | Deceleration diagnostic data | `int32 samplePack1 = 1`, `int32 samplePack2 = 2`, `int32 samplePack3 = 3` |

### Protobuf Enums (7) — Complete Values

#### `e_CMD` — Command Type (10 values)

| Value | Name | Message Type |
|-------|------|-------------|
| 0 | `APP_NOP` | `t_cmdAppNop` |
| 3 | `APP_INJECT_EVENT` | `t_cmdAppInjectEvent` |
| 4 | `APP_SET_DST_EVT` | `t_cmdAppSetDstEvt` |
| 5 | `APP_SET_DST_EVT_DIAG` | `t_cmdAppSetDstEvtDiag` |
| 6 | `APP_QUERY` | `t_cmdAppQuery` |
| 7 | `APP_WRITE_STRING` | `t_cmdAppWriteString` |
| 8 | `DSS_OPERATION` | `t_cmdDssOperation` |
| 9 | `DSS_SET_DATA` | `t_cmdDssSetData` |
| 10 | `DSS_GET_DATA` | `t_cmdDssGetData` |
| 16 | `LOS_SET_LIGHT` | `t_cmdLosSetLight` |

#### `e_APP_QUERY` — Query Type (4 values)

| Value | Name |
|-------|------|
| 0 | `SERIAL` |
| 1 | `APP_VERSIONS` |
| 2 | `SYS_VERSIONS` |
| 3 | `HW_VERSIONS` |

#### `e_CONFIG` — Setting ID (19 values)

| Value | Name |
|-------|------|
| 0 | `NULL` |
| 16 | `LOS_PLATE_LIGHT_BRIGHTNESS` |
| 17 | `LOS_TAIL_LIGHT_BRIGHTNESS` |
| 18 | `LOS_BRAKE_LIGHT_BRIGHTNESS` |
| 19 | `LOS_TURN_LIGHT_BRIGHTNESS` |
| 21 | `LOS_BRAKE_FLASH_COUNT` |
| 22 | `LOS_BRAKE_FLASH_TIME_MS` |
| 23 | `LOS_BRAKE_STROBE_DURATION_MS` |
| 26 | `LOS_TURN_LIGHT_SEQUENTIAL_STEP_MS` |
| 31 | `LOS_DEALER_DEMO_MODE` |
| 32 | `MMS_DECEL_OFF_DELAY_MS` |
| 33 | `MMS_DECEL_THRESHOLD` |
| 34 | `MMS_DECEL_COUNT` |
| 36 | `MMS_ENABLE_BRAKE_WHITE_STROBE` |
| 37 | `MMS_ENABLE_TIPOVER` |
| 42 | `LIS_ENABLE_BRAKE_INVERT` |
| 43 | `LIS_ENABLE_TWO_WIRE` |
| 64 | `ARMBAND_SIDE` |
| 96 | `TOTAL_SIZE` |

#### `e_DSS_OPERATION` — DSS Operation (5 values)

| Value | Name |
|-------|------|
| 0 | `DATA_MAINTAIN` |
| 1 | `DATA_FACTORY_DEFAULT` |
| 2 | `DATA_RELOAD` |
| 3 | `DATA_COMMIT` |
| 4 | `DATA_ABANDON_RESTORE` |

#### `e_LIGHT_OUTPUT` — Light Output (21 values)

| Value | Name | Category |
|-------|------|----------|
| 0 | `RESET_LIGHTS` | Control |
| 1 | `TAIL_LIGHT` | Normal |
| 2 | `BRAKE_LIGHT` | Normal |
| 3 | `BRAKE_WHITE` | Normal |
| 4 | `LEFT_TURN` | Normal |
| 5 | `RIGHT_TURN` | Normal |
| 6 | `PLATE_LIGHT` | Normal |
| 7 | `BLUE_LIGHT` | Normal |
| 10 | `OVERRIDE_TILTOVER` | Override |
| 11 | `OVERRIDE_HAZARD` | Override |
| 12 | `OVERRIDE_DEMO` | Override |
| 13 | `OVERRIDE_PROCESSION` | Override |
| 16–24 | `TEST_*` | Test (9 values) |

#### `e_APP_EVT` — App Event (37 values)

| Value | Name | Category |
|-------|------|----------|
| 0–4 | `STARTUP`, `QUERY_STATE`, `SOFT_RESET`, `ENTER_DFU` | System |
| 16–22 | `KMSG_BLE_*` | BLE connection events |
| 26–31 | `KMSG_BLE_ARMBAND_*`, `KMSG_BLE_SIGNALS_*` | Accessory events |
| 48–55 | `MMS_*` | Motion/deceleration events |
| 56–63 | `LIS_*` | Light input events |
| 128–129 | `BTN_DOWN`, `BTN_UP` | Button events |
| 144–145 | `ENTER_SLEEP`, `EXIT_SLEEP` | Power events |

#### `e_SKT` — Socket/Routing (35 values)

| Range | Names | Purpose |
|-------|-------|---------|
| 0 | `SRC_UNASSIGNED` | Default/unset |
| 16–19 | `*_BKND_*` | Backend routing |
| 24–26 | `*_BLE_ENGINE*` | BLE engine routing |
| 32–35 | `*_HOST_*` | Host routing |
| 64–76 | `*_APP*`, `*_UART_DIAG` | App routing |
| 80–94 | `*_ARML`, `*_ARMR` | Armband routing |
| 240–243 | `*_KMSG` | KMsg internal routing |

### Settings Commands

All settings are defined in `lb_config.xml` (Flutter asset). Each setting has an ID string
and discrete allowed values. Settings are sent to the device as protobuf messages over NUS.

#### Light Output Settings (LOS)

| Setting ID | Label | Type | Values |
|-----------|-------|------|--------|
| `LOS_TAIL_LIGHT_BRIGHTNESS` | Tail Light Brightness | discrete | OFF=0, 1=200, 2=400, 3=1000, 4=1500, 5=2000 |
| `LOS_BRAKE_LIGHT_BRIGHTNESS` | Brake Light Brightness | discrete | 6=5000, 7=5500, 8=6000, 9=6500, 10=7000 |
| `LOS_BRAKE_FLASH_COUNT` | Brake Flash (Count) | discrete | OFF=0, 2, 4, 6, 8, 10 |
| `LOS_BRAKE_FLASH_TIME_MS` | Brake Flash (Speed) | discrete | 1=50ms, 2=40ms, 3=30ms, 4=20ms, 5=10ms |
| `LOS_BRAKE_STROBE_DURATION_MS` | Amber Strobe (Brake) | discrete | OFF=0, 5s=5000, 10s=10000, 15s=15000, 20s=20000, ON=-1 |
| `LOS_PLATE_LIGHT_BRIGHTNESS` | Plate Light | toggle | ON=8000, OFF=0 |
| `LOS_TURN_LIGHT_SEQUENTIAL_STEP_MS` | Sequential Turn Signal | toggle | ON=30, OFF=0 |
| `LOS_TURN_LIGHT_BRIGHTNESS` | Turn Light Brightness | discrete | (not in lb_config.xml — internal/runtime use only) |
| `LOS_SET_LIGHT` | Set Light (direct) | — | (direct LED control via `sendLightOutput()` / `sendBarTest()`) |
| `LOS_DEALER_DEMO_MODE` | Demo Mode | toggle | ON=1, OFF=0 (firmware version ^1+) |

#### Motion Management Settings (MMS)

| Setting ID | Label | Type | Values |
|-----------|-------|------|--------|
| `MMS_DECEL_TOGGLE` | Accelerometer Sensor | toggle (native) | ON=1, OFF=0 |
| `MMS_DECEL_THRESHOLD` | Deceleration Sensitivity | discrete | OFF=0, 1=4000, 2=3920, ..., 50=80 (51 levels, step -80) |
| `MMS_DECEL_OFF_DELAY_MS` | Deceleration Light Delay | discrete | 1s=1000, 1.5s=1500, 2s=2000, 2.5s=2500, 3s=3000 |
| `MMS_DECEL_COUNT` | Deceleration Duration | discrete | 5–40 (integer) |
| `MMS_ENABLE_BRAKE_WHITE_STROBE` | Amber Strobe on Deceleration | toggle | ON=1, OFF=0 |
| `MMS_ENABLE_TIPOVER` | Tip Over Flash | toggle | ON=1, OFF=0 |

#### Light Input Settings (LIS)

| Setting ID | Label | Type | Values | Notes |
|-----------|-------|------|--------|-------|
| `LIS_ENABLE_BRAKE_INVERT` | Input Brake Invert | toggle | ON=1, OFF=0 | Firmware ^1+. For bikes where brake signal is inverted. |
| `LIS_ENABLE_TWO_WIRE` | Two Lamp Mode | toggle | ON=1, OFF=0 | Firmware ^1+. For bikes without dedicated brake signal. |

### Override / Special Modes

| Command | Description |
|---------|-------------|
| `OVERRIDE_HAZARD` | Activate hazard flasher |
| `OVERRIDE_PROCESSION` | Activate procession mode (amber wig-wag for group riding) |
| `OVERRIDE_DEMO` | Activate demo mode |
| `OVERRIDE_TILTOVER` | Activate tilt-over mode |

### System Commands

| Command | Description |
|---------|-------------|
| `APP_QUERY` | Query current device state |
| `APP_VERSIONS` | Query app version info |
| `APP_NOP` | No-op / keepalive |
| `HW_VERSIONS` | Query hardware version |
| `SYS_VERSIONS` | Query system/firmware version |
| `MMS_QUERY_INFO` | Query motion sensor info |
| `DATA_FACTORY_DEFAULT` | Reset all settings to factory defaults |
| `DATA_COMMIT` | Save/commit current settings |
| `DATA_RELOAD` | Reload settings from storage |
| `DATA_MAINTAIN` | Enter maintenance mode |
| `DATA_ABANDON_RESTORE` | Cancel restore operation |
| `SOFT_RESET` | Soft reset device |
| `ENTER_DFU` | Enter firmware update (DFU) mode |
| `ENTER_SLEEP` | Enter sleep mode |
| `RESET_LIGHTS` | Reset all light outputs |

### Test Commands

| Command | Description |
|---------|-------------|
| `TEST_BRAKE_LIGHT_LEFT` | Test left brake LEDs |
| `TEST_BRAKE_LIGHT_RIGHT` | Test right brake LEDs |
| `TEST_BRAKE_LIGHT_CENTER` | Test center brake LEDs |
| `TEST_BRAKE_WHITE` | Test white (plate) LEDs |
| `TEST_LEFT_TURN` | Test left turn signal |
| `TEST_RIGHT_TURN` | Test right turn signal |
| `TEST_PLATE_LIGHT` | Test plate light |
| `TEST_BLUE_LIGHT` | Test blue diagnostic light |
| `TEST_RESET_LIGHTS` | Reset all test lights |

### State Events (device → app)

These are reported by the device via the NUS TX characteristic:

| Event | Description |
|-------|-------------|
| `LIS_BRAKE_ON` / `LIS_BRAKE_OFF` | Physical brake switch state |
| `LIS_LEFT_ON` / `LIS_LEFT_OFF` | Left turn signal state |
| `LIS_RIGHT_ON` / `LIS_RIGHT_OFF` | Right turn signal state |
| `LIS_PWM_ON` / `LIS_PWM_OFF` | PWM output state |
| `MMS_DECEL_ON` / `MMS_DECEL_OFF` | Deceleration detected / cleared |
| `MMS_MOTION_ON` / `MMS_MOTION_OFF` / `MMS_MOTION_STOP` | Motion state |
| `MMS_TILT_DOWN` / `MMS_TILT_UPD` | Tilt detection |

### Connection Flow

1. **Scan**: `startScan()` with name filter `"AdMore Light Bar"` or `"AdMore Armband"`
2. **Connect**: `autoConnect` supported; establishes GATT connection
3. **Service Discovery**: `discoverServices()` → find NUS service UUID
4. **UART Open**: `openUart()` on `BleUartDevice` → subscribe to TX notifications via `setNotifyValue`
5. **Query**: `_queryLightbar()` → `getLightbarData()` → parse protobuf response
6. **Ready**: `KMSG_BLE_CONNECT_READY` event signals device is ready for commands
7. **Reconnect**: On disconnect → `RECONNECTING` state → retry with delay

### Device State Machine

The device controller tracks 19 states:

```
INITIAL → STARTUP → SEARCHING → CONNECT → SETUP_DONE → IDENTIFY → SERIAL → QUERY_STATE → SETTINGS
                       ↓                                                                      ↓
                  SEARCH_FAIL                                                               SAVING
                       ↓                                                                      ↓
                  RECONNECTING → RECONNECT_FAIL                                          PROCESSING
                                                                                              ↓
                                                                                         VERIFYING
                                                                                              ↓
                                                                                       TRANSFERRING
                                                                                              ↓
                                                                                       TRANSFER_FAIL
                                                                                              ↓
                                                                                        DISCONNECT
                                                                                              ↓
                                                                                        EXIT_SLEEP
```

### Version Reporting

The device reports version info via query commands with these fields:

| Field | Description | Query |
|-------|-------------|-------|
| `productFirmware` | Firmware version | `SYS_VERSIONS` |
| `productFirmwareBeta` | Beta firmware version | `SYS_VERSIONS` |
| `productBootloader` | Bootloader version | `SYS_VERSIONS` |
| `productSystem` | System/OS version | `SYS_VERSIONS` |
| `productDatabase` | Settings database version | `SYS_VERSIONS` |
| `productModel` | Hardware model | `HW_VERSIONS` |
| `productId` | Unique device ID | `HW_VERSIONS` |

### Firmware Update (DFU)

| Property | Value |
|----------|-------|
| DFU Library | Nordic DFU (`dev.steenbakker.nordic_dfu`) |
| DFU Trigger | Send `ENTER_DFU` command |
| DFU Device Name | `AdMore Light Bar DFU` |
| Firebase Project | `admore-light-bar-with-ble` |
| Storage Bucket | `admore-light-bar-with-ble.appspot.com` |
| Firmware Path | `lightbar-firmware/` |
| Debug Firmware | `/debug/dfu_lightbar_latest.zip` |
| Version Check | `getLatestLightbarVersion()` |
| DFU States | INITIAL → PROCESSING → VERIFYING → TRANSFERRING → success/TRANSFER_FAIL |

### Armband Protocol

The app supports AdMore Armband turn signal accessories:

| Property | Value |
|----------|-------|
| NUS Service UUID | `6E400001-B5A3-F393-E0A9-E50E24DCCAAE` |
| Types | `LEFT`, `RIGHT`, `UNDEFINED` (`ArmbandType` enum) |
| Provisioning Command | `ARMBAND_SIDE` |
| Routing (Left) | `SRC_CMD_APP_ARML` → `DST_CMD_APP_ARML` |
| Routing (Right) | `SRC_CMD_APP_ARMR` → `DST_CMD_APP_ARMR` |

Provisioning flow:
1. Scan for `"AdMore Armband"` (unprovisioned)
2. Connect and mark as Left or Right via `setArmbandSide`
3. App disconnects automatically; armband renames to `"AdMore Armband Left"` or `"AdMore Armband Right"`
4. User puts armband in reset mode (USB cable)
5. Rescan to verify correct provisioning

### Firebase Backend

| Property | Value |
|----------|-------|
| Project ID | `admore-light-bar-with-ble` |
| Database URL | `https://admore-light-bar-with-ble.firebaseio.com` |
| Storage Bucket | `admore-light-bar-with-ble.appspot.com` |
| Uses | Firmware distribution, user accounts, device registration, diagnostic upload |
| Diagnostic Paths | `diagnostics/accel/`, `accel_diag/` |
| Required for control? | No — device control is fully local over BLE |

### Config System

Settings are defined in `lb_config.xml` (Flutter asset, 18 settings). Three setting types:

| Type | Parser | Description |
|------|--------|-------------|
| Discrete | `_parseDiscrete()` | Finite set of labeled value options |
| Toggle | `_parseToggle()` | Binary on/off with explicit on/off values |
| Continuous | `_parseContinuous()` | Range with divisor and updates (not used in current config) |

Special setting behaviors:
- **NativeSetting** (`isnative=true`): Stored as app preference, not sent to device. Controls UI visibility. Example: `MMS_DECEL_TOGGLE`
- **Dependent settings** (`<dependent to="...">`): Hidden when parent is OFF. Example: `MMS_DECEL_THRESHOLD` depends on `MMS_DECEL_TOGGLE`
- **Version-gated** (`<version value="^1">`): Only shown for firmware ≥ v1. Example: `LIS_ENABLE_BRAKE_INVERT`

## Tools Used

- [x] apkeep — APK download (v0.18.0, source: APKPure, XAPK format)
- [x] `strings` + `readelf` — Dart AOT snapshot (libapp.so) analysis
- [x] `unzip` — XAPK/APK extraction, lb_config.xml extraction
- [x] ELF analysis — snapshot structure (_kDartIsolateSnapshotData, _kDartVmSnapshotData)
- [x] blutter — Dart AOT snapshot decompilation (Dart SDK 3.3.3, protobuf field numbers + enum values extracted)
- [ ] nRF Connect — GATT enumeration and characteristic discovery (requires device)
- [ ] Android HCI snoop log — capture BLE traffic during app usage (requires device)
- [ ] Wireshark — analyze HCI snoop / PCAP captures

## References

- [AdMore Light Bar Pro product page](https://admorelighting.com/product/admore-light-bar-pro/)
- [AdMore Connect on Google Play](https://play.google.com/store/apps/details?id=com.admorelighting.lightbar)
- [AdMore Connect App Help](https://admorelighting.com/admore-connect-app-help/)
- [Rider Magazine review (2024)](https://ridermagazine.com/2024/12/17/admore-light-bar-pro-motorcycle-lighting-system-review/)
- [Motorcycle Mojo review (2023)](https://motorcyclemojo.com/2023/07/admore-light-bar-pro-revisited/)

## Contributors

- OpenGreenIoT community — APK static analysis and protocol documentation
