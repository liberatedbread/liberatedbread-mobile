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

  /// Returned by [encodeImageFrame]; defaults to a single write echoing the
  /// pixels, targeting service 'srv' / characteristic 'chr'.
  final ImageWritePlanDto? imagePlan;

  final List<
          ({String charUuid, String commandName, Map<String, double> params})>
      encodeCalls = [];

  final List<
      ({
        int width,
        int height,
        List<int> rgb,
        int frameIndex,
        int maxPayloadPerWrite,
      })> encodeImageCalls = [];

  FakeSpecCodec({
    this.spec,
    this.matches = const [],
    Uint8List? encoded,
    this.decoded = const [],
    this.specByYaml,
    this.loadError,
    this.encodeError,
    this.decodeError,
    this.encodeImageError,
    this.imagePlan,
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
  Future<ImageWritePlanDto> encodeImageFrame({
    required String specYaml,
    required int width,
    required int height,
    required List<int> rgb,
    required int frameIndex,
    required int maxPayloadPerWrite,
  }) async {
    encodeImageCalls.add((
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
          characteristicUuid: 'chr',
          writes: [Uint8List.fromList(rgb)],
          // One packet consumed, like a real single-packet frame.
          nextFrameIndex: frameIndex + 1,
        );
  }
}
