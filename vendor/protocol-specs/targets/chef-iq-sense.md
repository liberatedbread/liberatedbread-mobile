# CHEF iQ Sense — target spec

## Target metadata
- target_id: chef-iq-sense
- app package_id(s): com.chefman.chefiq.prod
- device class: smart thermometer / cooking appliances
- transport(s): Wi-Fi + Bluetooth Low Energy
- local-only viability: medium — BLE direct probe reading appears feasible based on GATT
  service structure; WiFi setup and cloud features (guided cooking, recipes, sharing) require
  AWS IoT backend

## Known facts (static analysis)

### APK details
- Package: `com.chefman.chefiq.prod` v5.0.0 (versionCode 9388)
- APK SHA256 (base): `54a5947ad35ea15b41dfe8e3f5bafbd6bcc0baa085dc8221f81e55e0f41a1eb8`
- XAPK SHA256 (bundle): `87b7de31d9c4016d2eafe78261ea3f16e6a1977d3c05150f249ae5ff7140ef04`
- Framework: React Native / Expo with Hermes JS engine (New Architecture enabled)
- BLE library: react-native-ble-manager (it.innove)

### Cloud infrastructure
- REST API: `https://api.chefiq.com/` (API key in BuildConfig)
- GraphQL: `https://graph.chefiq.com/graphql`
- IoT broker: `iot.chefiq.com` (AWS IoT Core)
- Media CDN: `https://media.chefiq.com`
- Service API pattern: `https://{service}-api.chefiq.com/v1`
- Auth: AWS Cognito (identity pool `us-east-1:f95270e2-a024-41dc-bf5e-2d5df159f259`)
- Push: AWS Pinpoint (app ID `614e34f83bcf47f3894378403dc014b0`)
- Analytics: Firebase, Sentry
- Deep links: `link.chefiq.com`

### Android permissions (BLE/network relevant)
- `BLUETOOTH`, `BLUETOOTH_ADMIN`, `BLUETOOTH_SCAN`, `BLUETOOTH_CONNECT`
- `ACCESS_FINE_LOCATION`, `ACCESS_COARSE_LOCATION`
- `ACCESS_NETWORK_STATE`, `ACCESS_WIFI_STATE`
- `INTERNET`, `CAMERA` (likely for QR code scanning during setup)
- `FOREGROUND_SERVICE` (for background BLE operation)

### Supported device categories (from string extraction)
| Category | Model prefix | Description |
|----------|-------------|-------------|
| Smart Thermometer | CQ60-PR | Wireless probes with hub/base |
| Smart Cooker | CQ50 | Pressure cooker / multi-cooker |
| Smart Hub | CQ60 | Hub/base station for probes |
| Mini Oven | — | Countertop smart oven |
| iQ Sense | — | Standalone smart thermometer |

### Probe variants
- Probe2v3, Probe3v3, Probe4v8 — multiple hardware revisions exist
- Multi-probe support (up to 4 probes based on Hub model variants CQ60-1 through CQ60-4)
- Probe status states: OK, sensor error, overheat, not inserted properly, disconnected, warning, max time not synced

## Device discovery signals

### BLE — 5 custom UUID families discovered

Each family shares a common base UUID suffix; the 2nd-4th bytes vary per characteristic.

| Family base | Service UUID (primary) | Hypothesized device |
|-------------|----------------------|---------------------|
| `048A____-CD06-4D57-A048-CCD5CB9F8F43` | `048A00FF-CD06-4D57-A048-CCD5CB9F8F43` | Smart Cooker |
| `6AC4____-5BC3-4E99-ACB8-F85D442B9AE4` | `6AC400FB-5BC3-4E99-ACB8-F85D442B9AE4` | Smart Hub |
| `8A71____-BABE-B7AE-074F-86D0C0B50089` | `8A7100FE-BABE-B7AE-074F-86D0C0B50089` | Probe peripheral |
| `9C6F____-0420-41C1-BD98-7A015C45DC5A` | `9C6F00FC-0420-41C1-BD98-7A015C45DC5A` | iQ Sense / thermometer (most chars) |
| `F640____-6F49-4B5B-9BF8-76B3775D4D01` | `F64000FD-6F49-4B5B-9BF8-76B3775D4D01` | Mini Oven |

### BLE — advertised name
- Hypothesized prefix: `CHEFiQ` or `CQ` (based on brand strings and model prefixes)
- Needs device validation

### Wi-Fi
- Setup via BLE: WiFi credentials appear to be provisioned over BLE (BLUETOOTH_REGISTER_AND_CONNECT_TO_WIFI_SUCCESS constant)
- No ESP32/BluFi patterns detected — provisioning appears to be a custom BLE-to-WiFi flow
- IoT connectivity uses AWS IoT Core MQTT via AWS Amplify PubSub

## Protocol hypotheses (to validate)

### BLE pairing/bonding
- react-native-ble-manager handles standard Android BLE stack
- CCCD (0x2902) used for notifications — standard BLE notification subscription
- BLE-only mode appears feasible for thermometer readings (BLUETOOTH_SEND_BLE_ONLY constant)

### Session flow
1. App scans for device (service UUID filter)
2. Connect and discover services
3. Subscribe to temperature notification characteristics
4. For WiFi devices: write WiFi credentials over BLE characteristic
5. Once WiFi connected: device registers with AWS IoT, app communicates via MQTT PubSub

### Appliance state machine (from constant names)
- `APPL_STATE_IDLE_WARNING`
- `APPL_STATE_DELAY_START`
- `APPL_STATE_PREHEAT_DONE_DELAY`
- `APPL_STATE_COOKING`
- `APPL_STATE_ATTENDED` (attended cooking mode)
- `APPL_STATE_KEEP_WARM`
- `APPL_STATE_DONE_COOK`
- `APPL_STATE_PAUSE`
- `APPL_STATE_ERROR`

### Termination conditions
- `APPLIANCE_TERMINATE_ON_PROBE_OVERHEAT`
- `APPLIANCE_TERMINATE_ON_PROBE_ERROR`
- `APPLIANCE_TERMINATE_ON_PROBE_DISCONNECTED_FROM_DEVICE`
- `APPLIANCE_TERMINATE_ON_OVERHEAT`
- `APPLIANCE_TERMINATE_ON_DOOR_OPEN`
- `APPLIANCE_TERMINATE_ON_HEATER_FAILURE`
- `APPLIANCE_TERMINATE_ON_NACK`
- `APPLIANCE_TERMINATE_ON_LOCAL_NACK`

### BLE operations identified
- `BLUETOOTH_WRITE_SUCCESS` / `BLUETOOTH_WRITE_REQUEST_SUCCESS` / `BLUETOOTH_WRITE_COMMAND_REQUEST_SUCCESS`
- `BLUETOOTH_START_NOTIFICATION_SUCCESS` / `BLUETOOTH_STOP_NOTIFICATION_SUCCESS`
- `BLUETOOTH_SCAN_FOR_DEVICE_AND_CONNECT_SUCCESS`
- `BLUETOOTH_REBOOT_SUCCESS` — device reboot over BLE
- `BLUETOOTH_START_WIFI_NETWORK_TIMER` — WiFi provisioning timer
- `BLUETOOTH_HANDLE_DISCOVERED_PERIPHERAL` — scan callback
- `DEVICE_UPDATE_PROBE_INFO_BY_BLUETOOTH` — probe data arrives over BLE

### Cloud operations
- `WIFI_HANDLE_PUBSUB_UPDATE` — MQTT PubSub messages for device state
- `WIFI_CONNECT_IOT_CONNECTION` — AWS IoT connection
- `WIFI_HANDLE_IOT_DISCONNECT` — IoT disconnect handler
- `DEVICE_REGISTER_AND_SUBSCRIBE` — register device + subscribe to MQTT topics
- `DEVICE_SEND_TO_DEVICE` — cloud-to-device commands
- `APPLIANCE_CONTROL_MSG` — control messages via cloud

## Control surface inventory

### Core thermometer (MVP)
- Connect to probe via BLE
- Read temperature (real-time via notifications)
- Set target temperature alerts
- Probe status monitoring (inserted, error, overheat)
- Temperature unit setting (F/C — DEFAULT_TEMPERATURE_UNIT_SETTING constant)
- Multi-probe display

### Extended features
- Guided cooking programs with timer integration
- Cooking session history (PreviousCooks)
- Probe naming/nicknames
- Device firmware OTA updates (DEVICE_CHECK_FOR_UPDATE, firmware update messaging)
- Ambient temperature alerts (AmbientAlertsSet)
- Device sharing (APPLIANCE_SHARE_INVITATION)
- Recipe integration

### Cooker-specific
- Cook method selection (pressure, slow cook, keep warm, baked goods)
- Delay start
- Preheat monitoring
- Pressure release control (auto/manual)
- Door state monitoring (for oven)

## Evidence checklist
- [x] APK acquired: v5.0.0 (9388), SHA256 recorded above
- [x] jadx decompilation complete (90 non-critical errors)
- [x] apktool decode complete
- [x] Hermes bytecode string extraction complete
- [x] BLE UUID families extracted (5 families, 42+ unique UUIDs)
- [x] Cloud endpoints cataloged
- [ ] HCI snoop log (requires device)
- [ ] Dynamic BLE capture (requires device)
- [ ] WiFi PCAP (requires device)

## Threat model + guardrails
- Scope: owned devices only
- Food safety: temperature readings are informational — users remain responsible for food safety decisions
- No cloud credential extraction or account enumeration
- BLE-only mode avoids cloud dependency for core thermometer function
- Device firmware modification is out of scope

## Spec output (clean-room)
- Protocol spec: `docs/devices/chef-iq-sense.md`
- Machine-readable YAML: `device-specs/devices/chef-iq-sense.yaml`

## References
- https://play.google.com/store/apps/details?id=com.chefman.chefiq.prod
