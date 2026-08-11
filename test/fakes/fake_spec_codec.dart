// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
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
          ({String charUuid, String commandName, Map<String, double> params})>
      encodeCalls = [];

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

  /// Returned by [readNetworkEntity], as a function of entity name and the
  /// returned values.
  NetworkReadingDto? Function(String entityName, Map<String, String> returned)?
      networkReading;

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
    this.encodeStoredError,
    this.encodeEntityValueError,
    this.entityWrite,
    this.networkEntities,
    this.networkRequest,
    this.networkHttpRequest,
    this.networkReading,
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
    return networkHttpRequest?.call(commandName, values) ??
        HttpRequestDto(method: 'POST', path: '/fake/$commandName', body: '');
  }

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
    ));
    if (encodeStoredError != null) throw encodeStoredError!;
    return storedPlan ??
        StoredUploadPlanDto(
          serviceUuid: 'srv',
          uploadWrites: [
            ImageWriteDto(
                characteristicUuid: 'uploader', bytes: Uint8List.fromList(rgb)),
          ],
          playWrite: ImageWriteDto(
              characteristicUuid: 'ddp', bytes: Uint8List.fromList(const [1])),
          cid: cid,
        );
  }
}
