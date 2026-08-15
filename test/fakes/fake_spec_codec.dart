// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:convert';
import 'dart:typed_data';

import 'package:liberated_bread_mobile/services/spec_codec.dart';

/// Configurable fake [SpecCodec] for widget/unit tests. Returns hand-built DTOs
/// and canned bytes so the typed-control UI can be exercised without the native
/// Rust library, and records encode calls for assertions.
class FakeSpecCodec implements SpecCodec {
  /// Returned by [loadDeviceSpec] (yaml is ignored). If null and no [loadError]
  /// is set, [loadDeviceSpec] throws.
  final DeviceSpecDto? spec;

  /// Returned by [matchDeviceToSpec].
  final List<MatchResult> matches;

  /// Returned by [matchScannedDevice]. Either a fixed list, or a function of
  /// the observed device so one fake can answer differently per device — which
  /// is what a scan-list ordering test needs.
  final List<ScanMatch> Function(ScannedDeviceDto device)? scanMatches;

  /// Every device [matchScannedDevice] was asked about, in call order.
  final List<ScannedDeviceDto> scanMatchCalls = [];

  /// Returned by [matchNetworkDevice], as a function of the observed host.
  final List<ScanMatch> Function(NetworkDeviceDto device)? networkMatches;

  /// Every host [matchNetworkDevice] was asked about, in call order.
  final List<NetworkDeviceDto> networkMatchCalls = [];

  /// Returned by [encodeCommand].
  final Uint8List encoded;

  /// Returned by [decodeValue].
  final List<DecodedValueDto> decoded;

  /// Per-YAML spec overrides for [loadDeviceSpec], keyed by the YAML string.
  /// Lets a test bundle several distinct specs.
  final Map<String, DeviceSpecDto>? specByYaml;

  final Object? loadError;
  final Object? encodeError;
  final Object? decodeError;
  final Object? encodeImageError;
  final Object? encodeEntityValueError;

  /// Returned by [encodeEntityValue]; defaults to a write of [encoded]
  /// targeting service 'srv' / characteristic 'chr'.
  final EntityWriteDto? entityWrite;

  /// Setpoints requested through [encodeEntityValue], in DECODED units — what
  /// a card believes the user picked.
  final List<({String entityName, double value})> encodeEntityValueCalls = [];

  /// Returned by [encodeImageFrame]; defaults to a single write echoing the
  /// pixels, targeting service 'srv' / characteristic 'chr'.
  final ImageWritePlanDto? imagePlan;

  /// Returned by [encodeStoredImage]; defaults to a single uploader write plus
  /// a play write, so a widget test can drive the "Save to device" flow.
  final StoredUploadPlanDto? storedPlan;

  final Object? encodeStoredError;

  final List<
      ({
        String? serviceUuid,
        String charUuid,
        String commandName,
        Map<String, double> params,
      })> encodeCalls = [];

  final List<
      ({
        // Recorded because it is snapshotted at enqueue time alongside the
        // geometry: a send that carries one frame's dimensions and another
        // spec's YAML is the failure the snapshot exists to prevent, and it
        // is invisible unless the pairing is observable here.
        String specYaml,
        int width,
        int height,
        List<int> rgb,
        int frameIndex,
        int maxPayloadPerWrite,
      })> encodeImageCalls = [];

  /// Returned by [networkEntitiesForDevice], as a function of the SSDP
  /// targets so one fake can answer per model.
  final List<NetworkEntityDto> Function(List<String> ssdpTargets)?
      networkEntities;

  /// Returned by [renderNetworkCommand] / [renderNetworkStateRequest]; the
  /// action/soapAction carry the command or state-command name so a transport
  /// test can tell requests apart.
  SoapRequestDto Function(String name, Map<String, String> values)?
      networkRequest;

  /// Every rendered command, in call order, with the values it carried —
  /// including read-back values, which is what the Crock-Pot tests assert on.
  final List<({String commandName, Map<String, String> values})>
      renderNetworkCommandCalls = [];

  /// Returned by [renderNetworkHttpCommand]; the default renders the
  /// keypress shape (`POST /fake/<command>`) so a screen test can assert on
  /// the path without configuring anything.
  HttpRequestDto Function(String name, Map<String, String> values)?
      networkHttpRequest;

  /// Every rendered plain-HTTP command, in call order.
  final List<({String commandName, Map<String, String> values})>
      renderNetworkHttpCommandCalls = [];

  /// Returned by [listNetworkInstances]. Defaults to no children.
  final List<NetworkInstanceDto> instances;

  /// Returned by [readNetworkInstance], as a function of the instance id.
  List<NetworkRoleReadingDto> Function(String instanceId)? instanceReadings;

  /// Thrown by the http render calls when set — how a test stands in for an
  /// unpaired render (missing credential) failing visibly.
  final Object? httpRenderError;

  /// Returned by [readNetworkEntity], as a function of entity name and the
  /// returned values.
  NetworkReadingDto? Function(String entityName, Map<String, String> returned)?
      networkReading;

  /// Returned by [renderNetworkKasaCommand] / [renderNetworkKasaStateRequest];
  /// the default echoes the command name into a JSON object so a transport
  /// test can tell requests apart.
  KasaRequestDto Function(String name, Map<String, String> values)?
      networkKasaRequest;

  /// Every rendered Kasa command, in call order, with the values it carried.
  final List<({String commandName, Map<String, String> values})>
      renderNetworkKasaCommandCalls = [];

  /// Returned by [renderNetworkRabbitAirCommand] /
  /// [renderNetworkRabbitAirStateRequest]; the default builds a
  /// structurally-true envelope echoing the command name as `cmd`, so a
  /// transport test can tell requests apart and match on the request id.
  RabbitAirRequestDto Function(
          String name, Map<String, String> values, int requestId, int deviceTs)?
      networkRabbitAirRequest;

  /// Every rendered Rabbit Air command, in call order, with the values it
  /// carried.
  final List<({String commandName, Map<String, String> values})>
      renderNetworkRabbitAirCommandCalls = [];

  /// Every [encodeStoredImage] call, in order, for assertions.
  final List<
      ({
        String specYaml,
        int width,
        int height,
        List<int> rgb,
        String name,
        int cid,
        int timeSecs,
        String scroll,
        int speed,
        int sequence,
      })> encodeStoredCalls = [];

  FakeSpecCodec({
    this.spec,
    this.matches = const [],
    this.scanMatches,
    this.networkMatches,
    Uint8List? encoded,
    this.decoded = const [],
    this.specByYaml,
    this.loadError,
    this.encodeError,
    this.decodeError,
    this.encodeImageError,
    this.imagePlan,
    this.storedPlan,
    this.storedPlay,
    this.storedUploadEvents,
    this.encodeStoredError,
    this.encodeEntityValueError,
    this.entityWrite,
    this.networkEntities,
    this.networkRequest,
    this.networkHttpRequest,
    this.networkReading,
    this.instances = const [],
    this.instanceReadings,
    this.httpRenderError,
    this.networkKasaRequest,
    this.networkRabbitAirRequest,
  }) : encoded = encoded ?? Uint8List(0);

  @override
  Future<DeviceSpecDto> loadDeviceSpec(String yaml) async {
    if (loadError != null) throw loadError!;
    final mapped = specByYaml?[yaml];
    if (mapped != null) return mapped;
    final s = spec;
    if (s == null) throw StateError('FakeSpecCodec: no spec configured');
    return s;
  }

  @override
  Future<List<MatchResult>> matchDeviceToSpec({
    required List<DeviceSpecDto> specs,
    required String deviceName,
    required List<String> advertisedServiceUuids,
  }) async =>
      matches;

  @override
  Future<List<ScanMatch>> matchScannedDevice({
    required List<SpecIdentityDto> identities,
    required ScannedDeviceDto device,
  }) async {
    scanMatchCalls.add(device);
    return scanMatches?.call(device) ?? const [];
  }

  @override
  Future<List<ScanMatch>> matchNetworkDevice({
    required List<SpecIdentityDto> identities,
    required NetworkDeviceDto device,
  }) async {
    networkMatchCalls.add(device);
    return networkMatches?.call(device) ?? const [];
  }

  @override
  Future<Uint8List> encodeCommand({
    String? specYaml,
    String? serviceUuid,
    required String charUuid,
    required String commandName,
    required Map<String, double> params,
  }) async {
    encodeCalls.add((
      serviceUuid: serviceUuid,
      charUuid: charUuid,
      commandName: commandName,
      params: Map.of(params),
    ));
    if (encodeError != null) throw encodeError!;
    return encoded;
  }

  @override
  Future<List<DecodedValueDto>> decodeValue({
    String? specYaml,
    String? serviceUuid,
    required String charUuid,
    required List<int> bytes,
  }) async {
    if (decodeError != null) throw decodeError!;
    return decoded;
  }

  @override
  Future<List<ProfileInfoDto>> identifyStandardProfiles(
    List<String> serviceUuids,
  ) async =>
      const [];

  @override
  Future<EntityWriteDto> encodeEntityValue({
    required String specYaml,
    required String entityName,
    required double value,
  }) async {
    encodeEntityValueCalls.add((entityName: entityName, value: value));
    if (encodeEntityValueError != null) throw encodeEntityValueError!;
    return entityWrite ??
        EntityWriteDto(
          serviceUuid: 'srv',
          characteristicUuid: 'chr',
          bytes: encoded,
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
  }) async {
    encodeImageCalls.add((
      specYaml: specYaml,
      width: width,
      height: height,
      rgb: List.of(rgb),
      frameIndex: frameIndex,
      maxPayloadPerWrite: maxPayloadPerWrite,
    ));
    if (encodeImageError != null) throw encodeImageError!;
    return imagePlan ??
        ImageWritePlanDto(
          serviceUuid: 'srv',
          writes: [
            ImageWriteDto(
                characteristicUuid: 'chr', bytes: Uint8List.fromList(rgb)),
          ],
          // One packet consumed, like a real single-packet frame.
          nextFrameIndex: frameIndex + 1,
        );
  }

  /// The resolution [advertisedResolution] returns — a test sets it to simulate
  /// a device that advertises its panel size. Null (default) means "not
  /// advertised", the common case.
  PanelResolutionDto? advertisedResolutionResult;

  /// The manufacturer data [advertisedResolution] was last called with.
  Map<int, List<int>>? advertisedResolutionArg;

  @override
  Future<PanelResolutionDto?> advertisedResolution({
    required String specYaml,
    required Map<int, List<int>> manufacturerData,
  }) async {
    advertisedResolutionArg = manufacturerData;
    return advertisedResolutionResult;
  }

  /// The resolution [deviceInfoResolution] returns — a test sets it to simulate
  /// a device whose DeviceInfo push carried a size. Null (default) means the
  /// query found none.
  PanelResolutionDto? deviceInfoResolutionResult;

  /// How many times [deviceInfoResolution] was called (i.e. a DeviceInfo query
  /// actually ran — should stay 0 when the advertisement or cache answered).
  int deviceInfoResolutionCalls = 0;

  /// The notifications [deviceInfoResolution] was last given (so a test can
  /// check the buffered connect-time push was folded in).
  List<List<int>>? deviceInfoResolutionArg;

  @override
  Future<PanelResolutionDto?> deviceInfoResolution({
    required List<List<int>> notifications,
  }) async {
    deviceInfoResolutionCalls++;
    deviceInfoResolutionArg = notifications;
    return deviceInfoResolutionResult;
  }

  @override
  Future<List<NetworkEntityDto>> networkEntitiesForDevice({
    required String specYaml,
    required List<String> ssdpTargets,
  }) async =>
      networkEntities?.call(ssdpTargets) ?? const [];

  @override
  Future<SoapRequestDto> renderNetworkCommand({
    required String specYaml,
    required String commandName,
    required Map<String, String> values,
  }) async {
    renderNetworkCommandCalls.add((commandName: commandName, values: values));
    return networkRequest?.call(commandName, values) ??
        _defaultRequest(commandName);
  }

  @override
  Future<HttpRequestDto> renderNetworkHttpCommand({
    required String specYaml,
    required String commandName,
    required Map<String, String> values,
  }) async {
    renderNetworkHttpCommandCalls
        .add((commandName: commandName, values: values));
    if (httpRenderError != null) throw httpRenderError!;
    return networkHttpRequest?.call(commandName, values) ??
        HttpRequestDto(method: 'POST', path: '/fake/$commandName', body: '');
  }

  @override
  Future<HttpRequestDto> renderNetworkHttpStateRequest({
    required String specYaml,
    required String stateCommand,
    required Map<String, String> values,
  }) async {
    if (httpRenderError != null) throw httpRenderError!;
    return networkHttpRequest?.call(stateCommand, values) ??
        HttpRequestDto(method: 'GET', path: '/fake/$stateCommand', body: '');
  }

  @override
  Future<List<NetworkInstanceDto>> listNetworkInstances({
    required String specYaml,
    required String entityName,
    required String stateReply,
  }) async =>
      instances;

  @override
  Future<List<NetworkRoleReadingDto>> readNetworkInstance({
    required String specYaml,
    required String entityName,
    required String stateReply,
    required String instanceId,
  }) async =>
      instanceReadings?.call(instanceId) ?? const [];

  @override
  Future<SoapRequestDto> renderNetworkStateRequest({
    required String specYaml,
    required String stateCommand,
  }) async =>
      networkRequest?.call(stateCommand, const {}) ??
      _defaultRequest(stateCommand);

  static SoapRequestDto _defaultRequest(String name) => SoapRequestDto(
        service: 'urn:Fake:service:basicevent:1',
        action: name,
        soapAction: '"urn:Fake:service:basicevent:1#$name"',
        path: '/upnp/control/basicevent1',
        body: '<fake action="$name"/>',
      );

  @override
  Future<NetworkReadingDto?> readNetworkEntity({
    required String specYaml,
    required String entityName,
    required Map<String, String> returned,
  }) async =>
      networkReading?.call(entityName, returned);

  @override
  Future<KasaRequestDto> renderNetworkKasaCommand({
    required String specYaml,
    required String commandName,
    required Map<String, String> values,
  }) async {
    renderNetworkKasaCommandCalls
        .add((commandName: commandName, values: values));
    return networkKasaRequest?.call(commandName, values) ??
        KasaRequestDto(json: '{"cmd":"$commandName"}');
  }

  @override
  Future<KasaRequestDto> renderNetworkKasaStateRequest({
    required String specYaml,
    required String stateCommand,
  }) async =>
      networkKasaRequest?.call(stateCommand, const {}) ??
      KasaRequestDto(json: '{"cmd":"$stateCommand"}');

  // The XOR-autokey cipher, implemented here so the fake round-trips exactly
  // as the Rust codec does — a KasaControlClient test can drive a full
  // encode → exchange → decode cycle with no native library.
  static List<int> _kasaEncrypt(List<int> plain) {
    var key = 0xAB;
    return [for (final b in plain) key ^= b];
  }

  static List<int> _kasaDecrypt(List<int> cipher) {
    var key = 0xAB;
    final out = <int>[];
    for (final b in cipher) {
      out.add(key ^ b);
      key = b;
    }
    return out;
  }

  @override
  Future<List<int>> kasaEncodeFrame({required String json}) async {
    final body = _kasaEncrypt(utf8.encode(json));
    final len = body.length;
    return [
      (len >> 24) & 0xFF,
      (len >> 16) & 0xFF,
      (len >> 8) & 0xFF,
      len & 0xFF,
      ...body,
    ];
  }

  @override
  Future<String> kasaDecodeFrame({required List<int> frame}) async {
    if (frame.length < 4) throw const FormatException('short Kasa frame');
    final len =
        (frame[0] << 24) | (frame[1] << 16) | (frame[2] << 8) | frame[3];
    return utf8.decode(_kasaDecrypt(frame.sublist(4, 4 + len)));
  }

  @override
  Future<List<int>> kasaEncryptDatagram({required String json}) async =>
      _kasaEncrypt(utf8.encode(json));

  @override
  Future<String> kasaDecodeDatagram({required List<int> datagram}) async =>
      utf8.decode(_kasaDecrypt(datagram));

  /// The Tuya broadcast this fake will return for any datagram, or null (the
  /// default) to model "not a Tuya frame". Tests set it to drive the transport
  /// without a live device.
  TuyaBroadcastDto? tuyaBroadcast;

  @override
  Future<TuyaBroadcastDto?> tuyaParseBroadcast(
          {required List<int> datagram}) async =>
      tuyaBroadcast;

  // ── Rabbit Air ────────────────────────────────────────────────────────────
  // The fake's stand-in for the AES-128-CBC datagram crypto, round-tripping
  // exactly as the Rust codec does so a RabbitAirControlClient test can drive
  // a full encrypt → exchange → decrypt cycle with no native library. The key
  // is bound INTO the fake ciphertext, so decrypting under a different key
  // fails — the fake's answer to the real cipher's bad-padding rejection.

  @override
  Future<RabbitAirRequestDto> renderNetworkRabbitAirCommand({
    required String specYaml,
    required String commandName,
    required Map<String, String> values,
    required int requestId,
    required int deviceTs,
  }) async {
    renderNetworkRabbitAirCommandCalls
        .add((commandName: commandName, values: values));
    return networkRabbitAirRequest?.call(
            commandName, values, requestId, deviceTs) ??
        RabbitAirRequestDto(
            json: '{"id":$requestId,"cmd":"$commandName","ts":$deviceTs}',
            requestId: requestId);
  }

  @override
  Future<RabbitAirRequestDto> renderNetworkRabbitAirStateRequest({
    required String specYaml,
    required String stateCommand,
    required int requestId,
    required int deviceTs,
  }) async =>
      networkRabbitAirRequest?.call(
          stateCommand, const {}, requestId, deviceTs) ??
      RabbitAirRequestDto(
          json: '{"id":$requestId,"cmd":"$stateCommand","ts":$deviceTs}',
          requestId: requestId);

  @override
  Future<int> rabbitAirPort() async => 9009;

  @override
  Future<List<int>> rabbitAirEncryptDatagram({
    required String userKey,
    required String plaintext,
  }) async {
    if (!RegExp(r'^[0-9a-fA-F]{32}$').hasMatch(userKey)) {
      throw const FormatException('the user key is 32 hex characters');
    }
    return [...utf8.encode('$userKey\n$plaintext'), ...List.filled(16, 0xAB)];
  }

  @override
  Future<String> rabbitAirDecryptDatagram({
    required String userKey,
    required List<int> datagram,
  }) async {
    if (datagram.length < 17) {
      throw const FormatException('short Rabbit Air datagram');
    }
    final body = utf8.decode(datagram.sublist(0, datagram.length - 16));
    final split = body.indexOf('\n');
    if (split < 0 || body.substring(0, split) != userKey) {
      throw const FormatException('does not decrypt under this user key');
    }
    return body.substring(split + 1);
  }

  @override
  Future<int> rabbitAirTimeSyncOffset({
    required String replyJson,
    required int localNowSecs,
  }) async {
    final decoded = jsonDecode(replyJson);
    if (decoded is! Map ||
        decoded['error'] != null && decoded['error'] != false) {
      throw const FormatException('time-sync reply carries an error');
    }
    final data = decoded['data'];
    final ts = data is Map ? data['ts'] : null;
    if (ts is! int) throw const FormatException('no data.ts');
    return ts - localNowSecs;
  }

  // ── Rabbit Air BLE framing ────────────────────────────────────────────────
  // The pure byte functions re-implemented honestly — framing is cheap enough
  // that mimicking the Rust codec exactly beats a canned answer a test could
  // drift away from.

  @override
  Future<List<List<int>>> rabbitAirBleFrame({
    required List<int> payload,
    required int chunkSize,
  }) async {
    if (chunkSize < 3) {
      throw const FormatException(
          'a chunk must carry the 2-byte length prefix plus 1 payload byte');
    }
    if (payload.length > 0xFFFF) {
      throw const FormatException('the payload must fit the u16 prefix');
    }
    final framed = [
      payload.length & 0xFF,
      (payload.length >> 8) & 0xFF,
      ...payload,
    ];
    return [
      for (var i = 0; i < framed.length; i += chunkSize)
        framed.sublist(
            i, i + chunkSize > framed.length ? framed.length : i + chunkSize),
    ];
  }

  @override
  Future<int?> rabbitAirBleExpectedPayloadLen({
    required List<int> firstChunk,
  }) async =>
      firstChunk.length < 2 ? null : firstChunk[0] | (firstChunk[1] << 8);

  @override
  Future<String> renderRabbitAirSetupEnvelope({
    required int id,
    required int cmd,
    String? dataJson,
  }) async {
    var data = '';
    if (dataJson != null) {
      final decoded = jsonDecode(dataJson);
      if (decoded is! Map) {
        throw const FormatException('setup data must be a JSON object');
      }
      data = ',"data":${jsonEncode(decoded)}';
    }
    return '{"id":$id,"cmd":$cmd$data}';
  }

  @override
  Future<String> rabbitAirGenerateUserKey() async =>
      '0123456789ABCDEF0123456789ABCDEF';

  @override
  Future<String> rabbitAirBleServiceUuid() async =>
      '366048ae-9f36-43cf-8004-010c0c9fa52e';

  @override
  Future<String> rabbitAirBleCommandCharacteristicUuid() async =>
      '53ef7d7d-c244-42bd-9064-a1569a521ca9';

  @override
  Future<int> rabbitAirBleMtu() async => 515;

  @override
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
    required int sequence,
  }) async {
    encodeStoredCalls.add((
      specYaml: specYaml,
      width: width,
      height: height,
      rgb: List.of(rgb),
      name: name,
      cid: cid,
      timeSecs: timeSecs,
      scroll: scroll,
      speed: speed,
      sequence: sequence,
    ));
    if (encodeStoredError != null) throw encodeStoredError!;
    return storedPlan ?? _defaultStoredPlan(cid, rgb);
  }

  /// Every [encodeStoredText] call, in order.
  final List<
      ({
        String name,
        int cid,
        int textWidth,
        int textHeight,
        String scroll,
        int sequence,
      })> encodeTextCalls = [];

  /// Every [encodeStoredAnimation] call, in order.
  final List<
      ({
        String name,
        int cid,
        int width,
        int height,
        int frameCount,
        int frameMs,
        int sequence,
      })> encodeAnimationCalls = [];

  @override
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
  }) async {
    encodeTextCalls.add((
      name: name,
      cid: cid,
      textWidth: textWidth,
      textHeight: textHeight,
      scroll: scroll,
      sequence: sequence,
    ));
    if (encodeStoredError != null) throw encodeStoredError!;
    return storedPlan ?? _defaultStoredPlan(cid, bits);
  }

  @override
  Future<StoredUploadPlanDto> encodeStoredAnimation({
    required String specYaml,
    required int width,
    required int height,
    required List<List<int>> frames,
    required String name,
    required int cid,
    required int frameMs,
    required int sequence,
  }) async {
    encodeAnimationCalls.add((
      name: name,
      cid: cid,
      width: width,
      height: height,
      frameCount: frames.length,
      frameMs: frameMs,
      sequence: sequence,
    ));
    if (encodeStoredError != null) throw encodeStoredError!;
    return storedPlan ?? _defaultStoredPlan(cid, const [7]);
  }

  /// Maps a raw response-characteristic notification to an upload event; a
  /// test that exercises the wait-for-commit path supplies this. Defaults to
  /// "every notification is the completion", so a test only has to emit one
  /// byte on the notify stream.
  StoredUploadEventDto? Function(List<int> bytes)? storedUploadEvents;

  /// Every notification [decodeStoredUploadEvent] was asked about.
  final List<List<int>> decodeUploadEventCalls = [];

  @override
  Future<StoredUploadEventDto?> decodeStoredUploadEvent({
    required String specYaml,
    required List<int> bytes,
  }) async {
    decodeUploadEventCalls.add(List.of(bytes));
    final map = storedUploadEvents;
    if (map != null) return map(bytes);
    return StoredUploadEventDto(
      kind: StoredUploadEventKind.complete,
      code: BigInt.zero,
      resumeOffset: BigInt.zero,
      progress: BigInt.zero,
    );
  }

  /// Returned by [encodeStoredPlay]; defaults to a single framed write on the
  /// command channel, mirroring [_defaultStoredPlan]'s play write.
  final StoredPlayDto? storedPlay;

  /// Every ([cid], [sequence]) [encodeStoredPlay] was asked to replay, in order.
  final List<({int cid, int sequence})> encodeStoredPlayCalls = [];

  @override
  Future<StoredPlayDto> encodeStoredPlay({
    required String specYaml,
    required int cid,
    required int sequence,
  }) async {
    encodeStoredPlayCalls.add((cid: cid, sequence: sequence));
    if (encodeStoredError != null) throw encodeStoredError!;
    return storedPlay ??
        StoredPlayDto(
          serviceUuid: 'srv',
          write: ImageWriteDto(
              characteristicUuid: 'ddp', bytes: Uint8List.fromList(const [2])),
        );
  }

  // ── LIFX (binary UDP) ───────────────────────────────────────────────────

  /// Bytes returned by every LIFX builder/render method. A test that only
  /// checks a send happened does not need to configure this.
  Uint8List lifxBytes = Uint8List.fromList(const [1, 2, 3]);

  /// Returned by [decodeLifxState]; defaults to a powered-off warm white.
  LifxStateDto? lifxState;

  /// Returned by [decodeLifxZones]; defaults to no zones.
  LifxZonesDto? lifxZones;

  /// Returned by [parseLifxStateService].
  LifxServiceDto? lifxService;

  /// Every [renderLifxCommand] call, in order, with the params it carried.
  final List<
      ({
        String action,
        Map<String, double> params,
        String targetMac,
        int sequence
      })> renderLifxCalls = [];

  @override
  Future<int> lifxPort() async => 56700;

  @override
  Future<Uint8List> renderLifxCommand({
    required String action,
    required Map<String, double> params,
    required String targetMac,
    required int sequence,
  }) async {
    renderLifxCalls.add((
      action: action,
      params: Map.of(params),
      targetMac: targetMac,
      sequence: sequence,
    ));
    return lifxBytes;
  }

  @override
  Future<Uint8List> buildLifxDiscoveryProbe({required int sequence}) async =>
      lifxBytes;

  @override
  Future<Uint8List> buildLifxStateRequest({
    required String targetMac,
    required int sequence,
  }) async =>
      lifxBytes;

  @override
  Future<Uint8List> buildLifxZonesRequest({
    required String targetMac,
    required int start,
    required int end,
    required int sequence,
  }) async =>
      lifxBytes;

  @override
  Future<LifxServiceDto> parseLifxStateService({
    required List<int> bytes,
  }) async =>
      lifxService ??
      const LifxServiceDto(mac: 'd0:73:d5:aa:bb:cc', service: 1, port: 56700);

  @override
  Future<LifxStateDto> decodeLifxState({required List<int> bytes}) async =>
      lifxState ??
      const LifxStateDto(
        powerOn: false,
        red: 255,
        green: 255,
        blue: 255,
        brightness: 255,
        hue: 0,
        saturation: 0,
        kelvin: 3500,
        label: 'LIFX Z',
      );

  @override
  Future<LifxZonesDto> decodeLifxZones({required List<int> bytes}) async =>
      lifxZones ?? const LifxZonesDto(zonesCount: 0, zoneIndex: 0, colors: []);

  /// Returned by [decodeLifxAccessPoint].
  LifxAccessPointDto? lifxAccessPoint;

  /// Every [renderLifxSetAccessPoint] call, in order — so a provisioning test
  /// can assert the SSID/password/security handed over, without a real strip.
  final List<({String ssid, String password, int security, int sequence})>
      setAccessPointCalls = [];

  @override
  Future<int> lifxDefaultSecurity() async => 5;

  @override
  Future<Uint8List> buildLifxGetAccessPoints({required int sequence}) async =>
      lifxBytes;

  @override
  Future<Uint8List> renderLifxSetAccessPoint({
    required String ssid,
    required String password,
    required int security,
    required int sequence,
  }) async {
    setAccessPointCalls.add((
      ssid: ssid,
      password: password,
      security: security,
      sequence: sequence,
    ));
    return lifxBytes;
  }

  @override
  Future<LifxAccessPointDto> decodeLifxAccessPoint({
    required List<int> bytes,
  }) async =>
      lifxAccessPoint ??
      const LifxAccessPointDto(
        ssid: 'HomeNet',
        security: 5,
        isOpen: false,
        strength: -40,
        channel: 11,
      );

  /// Returned by [softApProfiles].
  List<SoftApProfileDto> softApProfilesResult = const [];

  /// Returned by [setupInstructions]. Either a fixed value, or a function of the
  /// YAML asked about so one fake can answer differently per spec. Null (the
  /// default function result) means "this spec has no instructions".
  SetupInstructionsDto? Function(String specYaml)? setupInstructionsFor;

  /// Every YAML [setupInstructions] was asked about, in call order.
  final List<String> setupInstructionsCalls = [];

  /// Returned by [matchSoftApSsid].
  int? Function(String ssid)? matchSoftApSsidFor;

  /// Returned by [renderWemoConnectRequests]; if [wemoConnectError] is set, the
  /// call throws it instead (the short-passphrase path).
  List<SoapRequestDto> wemoConnectRequests = const [
    SoapRequestDto(
      service: 'urn:Belkin:service:WiFiSetup:1',
      action: 'ConnectHomeNetwork',
      soapAction: '"urn:Belkin:service:WiFiSetup:1#ConnectHomeNetwork"',
      path: '/upnp/control/WiFiSetup1',
      body: '<connect/>',
    ),
  ];
  Object? wemoConnectError;

  /// The (rtos, iot) the last [renderWemoConnectRequests] was called with, so a
  /// test can assert the setup.xml selectors are threaded through.
  (int?, int?)? lastWemoConnectSelectors;

  /// Returned by [wemoNetworkStatus].
  WemoJoinStatus wemoStatus = WemoJoinStatus.connected;

  /// Returned by [parseWemoApList].
  List<WemoAccessPointDto> wemoApList = const [];

  @override
  Future<List<SoftApProfileDto>> softApProfiles(List<String> specYamls) async =>
      softApProfilesResult;

  @override
  Future<SetupInstructionsDto?> setupInstructions(String specYaml) async {
    setupInstructionsCalls.add(specYaml);
    return setupInstructionsFor?.call(specYaml);
  }

  @override
  Future<int?> matchSoftApSsid({
    required List<SoftApProfileDto> profiles,
    required String ssid,
  }) async =>
      matchSoftApSsidFor?.call(ssid);

  @override
  Future<List<SoapRequestDto>> renderWemoConnectRequests({
    required String specYaml,
    required String metaInfo,
    required String ssid,
    required String auth,
    required String encrypt,
    required String channel,
    required String passphrase,
    int? rtos,
    int? iot,
  }) async {
    lastWemoConnectSelectors = (rtos, iot);
    if (wemoConnectError != null) throw wemoConnectError!;
    return wemoConnectRequests;
  }

  @override
  Future<WemoJoinStatus> wemoNetworkStatus({required String code}) async =>
      wemoStatus;

  @override
  Future<List<WemoAccessPointDto>> parseWemoApList({
    required String apList,
  }) async =>
      wemoApList;

  /// Every [encodeSetPlaylist] call's cids, in order.
  final List<List<int>> encodeSetPlaylistCalls = [];

  @override
  Future<PlaylistWritesDto> encodeSetPlaylist({
    required String specYaml,
    required List<int> cids,
    required List<int> slots,
    required int sequence,
  }) async {
    encodeSetPlaylistCalls.add(List.of(cids));
    if (encodeStoredError != null) throw encodeStoredError!;
    return PlaylistWritesDto(
      serviceUuid: 'srv',
      writes: [
        ImageWriteDto(
            characteristicUuid: 'ddp', bytes: Uint8List.fromList(const [4])),
        ImageWriteDto(
            characteristicUuid: 'ddp', bytes: Uint8List.fromList(const [5])),
      ],
    );
  }

  /// Entries [decodeEffectList] returns, keyed by nothing — a test sets this.
  List<EffectEntryDto> effectListEntries = const [];

  @override
  Future<List<EffectEntryDto>> decodeEffectList({
    required String specYaml,
    required List<int> bytes,
  }) async =>
      effectListEntries;

  /// Every play-speed value [encodePlaySpeed] was asked to set, in order.
  final List<int> encodePlaySpeedCalls = [];

  @override
  Future<StoredPlayDto> encodePlaySpeed({
    required String specYaml,
    required int speed,
    required int sequence,
  }) async {
    encodePlaySpeedCalls.add(speed);
    return _framedStub();
  }

  /// Every autorun mode [encodeAutorunMode] was asked to set, in order.
  final List<int> encodeAutorunModeCalls = [];

  @override
  Future<StoredPlayDto> encodeAutorunMode({
    required String specYaml,
    required int mode,
    required int sequence,
  }) async {
    encodeAutorunModeCalls.add(mode);
    return _framedStub();
  }

  /// Every cid [encodeRemoveApp] was asked to delete, in order.
  final List<int> encodeRemoveAppCalls = [];

  @override
  Future<StoredPlayDto> encodeRemoveApp({
    required String specYaml,
    required int cid,
    required int sequence,
  }) async {
    encodeRemoveAppCalls.add(cid);
    return _framedStub();
  }

  /// Every [encodeBookmarkEnable] call's listId, in order.
  final List<int> encodeBookmarkEnableCalls = [];

  @override
  Future<StoredPlayDto> encodeBookmarkEnable({
    required String specYaml,
    required int listId,
    required int sequence,
  }) async {
    encodeBookmarkEnableCalls.add(listId);
    return _framedStub();
  }

  /// Every [encodeBookmarkClear] call's listId, in order.
  final List<int> encodeBookmarkClearCalls = [];

  @override
  Future<StoredPlayDto> encodeBookmarkClear({
    required String specYaml,
    required int listId,
    required int sequence,
  }) async {
    encodeBookmarkClearCalls.add(listId);
    return _framedStub();
  }

  /// How many times [encodeRemoveAllApps] was called.
  int encodeRemoveAllAppsCalls = 0;

  @override
  Future<StoredPlayDto> encodeRemoveAllApps({
    required String specYaml,
    required int sequence,
  }) async {
    encodeRemoveAllAppsCalls++;
    return _framedStub();
  }

  StoredPlayDto _framedStub() => StoredPlayDto(
        serviceUuid: 'srv',
        write: ImageWriteDto(
            characteristicUuid: 'ddp', bytes: Uint8List.fromList(const [9])),
      );

  /// When set, [_defaultStoredPlan] carries this as its response characteristic
  /// so the widget can subscribe to the notify channel (needed to exercise the
  /// DeviceInfo-query path). Null keeps the default no-notify behaviour so
  /// existing tests are unaffected.
  String? storedResponseChar;

  StoredUploadPlanDto _defaultStoredPlan(int cid, List<int> body) =>
      StoredUploadPlanDto(
        serviceUuid: 'srv',
        uploadWrites: [
          ImageWriteDto(
              characteristicUuid: 'uploader', bytes: Uint8List.fromList(body)),
        ],
        playWrite: ImageWriteDto(
            characteristicUuid: 'ddp', bytes: Uint8List.fromList(const [1])),
        responseCharacteristicUuid: storedResponseChar,
        cid: cid,
      );
}
