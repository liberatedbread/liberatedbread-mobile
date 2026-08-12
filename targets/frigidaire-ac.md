# Frigidaire Connected Air Conditioners

## Target metadata
- target_id: frigidaire-window-ac, frigidaire-portable-ac, frigidaire-wall-ac
- app package_id(s): com.electrolux.oneapp.android.frigidaire (verified active Google Play package; older guessed IDs com.electrolux.oneapp.frigidaire, com.frigidaire.android, and com.electrolux.oneapp did not fetch)
- device class: window air conditioner, portable air conditioner, wall-mounted air conditioner
- transport(s): Wi-Fi (802.11 b/g/n 2.4 GHz)
- local-only viability: low — APK static analysis found cloud/OCP control plus provisioning-only local networking; no mDNS, SSDP, static-IP, Greengrass, or post-pairing LAN control discovery path was found

## Known facts (public + observed)
- Frigidaire is an Electrolux brand; connected appliances use the Electrolux/Frigidaire app platform
- WiFi-connected window ACs include FHWW series (FHWW082WCE, FHWW102WCE, FHWW152WCE) and Gallery GHWQ series (GHWQ083WC1)
- WiFi-connected portable ACs include FHPC series (FHPC082AC1) and FHPH series (FHPH132AB1)
- App provides: power on/off, mode selection (cool/eco/fan only), temperature setpoint (60-90°F), fan speed (auto/low/medium/high), timer, sleep mode, filter status
- Gallery models add Clean Air (ionizer) feature
- Portable models add Dehumidify mode and drain-full indicator
- Devices connect to home WiFi during setup (2.4 GHz only) and communicate via Electrolux OCP cloud servers
- Static analysis performed on Frigidaire Android package `com.electrolux.oneapp.android.frigidaire` v3.6 / versionCode 504110958 (XAPK SHA-256 `0fa212791d3f488eaffbbb1dbc628b7c988d786e1546be32fcc297795a6c99aa`) found local networking only in onboarding/provisioning flows. `apkeep --list-versions` exposed APKPure versions through 3.6; public mirrors list newer 4.x builds for future re-check when obtainable.

## Device discovery signals
- BLE:
  - Not expected for ongoing control; Bluetooth permission and Bluetooth/WiFi onboarding copy are present, but AC categories in `provisioningConfig.json` use WiFi-only setup while WRAC allows Bluetooth+WiFi
  - advertised name patterns: unknown
  - service UUIDs: unknown
- Wi-Fi:
  - SSID patterns for provisioning: `AJ`, `@E`, `IOT`, `Air_Conditioner`, `Dehumidifier`
  - setup endpoint observed in APK: `192.168.6.1:3002`
  - provisioning broadcast: UDP broadcast on port 3000
  - AllJoyn onboarding/enrollment classes are bundled and referenced by provisioning code (`AJDiscoverResult`, `org.alljoyn.Onboarding`, `com.electrolux.HaclV4.Enrollment`)
  - mDNS service types: none found for post-pairing control
  - UPnP/SSDP URNs / LOCATION: none found

## Threat model + guardrails
- Scope: only owned devices, no safety-critical use cases
- Temperature commands must be bounded to safe ranges (60-90°F / 16-32°C)
- Do not attempt to bypass any safety interlocks (compressor delay timers, overtemp shutoff)
- Non-goals: firmware modification, cloud account compromise, multi-tenant access

## First experiments (do these first)
1) Network capture: set up mitmproxy/Wireshark on WiFi network during app usage; capture HTTPS/MQTT traffic between app and cloud
2) Fetch APK: `apkeep -a com.electrolux.oneapp.android.frigidaire`
3) Static analysis: decompile APK with jadx; grep for API endpoints, websocket hosts, provisioning paths, and local discovery patterns
4) DNS analysis: identify cloud endpoints (*.electrolux.one OCP); local API fallback was not found in APK static analysis
5) If BLE provisioning exists: capture HCI snoop log during device setup flow

## Protocol hypotheses (to validate)
- Cloud transport: Electrolux OCP HTTPS REST plus websocket paths observed in APK strings
- Authentication: OAuth2 or API key via Electrolux account; device likely uses certificate or token-based auth
- Command encoding: likely JSON payloads (MQTT or REST); could be protobuf
- Local API: no post-pairing LAN control/discovery found; local IP/AllJoyn paths appear provisioning-only
- Provisioning: SoftAP/AllJoyn/OCP provisioning; APK strings reference SSIDs starting with `AJ`, `@E`, `IOT`, `Air_Conditioner`, or `Dehumidifier`

## Control surface inventory (what the replacement app must support)

### Onboarding/pairing UX
- WiFi provisioning (send SSID + password to device)
- Device registration / naming

### Core controls (MVP)
- Power on/off
- Mode: Cool, Eco (Energy Saver), Fan Only
- Temperature setpoint: 60-90°F (16-32°C), 1°F increments
- Fan speed: Auto, Low, Medium, High
- Current room temperature (read-only)

### Extended controls
- Timer: on/off, 0.5-24 hours
- Sleep mode: on/off
- Display: on/off (brightness dimming)
- Filter alert status (read-only binary sensor)
- Filter reset command

### Model-specific controls
- **Gallery models**: Clean Air / Ionizer toggle
- **Portable models**: Dehumidify mode, drain-full indicator (binary sensor)

### Error handling and recovery
- WiFi reconnection after network interruption
- Compressor delay timer awareness (cannot restart compressor immediately after power cycle)
- Filter maintenance reminders

### Settings persistence
- Schedule programming (if supported by protocol)
- Temperature unit preference (°F / °C)

## Evidence checklist
- [x] APK hash + version code: analyzed `com.electrolux.oneapp.android.frigidaire` v3.6 / versionCode 504110958, XAPK SHA-256 `0fa212791d3f488eaffbbb1dbc628b7c988d786e1546be32fcc297795a6c99aa`; public mirrors list newer 4.x builds for future re-check
- [x] APK decompilation output (jadx): completed with recoverable decompiler errors; grep artifacts kept under `workspace/frigidaire/`
- [ ] Network capture (mitmproxy / PCAP) during app-to-cloud communication
- [ ] MQTT broker address + topic structure (if applicable): no MQTT/AWS IoT/Greengrass local proxy evidence found in static analysis
- [x] REST/API endpoints (static strings): `https://api.ocp-dev.electrolux.one`, `https://api.ocp-staging.electrolux.one`, `https://frigidaire.app.electrolux.one/`, `wss://ws.eu.ocp-dev.electrolux.one`, `wss://ws.eu.ocp-staging.electrolux.one`, `/appliance/api/v2/appliances?includeMetadata=true`, `/appliance/api/v2/appliances/{applianceId}/command`, `/appliance/api/v3/appliances/info`, `/remote-control/api/v1/appliances/`
- [ ] HCI snoop log during provisioning (if BLE used)
- [ ] Screenshots of app UI for each control (do not commit proprietary assets)

## Spec output (clean-room)
Write derived specs in:
- `device-specs/devices/frigidaire-window-ac.yaml`
- `device-specs/devices/frigidaire-portable-ac.yaml`
- `docs/devices/frigidaire-ac.md`

Include message formats, topic/endpoint structures, payload examples, and entity mappings.

## References (URLs only)
- https://www.frigidaire.com/owner-center/connect/
- https://play.google.com/store/apps/details?id=com.electrolux.oneapp.android.frigidaire
