# Anki Vector Robot — target spec

## Target metadata
- target_id: vector-robot
- app package_id(s): com.anki.vector (original Anki app), com.digitaldreamlabs.vector (DDL app, likely)
- device class: AI desktop companion robot
- transport(s): BLE (onboarding/setup), Wi-Fi LAN (primary control — gRPC+TLS on port 443)
- local-only viability: **high** — fully local after onboarding. gRPC runs entirely on-device with mDNS discovery. The cloud component (chipper) is voice-processing-only and has been replaced by community wire-pod. Full local SDK operation is proven and documented. OSKR firmware allows SSH root access.

## Known facts (public + observed)

### Company history
- Originally developed by **Anki** (founded 2010, shut down April 2019)
- Acquired by **Digital Dream Labs** (DDL) in late 2019
- DDL continued to sell Vector 1.0 and developed Vector 2.0
- DDL open-sourced most Vector software: chipper (voice proxy), vector-bluetooth, vector-web-setup, vector-cloud, escape-pod-extension, and the full robot OS (`digital-dream-labs/vector`)
- DDL's cloud services have had reliability issues, driving community adoption of wire-pod

### Hardware
- Qualcomm APQ8009 (Snapdragon 212) quad-core ARM Cortex-A7 @ 1.3 GHz
- 1 GB RAM, 8 GB eMMC storage
- HD camera (720p), 4-microphone array, touch sensor, 4 drop sensors
- Display: 184 × 96 IPS color display (face/screen)
- Motors: 2 treads, 1 head tilt, 1 lift arm
- Wi-Fi 802.11n 2.4 GHz, Bluetooth 4.0 BLE
- Battery: Li-Po, charges via dock

### Protocol architecture: Dual-stack BLE + gRPC

```
┌─────────────────────────────────────────────────────────────┐
│                      WiFi LAN (port 443)                     │
│  ┌──────────────────────────────────────────────────────┐   │
│  │  vic-gateway (gRPC server + gRPC-gateway REST proxy) │   │
│  │  - Protocol version negotiation                      │   │
│  │  - TLS mutual auth (robot cert + client GUID)        │   │
│  │  - BehaviorControl stream (takes over robot AI)      │   │
│  │  - EventStream (sensor, status, world events)         │   │
│  │  - Camera/Audio/NavMap feeds (streaming RPCs)        │   │
│  │  - ~45 RPC methods for full robot control             │   │
│  │  - Protobuf (proto3) serialization                    │   │
│  └──────────────────────────────────────────────────────┘   │
│  mDNS: _ankivector._tcp.local. → Vector-X1X2.local          │
└─────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────┐
│          BLE (onboarding, setup, OTA, SDK proxy)             │
│  RTS (Robot Transport Service) custom protocol               │
│  - NaCl/libsodium encryption after handshake                 │
│  - CLAD serialization (Compact Language for Anki Devices)    │
│  Read UUID:  7d2a4bda-d29b-4152-b725-2491478c5cd7           │
│  Write UUID: 30619f2d-0f54-41bd-a65a-7588d8c85b45           │
│  Capabilities:                                               │
│  - scan, connect, authorize (cloud session token)            │
│  - configure (locale, timezone, units, data analytics)       │
│  - wifi-scan, wifi-connect, wifi-forget, wifi-ip             │
│  - get-status (WiFi state, BLE state, battery, version, ESN) │
│  - ota-start, ota-cancel                                     │
│  - logs download                                             │
│  - SDK proxy (bypasses gRPC for WiFi-less operation)         │
│  - SSH key deployment (OSKR only)                            │
└─────────────────────────────────────────────────────────────┘
```

### Certificate + auth flow (from Anki SDK docs)
1. On first setup / after factory reset, the robot generates a self-signed x509 "Robot Session" certificate
2. The private key stays on-robot, never leaves the device
3. The public certificate is transferred to the app via BLE (PIN-verified secure channel) during onboarding
4. For future WiFi connections: client uses this robot certificate to pin TLS, and presents a `client_token_guid` (GUID) as a bearer token in gRPC metadata
5. The client_token_guid is obtained by authenticating with a DDL cloud session token (JWT at `/data/data/com.anki.victor/persistent/token/token.jwt`) via BLE, which returns the GUID

### Cloud infrastructure (optional, for voice commands only)
- **chipper**: voice processing gRPC proxy. Receives ogg-encoded audio streams, returns intent actions
- **vector-cloud**: jdocs (JSON document store for settings/state), token management service
- **server_config.json** on robot: `jdocs`, `tms`, `chipper`, `check`, `logfiles`, `appkey` endpoints
- wire-pod replaces all of this with a fully local self-hosted server

## Device discovery signals

### BLE
- advertised name patterns: `Vector-XXXX` where XXXX is 4 alphanumeric characters (last 4 of ESN)
- BLE address: random resolvable (Anki's BLE stack)
- Read characteristic UUID: `7d2a4bda-d29b-4152-b725-2491478c5cd7`
- Write characteristic UUID: `30619f2d-0f54-41bd-a65a-7588d8c85b45`
- RTS protocol versions: v2, v3, v4, v5 (backward compatible unions, see RtsConnection_2 through RtsConnection_5)
- NaCl/libsodium encryption after key exchange (Curve25519 public key exchange + nonces + challenge)

### Wi-Fi
- mDNS service type: `_ankivector._tcp.local.`
- mDNS hostname: `Vector-XXXX.local.`
- Default gRPC port: **443** (HTTPS/TLS)
- gRPC target name override: robot name (e.g., `Vector-A1B2`)
- REST API paths: `/v1/protocol_version`, `/v1/event_stream`, `/v1/battery_state`, etc.

### gRPC service: ExternalInterface (from external_interface.proto)
**Protocol version**: PROTOCOL_VERSION_CURRENT = 5 (as of 2019.03.12)

Core RPCs:
| Category | RPCs |
|----------|------|
| Version/Auth | ProtocolVersion, SDKInitialization, UserAuthentication |
| Motor Control | DriveWheels, MoveHead, MoveLift, StopAllMotors |
| Animation | PlayAnimation, PlayAnimationTrigger, ListAnimations, ListAnimationTriggers |
| Display | DisplayFaceImageRGB, SetEyeColor |
| Navigation | GoToPose, DockWithCube, DriveStraight, TurnInPlace, DriveOffCharger, DriveOnCharger |
| Head/Lift | SetHeadAngle, SetLiftHeight |
| Vision/Faces | FindFaces, LookAroundInPlace, EnableFaceDetection, EnableMarkerDetection, EnableMotionDetection |
| Face Enrollment | CancelFaceEnrollment, RequestEnrolledNames, UpdateEnrolledFaceByID, EraseEnrolledFaceByID, EraseAllEnrolledFaces, SetFaceToEnroll |
| Cube | ConnectCube, DisconnectCube, CubesAvailable, FlashCubeLights, SetCubeLights, ForgetPreferredCube, SetPreferredCube |
| Custom Objects | DeleteCustomObjects, CreateFixedCustomObject, DefineCustomObject |
| Object Interaction | TurnTowardsFace, GoToObject, RollObject, PopAWheelie, PickupObject, PlaceObjectOnGroundHere |
| Photos | PhotosInfo, Photo, Thumbnail, DeletePhoto |
| Audio | SayText, SetMasterVolume, ExternalAudioStreamPlayback |
| Streaming Feeds | EventStream (status, robot state, world), BehaviorControl (bidirectional AI control), CameraFeed, AudioFeed, NavMapFeed |
| Status | BatteryState, VersionState, EnableMirrorMode, EnableImageStreaming, IsImageStreamingEnabled |
| Control | CancelActionByIdTag, RollBlock |
| Image | CaptureSingleImage |

### BLE RTS protocol messages (from messageExternalComms.clad)
Wire-level serialization: CLAD (tag-length-value), little-endian, encrypted via NaCl/libsodium after handshake.

Handshake sequence (v2/v3/v4/v5):
1. `RtsConnRequest` (32-byte Curve25519 public key)
2. `RtsConnResponse` (connection type: FirstTimePair/Reconnection + 32-byte robot public key)
3. `RtsNonceMessage` (24-byte to-robot nonce + 24-byte to-device nonce)
4. `RtsChallengeMessage` (uint32 challenge number)
5. `RtsChallengeSuccessMessage` (empty, indicates crypto established)

Post-handshake messages:
| Message | Direction | Purpose |
|---------|-----------|---------|
| RtsWifiScanRequest/Response | C→R / R→C | Scan visible WiFi APs |
| RtsWifiConnectRequest/Response | C→R / R→C | Connect to WiFi with SSID+password |
| RtsWifiForgetRequest/Response | C→R / R→C | Forget WiFi networks |
| RtsWifiIpRequest/Response | C→R / R→C | Get IP address info |
| RtsWifiAccessPointRequest/Response | C→R / R→C | Enable/disable WiFi AP mode |
| RtsStatusRequest/Response | C→R / R→C | Get status (WiFi, BLE, battery, version, ESN, has-owner, is-cloud-authed) |
| RtsCloudSessionRequest/Response | C→R / R→C | Authorize with cloud token, get client_token_guid |
| RtsOtaUpdateRequest/Response | C→R / R→C | Start OTA firmware update |
| RtsOtaCancelRequest | C→R | Cancel ongoing OTA |
| RtsLogRequest/Response | C→R / R→C | Download robot logs |
| RtsFileDownload | R→C | File download chunks |
| RtsSdkProxyRequest/Response | C→R / R→C | Proxy gRPC calls over BLE |
| RtsSshRequest/Response | C→R / R→C | Deploy SSH keys (OSKR) |
| RtsCancelPairing | C→R | Cancel pairing |
| RtsForceDisconnect | C→R | Force BLE disconnect |
| RtsAppConnectionIdRequest/Response | C→R / R→C | Set app connection ID |
| RtsResponse | R→C | Error response |

## Threat model + guardrails
- Scope: only owned devices. The project aims to create a clean-room local-first replacement for the companion app.
- Never extract DDL cloud credentials or session tokens — use only the local BLE+gRPC protocol.
- Voice processing (chipper) is out of scope — wire-pod already replaces this comprehensively.
- No firmware modification required (production robots work with wire-pod; OSKR robots allow SSH but are not required).
- Anki/DDL copyrights apply to proto files and SDK code — derive protocol specs clean-room from observation + publicly documented behavior.
- Do NOT MITM TLS connections for capture — use the existing SDK with known certificate to record known-good traffic, or capture at the BLE level during onboarding.

## First experiments (do these first)
1. **Obtain APK**: `apkeep com.anki.vector` or `com.digitaldreamlabs.vector` (check which is available on Play Store)
2. **Clone SDKs for reference**:
   - `git clone https://github.com/anki/vector-python-sdk` — proto files, connection logic, auth flow
   - `git clone https://github.com/digital-dream-labs/vector-bluetooth` — BLE RTS protocol implementation
   - `git clone https://github.com/kercre123/wire-pod` — chipper replacement, cloud auth flow reference
3. **Static analysis of APK**:
   - Grep for UUIDs: `7d2a4bda-d29b-4152-b725-2491478c5cd7`, `30619f2d-0f54-41bd-a65a-7588d8c85b45`
   - Grep for `_ankivector._tcp.local.`, gRPC port references, `server_config.json`
   - Grep for cloud endpoints: `token.api.anki.com`, `jdocs.api.anki.com`, chipper endpoint
   - Extract embedded certs/CA bundles
4. **Dynamic observation** (if robot available):
   - BLE HCI snoop during onboarding (pairing, WiFi provisioning, auth flow)
   - mDNS scan: `avahi-browse _ankivector._tcp.local. -r`
   - gRPC reflection: attempt `grpcurl -insecure <robot-ip>:443 list` (won't work without cert, but worth trying)
   - With SDK cert: record known-good gRPC traffic via the SDK's connection
5. **SDK reference test**:
   - Run the Python SDK against a robot (if available) to verify protocol version 5
   - Capture protobuf message traces with `grpc_trace` logging
   - Document the full auth flow: BLE → cloud token → client_token_guid → gRPC TLS

## Protocol hypotheses (to validate)

### Pairing/bonding steps (BLE onboarding)
1. Robot enters BLE advertising after power-on / double-press backpack button
2. App scans for Vector BLE devices (name: `Vector-XXXX`)
3. PIN pairing (6-digit PIN displayed on Vector's screen) — used to authenticate initial BLE connection
4. NaCl/libsodium key exchange: Curve25519 public key exchange → shared secret
5. App requests WiFi scan → user selects network and enters password
6. App sends RtsWifiConnectRequest with SSID + password
7. Robot connects to WiFi network
8. App requests robot's session certificate via BLE (after WiFi connected)
9. App authenticates with cloud (or local wire-pod) using user credentials → gets session token
10. App sends RtsCloudSessionRequest(session_token) → robot validates with cloud → returns client_token_guid
11. App now has: robot certificate (.cert file) + client_token_guid + robot IP → gRPC TLS connection

### Session state machine (WiFi gRPC)
1. Client discovers robot via mDNS or known IP
2. Client opens TLS connection to robot:443 with robot cert pinning + GUID bearer token
3. Client calls ProtocolVersion RPC to negotiate protocol version
4. Client calls SDKInitialization (optional, for SDK metadata)
5. Client opens EventStream to receive robot state events
6. For motor control: client opens BehaviorControl bidirectional stream, requests control, waits for granted
7. Only one primary controller at a time; secondary clients get read-only access
8. Stream closure or disconnect drops control, session token invalidated
9. BehaviorControl priority levels: OVERRIDE_BEHAVIORS, DEFAULT, RESERVE_CONTROL

### Payload encoding
- gRPC: **Protobuf 3** (proto3) — `.proto` files at `anki_vector/messaging/`
- BLE: **CLAD** (Compact Language for Anki Devices) — tag-length-value binary format
- BLE encryption: **NaCl/libsodium** (secretbox after Curve25519 key exchange)
- Images: JPEG over gRPC stream
- Audio: Ogg/Opus (chipper voice stream), raw PCM via AudioFeed

### Timing constraints
- BehaviorControl stream: requires periodic keepalive (KeepAlivePing messages)
- mDNS discovery: ~5 second timeout typical
- BLE scan: ~3 second windows
- EventStream: persistent long-lived connection with server-side push
- OTA downloads: chunked with progress reporting

## Control surface inventory (what the replacement app must support)

### Onboarding/pairing UX (BLE)
- [ ] Scan for nearby Vector robots via BLE (filter by name `Vector-XXXX`)
- [ ] Display PIN from robot screen (or robot speaks it)
- [ ] NaCl key exchange + challenge-response auth
- [ ] WiFi scan → network selection → password entry → connect
- [ ] Retrieve robot session certificate via BLE
- [ ] Cloud/local auth → obtain client_token_guid
- [ ] Store cert + GUID + IP for future connections
- [ ] Robot name display, battery level, firmware version

### Core controls (gRPC — MVP)
- [ ] Drive: forward, backward, turn (DriveWheels)
- [ ] Head tilt up/down (MoveHead or SetHeadAngle)
- [ ] Lift arm up/down (MoveLift or SetLiftHeight)
- [ ] Play animations by trigger name (PlayAnimationTrigger)
- [ ] Say text via TTS (SayText)
- [ ] Set master volume (SetMasterVolume)
- [ ] Display face image / eye color (DisplayFaceImageRGB, SetEyeColor)
- [ ] Battery level display (BatteryState)
- [ ] Dock/undock charger (DriveOffCharger, DriveOnCharger)
- [ ] Stop all motors (StopAllMotors)

### Status monitoring
- [ ] Real-time battery percentage and charging state
- [ ] WiFi connection status + SSID
- [ ] Firmware version, ESN display
- [ ] Robot state events (EventStream: wake word, onboarding state, etc.)

### Advanced (nice-to-have)
- [ ] Camera feed viewer (CameraFeed stream)
- [ ] Cube/accessory interaction (ConnectCube, FlashCubeLights)
- [ ] Face recognition management (enroll, list, erase faces)
- [ ] Photo capture and gallery (CaptureSingleImage, PhotosInfo, Photo, DeletePhoto)
- [ ] NavMap visualization (NavMapFeed)
- [ ] Custom object definition for visual markers
- [ ] BLE SDK proxy fallback (for environments without WiFi access to robot)

### Settings persistence
- [ ] Locale / wake word language
- [ ] Timezone
- [ ] Default location (city/country for weather)
- [ ] Measurement units (metric/imperial)
- [ ] Data analytics toggle
- [ ] Robot name customization
- [ ] Eye color presets

### Error handling and recovery
- [ ] Robot not found on network (mDNS timeout)
- [ ] TLS cert mismatch or expiration
- [ ] Invalid GUID / session token → re-auth flow
- [ ] Behavior control denied (another client is primary)
- [ ] Robot on charger restrictions (some actions unavailable)
- [ ] Low battery state
- [ ] WiFi disconnection during BLE setup (retry)
- [ ] OTA failure recovery

## Evidence checklist
- [ ] APK acquired: package ID confirmed, SHA256 recorded, version code noted
- [ ] Proto files extracted from SDK (source: `anki/vector-python-sdk`)
- [ ] BLE RTS protocol documented (source: `digital-dream-labs/vector-bluetooth`)
- [ ] gRPC service methods cataloged (11 proto files, ~45 RPCs)
- [ ] Auth flow documented (source: Anki SDK connection docs)
- [ ] Cloud endpoints cataloged (DDL chipper, jdocs, TMS)
- [ ] mDNS service type confirmed: `_ankivector._tcp.local.`
- [ ] BLE UUIDs confirmed: Read `7d2a4bda-...`, Write `30619f2d-...`
- [ ] APK static analysis (grep for endpoints, UUIDs, native libs)
- [ ] HCI snoop log (requires robot)
- [ ] gRPC decrypted capture (requires robot + SDK cert)
- [ ] mDNS capture (requires robot on network)

## Spec output (clean-room)
- Protocol spec: `docs/specs/vector-robot.md` — gRPC service definition, protobuf message formats, auth flow, BLE RTS protocol
- Derived spec YAML: `device-specs/devices/vector-robot.yaml` — machine-readable protocol description
- Proto compilation: regenerate Python stubs from SDK `.proto` files for reference

## RE Plan: Highest-value work

Given Vector's already-open protocol (all proto files, BLE protocol, and auth flow are publicly documented in open-source repos), the RE value-add is NOT in protocol discovery but in:

### Tier 1: Build a local-first open-source companion app (highest impact)
- The official DDL app is proprietary, has cloud dependency, and may stop working if DDL shuts down
- The gRPC + BLE protocol is fully known — the problem is implementation, not discovery
- A local-only app (web-based or mobile) that can onboard a Vector robot and provide core controls without any cloud dependency would serve the community permanently

### Tier 2: Document the protocol in a single, accessible spec
- While the information is available across 5+ repos and internal DDL docs, it's scattered
- A single consolidated protocol spec (this target) with clean-room derived documentation
- Include wire-level examples, hex dumps, and test vectors

### Tier 3: Verify protocol against live capture (requires robot)
- HCI snoop the BLE onboarding flow end-to-end
- Decrypt and document the CLAD message exchange
- Capture the gRPC TLS handshake and compare certificate to documented flow
- Validate that the SDK's documented auth flow matches observed behavior on current firmware

### Tier 4: Discover undocumented extensions
- OSKR-only BLE messages (RtsSshRequest, etc.)
- Custom escape-pod extension protocol (gRPC-based inter-process communication for plugins)
- Any post-Anki DDL additions to the gRPC API (check firmware changelogs)
- Differences between Vector 1.0 and Vector 2.0 protocol

### What NOT to RE (already fully open)
- gRPC service definition: all proto files are Apache 2.0 licensed in the SDK repo
- BLE RTS protocol: source code in `digital-dream-labs/vector-bluetooth`
- Voice processing (chipper): open-source reference in `digital-dream-labs/chipper`, community-maintained in `kercre123/wire-pod`
- Cloud auth flow: documented in DDL's own SDK docs (`Victor SDK Connection Authentication.md`)

## References
- https://github.com/anki/vector-python-sdk — Official Python SDK with proto files (★601)
- https://github.com/digital-dream-labs/vector — Full robot OS source (★117)
- https://github.com/digital-dream-labs/chipper — Voice processing proxy reference (★58)
- https://github.com/digital-dream-labs/vector-bluetooth — BLE RTS protocol implementation (★13)
- https://github.com/digital-dream-labs/vector-cloud — Cloud services (jdocs, TMS) (★37)
- https://github.com/digital-dream-labs/vector-web-setup — Web-based BLE onboarding tool (★79)
- https://github.com/digital-dream-labs/escape-pod-extension — Plugin protocol for escape pod (★33)
- https://github.com/kercre123/wire-pod — Community chipper replacement, fully local (★770)
- https://github.com/codaris/Anki.Vector.SDK — .NET SDK implementation (★92)
- https://developer.anki.com/vector/docs/ — Official SDK docs (archived)
- https://www.digitaldreamlabs.com/pages/meet-vector — DDL Vector product page
- https://play.google.com/store/apps/details?id=com.anki.vector — Original Vector companion app
