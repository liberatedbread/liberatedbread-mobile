// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:typed_data';

import '../src/rust/api/device_api.dart';

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
        QuerySourceDto,
        LifxServiceDto,
        LifxStateDto,
        LifxZoneColorDto,
        LifxZonesDto,
        LifxAccessPointDto,
        SoftApProfileDto,
        SecurityAdvisoryDto,
        WemoAccessPointDto,
        WemoJoinStatus;

// `MacPrefixDto.confidence` is generated into the spec module rather than the
// api one, because the enum is declared where the catalogue is parsed. Callers
// of this abstraction should not have to know that.
export '../src/rust/spec/types.dart' show MacPrefixConfidence;

// `ParameterDto.allowed` crosses the FFI as flutter_rust_bridge's Int64List
// (a List<BigInt>, not dart:typed_data's). Re-export it so tests and widgets
// can build parameter DTOs carrying allowed values while still depending only
// on this abstraction.
export 'package:flutter_rust_bridge/flutter_rust_bridge.dart' show Int64List;

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

  /// The controls a spec declares for one discovered network device — the
  /// SOAP counterpart of a BLE spec's entities.
  ///
  /// [ssdpTargets] is what the device itself answered to; it narrows a family
  /// spec's variant-scoped entities to the model actually found, so a Wemo
  /// plug never grows the slow cooker's controls.
  Future<List<NetworkEntityDto>> networkEntitiesForDevice({
    required String specYaml,
    required List<String> ssdpTargets,
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

  /// Encode the BLE writes that persist a multi-frame animation on the device.
  ///
  /// [frames] are the screens in play order, each row-major RGB888
  /// `width * height * 3` bytes, ≤16 colours each. [frameMs] is the editor's
  /// preview interval; the container stores the matching frame rate so the
  /// device plays at the speed the user tuned on screen (0 falls back to the
  /// vendor's 20 fps).
  Future<StoredUploadPlanDto> encodeStoredAnimation({
    required String specYaml,
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
  Future<List<SoapRequestDto>> renderWemoConnectRequests({
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
}

/// Play/loop-mode values for [SpecCodec.encodeAutorunMode].
class AutorunMode {
  static const int fixed = 0;
  static const int repeat = 1;
  static const int random = 2;
}
