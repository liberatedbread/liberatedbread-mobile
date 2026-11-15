# Target: Belkin Wemo Smart Home Devices

## Target metadata
- target_id: wemo-devices
- app package_id(s): com.belkin.wemoandroid
- device class: WiFi smart home (plugs, switches, dimmers, energy monitors)
- transport(s): Wi-Fi LAN (SSDP/UPnP + SOAP 1.1 over HTTP)
- local-only viability: high — UPnP/SOAP protocol on local LAN; pywemo library exists; no cloud dependency for core functionality

## Known facts (verified from RE sources)
- **EDISAPK** (OpenGreenIoT internal APK analysis):
  - 32 widget directories in `wemo-apk/decoded/assets/www/widgets/` covering 16+ distinct device types
  - All share the same UPnP/SOAP control architecture
  - DeviceType URNs vary by device: `urn:Belkin:device:socket:1`, `:controllee:1`, `:insight:1`, `:dimmer:1`, `:lightswitch:1`, `:bridge:1`, `:Maker:1`, `:motion:1`, `:outdoor:1`, `:coffeemaker:1`, `:crockpot:1`, `:heater:1`, `:purifier:1`, `:humidifier:1`, `:humidifierb:1`
  - Cloud endpoints (documented for reference, not used for local control): `api.xwemo.com:8443`, `appapis.xwemo.com:8443`, Firebase (`productionwemoandroidpn.firebaseio.com`), AWS IoT
- Belkin Wemo Mini Smart Plug (F7C063) and Wemo Smart Plug V2 (WSP080): $15-25
- Wemo Insight Switch (F7C029): adds energy monitoring, ~$30
- Wemo Dimmer (F7C059): dimmable lighting, ~$40
- **VERIFIED**: Cloud shutdown announced for January 31, 2026
- **VERIFIED**: Uses UPnP/SOAP protocol on local network (pywemo, Home Assistant, ouimeaux)
- **VERIFIED**: SSDP multicast discovery on local LAN — NOT mDNS
- **VERIFIED**: pywemo Python library provides local control (source: pywemo/pywemo)
- **VERIFIED**: UPnP deviceTypes for plugs: `urn:Belkin:device:controllee:1` (Mini), `urn:Belkin:device:socket:1` (V2); SSDP search-target: `urn:Belkin:service:basicevent:1`
- Port instability: HTTP port drifts across 49152-49159 (probe 49153 first, re-probe after reconnect)
- WiFi provisioning: factory-reset device broadcasts an open AP whose SSID starts with `Wemo.` (match case-insensitively; observed `WeMo.Switch.A1B`, `Wemo.Mini.4A2`). A client joins it and provisions home WiFi via SOAP (GetApList / ConnectHomeNetwork) — no app required. Fully specified in `device.setup`.
- Structured spec: `device-specs/devices/wemo-smart-plug.yaml`

## Device discovery signals
- Wi-Fi (SSDP / UPnP — this is the discovery path; there is NO mDNS):
  - SSDP M-SEARCH: multicast group `239.255.255.250:1900`, MAN `"ssdp:discover"`, MX `1`, ST `urn:Belkin:service:basicevent:1`
    (alternates: `ssdp:all`, `urn:Belkin:device:controllee:1`, `urn:Belkin:device:socket:1`)
  - SSDP reply: `LOCATION` header → `http://<ip>:<port>/setup.xml`; `USN` → `uuid:Socket-1_0-<serial>::urn:Belkin:service:basicevent:1`
  - setup.xml port behavior: port is NOT stable — drifts across 49152-49159; probe 49153 first, then 49152, 49154, 49151, 49155-49159
  - setup-AP SSID: factory-reset device broadcasts an open AP starting with `Wemo.` (case-insensitive); the device reports its own AP name as MetaInfo field 4
  - mDNS service types: N/A — Wemo does not use mDNS/Bonjour
  - UPnP deviceTypes (from setup.xml, device.json mocks):
    - **Plug family**: `urn:Belkin:device:controllee:1` (Mini F7C063), `urn:Belkin:device:socket:1` (V2 WSP080, Smart Plug, mini widget)
    - **Energy monitoring**: `urn:Belkin:device:insight:1` (Insight F7C029)
    - **Lighting**: `urn:Belkin:device:dimmer:1` (dimmer V1/V2), `urn:Belkin:device:lightswitch:1` (1st gen / 2nd gen / 3-way)
    - **Sensors/I/O**: `urn:Belkin:device:Maker:1` (relay/sensor), `urn:Belkin:device:motion:1` (motion)
    - **Other**: `urn:Belkin:device:bridge:1` (bridge), `urn:Belkin:device:outdoor:1` (outdoor plug)
    - **Appliances**: `:coffeemaker:1`, `:crockpot:1`, `:heater:1`, `:purifier:1`, `:humidifier:1`, `:humidifierb:1`

## Threat model + guardrails
- Scope: only owned devices, no safety-critical use cases
- Smart plugs control power — avoid safety-critical loads (medical, life support)
- Insight switch: power monitoring only, no safety implications
- Wemo Dimmer / Light Switch: no safety implications for lighting
- UPnP/SSDP operates on the local LAN only — not exposed to WAN by default
- Cloud endpoints (api.xwemo.com, Firebase, AWS IoT) are documented for avoidance only
- Explicitly excluded: remote/cloud features, firmware updates over cloud

## First experiments (do these first)
1) Implement SSDP discovery from `device.discovery` in the spec (or use pywemo) on a LAN with Wemo devices
2) Fetch APK: `./scripts/fetch_apks_apkeep.sh` — already downloaded and decoded at `wemo-apk/decoded/`
3) Static: APK widget mock analysis complete (`wemo-apk/decoded/assets/www/widgets/*/mocks/device.json`); smali deep-dive pending for SOAP service strings
4) Dynamic: capture one "SSDP discover + toggle on/off" PCAP on local network
5) Build a SOAP request from `soap_common.request_format` and diff it against the published example

## Protocol hypotheses (to validate)
- **Pairing/bonding steps**: WiFi provisioning via the device's own `Wemo.*` AP (VERIFIED — pywemo `ouimeaux_device/__init__.py`); join AP → GetMetaInfo → GetApList → ConnectHomeNetwork → GetNetworkStatus → CloseSetup. Fully documented in `device.setup`, including the three passphrase encryption variants.
- **Session state machine**: SSDP M-SEARCH discovery → GET `/setup.xml` → SOAP action calls; rediscover after IP/port change
- **Commands** (VERIFIED SOAP actions, SOAP 1.1 POST over HTTP):
  - **basicevent** (`/upnp/control/basicevent1`): `SetBinaryState` (BinaryState=1/0), `GetBinaryState`; each requires `SOAPACTION: "urn:Belkin:service:basicevent:1#<Action>"` header
  - **insight** (`/upnp/control/insight1`, Insight only): `GetInsightParams` → pipe-delimited telemetry (field layout in the spec's top-level `payload_formats.InsightParams`); `SetPowerThreshold`, `GetPowerThreshold`
  - **metainfo** (`/upnp/control/metainfo1`): `GetMetaInfo` — device metadata
  - **timesync** (`/upnp/control/timesync1`): `TimeSync` — set device clock
  - **deviceinf** (`/upnp/control/deviceinf1`): `GetDeviceInformation` — model/serial/MAC
  - **WiFi setup** (`/upnp/control/wifi1`): `GetApList`, `ConnectHomeNetwork` — provisioning
- **Payload encoding**: XML/SOAP over HTTP (VERIFIED from pywemo)
- **Async events**: UPnP eventing — SUBSCRIBE to each service's `eventSubURL` (e.g. `/upnp/event/basicevent1`)
- **Timing constraints**: SSDP multicast MX 1 second response window; connection timeout ~30s per port probe

## Control surface inventory (what the replacement app must support)
### Phase 1 — Core Plug (MVP)
- **Onboarding**: documented and entirely local — see `device.setup` in the spec and docs/devices/wemo-setup.md. It is not app-only, which is what makes these devices recoverable after the cloud shutdown. Not yet replayed against hardware (issue #16).
- **Discovery**: SSDP M-SEARCH → parse LOCATION → fetch /setup.xml → enumerate services
- **Core controls**: on/off (SetBinaryState), get current state (GetBinaryState)
- **Rediscovery**: handle port change after device reconnects

### Phase 2 — Energy Monitoring
- **Insight telemetry**: instant power (mW), energy today/total, on-time stats (GetInsightParams)
- **Power threshold alerts**: SetPowerThreshold / GetPowerThreshold

### Phase 3 — Lighting
- **Dimmer**: SetBinaryState (dim level), brightness
- **Light Switch**: SetBinaryState, 3-way support
- **Bridge**: Links smart bulb control

### Phase 4 — Specialty (opportunistic)
- **Maker**: relay switch control + sensor input reading
- **Motion**: motion sensor events
- **Outdoor Plug**: dual-outlet control

### Error handling and recovery
- Device rediscovery after IP/port change
- SOAP fault handling (error responses)
- Timeout handling for unreachable devices
- Deduplication (same USN from multiple interfaces)

### Settings persistence
- Device retains relay state across power cycles
- Insight counters persist (today/total)

## Evidence checklist
- **APK downloaded**: ✅ `wemo-apk/com.belkin.wemoandroid.apk`
- **APK decoded**: ✅ `wemo-apk/decoded/` (apktool)
- **Widget mock analysis**: ✅ 32 widget directories, 16 device type mocks
- **PCAP logs**: TBD
- **APK version code**: TBD (extract from AndroidManifest)

## Spec output (clean-room)
Write a derived spec in:
- `device-specs/devices/wemo-smart-plug.yaml` (Phase 1 — plug family)
- `docs/devices/wemo-smart-plug.md` (user-facing docs)

Future specs:
- `device-specs/devices/wemo-insight.yaml` (Phase 2 — energy monitoring)
- `device-specs/devices/wemo-lighting.yaml` (Phase 3 — light switch + dimmer)

## Device Type Family (from APK mock data)

| widget directory | deviceType URN | friendlyName | UDN pattern |
|---|---|---|---|
| `wemo_mini` | `urn:Belkin:device:socket:1` | WeMo Switch | `uuid:socket-1_0-...` |
| `wemo_socket` | `urn:Belkin:device:socket:1` | WeMo Switch | `uuid:socket-1_0-...` |
| `wemo_smart_plug` | `urn:Belkin:device:socket:1` | WeMo Smart Plug | `uuid:socket-1_0-...` |
| `bundlemanager` | `urn:Belkin:device:controllee:1` | WeMo ec3 | `uuid:Socket-1_0-...` |
| `wemo_dimmer` | `urn:Belkin:device:socket:1` | WeMo Switch | `uuid:socket-1_0-...` |
| `wemo_dimmer_v2` | `urn:Belkin:device:socket:1` | WeMo Switch | `uuid:socket-1_0-...` |
| `wemo_insight` | (no mock) | — | — |
| `wemo_lightswitch` | `urn:Belkin:device:Lightswitch:1` | WeMo Light Switch | `uuid:Lightswitch-1_0-...` |
| `wemo_lightswitch_2gen` | `urn:Belkin:device:Lightswitch:1` | WeMo Light Switch | `uuid:Lightswitch-1_0-...` |
| `wemo_lightswitch3way` | `urn:Belkin:device:Lightswitch:1` | WeMo Light Switch | `uuid:Lightswitch-1_0-...` |
| `wemo_lighting` | `urn:Belkin:device:bridge:1` | Bulb 01 | `uuid:bridge-1_0-...` |
| `wemo_maker` | `urn:Belkin:device:Maker:1` | WeMo Motion | `uuid:Maker-1_0-...` |
| `wemo_sensor` | `urn:Belkin:device:motion:1` | WeMo Motion | `uuid:motion-1_0-...` |
| `wemo_outdoorplug` | `urn:Belkin:device:outdoor:1` | Wemo Outdoor Plug | `uuid:OutdoorPlug-1_0-...` |
| `wemo_airpurifier` | `urn:Belkin:device:purifier:1` | Holmes® Air Purifier | `uuid:purifier-1_0-...` |
| `wemo_coffeemaker` | `urn:Belkin:device:coffeemaker:1` | Mr. Coffee® Brewer | `uuid:coffeemaker-1_0-...` |
| `wemo_crockpot` | `urn:Belkin:device:crockpot:1` | Crock-Pot® Slow Cooker | `uuid:crockpot-1_0-...` |
| `wemo_heatera` | `urn:Belkin:device:heater:1` | Holmes® Heater | `uuid:heater-1_0-...` |
| `wemo_humidifier` | `urn:Belkin:device:humidifier:1` | Holmes® Humidifier | `uuid:humidifier-1_0-...` |
| `wemo_humidifierb` | `urn:Belkin:device:humidifierb:1` | Holmes® Humidifier | `uuid:humidifier-1_0-...` |

Note: dimmer mock devices use `urn:Belkin:device:socket:1` (not `dimmer:1`) — the dimmer may identify as a socket variant or use an unexposed mock. The pywemo library references `urn:Belkin:device:dimmer:1` for real dimmer hardware.

## References (URLs only)
- https://github.com/pywemo/pywemo
- https://github.com/pywemo/pywemo/blob/main/pywemo/ssdp.py
- https://github.com/pywemo/pywemo/tree/main/pywemo/ouimeaux_device
- https://github.com/pywemo/pywemo/tree/main/pywemo/ouimeaux_device/api/xsd
- https://github.com/pywemo/pywemo/blob/main/pywemo/ouimeaux_device/api/wifi_setup.py
- https://www.home-assistant.io/integrations/wemo/
- https://github.com/home-assistant/core/tree/dev/homeassistant/components/wemo
- https://github.com/iancmcc/ouimeaux
