# Chef iQ Sense

> **Status**: Complete
> **Protocol**: BLE + Wi-Fi
> **Manufacturer**: Chefman / Chef iQ
> **Manufacturer Status**: Server-dependent

## Overview

Smart thermometer hub (CQ60) with wireless probes. Uses BLE for probe communication and Wi-Fi provisioning; Wi-Fi connects to AWS IoT cloud via MQTT. The Android app is React Native with Hermes bytecode (v96), decompiled via `hermes-dec` to extract full protocol logic. Five BLE UUID families support thermometer probes, system configuration, Wi-Fi provisioning, user identity, and OTA firmware updates. Temperatures are IEEE 754 single-precision floats in Fahrenheit; the app converts to Celsius for display.

## Hardware

| Property | Value |
|----------|-------|
| Models | A2YP-CQ60 (hub), RJ40 (iQ MiniOven) |
| Chipset | ESP32-WROOM-E |
| Radio | BLE + Wi-Fi |
| FCC ID | ESP32WROVERE |
| Components | TS5A3159 analog switches, TCA9534 I2C port expander, NS4168 speaker |

## Protocol Summary

### BLE Discovery

- **Device name**: exactly `"CQ60"` (scan uses `exactAdvertisingName` filter)
- **Scan mode**: LOW_LATENCY (mode 2), 5-second window, 2000ms delay between cycles
- **Manufacturer data**: AD type `0xFF`, manufacturer ID `0x05CD`

### BLE Services Overview

| UUID Family | Service UUID | Name |
|-------------|-------------|------|
| A (`048A`) | `048A00FF-CD06-4D57-A048-CCD5CB9F8F43` | Thermometer/Probe |
| B (`9C6F`) | `9C6F00FC-0420-41C1-BD98-7A015C45DC5A` | System/Config |
| C (`8A71`) | `8A7100FE-BABE-B7AE-074F-86D0C0B50089` | Wi-Fi Provisioning |
| D (`6AC4`) | `6AC400FB-5BC3-4E99-ACB8-F85D442B9AE4` | User/Identity |
| E (`F640`) | `F64000FD-6F49-4B5B-9BF8-76B3775D4D01` | FTP/File Transfer (OTA) |

### Family A: Thermometer/Probe (`048A`)

| UUID | Name | Properties |
|------|------|------------|
| `048AF000` | Probe Data | notify |
| `048AF001` | Session Data | notify |
| `048AF010` | Docked List | read, notify |
| `048AF011` | Registered List | read |
| `048AF014` | Session Probe List | read, notify |
| `048AF020` | System Notification | notify |
| `048AF021` | Session Notification | notify |
| `048AF022` | Cooking State Notification | notify |
| `048AFFF0` | Thermometer Command Request | write |
| `048AFFF1` | Thermometer Command Response | notify |

#### Thermometer Commands (written to `048AFFF0`)

| ID | Command | Description |
|----|---------|-------------|
| 0 | GetVersion | Get firmware version |
| 16 | RegisterProbe | Register a probe to the hub |
| 17 | DeregisterProbe | Remove a probe registration |
| 18 | UpdateProbe | Update probe settings |
| 20 | StartSession | Start a cooking session |
| 21 | GetProbeAttributes | Read probe attribute data |
| 22 | GetSessionAttributes | Read session attribute data |
| 23 | UpdateSession | Update running session parameters |
| 24 | CancelSession | Cancel a cooking session |
| 25 | EndSession | End a cooking session |
| 32 | GetCookingStateNotificationIds | List cooking notification IDs |
| 33 | GetCookingStateNotification | Read a cooking notification |
| 34 | SetCookingStateNotification | Create a cooking notification |
| 35 | UpdateCookingStateNotification | Update a cooking notification |
| 36 | DeleteCookingStateNotification | Delete a cooking notification |
| 37 | StartCookingStateNotification | Activate a cooking notification |
| 48 | GetSessionNotificationIds | List session notification IDs |
| 49 | GetSessionNotification | Read a session notification |
| 50 | SetSessionNotification | Create a session notification |
| 51 | UpdateSessionNotification | Update a session notification |
| 52 | DeleteSessionNotification | Delete a session notification |
| 58 | GetSessionNotificationStatus | Get notification status |

### Family B: System/Config (`9C6F`)

| UUID | Name | Properties | Data Type |
|------|------|------------|-----------|
| `9C6FF050` | Cloud Status | read, notify | SignedInt32 |
| `9C6FF051` | Battery Status | read, notify | — |
| `9C6FF052` | Battery Level | read | — |
| `9C6FF054` | Mute | read, write, notify | Boolean |
| `9C6FF055` | Volume | read, write, notify | SignedInt16 |
| `9C6FFF81` | Device Name | read, write | String |
| `9C6FFF82` | Has New Update | read, notify | Boolean |
| `9C6FFF84` | OTA Progress | read, notify | UnsignedChar |
| `9C6FFF85` | Generation | read | UnsignedChar |
| `9C6FFFB0` | Signature | read | String |
| `9C6FFFC0` | Temperature Unit | read, write, notify | UnsignedChar (0=F, 1=C) |
| `9C6FFFC1` | Data Update Interval | read, write, notify | UnsignedInt32 |
| `9C6FFFF0` | System Command Request | write | SystemCommandRequest |
| `9C6FFFF1` | System Command Response | notify | SystemCommandResponse |

#### System Commands (written to `9C6FFFF0`)

| ID | Command | Description |
|----|---------|-------------|
| 0 | GetVersion | Get firmware version |
| 1 | FactoryReset | Factory reset the device |
| 2 | AppReboot | Reboot the device |
| 3 | SetEpochTime | Set the device clock |
| 4 | SetLocalTimeZone | Set timezone |
| 5 | SetLanguage | Set language |
| 6 | GetEpochTime | Read device clock |
| 7 | GetLocalTimeZone | Get timezone |
| 8 | GetLanguage | Get language |

### Family C: Wi-Fi Provisioning (`8A71`)

| UUID | Name | Properties | Description |
|------|------|------------|-------------|
| `8A71FFA0` | Network Info | read, notify | Current Wi-Fi status (ssid, rssi, ip, bssid) |
| `8A71FFA1` | Scanned Network | read | Available Wi-Fi networks |
| `8A71FFA2` | Saved Network | read | Previously saved credentials |
| `8A71FFA3` | Set Wi-Fi Network | write | Send SSID + password to device |
| `8A71FFA4` | Wi-Fi Mode | read, write, notify | Control Wi-Fi connection state |
| `8A71FFA5` | Remove Credential | write | Remove saved Wi-Fi credentials |

#### Wi-Fi Provisioning Flow

1. Read `Network Info` (`8A71FFA0`) — get current status
2. Read `Scanned Network` (`8A71FFA1`) — list available networks
3. Write `Set Wi-Fi Network` (`8A71FFA3`) — send SSID + password
4. Monitor `Wi-Fi Mode` (`8A71FFA4`) — track connection progress
5. Read `Network Info` (`8A71FFA0`) — confirm connected (has IP)

### Family D: User/Identity (`6AC4`)

| UUID | Name | Properties |
|------|------|------------|
| `6AC4FF80` | User Name | read, write |
| `6AC4FF83` | User ID | read, write |
| `6AC4FFB1` | Cognito ID | read, write |
| `6AC4FFB2` | Notification Key | read, write |

### Family E: FTP/OTA (`F640`)

| UUID | Name | Properties |
|------|------|------------|
| `F640FFF0` | FTP Command Request | write |
| `F640FFF1` | FTP Command Response | notify |

#### FTP Commands (written to `F640FFF0`)

| ID | Command | Description |
|----|---------|-------------|
| 0 | GetVersion | Get FTP service version |
| 1 | FileReadStart | Begin reading a file from device |
| 2 | FileReadTransfer | Continue reading file data |
| 3 | FileReadEnd | Complete file read |
| 4 | FileWriteStart | Begin writing a file (OTA) |
| 5 | FileWriteTransfer | Continue writing file data |
| 6 | FileWriteEnd | Complete file write |

### Temperature Data Encoding

All temperatures are **IEEE 754 single-precision floats (4 bytes)**, stored natively in **Fahrenheit**. The app converts for display:

- **F to C**: `(temp - 32) / 1.8`
- **C to F**: `(temp * 1.8) + 32`
- **Freezing threshold**: 32°F

Temperature unit setting: `0` = Fahrenheit (default), `1` = Celsius (characteristic `9C6FFFC0`).

### Probe Data TLV Format

Probe data notifications (`048AF000`) use a Tag-Length-Value binary encoding. Each attribute has a numeric ID and typed value:

| Attr ID | Name | Data Type | Size |
|---------|------|-----------|------|
| 0 | Timestamp | UnsignedInt32 | 4 |
| 16 | ProbeAddress | MacAddress | 6 |
| 17 | Type | SignedChar | 1 |
| 18 | HwVersion | String | var |
| 19 | FwVersion | String | var |
| 20 | SerialNumber | String | var |
| 22 | ServiceConfig | UnsignedChar | 2 |
| 23 | Name | String | 12 |
| 24 | Registered | Boolean | 1 |
| 25 | DockNumber | UnsignedChar | 1 |
| 26 | Size | UnsignedChar | 1 |
| 27 | Color | UnsignedChar | 1 |
| 28 | Number | UnsignedChar | 1 |
| 29 | IsIncompatible | Boolean | 1 |
| 32 | IsActive | Boolean | 1 |
| 33 | Rssi | SignedChar | 1 |
| 34 | BatteryLevel | UnsignedChar | 1 |
| 35 | IcTemp | SingleFloat | 4 |
| 36 | InternalTemp | SingleFloat | 4 |
| 37 | AmbientTemp | SingleFloat | 4 |
| 38 | IsOverheat | Boolean | 1 |
| 39 | IsSensorFail | Boolean | 1 |
| 40 | Tip1Temp | SingleFloat | 4 |
| 41 | Tip2Temp | SingleFloat | 4 |
| 42 | Tip3Temp | SingleFloat | 4 |
| 43 | Tip4Temp | SingleFloat | 4 |
| 44 | Ext1Temp | SingleFloat | 4 |
| 48 | SessionId | — | var |
| 49 | CookingCategory | UnsignedChar | 1 |
| 50 | CookingMethod | UnsignedChar | 1 |
| 56 | CookingTime | UnsignedInt32 | 4 |
| 57 | EstimatedCookingTime | UnsignedInt32 | 4 |
| 59 | TargetTemp | SingleFloat | 4 |
| 89 | SessionInternalTemp | SingleFloat | 4 |
| 90 | SessionAmbientTemp | SingleFloat | 4 |

### Operating States

| Value | State |
|-------|-------|
| 0 | Standby |
| 1 | Delay Start |
| 2 | Preheating |
| 3 | Build Pressure |
| 4 | Cooking |
| 5 | Release Pressure |
| 6 | Keep Warm |
| 7 | Stop |
| 8 | Done |
| 9 | Sleep |
| 10 | Error |
| 11 | Pending Cooking |

### Operating Warnings

| Value | Warning |
|-------|---------|
| 0 | None |
| 1 | Door Open |
| 2 | Door Close |
| 3 | Lid Off |
| 4 | Lid On |
| 5 | Lid Locked |
| 6 | Lid Not Locked |
| 7 | Pressure Go Release |
| 8 | Pressure Overheat |
| 9 | Pressure Not Building |
| 10 | Dry Detected |
| 11 | Probe Disconnected |
| 12 | Probe Sensor Error |
| 13 | Probe Sensor Overheat |
| 14 | Probe Battery Low |
| 15 | Probe Not Inserted Properly |

### Device Categories

| Code | Device |
|------|--------|
| SC | iQ Cooker |
| SO | iQ MiniOven |
| ST | iQ Sense (Thermometer) |

### Wi-Fi / Cloud Architecture

| Layer | Details |
|-------|---------|
| REST API | `https://api.chefiq.com/` |
| GraphQL | `https://graph.chefiq.com/graphql` |
| IoT MQTT | `iot.chefiq.com` (mqttv3) |
| Auth | AWS Cognito User Pools (`us-east-1`) |
| Cognito Pool | `us-east-1:f95270e2-a024-41dc-bf5e-2d5df159f259` (public client-side identity-pool id, not a secret) |
| Certificate pinning | None |

### MQTT Topics

```
ciq-v2/cmd/thermometer/{cognito_id}~{device_id}/req/{command}  # V2 requests
ciq-v2/cmd/app/{cognito_id}~{device_id}/res/{request_id}       # V2 responses
ciq-v2/dt/thermometer/{cognito_id}~{device_id}/+               # V2 telemetry
ciq-v2/evt/thermometer/{cognito_id}~{device_id}/notification/+  # V2 events

ciq-v3/cmd/oven/{cognito_id}~{device_id}/{command}             # V3 requests (oven)
ciq-v3/cmd/app/{cognito_id}~{device_id}/res/{request_id}       # V3 responses
ciq-v3/dt/oven/{cognito_id}~{device_id}/state                  # V3 state updates
$aws/events/presence/connected/{device_id}                       # Connection events
$aws/events/presence/disconnected/{device_id}                    # Disconnection events
```

MQTT payload envelope (V2/V3):

```json
{
    "version": "1.0.0",
    "env": "production",
    "time_stamp": 1709500000000,
    "request_id": "uuid",
    "client_id": "client-uuid",
    "response_topic": "ciq-v2/cmd/app/.../res/...",
    "data": {}
}
```

### Wi-Fi Provisioning Protocol Versions

Three versions exist, selected by device capability:

- **V1**: Uses MQTT topic `{deviceId}/cmd/{update}`, simple request/response
- **V2**: Uses `ciq-v2/cmd/thermometer/{cognitoId}~{deviceId}/req/{command}`, versioned envelope
- **V3**: Uses `ciq-v3/cmd/oven/{cognitoId}~{deviceId}/{command}`, same envelope as V2

### Standard BLE Services

The device also exposes standard Device Information Service (`0x180A`):

| UUID | Name | Properties |
|------|------|------------|
| `0x2A24` | Model Number | read |
| `0x2A25` | Serial Number | read |
| `0x2A26` | Manifest Version | read |
| `0x2A27` | Hardware Version | read |
| `0x2A28` | Software Version | read |
| `0x2A29` | Manufacturer Name | read |

## Tools Used

- [x] APK decompilation (jadx) -- UUIDs, cloud endpoints, architecture
- [x] Hermes bytecode decompilation (hermes-dec) -- full BLE protocol, commands, TLV format, temperature encoding
- [ ] HCI snoop capture (not yet needed; protocol logic fully extracted from Hermes)
- [ ] MQTT capture (pending)

## References

- [Google Play: Chef iQ](https://play.google.com/store/apps/details?id=com.chefman.chefiq.prod)
- [HA Community Thread](https://community.home-assistant.io/t/chef-iq-smart-wireless-meat-thermometer/654248)

## Contributors

- HA BLE Monitor community -- partial BLE broadcaster data
- APK static analysis (jadx decompilation)
- Hermes bytecode decompilation (hermes-dec) -- full protocol extraction
