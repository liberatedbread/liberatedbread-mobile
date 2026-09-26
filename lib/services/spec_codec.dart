// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show immutable;

import '../src/rust/api/device_api.dart';
import '../src/rust/api/print_api.dart'
    show LabelCanvasDto, PrintDither, RasterPrintDto;
import '../src/rust/api/spec_handle.dart'
    show CatalogueEntryDto, SpecLoadFailureDto, UdpProbeDto;

// Re-export the flutter_rust_bridge DTOs so widgets and tests depend on this
// abstraction instead of importing the generated bindings directly. The DTOs
// have const constructors, so a fake codec can build them by hand in tests
// without the native library. (Their generated `==` compares List fields by
// reference, not deeply — see device_spec_match_provider for where the match
// lookup works around that.)
export '../src/rust/api/device_api.dart'
    show
        DeviceSpecDto,
        EntityDto,
        EntityActionDto,
        EntityWriteDto,
        ServiceDto,
        CharacteristicDto,
        CommandDto,
        ParameterDto,
        FormatFieldDto,
        DecodedValueDto,
        ImageUploadDto,
        PanelResolutionDto,
        ImageWriteDto,
        ImageWritePlanDto,
        StoredUploadDto,
        StoredUploadPlanDto,
        StoredUploadEventDto,
        StoredUploadEventKind,
        StoredPlayDto,
        PlaylistWritesDto,
        EffectEntryDto,
        MatchResult,
        MatchConfidence,
        MacPrefixDto,
        ScanMatch,
        ScannedDeviceDto,
        NetworkDeviceDto,
        SpecIdentityDto,
        ProfileInfoDto,
        ProfileCharacteristicDto,
        NetworkEntityDto,
        NetworkEntitySurfaceDto,
        NetworkCapabilitiesDto,
        NetworkCredentialDto,
        NetworkCredentialIssuanceDto,
        NetworkActionDto,
        NetworkOptionDto,
        NetworkReadBackDto,
        NetworkReadingDto,
        NetworkReadingKind,
        NetworkSourceParamDto,
        NetworkInstanceDto,
        NetworkRoleReadingDto,
        SoapRequestDto,
        HttpRequestDto,
        KasaRequestDto,
        TuyaBroadcastDto,
        RabbitAirRequestDto,
        RoombaRequestDto,
        MqttRequestDto,
        WebSocketSurfaceDto,
        WebSocketFrameDto,
        WebSocketChannelDto,
        WebSocketHeaderDto,
        RoombaAnnouncementDto,
        MqttIncomingDto,
        MqttParsedDto,
        QuerySourceDto,
        LifxServiceDto,
        LifxStateDto,
        LifxZoneColorDto,
        LifxZonesDto,
        LifxAccessPointDto,
        SoftApProfileDto,
        BleProvisioningProfileDto,
        SecurityAdvisoryDto,
        SafetyAdvisoryDto,
        SetupInstructionsDto,
        SetupMethodDto,
        SetupStageDto,
        SetupStepDto,
        TroubleshootingDto,
        FactoryResetDto,
        FactoryResetProcedureDto,
        RejoinDto,
        WemoAccessPointDto,
        WemoConnectAttemptDto,
        WemoJoinStatus,
        BrotherQlStatusDto,
        BrotherQlJobParamsDto,
        CameraDto,
        CameraStreamDto,
        CameraKeepaliveDto,
        BleHandshakeDto,
        BleHandshakeStepDto,
        StateTopicFallbackDto;

// `MacPrefixDto.confidence` is generated into the spec module rather than the
// api one, because the enum is declared where the catalogue is parsed. Callers
// of this abstraction should not have to know that.
export '../src/rust/spec/types.dart' show MacPrefixConfidence;

// `ParameterDto.allowed` crosses the FFI as flutter_rust_bridge's Int64List
// (a List<BigInt>, not dart:typed_data's). Re-export it so tests and widgets
// can build parameter DTOs carrying allowed values while still depending only
// on this abstraction.
export 'package:flutter_rust_bridge/flutter_rust_bridge.dart' show Int64List;

// The catalogue DTOs live in their own generated module because the Rust
// types that produce them do. Re-exported here for the same reason every
// other DTO is: consumers depend on this abstraction, not on where
// flutter_rust_bridge happened to put a file.
export '../src/rust/api/spec_handle.dart'
    show
        CatalogueEntryDto,
        SpecLoadFailureDto,
        UdpIdentityFieldDto,
        UdpProbeDto;

// The printing DTOs, from their own generated module for the same reason.
export '../src/rust/api/print_api.dart'
    show
        LabelCanvasDto,
        PrintChoiceDto,
        PrintDither,
        PrintMediaDto,
        RasterPrintDto;

/// Abstraction over the Rust device-spec codec (flutter_rust_bridge FFI).
///
/// The production implementation ([RealSpecCodec]) delegates to the generated
/// top-level functions in `src/rust/api/device_api.dart`, which require the
/// native Rust library to be loaded. Wrapping them behind this interface lets
/// the typed-control UI be unit/widget-tested with a fake that returns
/// hand-built specs and canned bytes, with no native library present.
abstract class SpecCodec {
  /// Parse a device-spec YAML string into a [DeviceSpecDto].
  Future<DeviceSpecDto> loadDeviceSpec(String yaml);

  /// Parse the whole catalogue and hold it, returning the handle the match,
  /// scan, adopt and group paths ask through.
  ///
  /// [specs] is key → YAML in catalogue order (bundled assets first, then
  /// installed packs — the order the pack-shadows-bundled rule depends on).
  ///
  /// The catalogue is loaded, not returned: parsing 203 specs into 203
  /// [DeviceSpecDto]s and decoding them on the UI isolate was a ~70-77 ms
  /// stall on the first scan result, for data that only two dozen light
  /// fields per spec were ever read from. What comes back is those fields
  /// ([SpecCatalogue.specs]) plus the ability to ask for one spec's full DTO
  /// by index, for the one or two a screen actually renders.
  ///
  /// [onProgress] is called with the number of specs parsed so far after
  /// each chunk, for a caller that wants to show the warm-up.
  Future<SpecCatalogue> loadCatalogue(
    Map<String, String> specs, {
    void Function(int loaded, int total)? onProgress,
  });

  /// Which of the spec's `device.variants[]` the BLE device in front of us
  /// could be, from what it advertised and what it carries.
  ///
  /// Checked against each entity's own `variants`. Not the surviving entity
  /// NAMES, which was the obvious shape and is wrong: a family spec can
  /// declare two entities with one name on different command dialects, so a
  /// name is not an identity here.
  ///
  /// Separate from [loadDeviceSpec] because that one is cached by spec string
  /// and must stay device-independent — a device-dependent answer there would
  /// serve one unit's narrowing to the next. Empty means DO NOT NARROW:
  /// narrowing a device we cannot identify would blank it.
  Future<List<String>> bleVariantNamesForDevice({
    required String yaml,
    required String deviceName,
    required List<String> serviceUuids,
  });

  /// Find every spec matching a device we are already connected to, with the
  /// reasons it matched. Expects discovered GATT service UUIDs.
  Future<List<MatchResult>> matchDeviceToSpec({
    required List<DeviceSpecDto> specs,
    required String deviceName,
    required List<String> advertisedServiceUuids,
  });

  /// Rank the catalogue against one device seen during a scan, best first.
  ///
  /// Takes identities rather than whole specs: this runs per newly-seen device
  /// while a scan is in flight, and pushing 70-odd parsed specs across the FFI
  /// boundary each time would cost far more than the matching.
  Future<List<ScanMatch>> matchScannedDevice({
    required List<SpecIdentityDto> identities,
    required ScannedDeviceDto device,
  });

  /// Rank the catalogue against one device found on the local network.
  ///
  /// Shares [matchScannedDevice]'s confidence vocabulary, so a badge means the
  /// same thing whichever tab it appears on.
  Future<List<ScanMatch>> matchNetworkDevice({
    required List<SpecIdentityDto> identities,
    required NetworkDeviceDto device,
  });

  /// Encode a named command into bytes for a BLE write.
  Future<Uint8List> encodeCommand({
    String? specYaml,
    String? serviceUuid,
    required String charUuid,
    required String commandName,
    required Map<String, double> params,
  });

  /// Decode raw bytes from a BLE read/notify into named values.
  Future<List<DecodedValueDto>> decodeValue({
    String? specYaml,
    String? serviceUuid,
    required String charUuid,
    required List<int> bytes,
  });

  /// Identify any standard Bluetooth profiles among the given service UUIDs.
  Future<List<ProfileInfoDto>> identifyStandardProfiles(
    List<String> serviceUuids,
  );

  /// Encode a setpoint for a `number`/`climate` entity into the write that
  /// applies it, and say where to send it.
  ///
  /// [value] is in the entity's DECODED unit — degrees, percent — because
  /// that is what the user picked. Inverting the spec's linear transform to
  /// get raw bytes happens in Rust, so the UI never has to know whether a
  /// device speaks centidegrees or `raw * 0.5 + 85`.
  Future<EntityWriteDto> encodeEntityValue({
    required String specYaml,
    required String entityName,
    required double value,
  });

  /// Encode one RGB888 image frame into the ordered BLE writes that display
  /// it, dispatched on the spec's `protocol_handler`.
  ///
  /// [rgb] is row-major, `width * height * 3` bytes. [frameIndex] sequences
  /// consecutive frames of an animation, and [maxPayloadPerWrite] is the
  /// usable bytes per BLE write (ATT MTU - 3; 20 when the MTU is unknown).
  Future<ImageWritePlanDto> encodeImageFrame({
    required String specYaml,
    required int width,
    required int height,
    required List<int> rgb,
    required int frameIndex,
    required int maxPayloadPerWrite,
  });

  /// The device's REAL panel resolution, read from its advertisement per the
  /// spec's `image_upload.resolution_advertisement`. Lets a `device_reported`
  /// panel's editor default the canvas to the true size before connecting.
  /// [manufacturerData] is company id -> value bytes (as the scan captured it).
  /// Null when the spec declares no advertised resolution, no record matches,
  /// or the bytes are out of range.
  Future<PanelResolutionDto?> advertisedResolution({
    required String specYaml,
    required Map<int, List<int>> manufacturerData,
  });

  /// The device's REAL panel resolution decoded from its M_DEVICE_INFO_NOTIFY
  /// push (mt=2103) — the source used on a reconnect that carries no
  /// advertisement. [notifications] are raw notify events collected off the DDP
  /// notify characteristic in a short window; the core reassembles them (the
  /// message spans several notifications at a low MTU) and reads its
  /// width/height fields. Null when none carried a DeviceInfo.
  Future<PanelResolutionDto?> deviceInfoResolution({
    required List<List<int>> notifications,
  });

  /// The control surface a spec declares for one discovered network device —
  /// the SOAP counterpart of a BLE spec's entities, plus the names of
  /// declared entities that resolve nothing (the hide-rule note's count).
  ///
  /// [ssdpTargets] is what the device itself answered to; it narrows a family
  /// spec's variant-scoped entities to the model actually found, so a Wemo
  /// plug never grows the slow cooker's controls.
  Future<NetworkEntitySurfaceDto> networkEntitiesForDevice({
    required String specYaml,
    required List<String> ssdpTargets,
  });

  /// [networkEntitiesForDevice] with the device's state replies in hand:
  /// variants the spec identifies by reply shape (`state_probe`) resolve
  /// strictly against the flattened replies instead of optimistically, so
  /// the surface settles on what the device actually is. [stateKeys] maps
  /// each state command's name to the flattened key→value map of its reply.
  Future<NetworkEntitySurfaceDto> networkEntitiesForStateKeys({
    required String specYaml,
    required List<String> ssdpTargets,
    required Map<String, Map<String, String>> stateKeys,
  });

  /// Spec-declared capabilities of a network device's control path — the
  /// signed-session protocol it prefers, its declared control port and URL
  /// scheme — so the transport layer routes on what the spec says instead of
  /// per-device discovery-string checks.
  Future<NetworkCapabilitiesDto> networkCapabilities({
    required String specYaml,
  });

  /// What this spec says a client must HOLD before it can drive the device —
  /// every `credential:<name>` its commands refer to, joined to the setup
  /// method that issues it where the spec declares one.
  ///
  /// Answered for the device rather than per action: "what do I need before
  /// this screen works" is the question, and a per-action answer misses the
  /// credential no action mentions (Hue's `clientkey`, issued at pairing and
  /// obtainable at no other time).
  Future<List<NetworkCredentialDto>> credentialsForDevice(String specYaml);

  /// Apply a spec-declared credential derivation (`base64_sha512`) to what the
  /// person typed — the sticker password in, the wire value out.
  Future<String> deriveCredentialValue({
    required String derivation,
    required String value,
  });

  /// Render a named command from the spec's `commands` block into a POSTable
  /// SOAP request. [values] carries what the user picked plus any read-back
  /// values fetched from the device; the spec's defaults fill the rest.
  Future<SoapRequestDto> renderNetworkCommand({
    required String specYaml,
    required String commandName,
    required Map<String, String> values,
  });

  /// Render a named `transport: http` command into a sendable plain-HTTP
  /// request — [renderNetworkCommand]'s sibling for the transport with no
  /// envelope (Roku ECP's keypresses). An action's `transport` field says
  /// which of the two to call; each renderer declines the other's commands.
  Future<HttpRequestDto> renderNetworkHttpCommand({
    required String specYaml,
    required String commandName,
    required Map<String, String> values,
  });

  /// Render the HTTP request that reads a state command's values — on an
  /// instanced entity, the one GET that enumerates every child and carries
  /// all their state. [values] fills the path's placeholders (the pairing
  /// credential, on a Hue bridge); a missing one fails the render.
  Future<HttpRequestDto> renderNetworkHttpStateRequest({
    required String specYaml,
    required String stateCommand,
    required Map<String, String> values,
  });

  /// The second spelling of each state topic the spec declares one for, as
  /// declared (placeholders unfilled). Empty for a spec with no
  /// `state_topic_fallback` — all but ratgdo, today.
  ///
  /// A subscription has no 404 to fall back on, so the MQTT sender listens on
  /// both spellings rather than waiting out a topic that may simply never be
  /// published.
  Future<List<StateTopicFallbackDto>> specStateTopicFallbacks({
    required String specYaml,
  });

  /// The ordered handshake the spec wants run on every BLE connect, before
  /// anything else is read or written — the schema's `initialization`, both
  /// the device-wide block and each service's.
  ///
  /// Rust decides what to send and in what order; the caller is a loop.
  /// [BleHandshakeDto.described] carries the steps the spec could only state
  /// in prose, so a client knows when it has run half a handshake.
  Future<BleHandshakeDto> specBleHandshake({required String specYaml});

  /// Enumerate the children an instanced entity's state reply carries, in the
  /// hub's own order.
  Future<List<NetworkInstanceDto>> listNetworkInstances({
    required String specYaml,
    required String entityName,
    required String stateReply,
  });

  /// Read one child's roles out of an instanced entity's state reply. Empty
  /// for a child the reply no longer carries — rendered as unknown, never as
  /// a fabricated "off".
  Future<List<NetworkRoleReadingDto>> readNetworkInstance({
    required String specYaml,
    required String entityName,
    required String stateReply,
    required String instanceId,
  });

  /// Render the argument-less request that reads a state command's values.
  Future<SoapRequestDto> renderNetworkStateRequest({
    required String specYaml,
    required String stateCommand,
  });

  /// Render a named `transport: tcp-json` command into the JSON to send — the
  /// Kasa sibling of [renderNetworkCommand]/[renderNetworkHttpCommand], for
  /// the TP-Link Smart Home protocol (JSON over a raw TCP socket on port 9999).
  /// The action's `transport` field says which renderer to call.
  Future<KasaRequestDto> renderNetworkKasaCommand({
    required String specYaml,
    required String commandName,
    required Map<String, String> values,
  });

  /// Render the JSON that polls a Kasa state command (`get_sysinfo`) — the Kasa
  /// counterpart of [renderNetworkStateRequest].
  Future<KasaRequestDto> renderNetworkKasaStateRequest({
    required String specYaml,
    required String stateCommand,
  });

  /// Encrypt and length-frame a Kasa JSON request for the TCP control socket.
  /// The XOR-autokey cipher lives in Rust; a client just writes these bytes.
  Future<List<int>> kasaEncodeFrame({required String json});

  /// Decode a length-framed Kasa TCP reply back to its JSON text. Throws on a
  /// short/truncated frame rather than returning garbage.
  Future<String> kasaDecodeFrame({required List<int> frame});

  /// Encrypt a Kasa JSON request as a UDP discovery datagram (no length prefix).
  Future<List<int>> kasaEncryptDatagram({required String json});

  /// Decode a Kasa UDP reply datagram (no length prefix) back to its JSON text.
  Future<String> kasaDecodeDatagram({required List<int> datagram});

  /// Parse a Tuya discovery datagram (UDP 6666 plaintext / 6667 fixed-key
  /// AES-128-ECB) into the identity it advertises, or null when the bytes are
  /// not a Tuya broadcast. Identify-only: the decrypt unwraps the device's own
  /// beacon, never a control channel.
  Future<TuyaBroadcastDto?> tuyaParseBroadcast({required List<int> datagram});

  // ── Rabbit Air (encrypted JSON over UDP) ──────────────────────────────────
  // Like Kasa the invocation is JSON, but the wire crypto is real:
  // AES-128-CBC under the per-device user key, the random IV appended as the
  // datagram's last 16 bytes. Byte-in/byte-out, same as Kasa — Dart owns the
  // socket, the retries, and the request-id matching.

  /// Render a named `transport: udp` command into the Rabbit Air envelope
  /// JSON to send — the sibling of [renderNetworkKasaCommand]. [requestId] is
  /// the caller's fresh nonce (the reply echoes it); [deviceTs] is the
  /// device-clock timestamp, extrapolated from the learned offset.
  Future<RabbitAirRequestDto> renderNetworkRabbitAirCommand({
    required String specYaml,
    required String commandName,
    required Map<String, String> values,
    required int requestId,
    required int deviceTs,
  });

  /// Render the envelope that polls a Rabbit Air state command (`get_state`),
  /// or the `time_sync` handshake command — the counterpart of
  /// [renderNetworkKasaStateRequest].
  Future<RabbitAirRequestDto> renderNetworkRabbitAirStateRequest({
    required String specYaml,
    required String stateCommand,
    required int requestId,
    required int deviceTs,
  });

  /// The UDP port every Rabbit Air purifier listens on (9009).
  Future<int> rabbitAirPort();

  /// Encrypt an envelope for the wire under the 16-byte user key (its
  /// 32-hex-character spelling); the returned datagram is ciphertext with the
  /// random IV appended as the last 16 bytes. Throws on a malformed key.
  Future<List<int>> rabbitAirEncryptDatagram({
    required String userKey,
    required String plaintext,
  });

  /// Decrypt a reply datagram back to its JSON text. Throws on a wrong key or
  /// a short/mis-sized datagram rather than returning garbage.
  Future<String> rabbitAirDecryptDatagram({
    required String userKey,
    required List<int> datagram,
  });

  /// The clock offset a `time_sync` reply teaches: the reply's `data.ts`
  /// minus [localNowSecs]. Throws on a reply carrying `error` or no `data.ts`.
  Future<int> rabbitAirTimeSyncOffset({
    required String replyJson,
    required int localNowSecs,
  });

  // ── Rabbit Air BLE provisioning transport ─────────────────────────────────
  // The same payload a UDP datagram would carry, framed for the GATT command
  // characteristic: a 2-byte little-endian payload-length prefix, then
  // consecutive chunks. Dart owns the connection, MTU negotiation,
  // notification accumulation, and the response timeout.

  /// Frame [payload] for the BLE command characteristic: the length prefix,
  /// then chunks of [chunkSize] bytes, in write order. Throws when
  /// [chunkSize] cannot carry the prefix plus one payload byte.
  Future<List<List<int>>> rabbitAirBleFrame({
    required List<int> payload,
    required int chunkSize,
  });

  /// The total payload length the first notification of a BLE reply
  /// announces, or null when the chunk is shorter than the 2-byte prefix and
  /// must be ignored.
  Future<int?> rabbitAirBleExpectedPayloadLen({required List<int> firstChunk});

  /// Render a setup-phase envelope: minified cleartext `{"id":id,"cmd":cmd}`
  /// with `,"data":<object>` when [dataJson] is supplied — no `ts`, no
  /// encryption. [id] is the caller's per-client counter starting at 0.
  /// Throws when [dataJson] is not a JSON object.
  Future<String> renderRabbitAirSetupEnvelope({
    required int id,
    required int cmd,
    String? dataJson,
  });

  /// Generate a user key the way the vendor app does: 32 random uppercase
  /// hex characters, pushed during setup (cmd 5, type 4).
  Future<String> rabbitAirGenerateUserKey();

  /// The GATT service UUID the Rabbit Air BLE protocol lives on.
  Future<String> rabbitAirBleServiceUuid();

  /// The command characteristic UUID: write-with-response for requests,
  /// notifications for responses.
  Future<String> rabbitAirBleCommandCharacteristicUuid();

  /// The ATT MTU the client requests (515); the negotiated chunk size is
  /// MTU - 5, and the pre-negotiation default is 512.
  Future<int> rabbitAirBleMtu();
  // ── Roomba (MQTT over TLS, on the robot) ─────────────────────────────────
  //
  // The whole protocol is koalazak/dorita980's work (MIT). Dart owns the TLS
  // socket because Rust does no I/O here; every byte that goes through it is
  // built and read on the Rust side, so the framing exists in one tested place.

  /// The nine ASCII bytes broadcast to `255.255.255.255:5678` to find robots.
  Future<List<int>> roombaDiscoveryProbe();

  /// Parse one discovery datagram. Null — not an error — for a datagram that
  /// is not from a robot: the probe is a broadcast and reaches every host on
  /// the segment, so a scan must not fail because a printer answered.
  Future<RoombaAnnouncementDto?> roombaParseAnnouncement({
    required List<int> datagram,
  });

  /// The 7-byte password-disclosure probe, written on a TLS connection to
  /// `<robot>:8883` while the robot is in disclosure mode.
  Future<List<int>> roombaPasswordProbe();

  /// Extract the password from a disclosure reply. The whole returned string
  /// is the credential — Roomba passwords begin with `:` and contain `:`
  /// separators, so a caller must never split it. Throws with text meant to be
  /// shown: "not in disclosure mode" (hold the button again) and "this model
  /// cannot disclose locally" (use the account route) are different answers.
  Future<String> roombaParsePasswordReply({required List<int> reply});

  /// Render a named `transport: mqtt` command. [epochSeconds] is the caller's
  /// clock and is required — the codec has none, and a silently defaulted
  /// timestamp is a plausible-but-wrong request.
  Future<RoombaRequestDto> renderNetworkRoombaCommand({
    required String specYaml,
    required String commandName,
    required int epochSeconds,
  });

  /// Flatten a state payload into the dotted paths entities bind to
  /// (`state.reported.batPct`). Booleans arrive as `1`/`0` so an entity's
  /// `on_when: nonzero` reads them. An unparseable payload yields an empty map
  /// rather than throwing: a dropped connection delivers half a message, and
  /// that must not take the control screen down.
  Future<Map<String, String>> roombaStateFields({required String payload});

  /// MQTT CONNECT, with the BLID as both client id and username.
  Future<List<int>> roombaConnectPacket({
    required String blid,
    required String password,
  });

  /// A spec's WebSocket control surface — where the socket is, how a client
  /// is authorised on it, and which frame shapes it speaks — or null when the
  /// spec declares none.
  Future<WebSocketSurfaceDto?> websocketSurface(String specYaml);

  /// Render one of a spec's `transport: websocket` commands into the frame to
  /// send and the channel to send it on. [requestId] is the client's
  /// correlation integer: a frame rendered with a fixed one would match every
  /// reply to the same request.
  Future<WebSocketFrameDto> renderNetworkWebsocketCommand({
    required String specYaml,
    required String commandName,
    required Map<String, String> values,
    required int requestId,
  });

  /// MQTT CONNECT for a spec-declared broker. Username and password are each
  /// sent only when given: a broker expecting neither refuses a CONNECT
  /// carrying two empty strings, and one expecting a token takes a username
  /// with no password.
  Future<List<int>> mqttConnectPacket({
    required String clientId,
    String? username,
    String? password,
  });

  /// Render one of a spec's `transport: mqtt` commands into the topic to
  /// publish on and the payload to publish. A placeholder with no value, or
  /// one the command never declared, is an error rather than a blank: a
  /// publish to a half-rendered topic succeeds at the socket and does nothing
  /// at the device.
  Future<MqttRequestDto> renderNetworkMqttCommand({
    required String specYaml,
    required String commandName,
    required Map<String, String> values,
  });

  /// Fill an MQTT state topic's `{name}` placeholders from what the app
  /// holds — stored credentials and discovery facts, keyed by exactly the
  /// names the topic uses. Single-pass: a value is data, never re-scanned as
  /// template. What nothing fills survives verbatim, which is the caller's
  /// signal that the topic is not subscribable yet.
  Future<String> fillMqttStateTopic({
    required String topic,
    required Map<String, String> values,
  });

  /// MQTT SUBSCRIBE at QoS 0.
  Future<List<int>> mqttSubscribePacket({
    required String topic,
    required int packetId,
  });

  /// MQTT PUBLISH at QoS 0 — no device broker in the catalogue acknowledges
  /// commands, and a higher QoS needs bookkeeping the codec does not hold.
  Future<List<int>> mqttPublishPacket({
    required String topic,
    required String payload,
  });

  /// MQTT PINGREQ, to hold the session open inside the keepalive window.
  Future<List<int>> mqttPingreqPacket();

  /// MQTT DISCONNECT. Always sent on the way out: a device that serves one
  /// local client at a time (the Roomba does) leaves the owner locked out of
  /// their own app until it notices a client that merely dropped the socket.
  Future<List<int>> mqttDisconnectPacket();

  /// Parse whole MQTT packets out of whatever has arrived so far, and say how
  /// many bytes they consumed. The remainder is a partial packet and must be
  /// kept — a TLS stream splits and coalesces wherever it likes.
  Future<MqttParsedDto> mqttParseIncoming({required List<int> buffer});

  /// Decode one entity's state from the name→value pairs a state call
  /// returned. Null when the reply did not carry the entity's value — which
  /// renders as unknown, never as a fabricated zero.
  Future<NetworkReadingDto?> readNetworkEntity({
    required String specYaml,
    required String entityName,
    required Map<String, String> returned,
  });

  /// Encode the BLE writes that PERSIST a picture on the device so it plays
  /// standalone after disconnect, dispatched on the spec's `stored_upload`
  /// feature.
  ///
  /// [rgb] is the canvas, row-major `width * height * 3`, already reduced to at
  /// most 16 distinct colours (the editor quantises before calling). [name] is
  /// the stored label, [cid] the id it is stored under, [timeSecs] the
  /// run/scroll duration, [scroll] one of `none`/`left`/`right`/`up`/`down`,
  /// and [speed] the scroll-speed byte. The returned plan carries the ordered
  /// uploader writes and, when the spec declares one, a play-by-id command.
  Future<StoredUploadPlanDto> encodeStoredImage({
    required String specYaml,
    // Usable bytes per BLE write on the live link (MTU - 3): DATA packets
    // are sized to fit it. Null sizes them from the spec alone.
    int? maxWrite,
    required int width,
    required int height,
    required List<int> rgb,
    required String name,
    required int cid,
    required int timeSecs,
    required String scroll,
    required int speed,

    /// Per-connection rolling counter driving the play write's fragment serial
    /// and DNX `sn`, so repeated plays are distinct on the wire (see
    /// [commandSequenceProvider]). One-shot callers may pass 0.
    required int sequence,
  });

  /// Encode the BLE writes that persist a scrolling-text marquee on the device.
  ///
  /// [bits] is the rendered text bitmap — one byte per pixel (`0` off, non-zero
  /// lit), row-major, `textWidth * textHeight` bytes. The width is usually wider
  /// than the panel so the text scrolls.
  Future<StoredUploadPlanDto> encodeStoredText({
    required String specYaml,
    // Usable bytes per BLE write on the live link (MTU - 3): DATA packets
    // are sized to fit it. Null sizes them from the spec alone.
    int? maxWrite,
    required int textWidth,
    required int textHeight,
    required List<int> bits,
    required String name,
    required int cid,
    required int timeSecs,
    required String scroll,
    required int speed,
    required int sequence,
  });

  /// Encode the BLE writes that persist a multi-frame animation as one `.eff`
  /// container.
  ///
  /// **DORMANT — do not wire an "animate" button to this.** On the JY25CUT
  /// curtain, the only Daniao hardware anyone here has tested, a `.eff`
  /// container COMMITS and then never registers as a playable effect: the
  /// upload succeeds, the effect list comes back without it, and nothing
  /// plays. That is hardware-confirmed, and it is invisible from this side —
  /// every call here returns a valid-looking plan.
  ///
  /// The curtain's real animation path is the cycling-stills loop the LED
  /// editor already implements: [encodeStoredImage] once per frame, then
  /// [encodeSetPlaylist] and `play_next`. If you are here because animations
  /// do not persist, that loop is what to fix — not this.
  ///
  /// Kept because the vendor's matrix panels are a different renderer and may
  /// well play a `.eff`; nobody has captured one. Reaching for it means doing
  /// that capture first.
  ///
  /// [frames] are the screens in play order, each row-major RGB888
  /// `width * height * 3` bytes, ≤16 colours each. [frameMs] is the editor's
  /// preview interval; the container stores the matching frame rate so the
  /// device plays at the speed the user tuned on screen (0 falls back to the
  /// vendor's 20 fps).
  Future<StoredUploadPlanDto> encodeStoredAnimation({
    required String specYaml,
    // Usable bytes per BLE write on the live link (MTU - 3): DATA packets
    // are sized to fit it. Null sizes them from the spec alone.
    int? maxWrite,
    required int width,
    required int height,
    required List<List<int>> frames,
    required String name,
    required int cid,
    required int frameMs,
    required int sequence,
  });

  /// Decode one notification from the stored-upload response characteristic
  /// (the plan's `responseCharacteristicUuid`) into an upload event, or null
  /// when the notification is some other push sharing the channel.
  Future<StoredUploadEventDto?> decodeStoredUploadEvent({
    required String specYaml,
    required List<int> bytes,
  });

  /// The same over a WINDOW of recent notifications: fragments are
  /// reassembled by serial before anything is read, so a packet a 23-byte
  /// MTU splits in two is decoded once both halves are in. Events come back
  /// in packet order; [StoredUploadEventReader] is the caller that keeps the
  /// window.
  Future<List<StoredUploadEventDto>> decodeStoredUploadEvents({
    required String specYaml,
    required List<List<int>> notifications,
  });

  /// The play-by-cid write that RE-triggers an already stored design — the
  /// replay list's whole wire footprint.
  Future<StoredPlayDto> encodeStoredPlay({
    required String specYaml,
    required int cid,
    required int sequence,
  });

  // ── LIFX (binary UDP) ─────────────────────────────────────────────────────
  // LIFX speaks a binary LAN protocol over UDP, so — unlike SOAP/HTTP — these
  // return the datagram *bytes* the UDP client sends, and take reply bytes back
  // to decode. The byte-in/byte-out shape of the BLE codec, one transport over.

  /// The UDP port every LIFX device listens on (56700). Sourced from Rust so
  /// the client never hardcodes a second copy that could drift.
  Future<int> lifxPort();

  /// Render one LIFX control action into the datagram bytes to send.
  ///
  /// [action] is a LIFX entity action's `commandName` (`turn_on`, `set_color`,
  /// `set_zone_color`, …); [params] carries the UI-owned values
  /// (`red`/`green`/`blue`/`brightness` on 0–255, `kelvin` 1500–9000, `zone` a
  /// zone index). [targetMac] is `d0:73:d5:…` or empty for a device not yet
  /// identified; [sequence] is the caller's counter, echoed in any reply.
  Future<Uint8List> renderLifxCommand({
    required String action,
    required Map<String, double> params,
    required String targetMac,
    required int sequence,
  });

  /// The tagged-broadcast `GetService` probe every LIFX device answers with a
  /// `StateService`.
  Future<Uint8List> buildLifxDiscoveryProbe({required int sequence});

  /// The `LightGet` datagram that asks a device for its colour and power.
  Future<Uint8List> buildLifxStateRequest({
    required String targetMac,
    required int sequence,
  });

  /// The `GetColorZones` datagram asking for the colours of zones [start]–[end].
  Future<Uint8List> buildLifxZonesRequest({
    required String targetMac,
    required int start,
    required int end,
    required int sequence,
  });

  /// Decode a `StateService` discovery reply (MAC, service, port).
  Future<LifxServiceDto> parseLifxStateService({required List<int> bytes});

  /// Decode a light `State` reply into a UI-facing reading (RGB, brightness,
  /// power, label).
  Future<LifxStateDto> decodeLifxState({required List<int> bytes});

  /// Decode a `StateMultiZone`/`StateZone` reply into per-zone colours.
  Future<LifxZonesDto> decodeLifxZones({required List<int> bytes});

  // ── LIFX SoftAP provisioning ──────────────────────────────────────────────
  // The legacy access-point family that onboards an unprovisioned strip onto
  // WiFi over its own setup AP. Unauthenticated, plaintext passphrase — send it
  // once, never persist it.

  /// The default security byte (WPA2-AES) to try for a manually-typed SSID that
  /// never appeared in a scan.
  Future<int> lifxDefaultSecurity();

  /// The `GetAccessPoints` datagram asking an unprovisioned device to scan.
  Future<Uint8List> buildLifxGetAccessPoints({required int sequence});

  /// The `SetAccessPoint` datagram handing the device its home-network
  /// credentials. [password] is sent in plaintext — do not persist it.
  Future<Uint8List> renderLifxSetAccessPoint({
    required String ssid,
    required String password,
    required int security,
    required int sequence,
  });

  /// Decode a `StateAccessPoint` scan-result reply.
  Future<LifxAccessPointDto> decodeLifxAccessPoint({required List<int> bytes});

  // ── Wemo SoftAP setup, and the shared softap-profile catalogue ─────────────
  // The Wemo half of adoption (SOAP): the passphrase encryption and the ApList
  // parse. `softApProfiles`/`matchSoftApSsid` are family-agnostic — they back
  // the "a setup network is nearby" hint that spins the adopt icon.

  /// Every softap setup method the catalogue declares (Wemo, LIFX, …), from the
  /// given spec YAMLs — the families the adopt flow can offer, and the SSID
  /// prefixes the nearby-network hint watches for.
  Future<List<SoftApProfileDto>> softApProfiles(List<String> specYamls);

  /// One spec's renderable `device.setup` instructions — how to pair, why a
  /// connect might fail, how to factory reset, how to rejoin — or null when the
  /// spec carries no such prose. Shown when a connect fails, from the single
  /// YAML the caller resolved for the device.
  Future<SetupInstructionsDto?> setupInstructions(String specYaml);

  /// Every BLE-provisioning setup method the catalogue declares — the
  /// families that take their Wi-Fi credentials over Bluetooth instead of from
  /// a setup network of their own, so the adopt screen lists them from the
  /// specs rather than from a hand-written card.
  Future<List<BleProvisioningProfileDto>> bleProvisioningProfiles(
    List<String> specYamls,
  );

  /// The index of the first profile whose setup-mode advertised name matches
  /// [advertisedName] under that spec's exact/prefix rule, or null. Decides
  /// both "is this peripheral waiting to be set up" and which family it is.
  Future<int?> matchBleProvisioningName({
    required List<BleProvisioningProfileDto> profiles,
    required String advertisedName,
  });

  /// The index of the first profile whose setup-AP prefix matches [ssid]
  /// (case-insensitive, anchored), or null. Drives the spinning hint.
  Future<int?> matchSoftApSsid({
    required List<SoftApProfileDto> profiles,
    required String ssid,
  });

  /// Every `ConnectHomeNetwork` request worth sending to join [ssid], rendered
  /// and ready to POST — the Wemo counterpart of [renderLifxSetAccessPoint].
  /// The passphrase is encrypted (each variant of the spec's sweep) and each
  /// attempt rendered into a SOAP request; the caller POSTs them in turn until
  /// one joins. [metaInfo] is the raw `GetMetaInfo` reply (unused for an open
  /// network). Throws when the passphrase is too short — terminal, worth saying
  /// before any network I/O.
  ///
  /// Each attempt carries the variant that built it, because the device never
  /// says which one it accepted — it just joins or does not — so naming the
  /// one that worked in a log is only possible if the renderer labels them.
  Future<List<WemoConnectAttemptDto>> renderWemoConnectRequests({
    required String specYaml,
    required String metaInfo,
    required String ssid,
    required String auth,
    required String encrypt,
    required String channel,
    required String passphrase,
    // From the device's setup.xml: rtos=1 without iot=1 puts the method-2
    // password layout first. Null (older firmware) keeps the default order.
    int? rtos,
    int? iot,
  });

  /// Interpret a Wemo `GetNetworkStatus` reply's `NetworkStatus` value.
  Future<WemoJoinStatus> wemoNetworkStatus({required String code});

  /// Parse a Wemo `GetApList` reply into pickable networks.
  Future<List<WemoAccessPointDto>> parseWemoApList({required String apList});

  /// Encode the writes that loop stored frames as an animation: the
  /// set-playlist command then loop mode. [cids] are the stored frames in play
  /// order; [slots] are their device slots (0 when unknown). [sequence] seeds
  /// the two writes' rolling serials.
  Future<PlaylistWritesDto> encodeSetPlaylist({
    required String specYaml,
    required List<int> cids,
    required List<int> slots,
    required int sequence,
  });

  /// Decode one M_EFFECT_LIST notification into `{cid, slot}` entries. The
  /// device answers a list request with several notifications; merge them to
  /// map a stored frame's cid to the device slot a playlist must address.
  Future<List<EffectEntryDto>> decodeEffectList({
    required String specYaml,
    required List<int> bytes,
  });

  /// Encode the global play-speed command — how fast the device advances the
  /// playlist. [speed] is the device's slider value (default 100).
  Future<StoredPlayDto> encodePlaySpeed({
    required String specYaml,
    required int speed,
    required int sequence,
  });

  /// Encode the play/loop-mode command (M_SET_AUTORUN_MODE). [mode] is
  /// `0=fixed | 1=repeat | 2=random`. Sending fixed after playing a design
  /// pins the device to it across disconnect (instead of randomly cycling all
  /// stored effects).
  Future<StoredPlayDto> encodeAutorunMode({
    required String specYaml,
    required int mode,
    required int sequence,
  });

  /// Encode M_BOOKMARK_ENABLE — activate bookmark/playlist [listId] so the
  /// device plays ONLY its items. Without it, playback stays over the whole
  /// stored set (`play_next` cycles every effect). Sent as part of the loop
  /// setup: clear → enable → set_playlist → play_next.
  Future<StoredPlayDto> encodeBookmarkEnable({
    required String specYaml,
    required int listId,
    required int sequence,
  });

  /// Encode M_BOOKMARK_CLEAR — empty bookmark/playlist [listId] before a
  /// re-save, so the loop replaces the old list instead of accumulating.
  Future<StoredPlayDto> encodeBookmarkClear({
    required String specYaml,
    required int listId,
    required int sequence,
  });

  /// Encode the delete-one-stored-design command by cid (M_REMOVE_APP).
  Future<StoredPlayDto> encodeRemoveApp({
    required String specYaml,
    required int cid,
    required int sequence,
  });

  /// Encode the clear-all-stored-designs command (M_REMOVE_ALL_APPS).
  Future<StoredPlayDto> encodeRemoveAllApps({
    required String specYaml,
    required int sequence,
  });

  // ── Brother QL raster label printers (raw byte stream, TCP 9100/LPR/SPP) ──

  /// The `ESC i S` bytes that ask a Brother QL printer for its 32-byte status
  /// reply. Written to the same raw stream a job goes to.
  Future<Uint8List> brotherQlStatusRequest();

  /// Decode a Brother QL 32-byte status reply into loaded-media and error
  /// information (throws on a wrong-length or wrong-header buffer).
  Future<BrotherQlStatusDto> decodeBrotherQlStatus({required List<int> reply});

  /// Render a self-contained test label sized to the loaded media, encoded as a
  /// complete raster job ready to write to the printer.
  Future<Uint8List> renderBrotherQlTestLabel({
    required String specYaml,
    required BrotherQlJobParamsDto params,
  });

  /// The device's `camera:` feed(s) and optional keepalive, or null when the
  /// spec declares no camera.
  Future<CameraDto?> cameraForDevice({required String specYaml});

  /// The spec's raster-print surface — transport, head geometry, rolls — or
  /// null when the spec is not a raster printer.
  Future<RasterPrintDto?> rasterPrintForSpec({required String specYaml});

  /// Reduce a composed RGBA canvas (straight alpha) to the black-and-white
  /// RGB888 a raster printer takes — what the preview shows is what prints.
  Future<Uint8List> prepareMonoRaster({
    required Uint8List rgba,
    required int width,
    required int height,
    required PrintDither dither,
    required int threshold,
  });

  /// The canvas to compose a Brother QL label on for the given media.
  Future<LabelCanvasDto> brotherQlLabelCanvas({
    required String specYaml,
    required BrotherQlJobParamsDto params,
  });

  /// Encode a composed black-and-white RGB888 label as a whole Brother QL
  /// raster job, placed on the head for the given media.
  Future<Uint8List> renderBrotherQlJob({
    required String specYaml,
    required BrotherQlJobParamsDto params,
    required Uint8List rgb,
    required int width,
    required int height,
  });
}

/// Play/loop-mode values for [SpecCodec.encodeAutorunMode].
class AutorunMode {
  static const int fixed = 0;
  static const int repeat = 1;
  static const int random = 2;
}

/// The spec catalogue, parsed and held by the codec.
///
/// Exists because the catalogue is asked about far more often than it is
/// rendered. Matching a connected device, ranking a scan result, joining a
/// saved spec key and selecting by protocol handler all read a handful of
/// identifying fields; only the screen that actually draws a device needs the
/// spec itself. So the parse stays where it happened ([RealSpecCodec] keeps
/// it in Rust) and this is the window onto it: light entries by value, full
/// DTOs one index at a time.
abstract class SpecCatalogue {
  /// Every spec that parsed, in catalogue order. The index of an entry is
  /// what [matchDevice] reports and what [specAt] takes.
  List<CatalogueSpec> get specs;

  /// Every spec that did NOT parse, with the parser's reason. Named rather
  /// than dropped: a catalogue that quietly shrank is how a bundled device
  /// stops matching with nothing in the log.
  List<SpecLoadFailureDto> get failures;

  /// Match every spec against a device we are already connected to.
  ///
  /// Returns one entry per spec that matched, in catalogue order, with the
  /// axes that hit. Ranking them is `rankSpecMatches`' job, not this one's.
  Future<List<SpecMatch>> matchDevice({
    required String deviceName,
    required List<String> serviceUuids,
  });

  /// The full DTO of the spec at [index] — everything a device screen draws.
  ///
  /// Also the point at which a codec that holds parses may hand its parse to
  /// the per-spec call path, so the screen's first `decodeValue` does not
  /// re-send the YAML. [index] must be a [specs] index.
  Future<DeviceSpecDto> specAt(int index);

  /// Every UDP discovery probe the catalogue declares, bytes already decoded.
  ///
  /// The scan service sends these rather than holding a payload constant and a
  /// transport per vendor — adding a device that answers its own broadcast
  /// then takes a spec and nothing else (SPECS_TO_FIX.md S-10).
  Future<List<UdpProbeDto>> udpBroadcastProbes();
}

/// One catalogue member as the non-rendering paths see it: the YAML it was
/// loaded from, the identity projection the scan matchers take, and the two
/// fields the adopt/network paths select on.
@immutable
class CatalogueSpec {
  /// Position in [SpecCatalogue.specs] — the index [SpecCatalogue.specAt]
  /// takes and [SpecMatch] reports.
  final int index;

  /// The key the catalogue was loaded under: a bundled asset path, or
  /// `pack:<name>/<file>` for an installed pack.
  final String key;

  /// The spec's text. Still here because most entry points still take it;
  /// the ones that are asked repeatedly take a held parse instead.
  final String yaml;

  /// The identifying projection — what both scan matchers rank against.
  final SpecIdentityDto identity;

  /// `device.protocol_handler`, which the adopt and Rabbit Air paths select
  /// specs by.
  final String? protocolHandler;

  /// UUIDs of the GATT services this spec declares, as declared. The
  /// post-connect ranking drops a name-only match no declared service
  /// corroborates, and asks it here rather than pulling the whole spec.
  final List<String> gattServiceUuids;

  const CatalogueSpec({
    required this.index,
    required this.key,
    required this.yaml,
    required this.identity,
    required this.protocolHandler,
    required this.gattServiceUuids,
  });

  /// From the projection Rust hands back, joined to the text Dart already
  /// holds.
  CatalogueSpec.fromDto(CatalogueEntryDto dto, String yaml)
    : this(
        index: dto.index,
        key: dto.key,
        yaml: yaml,
        identity: dto.identity,
        protocolHandler: dto.protocolHandler,
        gattServiceUuids: dto.gattServiceUuids,
      );

  String get deviceName => identity.deviceName;
  String get manufacturer => identity.manufacturer;
}

/// One catalogue entry's match against a connected device: which spec, and
/// on which evidence.
///
/// Carries the entry rather than a [DeviceSpecDto]: the whole point of the
/// index is that a match no longer ships 203 specs in and the winners back
/// out. `rankSpecMatches` reads only what is here.
@immutable
class SpecMatch {
  final CatalogueSpec entry;

  /// The device's advertised name starts with one of the spec's declared
  /// prefixes (or matches one of its exact names).
  final bool matchedByNamePrefix;

  /// How strong the evidence is, on the scan badge's own scale.
  final MatchConfidence confidence;

  /// The spec's declared service UUIDs the device actually carries.
  final List<String> matchedServiceUuids;

  const SpecMatch({
    required this.entry,
    required this.matchedByNamePrefix,
    required this.confidence,
    required this.matchedServiceUuids,
  });
}

/// A [SpecCatalogue] built out of a codec's per-spec calls: one
/// [SpecCodec.loadDeviceSpec] per spec, and [SpecCodec.matchDeviceToSpec]
/// over the resulting DTOs.
///
/// This is what the catalogue was before Rust held it, kept as the path for
/// any codec without native handles — the fakes the widget suite runs on. It
/// composes the codec's own public calls rather than re-implementing
/// anything, and `test/services/spec_catalogue_golden_test.dart` pins it
/// against the real one over the whole vendored catalogue.
/// The native core is not loaded: the whole catalogue answers "no spec", and
/// says why once per spec.
///
/// What main() chose for a core that fails to load is to carry on without
/// it — every scan and connect still works, no device matches a spec, the
/// raw controls are what the user gets. An AsyncError from the catalogue
/// provider took that away from every screen that watches it (the adopt
/// screen showed "Could not read the device catalogue", BLE group members
/// "Could not reach this device"). This is the same choice, at the
/// catalogue: empty, with the reason attached to every key so the provider's
/// one "native codec unavailable" line still has its count.
class EmptySpecCatalogue implements SpecCatalogue {
  @override
  final List<CatalogueSpec> specs = const [];

  @override
  final List<SpecLoadFailureDto> failures;

  EmptySpecCatalogue(this.failures);

  @override
  Future<List<SpecMatch>> matchDevice({
    required String deviceName,
    required List<String> serviceUuids,
  }) async => const [];

  @override
  Future<DeviceSpecDto> specAt(int index) async =>
      throw RangeError.index(index, specs, 'index', 'the catalogue is empty');

  @override
  Future<List<UdpProbeDto>> udpBroadcastProbes() async => const [];
}

/// Whether [error] is flutter_rust_bridge saying the native core was never
/// initialised — the one failure that is not about any spec.
bool isBridgeUninitialised(Object error) =>
    error.toString().contains('has not been initialized');

class FallbackSpecCatalogue implements SpecCatalogue {
  final SpecCodec _codec;

  @override
  final List<CatalogueSpec> specs;

  @override
  final List<SpecLoadFailureDto> failures;

  /// The DTOs behind [specs], by index — this catalogue parses eagerly
  /// because that is all its codec can do.
  final List<DeviceSpecDto> _dtos;

  FallbackSpecCatalogue._(this._codec, this.specs, this._dtos, this.failures);

  /// Parse every spec in [yamls] through [codec], skipping the ones that
  /// fail. Chunked for the same reason the real catalogue is: a 203-spec
  /// parse that never yields is a frame the UI dropped.
  static Future<FallbackSpecCatalogue> load(
    SpecCodec codec,
    Map<String, String> yamls, {
    void Function(int loaded, int total)? onProgress,
    int chunkSize = catalogueChunkSize,
  }) async {
    final entries = yamls.entries.toList();
    final specs = <CatalogueSpec>[];
    final dtos = <DeviceSpecDto>[];
    final failures = <SpecLoadFailureDto>[];
    for (var start = 0; start < entries.length; start += chunkSize) {
      final chunk = entries.skip(start).take(chunkSize).toList();
      final parsed = await Future.wait(
        chunk.map((e) async {
          try {
            return await codec.loadDeviceSpec(e.value);
          } catch (error) {
            failures.add(
              SpecLoadFailureDto(key: e.key, message: error.toString()),
            );
            return null;
          }
        }),
      );
      for (var i = 0; i < chunk.length; i++) {
        final dto = parsed[i];
        if (dto == null) continue;
        specs.add(
          CatalogueSpec(
            index: specs.length,
            key: chunk[i].key,
            yaml: chunk[i].value,
            identity: specIdentityOf(dto),
            protocolHandler: dto.protocolHandler,
            gattServiceUuids: [for (final s in dto.services) s.uuid],
          ),
        );
        dtos.add(dto);
      }
      onProgress?.call(specs.length + failures.length, entries.length);
    }
    return FallbackSpecCatalogue._(codec, specs, dtos, failures);
  }

  /// A catalogue over specs that are ALREADY parsed.
  ///
  /// For a caller holding the DTOs and their text — the group screen's
  /// invalidation path, and the suites that stand a catalogue up without a
  /// codec that can parse. [keys] defaults to the spec's own identity key, so
  /// entries stay distinguishable without inventing asset paths.
  factory FallbackSpecCatalogue.fromParsed(
    SpecCodec codec,
    List<({DeviceSpecDto spec, String yaml})> parsed, {
    List<String>? keys,
  }) {
    final specs = <CatalogueSpec>[];
    for (var i = 0; i < parsed.length; i++) {
      final dto = parsed[i].spec;
      specs.add(
        CatalogueSpec(
          index: i,
          key: keys?[i] ?? '${dto.deviceName}|${dto.manufacturer}',
          yaml: parsed[i].yaml,
          identity: specIdentityOf(dto),
          protocolHandler: dto.protocolHandler,
          gattServiceUuids: [for (final s in dto.services) s.uuid],
        ),
      );
    }
    return FallbackSpecCatalogue._(codec, specs, [
      for (final entry in parsed) entry.spec,
    ], const []);
  }

  /// No probes from the fallback catalogue.
  ///
  /// The probe blocks are read by the Rust spec model, which is exactly what
  /// this catalogue exists to do without. A build that has fallen back to it
  /// has bigger problems than a Milight bridge it cannot find, and answering
  /// "none" costs only the probes the dedicated transports send anyway.
  @override
  Future<List<UdpProbeDto>> udpBroadcastProbes() async => const [];

  @override
  Future<List<SpecMatch>> matchDevice({
    required String deviceName,
    required List<String> serviceUuids,
  }) async {
    final matches = await _codec.matchDeviceToSpec(
      specs: _dtos,
      deviceName: deviceName,
      advertisedServiceUuids: serviceUuids,
    );
    // The matcher hands back the specs it was given, so an identity join
    // recovers each one's index. A plain `==` is not an option: the generated
    // `DeviceSpecDto ==` compares List fields by reference, which an FFI
    // round trip does not preserve.
    final byIdentity = <String, int>{};
    for (var i = 0; i < _dtos.length; i++) {
      byIdentity.putIfAbsent(_identityKey(_dtos[i]), () => i);
    }
    return [
      for (final match in matches)
        if (byIdentity[_identityKey(match.spec)] case final index?)
          SpecMatch(
            entry: specs[index],
            matchedByNamePrefix: match.matchedByNamePrefix,
            confidence: match.confidence,
            matchedServiceUuids: match.matchedServiceUuids,
          ),
    ];
  }

  static String _identityKey(DeviceSpecDto spec) => [
    spec.deviceName,
    spec.manufacturer,
    spec.localNamePrefixes.join(','),
    spec.serviceUuids.join(','),
  ].join('|');

  @override
  Future<DeviceSpecDto> specAt(int index) async => _dtos[index];
}

/// How many specs a catalogue load parses per event-loop turn.
///
/// The load is chunked rather than issued as one 200-wide `Future.wait`
/// because both ends of it run on the calling isolate: the YAML is encoded
/// going out and the entries decoded coming back, and as one burst that was
/// a frame-eating stall landing exactly as the first scan results appear.
///
/// Forty is where the two pressures meet. Smaller chunks cost round trips
/// and leave the Rust side too little to spread across its cores; larger
/// ones grow the per-turn share. At forty the whole 204-spec load holds the
/// isolate for about 2 ms in total on an Apple Silicon host — measured, with
/// the by-value load it replaced, by
/// `test/services/spec_codec_ffi_budget_test.dart`.
const catalogueChunkSize = 40;

/// The identifying projection of a parsed spec — the fields both scan
/// matchers rank against.
///
/// Mirrors Rust's `SpecIdentityDto::from(&DeviceSpecDto)`, for the codecs
/// that build a catalogue out of DTOs (see [FallbackSpecCatalogue]). The
/// golden test compares the two projections over the whole vendored
/// catalogue, so a field added on one side and forgotten on the other fails
/// there rather than in a scan that quietly stops matching.
SpecIdentityDto specIdentityOf(DeviceSpecDto spec) => SpecIdentityDto(
  deviceName: spec.deviceName,
  manufacturer: spec.manufacturer,
  category: spec.category,
  pictogram: spec.pictogram,
  adminUrl: spec.adminUrl,
  integration: spec.integration,
  securityAdvisory: spec.securityAdvisory,
  localNamePrefixes: spec.localNamePrefixes,
  localNames: spec.localNames,
  serviceUuids: spec.serviceUuids,
  companyIds: spec.companyIds,
  macPrefixes: spec.macPrefixes,
  mdnsServiceTypes: spec.mdnsServiceTypes,
  ssdpSearchTargets: spec.ssdpSearchTargets,
  lanProtocols: spec.lanProtocols,
  defaultPort: spec.defaultPort,
  nameMatchers: spec.nameMatchers,
  txtMatchGroups: spec.txtMatchGroups,
  platformFallbackTypes: spec.platformFallbackTypes,
);
