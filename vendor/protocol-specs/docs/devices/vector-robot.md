# Anki Vector Robot

> **Status**: Research — protocol fully documented, local-first tools available
> **Protocol**: Wi-Fi (gRPC + protobuf over TLS) + BLE (CLAD + NaCl encryption)
> **Manufacturer**: Anki (2016–2019) → Digital Dream Labs (2019–present)
> **Manufacturer Status**: Active but cloud-reliant; community local replacements exist

## Overview

Vector is a small AI-powered companion robot with an expressive face display,
treads, a lift arm, and a 4-microphone array. Originally from Anki, now maintained
by Digital Dream Labs (DDL). The protocol is fully open: Apache 2.0 licensed `.proto`
files, open-source BLE protocol implementation, and a community-maintained local
voice server replacement (wire-pod).

The robot can be fully controlled locally over Wi-Fi via gRPC after a one-time
BLE onboarding, with zero cloud dependency when using wire-pod.

## Hardware

| Property | Value |
|----------|-------|
| Model | Vector 1.0 / Vector 2.0 |
| Chipset | Qualcomm APQ8009 (Snapdragon 212), quad-core Cortex-A7 @ 1.3 GHz |
| RAM | 1 GB |
| Storage | 8 GB eMMC |
| Display | 184 × 96 IPS color |
| Camera | HD (720p) |
| Microphones | 4-mic array |
| Sensors | Touch, 4× drop, IMU, cliff |
| Motors | 2× treads, 1× head tilt, 1× lift arm |
| Wi-Fi | 802.11n 2.4 GHz |
| Bluetooth | 4.0 BLE |
| Battery | Li-Po (dock-charged) |
| FCC ID | 2AKKJ-VEC1 |

## Protocol Summary

Vector uses a **dual-stack** protocol:

### 1. Wi-Fi gRPC (port 443, primary control)

- **Serialization**: Protobuf 3 (proto3)
- **Transport**: gRPC over HTTP/2 over TLS
- **Authentication**: TLS certificate pinning (robot self-signed cert) + GUID bearer token
- **mDNS discovery**: `_ankivector._tcp.local.` → `Vector-XXXX.local`
- **REST gateway**: Many RPCs also exposed as `POST /v1/<endpoint>` JSON endpoints
- **Protocol version**: Current version = 5 (2019.03.12)
- **Proto source**: [anki/vector-python-sdk](https://github.com/anki/vector-python-sdk) (Apache 2.0)

### 2. BLE RTS Protocol (onboarding/setup/recovery)

- **Serialization**: CLAD (Compact Language for Anki Devices) — tag-length-value, little-endian
- **Encryption**: NaCl/libsodium (Curve25519 key exchange + secretbox after handshake)
- **Protocol versions**: v2, v3, v4, v5 (backward compatible)
- **Source**: [digital-dream-labs/vector-bluetooth](https://github.com/digital-dream-labs/vector-bluetooth)

### BLE Characteristics

| UUID | Name | Description |
|------|------|-------------|
| `7d2a4bda-d29b-4152-b725-2491478c5cd7` | Read | RTS protocol read (notify) |
| `30619f2d-0f54-41bd-a65a-7588d8c85b45` | Write | RTS protocol write |

Advertised name pattern: `Vector-XXXX` (4 alphanumeric chars from ESN).

### BLE RTS Handshake Sequence

```
1. CLIENT → ROBOT:  RtsConnRequest      (32-byte Curve25519 public key)
2. ROBOT  → CLIENT:  RtsConnResponse     (FirstTimePair/Reconnection + 32-byte robot pubkey)
3. CLIENT → ROBOT:  RtsNonceMessage      (24-byte client nonce + 24-byte robot nonce)
4. ROBOT  → CLIENT:  RtsChallengeMessage (uint32 challenge number)
5. CLIENT → ROBOT:  RtsChallengeSuccessMessage (empty — crypto established)
```

After handshake, all messages are encrypted with NaCl/libsodium secretbox.

### BLE Message Catalog (RTS v2–v5)

| Message | Direction | Description |
|---------|-----------|-------------|
| `RtsConnRequest` | C→R | Curve25519 public key |
| `RtsConnResponse` | R→C | Connection type + robot public key |
| `RtsNonceMessage` | C→R | 24-byte client + robot nonces |
| `RtsAck` | R→C | Connection tag acknowledgment |
| `RtsChallengeMessage` | R→C | uint32 challenge |
| `RtsChallengeSuccessMessage` | C→R | Crypto established |
| `RtsWifiScanRequest` | C→R | Request WiFi scan |
| `RtsWifiScanResponse[_2,_3]` | R→C | WiFi AP list with signal/auth/hidden/provisioned |
| `RtsWifiConnectRequest` | C→R | SSID, password, auth type, timeout, hidden |
| `RtsWifiConnectResponse[_3]` | R→C | WiFi state + connect result |
| `RtsWifiForgetRequest` | C→R | Delete one or all WiFi networks |
| `RtsWifiForgetResponse` | R→C | Did delete + SSID |
| `RtsWifiIpRequest` | C→R | Request IP info |
| `RtsWifiIpResponse` | R→C | IPv4/IPv6 address info |
| `RtsWifiAccessPointRequest` | C→R | Enable/disable AP mode |
| `RtsWifiAccessPointResponse` | R→C | AP SSID + password |
| `RtsStatusRequest` | C→R | Request status |
| `RtsStatusResponse[_2,_3,_4,_5]` | R→C | WiFi/BLE/battery/version/ESN/owner/cloud-auth |
| `RtsCloudSessionRequest[_5]` | C→R | Cloud session token → get GUID |
| `RtsCloudSessionResponse` | R→C | Cloud authorization status |
| `RtsOtaUpdateRequest` | C→R | OTA URL |
| `RtsOtaUpdateResponse` | R→C | OTA progress (current/expected) |
| `RtsOtaCancelRequest` | C→R | Cancel OTA |
| `RtsLogRequest` | C→R | Request logs |
| `RtsSdkProxyRequest` | C→R | Proxy gRPC call over BLE |
| `RtsSdkProxyResponse` | R→C | gRPC proxy response |
| `RtsSshRequest` | C→R | Deploy SSH key (OSKR only) |
| `RtsSshResponse` | R→C | SSH key deployment result |
| `RtsCancelPairing` | C→R | Cancel pairing |
| `RtsForceDisconnect` | C→R | Force BLE disconnect |
| `RtsAppConnectionIdRequest` | C→R | Set app connection ID |
| `RtsAppConnectionIdResponse` | R→C | Connection ID confirmation |
| `RtsFileDownload` | R→C | File download chunks |
| `RtsResponse` | R→C | Error response |

### Authentication Flow

```
ONBOARDING (one-time):
1. Robot advertises BLE: "Vector-XXXX"
2. App connects, PIN displayed on Vector's screen
3. NaCl key exchange (Curve25519) → encrypted channel
4. App requests WiFi scan → user selects network
5. App sends RtsWifiConnectRequest(SSID, password)
6. Robot connects to WiFi, starts gRPC server on port 443
7. App retrieves robot's session certificate via BLE
8. App authenticates with cloud (or wire-pod) → session token
9. App sends RtsCloudSessionRequest(token) → robot returns client_token_guid
10. App stores: cert + GUID + IP → ready for gRPC sessions

NORMAL OPERATION (subsequent connections):
1. Discover robot via mDNS: _ankivector._tcp.local.
2. Open TLS connection to robot:443
3. Pin TLS to stored robot certificate
4. Set Authorization: Bearer <guid> header
5. Call ProtocolVersion RPC to negotiate
6. Open EventStream for status updates
7. Open BehaviorControl stream for motor control
```

### gRPC Service: ExternalInterface (48 RPCs)

Complete catalog from `external_interface.proto`. All listed with their REST gateway
endpoints where available.

#### Version & Authentication
| RPC | REST | Description |
|-----|------|-------------|
| `ProtocolVersion` | `POST /v1/protocol_version` | Negotiate protocol version |
| `SDKInitialization` | `POST /v1/sdk_initialization` | SDK version info |
| `UserAuthentication` | `POST /v1/user_authentication` | Authenticate with cloud token, get GUID |

#### Motor Control
| RPC | REST | Description |
|-----|------|-------------|
| `DriveWheels` | — | Set wheel speeds and accelerations |
| `MoveHead` | — | Move head by degrees |
| `MoveLift` | — | Move lift arm |
| `StopAllMotors` | — | Emergency stop all motors |
| `DriveStraight` | — | Drive straight (distance + speed) |
| `TurnInPlace` | — | Rotate in place |
| `SetHeadAngle` | — | Absolute head angle |
| `SetLiftHeight` | — | Absolute lift height |

#### Animation & Display
| RPC | REST | Description |
|-----|------|-------------|
| `PlayAnimation` | — | Play animation by name |
| `PlayAnimationTrigger` | — | Play animation by trigger |
| `ListAnimations` | `POST /v1/list_animations` | List available animations |
| `ListAnimationTriggers` | `POST /v1/list_animation_triggers` | List triggers |
| `DisplayFaceImageRGB` | `POST /v1/display_face_image_rgb` | Show image on face screen |
| `SetEyeColor` | `POST /v1/set_eye_color` | Change eye color |

#### Navigation
| RPC | REST | Description |
|-----|------|-------------|
| `GoToPose` | `POST /v1/go_to_pose` | Drive to (x, y, angle) |
| `DockWithCube` | `POST /v1/dock_with_cube` | Approach and dock with cube |
| `DriveOffCharger` | `POST /v1/drive_off_charger` | Leave charger |
| `DriveOnCharger` | `POST /v1/drive_on_charger` | Return to charger |

#### Vision & Faces
| RPC | REST | Description |
|-----|------|-------------|
| `FindFaces` | `POST /v1/find_faces` | Look around for faces |
| `LookAroundInPlace` | `POST /v1/look_around_in_place` | Scan environment |
| `EnableFaceDetection` | `POST /v1/enable_face_detection` | Toggle face detection |
| `EnableMarkerDetection` | `POST /v1/enable_marker_detection` | Toggle marker detection |
| `EnableMotionDetection` | `POST /v1/enable_motion_detection` | Toggle motion detection |

#### Face Enrollment
| RPC | REST | Description |
|-----|------|-------------|
| `CancelFaceEnrollment` | `POST /v1/cancel_face_enrollment` | Cancel enrollment |
| `RequestEnrolledNames` | `POST /v1/request_enrolled_names` | List enrolled faces |
| `UpdateEnrolledFaceByID` | `POST /v1/update_enrolled_face_by_id` | Rename a face |
| `EraseEnrolledFaceByID` | `POST /v1/erase_enrolled_face_by_id` | Delete one face |
| `EraseAllEnrolledFaces` | `POST /v1/erase_all_enrolled_faces` | Delete all faces |
| `SetFaceToEnroll` | `POST /v1/set_face_to_enroll` | Start face enrollment |

#### Object Interaction
| RPC | REST | Description |
|-----|------|-------------|
| `TurnTowardsFace` | — | Turn towards a face |
| `GoToObject` | — | Drive to specified object |
| `RollObject` | — | Roll a cube |
| `PopAWheelie` | — | Pop a wheelie with cube |
| `PickupObject` | — | Pick up an object |
| `PlaceObjectOnGroundHere` | — | Place object on ground |

#### Cube Control
| RPC | REST | Description |
|-----|------|-------------|
| `ConnectCube` | `POST /v1/connect_cube` | Connect to a cube |
| `DisconnectCube` | `POST /v1/disconnect_cube` | Disconnect cube |
| `CubesAvailable` | `POST /v1/cubes_available` | List visible cubes |
| `FlashCubeLights` | `POST /v1/flash_cube_lights` | Flash cube lights |
| `SetCubeLights` | — | Program cube LED pattern |
| `ForgetPreferredCube` | `POST /v1/forget_preferred_cube` | Reset cube preference |
| `SetPreferredCube` | `POST /v1/set_preferred_cube` | Set preferred cube |
| `RollBlock` | `POST /v1/roll_block` | Roll block |

#### Custom Objects
| RPC | REST | Description |
|-----|------|-------------|
| `DeleteCustomObjects` | `POST /v1/delete_custom_objects` | Clear custom objects |
| `CreateFixedCustomObject` | `POST /v1/create_fixed_custom_object` | Add fixed object |
| `DefineCustomObject` | `POST /v1/define_custom_object` | Define custom marker |

#### Audio
| RPC | REST | Description |
|-----|------|-------------|
| `SayText` | `POST /v1/say_text` | Text-to-speech |
| `SetMasterVolume` | — | Volume control |

#### Streaming Feeds
| RPC | REST | Description |
|-----|------|-------------|
| `EventStream` | `POST /v1/event_stream` | Server-push status/event stream |
| `BehaviorControl` | — | Bidirectional AI override stream |
| `AssumeBehaviorControl` | `POST /v1/assume_behavior_control` | Take control unary variant |
| `AudioFeed` | `POST /v1/audio_feed` | Robot mic audio stream |
| `CameraFeed` | `POST /v1/camera_feed` | Robot camera stream |
| `NavMapFeed` | `POST /v1/nav_map_feed` | Navigation map stream |
| `ExternalAudioStreamPlayback` | — | Bidirectional audio playback stream |

#### Status & Control
| RPC | REST | Description |
|-----|------|-------------|
| `BatteryState` | `POST /v1/battery_state` | Battery level + charging status |
| `VersionState` | `POST /v1/version_state` | Firmware/OS/ESN info |
| `EnableMirrorMode` | `POST /v1/enable_mirror_mode` | Mirror display mode |
| `EnableImageStreaming` | `POST /v1/enable_image_streaming` | Toggle image streaming |
| `IsImageStreamingEnabled` | `POST /v1/is_image_streaming_enabled` | Query streaming state |
| `CancelActionByIdTag` | `POST /v1/cancel_action_by_id_tag` | Cancel queued action |

#### Photos
| RPC | REST | Description |
|-----|------|-------------|
| `PhotosInfo` | `POST /v1/photos_info` | List stored photos |
| `Photo` | `POST /v1/photo` | Get a full photo |
| `Thumbnail` | `POST /v1/thumbnail` | Get a photo thumbnail |
| `DeletePhoto` | `POST /v1/delete_photo` | Delete a photo |
| `CaptureSingleImage` | `POST /v1/capture_single_image` | Take a photo |

## Discovery

### mDNS (Wi-Fi)
- Service type: `_ankivector._tcp.local.`
- Hostname: `Vector-XXXX.local.` (XXXX = last 4 of ESN)
- Port: `443`
- Use `vector_discover.py` for automatic discovery

### BLE
- Advertised name: `Vector-XXXX` (XXXX = last 4 of ESN)
- BLE address: random resolvable (Anki BLE stack)
- Read UUID: `7d2a4bda-d29b-4152-b725-2491478c5cd7`
- Write UUID: `30619f2d-0f54-41bd-a65a-7588d8c85b45`
- Pairing: PIN displayed on screen (6 digits)

### Cloud Infrastructure (optional)

Vector's cloud services are voice-processing-only and replaceable:

| Service | Purpose | Replacement |
|---------|---------|-------------|
| **chipper** | Voice intent processing (ogg→intents) | [wire-pod](https://github.com/kercre123/wire-pod) |
| **jdocs** | JSON document store (settings/state) | wire-pod / escape-pod |
| **TMS** | Token management service | wire-pod |
| **vector-cloud** | Cloud services orchestration | [digital-dream-labs/vector-cloud](https://github.com/digital-dream-labs/vector-cloud) |

## Tools Used

- [x] Source proto files (Apache 2.0 licensed, from `anki/vector-python-sdk`)
- [x] BLE RTS protocol source (from `digital-dream-labs/vector-bluetooth`)
- [x] Community open-source implementations (wire-pod, escape-pod)
- [ ] HCI snoop log (requires physical robot)
- [ ] gRPC decrypted capture (requires physical robot + cert)
- [ ] mDNS capture (requires robot on network)

## Local Tooling

| Tool | Path | Description |
|------|------|-------------|
| `vector_discover.py` | `scripts/vector_discover.py` | mDNS discovery, finds robots on local network |
| `vector_status.py` | `scripts/vector_status.py` | gRPC status client (battery, version, robot state) |

### Using the Tools

```bash
# Discover robots on the local network
python scripts/vector_discover.py --timeout 5

# Get robot status (requires cert + GUID from BLE onboarding)
python scripts/vector_status.py 192.168.1.42 \
  --cert ~/.anki_vector/Vector-A1B2-00e00000.cert \
  --guid YOUR_CLIENT_TOKEN_GUID
```

## Protocol Gaps

| Gap | Details | Workaround |
|-----|---------|------------|
| Certificate extraction via BLE | RtsCloudSessionRequest flow not implemented in our tools | Use official anki_vector SDK once for onboarding, then extract cert |
| gRPC BehaviorControl stream | Full bidirectional stream not yet implemented | REST endpoints cover most status RPCs |
| OSKR-specific BLE messages | RtsSshRequest/RtsSshResponse not tested | Requires OSKR firmware |
| Vector 2.0 protocol differences | Not yet characterized | Assumes Vector 1.0 protocol applies |
| Proto stub compilation | Not compiled — REST gateway used instead | Compile with grpcio-tools for native gRPC performance |
| Dynamic observation | No live robot capture yet | Protocol derived from open-source SDK sources |

## References

- [anki/vector-python-sdk](https://github.com/anki/vector-python-sdk) — Official Python SDK, proto files (★601)
- [digital-dream-labs/vector](https://github.com/digital-dream-labs/vector) — Full robot OS source (★117)
- [digital-dream-labs/chipper](https://github.com/digital-dream-labs/chipper) — Voice processing proxy (★58)
- [digital-dream-labs/vector-bluetooth](https://github.com/digital-dream-labs/vector-bluetooth) — BLE RTS protocol (★13)
- [digital-dream-labs/vector-cloud](https://github.com/digital-dream-labs/vector-cloud) — Cloud services (★37)
- [digital-dream-labs/vector-web-setup](https://github.com/digital-dream-labs/vector-web-setup) — Web BLE onboarding (★79)
- [digital-dream-labs/escape-pod-extension](https://github.com/digital-dream-labs/escape-pod-extension) — Plugin protocol (★33)
- [kercre123/wire-pod](https://github.com/kercre123/wire-pod) — Community local chipper replacement (★770)
- [codaris/Anki.Vector.SDK](https://github.com/codaris/Anki.Vector.SDK) — .NET SDK (★92)
- [developer.anki.com/vector/docs/](https://developer.anki.com/vector/docs/) — Official SDK docs (archived)
- [Protocol target spec](https://github.com/PigsCanFlyLabs/opengreeniot-protocol-docs/blob/main/targets/vector-robot.md) — Full RE target spec

## Contributors

- @opengreeniot — protocol consolidation, local-first tools
