// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show visibleForTesting;

import '../src/rust/api/device_api.dart' as rust;
import '../src/rust/api/print_api.dart' as print_rust;
import '../src/rust/api/spec_handle.dart' as handles;
import 'spec_codec.dart';

/// Production [SpecCodec] backed by the Rust core via flutter_rust_bridge.
///
/// Most methods are a thin pass-through to the generated FFI function, so the
/// behavior is identical to calling the bindings directly — the indirection
/// exists only so the UI can be tested against a fake.
///
/// The exceptions are the calls a connected device makes over and over:
/// `decodeValue`, `encodeCommand`, `encodeEntityValue` and the network state
/// poll. Their signatures still take the spec's YAML, but when this codec is
/// already holding the parse for that exact string it sends a handle instead
/// — a pointer rather than up to 123 KB of text, re-encoded on the UI isolate
/// once per subscribed widget per notification.
///
/// See [_held] for what "that exact string" means and why a miss costs
/// nothing.
class RealSpecCodec implements SpecCodec {
  /// Parses this codec is holding, keyed by the IDENTITY of the YAML string
  /// they were parsed from.
  ///
  /// Identity, not equality, and deliberately: hashing an 85 KB string to
  /// look it up would cost a good share of what the lookup saves, while
  /// `identityHashCode` is the object's own header hash. It is also enough.
  /// Every repeated caller reads the text out of one long-lived place — the
  /// matched spec a device screen holds for as long as it is open — so the
  /// hot path passes one string instance, over and over.
  ///
  /// A caller that rebuilds the text per call simply misses, and a miss is
  /// not a penalty: [_holdSpec] starts the parse for next time while THIS
  /// call goes by value, exactly as it did before handles existed. So the
  /// worst case is the old cost, not twice it.
  final Map<String, handles.LoadedSpec> _handles = HashMap(
    equals: identical,
    hashCode: identityHashCode,
  );

  /// Parses in flight, so a burst of notifications on a cold spec starts one
  /// parse rather than one per packet.
  final Map<String, Future<void>> _holding = HashMap(
    equals: identical,
    hashCode: identityHashCode,
  );

  /// Order [_handles] keys were filed in, oldest first, for eviction.
  final List<String> _handleOrder = [];

  /// How many parses this codec holds at once.
  ///
  /// A device screen needs one, a group run a handful. The bound exists
  /// because spec packs can be installed from arbitrary URLs and each parse
  /// is real memory; past it the oldest is dropped. Dropping means dropping
  /// the Dart reference only — never `dispose()`, which would pull the Rust
  /// object out from under a call that is already encoding its pointer. The
  /// finalizer releases it once nothing holds it, which is exactly the
  /// question we cannot answer here.
  static const _maxHeldSpecs = 8;

  /// The most recent decodes, newest last, for the packet-fanout memo. See
  /// [_memoisedDecode].
  final List<_DecodeMemo> _recentDecodes = [];

  /// How many recent decodes the memo keeps.
  ///
  /// One entry per (spec, service, characteristic) actively notifying is all
  /// it needs — an Airthings streams one combined packet to seven tiles — so
  /// this is generous for the real workload and small enough that the linear
  /// identity scan is cheaper than hashing anything.
  static const _maxRecentDecodes = 8;

  RealSpecCodec();

  /// The parse this codec holds for [yaml], or null when it holds none yet.
  ///
  /// Synchronous on purpose: the notification path must be able to choose
  /// between the handle and the by-value call without an extra event-loop
  /// turn.
  handles.LoadedSpec? _held(String? yaml) {
    if (yaml == null) return null;
    final held = _handles[yaml];
    // A handle a caller disposed is not usable and must not be served again.
    if (held != null && held.isDisposed) {
      _handles.remove(yaml);
      _handleOrder.remove(yaml);
      return null;
    }
    return held;
  }

  /// Start holding the parse for [yaml], if it is not held or being held
  /// already. Returns when the parse is available (or has failed).
  ///
  /// A parse failure is swallowed: the by-value path raises the same error
  /// with the same message for the same spec, and this call's only job is to
  /// make the NEXT call cheaper.
  Future<void> _holdSpec(String yaml) {
    final holding = _holding[yaml];
    if (holding != null) return holding;
    if (_handles.containsKey(yaml)) return Future.value();
    final future = () async {
      try {
        hold(yaml, await handles.loadSpec(yaml: yaml));
      } catch (_) {
        // Left unheld; the by-value path reports the failure.
      } finally {
        // removeWhere, not remove: `remove` hands back the future it
        // removed — this one — and discarding a future is exactly what the
        // analyzer is right to complain about everywhere else.
        _holding.removeWhere((key, _) => identical(key, yaml));
      }
    }();
    _holding[yaml] = future;
    return future;
  }

  /// File an already-built parse under [yaml].
  ///
  /// The catalogue calls this: a spec it has already parsed becomes the
  /// screen's handle with no second parse and no YAML crossing.
  void hold(String yaml, handles.LoadedSpec spec) {
    if (!_handles.containsKey(yaml)) _handleOrder.add(yaml);
    _handles[yaml] = spec;
    while (_handleOrder.length > _maxHeldSpecs) {
      _handles.remove(_handleOrder.removeAt(0));
    }
  }

  /// How many recent packets the decode memo is holding, and how many parses
  /// this codec holds. Both are internal bookkeeping with no caller in `lib`;
  /// the golden suite reads them to prove that a packet fanned out to seven
  /// widgets crosses the boundary once, and that a disposed parse is dropped.
  @visibleForTesting
  int get memoisedPacketCount => _recentDecodes.length;

  @visibleForTesting
  int get heldParseCount => _handles.length;

  /// Parse [yaml] now and hold it, so later calls about this same string
  /// instance ship a handle. For a caller that knows a spec is about to be
  /// used repeatedly; everything else warms itself on its first call.
  Future<void> prepareSpec(String yaml) => _holdSpec(yaml);

  @override
  Future<DeviceSpecDto> loadDeviceSpec(String yaml) =>
      rust.loadDeviceSpec(yaml: yaml);

  @override
  Future<SpecCatalogue> loadCatalogue(
    Map<String, String> specs, {
    void Function(int loaded, int total)? onProgress,
  }) => RustSpecCatalogue.load(this, specs, onProgress: onProgress);

  @override
  Future<List<String>> bleVariantNamesForDevice({
    required String yaml,
    required String deviceName,
    required List<String> serviceUuids,
  }) => rust.bleVariantNamesForDevice(
    specYaml: yaml,
    deviceName: deviceName,
    serviceUuids: serviceUuids,
  );

  @override
  Future<List<MatchResult>> matchDeviceToSpec({
    required List<DeviceSpecDto> specs,
    required String deviceName,
    required List<String> advertisedServiceUuids,
  }) => rust.matchDeviceToSpec(
    specs: specs,
    deviceName: deviceName,
    advertisedServiceUuids: advertisedServiceUuids,
  );

  @override
  Future<List<ScanMatch>> matchScannedDevice({
    required List<SpecIdentityDto> identities,
    required ScannedDeviceDto device,
  }) => rust.matchScannedDevice(identities: identities, device: device);

  @override
  Future<List<ScanMatch>> matchNetworkDevice({
    required List<SpecIdentityDto> identities,
    required NetworkDeviceDto device,
  }) => rust.matchNetworkDevice(identities: identities, device: device);

  @override
  Future<Uint8List> encodeCommand({
    String? specYaml,
    String? serviceUuid,
    required String charUuid,
    required String commandName,
    required Map<String, double> params,
  }) {
    final held = _held(specYaml);
    if (held != null) {
      return held.encodeCommand(
        serviceUuid: serviceUuid,
        charUuid: charUuid,
        commandName: commandName,
        params: params,
      );
    }
    if (specYaml != null) unawaited(_holdSpec(specYaml));
    return rust.encodeCommand(
      specYaml: specYaml,
      serviceUuid: serviceUuid,
      charUuid: charUuid,
      commandName: commandName,
      params: params,
    );
  }

  @override
  Future<List<DecodedValueDto>> decodeValue({
    String? specYaml,
    String? serviceUuid,
    required String charUuid,
    required List<int> bytes,
  }) {
    // The hot one. A notify-driven sensor tile lands here several times a
    // second, once per subscribed widget, and every one of those used to
    // re-encode the whole spec on the UI isolate to decode a few bytes.
    final held = _held(specYaml);
    if (held != null) {
      return _memoisedDecode(
        specYaml,
        serviceUuid,
        charUuid,
        bytes,
        () => held.decodeValue(
          serviceUuid: serviceUuid,
          charUuid: charUuid,
          bytes: bytes,
        ),
      );
    }
    if (specYaml != null) unawaited(_holdSpec(specYaml));
    return _memoisedDecode(
      specYaml,
      serviceUuid,
      charUuid,
      bytes,
      () => rust.decodeValue(
        specYaml: specYaml,
        serviceUuid: serviceUuid,
        charUuid: charUuid,
        bytes: bytes,
      ),
    );
  }

  /// One decode per packet, however many widgets ask for it.
  ///
  /// The BLE layer refcounts a notify subscription at the CCCD, so one
  /// notification is delivered to every subscriber as THE SAME `List<int>`
  /// instance — and on an Airthings that is six sensor tiles plus the raw
  /// service card all decoding the one combined packet, which was six extra
  /// crossings of the boundary for an answer already computed.
  ///
  /// Keyed by identity throughout (the byte list, the spec text), so the memo
  /// can only serve a caller that was handed the very object a previous
  /// caller decoded. Equal-but-distinct bytes miss and decode again, which is
  /// the safe direction: a device that sends the same bytes twice gets two
  /// decodes rather than one stale answer.
  ///
  /// Each caller gets its own list, so a consumer that sorts or trims what it
  /// was given cannot reach into another widget's reading.
  Future<List<DecodedValueDto>> _memoisedDecode(
    String? specYaml,
    String? serviceUuid,
    String charUuid,
    List<int> bytes,
    Future<List<DecodedValueDto>> Function() decode,
  ) {
    for (final memo in _recentDecodes) {
      if (memo.matches(specYaml, serviceUuid, charUuid, bytes)) {
        return memo.result.then(List<DecodedValueDto>.of);
      }
    }
    final result = decode();
    _recentDecodes.add(
      _DecodeMemo(specYaml, serviceUuid, charUuid, bytes, result),
    );
    if (_recentDecodes.length > _maxRecentDecodes) _recentDecodes.removeAt(0);
    // A failed decode must not be remembered: the next notification on that
    // characteristic deserves its own attempt, and a caller that retries the
    // same packet after a transient failure should get a real call.
    return result
        .catchError((Object error, StackTrace stack) {
          _recentDecodes.removeWhere((memo) => identical(memo.result, result));
          throw error;
        })
        .then(List<DecodedValueDto>.of);
  }

  @override
  Future<List<ProfileInfoDto>> identifyStandardProfiles(
    List<String> serviceUuids,
  ) => rust.identifyStandardProfiles(serviceUuids: serviceUuids);

  @override
  Future<EntityWriteDto> encodeEntityValue({
    required String specYaml,
    required String entityName,
    required double value,
  }) {
    final held = _held(specYaml);
    if (held != null) {
      return held.encodeEntityValue(entityName: entityName, value: value);
    }
    unawaited(_holdSpec(specYaml));
    return rust.encodeEntityValue(
      specYaml: specYaml,
      entityName: entityName,
      value: value,
    );
  }

  @override
  Future<ImageWritePlanDto> encodeImageFrame({
    required String specYaml,
    required int width,
    required int height,
    required List<int> rgb,
    required int frameIndex,
    required int maxPayloadPerWrite,
  }) => rust.encodeImageFrame(
    specYaml: specYaml,
    width: width,
    height: height,
    rgb: rgb,
    frameIndex: frameIndex,
    maxPayloadPerWrite: maxPayloadPerWrite,
  );

  @override
  Future<PanelResolutionDto?> advertisedResolution({
    required String specYaml,
    required Map<int, List<int>> manufacturerData,
  }) => rust.advertisedResolution(
    specYaml: specYaml,
    manufacturerData: [
      for (final e in manufacturerData.entries)
        (e.key, Uint8List.fromList(e.value)),
    ],
  );

  @override
  Future<PanelResolutionDto?> deviceInfoResolution({
    required List<List<int>> notifications,
  }) => rust.deviceInfoResolution(
    notifications: [for (final n in notifications) Uint8List.fromList(n)],
  );

  @override
  Future<NetworkEntitySurfaceDto> networkEntitiesForDevice({
    required String specYaml,
    required List<String> ssdpTargets,
  }) => rust.networkEntitiesForDevice(
    specYaml: specYaml,
    ssdpTargets: ssdpTargets,
  );

  @override
  Future<NetworkEntitySurfaceDto> networkEntitiesForStateKeys({
    required String specYaml,
    required List<String> ssdpTargets,
    required Map<String, Map<String, String>> stateKeys,
  }) => rust.networkEntitiesForStateKeys(
    specYaml: specYaml,
    ssdpTargets: ssdpTargets,
    stateKeys: stateKeys,
  );

  @override
  Future<NetworkCapabilitiesDto> networkCapabilities({
    required String specYaml,
  }) => rust.networkCapabilities(specYaml: specYaml);

  @override
  Future<List<NetworkCredentialDto>> credentialsForDevice(String specYaml) =>
      rust.credentialsForDevice(specYaml: specYaml);

  @override
  Future<String> deriveCredentialValue({
    required String derivation,
    required String value,
  }) => rust.deriveCredentialValue(derivation: derivation, value: value);

  @override
  Future<SoapRequestDto> renderNetworkCommand({
    required String specYaml,
    required String commandName,
    required Map<String, String> values,
  }) => rust.renderNetworkCommand(
    specYaml: specYaml,
    commandName: commandName,
    values: values,
  );

  @override
  Future<HttpRequestDto> renderNetworkHttpCommand({
    required String specYaml,
    required String commandName,
    required Map<String, String> values,
  }) => rust.renderNetworkHttpCommand(
    specYaml: specYaml,
    commandName: commandName,
    values: values,
  );

  @override
  Future<HttpRequestDto> renderNetworkHttpStateRequest({
    required String specYaml,
    required String stateCommand,
    required Map<String, String> values,
  }) {
    // The network side's hot path: every open network device re-renders this
    // on a four-second poll, per entity.
    final held = _held(specYaml);
    if (held != null) {
      return held.renderNetworkHttpStateRequest(
        stateCommand: stateCommand,
        values: values,
      );
    }
    unawaited(_holdSpec(specYaml));
    return rust.renderNetworkHttpStateRequest(
      specYaml: specYaml,
      stateCommand: stateCommand,
      values: values,
    );
  }

  @override
  Future<List<StateTopicFallbackDto>> specStateTopicFallbacks({
    required String specYaml,
  }) => rust.specStateTopicFallbacks(specYaml: specYaml);

  @override
  Future<BleHandshakeDto> specBleHandshake({required String specYaml}) =>
      rust.specBleHandshake(specYaml: specYaml);

  @override
  Future<List<NetworkInstanceDto>> listNetworkInstances({
    required String specYaml,
    required String entityName,
    required String stateReply,
  }) {
    final held = _held(specYaml);
    if (held != null) {
      return held.listNetworkInstances(
        entityName: entityName,
        stateReply: stateReply,
      );
    }
    unawaited(_holdSpec(specYaml));
    return rust.listNetworkInstances(
      specYaml: specYaml,
      entityName: entityName,
      stateReply: stateReply,
    );
  }

  @override
  Future<List<NetworkRoleReadingDto>> readNetworkInstance({
    required String specYaml,
    required String entityName,
    required String stateReply,
    required String instanceId,
  }) {
    final held = _held(specYaml);
    if (held != null) {
      return held.readNetworkInstance(
        entityName: entityName,
        stateReply: stateReply,
        instanceId: instanceId,
      );
    }
    unawaited(_holdSpec(specYaml));
    return rust.readNetworkInstance(
      specYaml: specYaml,
      entityName: entityName,
      stateReply: stateReply,
      instanceId: instanceId,
    );
  }

  @override
  Future<SoapRequestDto> renderNetworkStateRequest({
    required String specYaml,
    required String stateCommand,
  }) {
    final held = _held(specYaml);
    if (held != null) {
      return held.renderNetworkStateRequest(stateCommand: stateCommand);
    }
    unawaited(_holdSpec(specYaml));
    return rust.renderNetworkStateRequest(
      specYaml: specYaml,
      stateCommand: stateCommand,
    );
  }

  @override
  Future<KasaRequestDto> renderNetworkKasaCommand({
    required String specYaml,
    required String commandName,
    required Map<String, String> values,
  }) => rust.renderNetworkKasaCommand(
    specYaml: specYaml,
    commandName: commandName,
    values: values,
  );

  @override
  Future<KasaRequestDto> renderNetworkKasaStateRequest({
    required String specYaml,
    required String stateCommand,
  }) => rust.renderNetworkKasaStateRequest(
    specYaml: specYaml,
    stateCommand: stateCommand,
  );

  @override
  Future<List<int>> kasaEncodeFrame({required String json}) =>
      rust.kasaEncodeFrame(json: json);

  @override
  Future<String> kasaDecodeFrame({required List<int> frame}) =>
      rust.kasaDecodeFrame(frame: frame);

  @override
  Future<List<int>> kasaEncryptDatagram({required String json}) =>
      rust.kasaEncryptDatagram(json: json);

  @override
  Future<String> kasaDecodeDatagram({required List<int> datagram}) =>
      rust.kasaDecodeDatagram(datagram: datagram);

  @override
  Future<TuyaBroadcastDto?> tuyaParseBroadcast({required List<int> datagram}) =>
      rust.tuyaParseBroadcast(datagram: datagram);

  @override
  Future<RabbitAirRequestDto> renderNetworkRabbitAirCommand({
    required String specYaml,
    required String commandName,
    required Map<String, String> values,
    required int requestId,
    required int deviceTs,
  }) => rust.renderNetworkRabbitAirCommand(
    specYaml: specYaml,
    commandName: commandName,
    values: values,
    requestId: requestId,
    deviceTs: deviceTs,
  );

  @override
  Future<RabbitAirRequestDto> renderNetworkRabbitAirStateRequest({
    required String specYaml,
    required String stateCommand,
    required int requestId,
    required int deviceTs,
  }) => rust.renderNetworkRabbitAirStateRequest(
    specYaml: specYaml,
    stateCommand: stateCommand,
    requestId: requestId,
    deviceTs: deviceTs,
  );

  @override
  Future<int> rabbitAirPort() => rust.rabbitAirPort();

  @override
  Future<List<int>> rabbitAirEncryptDatagram({
    required String userKey,
    required String plaintext,
  }) => rust.rabbitAirEncryptDatagram(userKey: userKey, plaintext: plaintext);

  @override
  Future<String> rabbitAirDecryptDatagram({
    required String userKey,
    required List<int> datagram,
  }) => rust.rabbitAirDecryptDatagram(userKey: userKey, datagram: datagram);

  @override
  Future<int> rabbitAirTimeSyncOffset({
    required String replyJson,
    required int localNowSecs,
  }) => rust.rabbitAirTimeSyncOffset(
    replyJson: replyJson,
    localNowSecs: localNowSecs,
  );

  @override
  Future<List<List<int>>> rabbitAirBleFrame({
    required List<int> payload,
    required int chunkSize,
  }) => rust.rabbitAirBleFrame(payload: payload, chunkSize: chunkSize);

  @override
  Future<int?> rabbitAirBleExpectedPayloadLen({
    required List<int> firstChunk,
  }) => rust.rabbitAirBleExpectedPayloadLen(firstChunk: firstChunk);

  @override
  Future<String> renderRabbitAirSetupEnvelope({
    required int id,
    required int cmd,
    String? dataJson,
  }) => rust.renderRabbitAirSetupEnvelope(id: id, cmd: cmd, dataJson: dataJson);

  @override
  Future<String> rabbitAirGenerateUserKey() => rust.rabbitAirGenerateUserKey();

  @override
  Future<String> rabbitAirBleServiceUuid() => rust.rabbitAirBleServiceUuid();

  @override
  Future<String> rabbitAirBleCommandCharacteristicUuid() =>
      rust.rabbitAirBleCommandCharacteristicUuid();

  @override
  Future<int> rabbitAirBleMtu() => rust.rabbitAirBleMtu();
  @override
  Future<List<int>> roombaDiscoveryProbe() => rust.roombaDiscoveryProbe();

  @override
  Future<RoombaAnnouncementDto?> roombaParseAnnouncement({
    required List<int> datagram,
  }) => rust.roombaParseAnnouncement(datagram: datagram);

  @override
  Future<List<int>> roombaPasswordProbe() => rust.roombaPasswordProbe();

  @override
  Future<String> roombaParsePasswordReply({required List<int> reply}) =>
      rust.roombaParsePasswordReply(reply: reply);

  @override
  Future<RoombaRequestDto> renderNetworkRoombaCommand({
    required String specYaml,
    required String commandName,
    required int epochSeconds,
  }) => rust.renderNetworkRoombaCommand(
    specYaml: specYaml,
    commandName: commandName,
    epochSeconds: epochSeconds,
  );

  @override
  Future<Map<String, String>> roombaStateFields({required String payload}) =>
      rust.roombaStateFields(payload: payload);

  @override
  Future<List<int>> roombaConnectPacket({
    required String blid,
    required String password,
  }) => rust.roombaConnectPacket(blid: blid, password: password);

  @override
  Future<WebSocketSurfaceDto?> websocketSurface(String specYaml) =>
      rust.websocketSurface(specYaml: specYaml);

  @override
  Future<WebSocketFrameDto> renderNetworkWebsocketCommand({
    required String specYaml,
    required String commandName,
    required Map<String, String> values,
    required int requestId,
  }) => rust.renderNetworkWebsocketCommand(
    specYaml: specYaml,
    commandName: commandName,
    values: values,
    requestId: requestId,
  );

  @override
  Future<List<int>> mqttConnectPacket({
    required String clientId,
    String? username,
    String? password,
  }) => rust.mqttConnectPacket(
    clientId: clientId,
    username: username,
    password: password,
  );

  @override
  Future<MqttRequestDto> renderNetworkMqttCommand({
    required String specYaml,
    required String commandName,
    required Map<String, String> values,
  }) => rust.renderNetworkMqttCommand(
    specYaml: specYaml,
    commandName: commandName,
    values: values,
  );

  @override
  Future<String> fillMqttStateTopic({
    required String topic,
    required Map<String, String> values,
  }) => rust.fillMqttStateTopic(topic: topic, values: values);

  @override
  Future<List<int>> mqttSubscribePacket({
    required String topic,
    required int packetId,
  }) => rust.mqttSubscribePacket(topic: topic, packetId: packetId);

  @override
  Future<List<int>> mqttPublishPacket({
    required String topic,
    required String payload,
  }) => rust.mqttPublishPacket(topic: topic, payload: payload);

  @override
  Future<List<int>> mqttPingreqPacket() => rust.mqttPingreqPacket();

  @override
  Future<List<int>> mqttDisconnectPacket() => rust.mqttDisconnectPacket();

  @override
  Future<MqttParsedDto> mqttParseIncoming({required List<int> buffer}) =>
      rust.mqttParseIncoming(buffer: buffer);

  @override
  Future<NetworkReadingDto?> readNetworkEntity({
    required String specYaml,
    required String entityName,
    required Map<String, String> returned,
  }) {
    // The other half of the four-second poll: one of these per entity per
    // tick, each of which re-sent the spec.
    final held = _held(specYaml);
    if (held != null) {
      return held.readNetworkEntity(entityName: entityName, returned: returned);
    }
    unawaited(_holdSpec(specYaml));
    return rust.readNetworkEntity(
      specYaml: specYaml,
      entityName: entityName,
      returned: returned,
    );
  }

  @override
  Future<StoredUploadPlanDto> encodeStoredImage({
    required String specYaml,
    int? maxWrite,
    required int width,
    required int height,
    required List<int> rgb,
    required String name,
    required int cid,
    required int timeSecs,
    required String scroll,
    required int speed,
    required int sequence,
  }) => rust.encodeStoredImage(
    specYaml: specYaml,
    maxWrite: maxWrite,
    width: width,
    height: height,
    rgb: rgb,
    name: name,
    cid: cid,
    timeSecs: timeSecs,
    scroll: scroll,
    speed: speed,
    sequence: sequence,
  );

  @override
  Future<StoredUploadPlanDto> encodeStoredText({
    required String specYaml,
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
  }) => rust.encodeStoredText(
    specYaml: specYaml,
    maxWrite: maxWrite,
    textWidth: textWidth,
    textHeight: textHeight,
    bits: bits,
    name: name,
    cid: cid,
    timeSecs: timeSecs,
    scroll: scroll,
    speed: speed,
    sequence: sequence,
  );

  @override
  Future<StoredUploadPlanDto> encodeStoredAnimation({
    required String specYaml,
    int? maxWrite,
    required int width,
    required int height,
    required List<List<int>> frames,
    required String name,
    required int cid,
    required int frameMs,
    required int sequence,
  }) => rust.encodeStoredAnimation(
    specYaml: specYaml,
    maxWrite: maxWrite,
    width: width,
    height: height,
    frames: frames.map(Uint8List.fromList).toList(),
    name: name,
    cid: cid,
    frameMs: frameMs,
    sequence: sequence,
  );

  @override
  Future<List<StoredUploadEventDto>> decodeStoredUploadEvents({
    required String specYaml,
    required List<List<int>> notifications,
  }) => rust.decodeStoredUploadEvents(
    specYaml: specYaml,
    notifications: [for (final n in notifications) Uint8List.fromList(n)],
  );

  @override
  Future<StoredUploadEventDto?> decodeStoredUploadEvent({
    required String specYaml,
    required List<int> bytes,
  }) => rust.decodeStoredUploadEvent(
    specYaml: specYaml,
    bytes: Uint8List.fromList(bytes),
  );

  @override
  Future<StoredPlayDto> encodeStoredPlay({
    required String specYaml,
    required int cid,
    required int sequence,
  }) => rust.encodeStoredPlay(specYaml: specYaml, cid: cid, sequence: sequence);

  @override
  Future<int> lifxPort() => rust.lifxPort();

  @override
  Future<Uint8List> renderLifxCommand({
    required String action,
    required Map<String, double> params,
    required String targetMac,
    required int sequence,
  }) => rust.renderLifxCommand(
    action: action,
    params: params,
    targetMac: targetMac,
    sequence: sequence,
  );

  @override
  Future<Uint8List> buildLifxDiscoveryProbe({required int sequence}) =>
      rust.buildLifxDiscoveryProbe(sequence: sequence);

  @override
  Future<Uint8List> buildLifxStateRequest({
    required String targetMac,
    required int sequence,
  }) => rust.buildLifxStateRequest(targetMac: targetMac, sequence: sequence);

  @override
  Future<Uint8List> buildLifxZonesRequest({
    required String targetMac,
    required int start,
    required int end,
    required int sequence,
  }) => rust.buildLifxZonesRequest(
    targetMac: targetMac,
    start: start,
    end: end,
    sequence: sequence,
  );

  @override
  Future<LifxServiceDto> parseLifxStateService({required List<int> bytes}) =>
      rust.parseLifxStateService(bytes: bytes);

  @override
  Future<LifxStateDto> decodeLifxState({required List<int> bytes}) =>
      rust.decodeLifxState(bytes: bytes);

  @override
  Future<LifxZonesDto> decodeLifxZones({required List<int> bytes}) =>
      rust.decodeLifxZones(bytes: bytes);

  @override
  Future<int> lifxDefaultSecurity() => rust.lifxDefaultSecurity();

  @override
  Future<Uint8List> buildLifxGetAccessPoints({required int sequence}) =>
      rust.buildLifxGetAccessPoints(sequence: sequence);

  @override
  Future<Uint8List> renderLifxSetAccessPoint({
    required String ssid,
    required String password,
    required int security,
    required int sequence,
  }) => rust.renderLifxSetAccessPoint(
    ssid: ssid,
    password: password,
    security: security,
    sequence: sequence,
  );

  @override
  Future<LifxAccessPointDto> decodeLifxAccessPoint({
    required List<int> bytes,
  }) => rust.decodeLifxAccessPoint(bytes: bytes);

  @override
  Future<List<SoftApProfileDto>> softApProfiles(List<String> specYamls) =>
      rust.softApProfiles(specYamls: specYamls);

  @override
  Future<SetupInstructionsDto?> setupInstructions(String specYaml) =>
      rust.setupInstructions(specYaml: specYaml);

  @override
  Future<List<BleProvisioningProfileDto>> bleProvisioningProfiles(
    List<String> specYamls,
  ) => rust.bleProvisioningProfiles(specYamls: specYamls);

  @override
  Future<int?> matchBleProvisioningName({
    required List<BleProvisioningProfileDto> profiles,
    required String advertisedName,
  }) => rust.matchBleProvisioningName(
    profiles: profiles,
    advertisedName: advertisedName,
  );

  @override
  Future<int?> matchSoftApSsid({
    required List<SoftApProfileDto> profiles,
    required String ssid,
  }) => rust.matchSoftApSsid(profiles: profiles, ssid: ssid);

  @override
  Future<List<WemoConnectAttemptDto>> renderWemoConnectRequests({
    required String specYaml,
    required String metaInfo,
    required String ssid,
    required String auth,
    required String encrypt,
    required String channel,
    required String passphrase,
    int? rtos,
    int? iot,
  }) => rust.renderWemoConnectRequests(
    specYaml: specYaml,
    metaInfo: metaInfo,
    ssid: ssid,
    auth: auth,
    encrypt: encrypt,
    channel: channel,
    passphrase: passphrase,
    rtos: rtos,
    iot: iot,
  );

  @override
  Future<WemoJoinStatus> wemoNetworkStatus({required String code}) =>
      rust.wemoNetworkStatus(code: code);

  @override
  Future<List<WemoAccessPointDto>> parseWemoApList({required String apList}) =>
      rust.parseWemoApList(apList: apList);

  @override
  Future<PlaylistWritesDto> encodeSetPlaylist({
    required String specYaml,
    required List<int> cids,
    required List<int> slots,
    required int sequence,
  }) => rust.encodeSetPlaylist(
    specYaml: specYaml,
    cids: cids,
    slots: slots,
    sequence: sequence,
  );

  @override
  Future<List<EffectEntryDto>> decodeEffectList({
    required String specYaml,
    required List<int> bytes,
  }) => rust.decodeEffectList(
    specYaml: specYaml,
    bytes: Uint8List.fromList(bytes),
  );

  @override
  Future<StoredPlayDto> encodePlaySpeed({
    required String specYaml,
    required int speed,
    required int sequence,
  }) => rust.encodePlaySpeed(
    specYaml: specYaml,
    speed: speed,
    sequence: sequence,
  );

  @override
  Future<StoredPlayDto> encodeAutorunMode({
    required String specYaml,
    required int mode,
    required int sequence,
  }) => rust.encodeAutorunMode(
    specYaml: specYaml,
    mode: mode,
    sequence: sequence,
  );

  @override
  Future<StoredPlayDto> encodeBookmarkEnable({
    required String specYaml,
    required int listId,
    required int sequence,
  }) => rust.encodeBookmarkEnable(
    specYaml: specYaml,
    listId: listId,
    sequence: sequence,
  );

  @override
  Future<StoredPlayDto> encodeBookmarkClear({
    required String specYaml,
    required int listId,
    required int sequence,
  }) => rust.encodeBookmarkClear(
    specYaml: specYaml,
    listId: listId,
    sequence: sequence,
  );

  @override
  Future<StoredPlayDto> encodeRemoveApp({
    required String specYaml,
    required int cid,
    required int sequence,
  }) => rust.encodeRemoveApp(specYaml: specYaml, cid: cid, sequence: sequence);

  @override
  Future<StoredPlayDto> encodeRemoveAllApps({
    required String specYaml,
    required int sequence,
  }) => rust.encodeRemoveAllApps(specYaml: specYaml, sequence: sequence);

  @override
  Future<Uint8List> brotherQlStatusRequest() => rust.brotherQlStatusRequest();

  @override
  Future<BrotherQlStatusDto> decodeBrotherQlStatus({
    required List<int> reply,
  }) => rust.decodeBrotherQlStatus(reply: reply);

  @override
  Future<Uint8List> renderBrotherQlTestLabel({
    required String specYaml,
    required BrotherQlJobParamsDto params,
  }) => rust.renderBrotherQlTestLabel(specYaml: specYaml, params: params);

  @override
  Future<CameraDto?> cameraForDevice({required String specYaml}) =>
      rust.cameraForDevice(specYaml: specYaml);

  @override
  Future<RasterPrintDto?> rasterPrintForSpec({required String specYaml}) =>
      print_rust.rasterPrintForSpec(specYaml: specYaml);
}

/// The catalogue, parsed once and kept in Rust.
///
/// What crosses the boundary on a load is the YAML going out (which it had to
/// anyway) and one light entry per spec coming back. What used to cross was
/// 203 full `DeviceSpecDto`s, decoded on the UI isolate as a single ~70-77 ms
/// burst timed, on a cold app, to land exactly as the first scan results
/// appeared. What used to cross on every `matchDeviceToSpec` — once per
/// connect, and again on every spec-choice change — was all 203 of them
/// again, encoded on the UI isolate: ~16-31 ms a call. Here a match sends two
/// strings and gets indices back.
class RustSpecCatalogue implements SpecCatalogue {
  final RealSpecCodec _codec;
  final handles.CatalogueHandle _handle;

  @override
  final List<CatalogueSpec> specs;

  @override
  final List<SpecLoadFailureDto> failures;

  RustSpecCatalogue._(this._codec, this._handle, this.specs, this.failures);

  /// Parse [yamls] into a Rust-side catalogue, [catalogueChunkSize] specs per
  /// event-loop turn.
  ///
  /// Chunked rather than issued as one call so neither the YAML encode on the
  /// way out nor the entry decode on the way back lands as one long
  /// synchronous block: the loader is warmed from `main()` while the first
  /// screen is building, and a burst there is a dropped frame.
  static Future<SpecCatalogue> load(
    RealSpecCodec codec,
    Map<String, String> yamls, {
    void Function(int loaded, int total)? onProgress,
    int chunkSize = catalogueChunkSize,
  }) async {
    final entries = yamls.entries.toList();
    final handles.CatalogueHandle handle;
    try {
      handle = await handles.newCatalogue();
    } catch (e) {
      // The first FFI call. A native library that failed to load throws here,
      // before any spec is parsed, and used to reject the whole load: the
      // provider went AsyncError and every screen watching it showed an
      // error the user could do nothing about. The app carries on without
      // the core instead, as main() decided it should, and the provider's
      // per-key failures still carry the one reason.
      if (!isBridgeUninitialised(e)) rethrow;
      return EmptySpecCatalogue([
        for (final key in yamls.keys)
          SpecLoadFailureDto(key: key, message: '$e'),
      ]);
    }
    final failures = <SpecLoadFailureDto>[];
    for (var start = 0; start < entries.length; start += chunkSize) {
      final chunk = entries.skip(start).take(chunkSize).toList();
      failures.addAll(
        await handle.addSpecs(
          keys: [for (final e in chunk) e.key],
          yamls: [for (final e in chunk) e.value],
        ),
      );
      onProgress?.call(start + chunk.length, entries.length);
    }
    // Keys come back exactly as they went in, so the entry order is the
    // caller's order minus whatever failed to parse — which is how the YAML
    // is rejoined to it.
    final byKey = {for (final e in entries) e.key: e.value};
    final dtos = await handle.entries();
    return RustSpecCatalogue._(codec, handle, [
      for (final dto in dtos) CatalogueSpec.fromDto(dto, byKey[dto.key] ?? ''),
    ], failures);
  }

  @override
  Future<List<UdpProbeDto>> udpBroadcastProbes() =>
      _handle.udpBroadcastProbes();

  @override
  Future<List<SpecMatch>> matchDevice({
    required String deviceName,
    required List<String> serviceUuids,
  }) async {
    final matches = await _handle.matchDevice(
      deviceName: deviceName,
      serviceUuids: serviceUuids,
    );
    return [
      for (final match in matches)
        SpecMatch(
          entry: specs[match.index],
          matchedByNamePrefix: match.matchedByNamePrefix,
          confidence: match.confidence,
          matchedServiceUuids: match.matchedServiceUuids,
        ),
    ];
  }

  @override
  Future<DeviceSpecDto> specAt(int index) async {
    // One call, two results: the DTO the screen draws, and the parse behind
    // it handed to the codec so the screen's first decodeValue (and every one
    // after it) ships a pointer instead of the spec's text.
    final spec = await _handle.specAt(index: index);
    _codec.hold(specs[index].yaml, spec);
    return spec.dto();
  }
}

/// One remembered decode, matched by the identity of what it decoded.
///
/// See [RealSpecCodec._memoisedDecode] for why identity and not equality.
class _DecodeMemo {
  final String? specYaml;
  final String? serviceUuid;
  final String charUuid;
  final List<int> bytes;
  final Future<List<DecodedValueDto>> result;

  _DecodeMemo(
    this.specYaml,
    this.serviceUuid,
    this.charUuid,
    this.bytes,
    this.result,
  );

  bool matches(
    String? specYaml,
    String? serviceUuid,
    String charUuid,
    List<int> bytes,
  ) =>
      identical(this.bytes, bytes) &&
      identical(this.specYaml, specYaml) &&
      this.serviceUuid == serviceUuid &&
      this.charUuid == charUuid;
}
