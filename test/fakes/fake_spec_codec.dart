// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:typed_data';

import 'package:opengreeniot_mobile/services/spec_codec.dart';

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

  final Object? loadError;
  final Object? encodeError;
  final Object? decodeError;

  final List<
          ({String charUuid, String commandName, Map<String, double> params})>
      encodeCalls = [];

  FakeSpecCodec({
    this.spec,
    this.matches = const [],
    Uint8List? encoded,
    this.decoded = const [],
    this.loadError,
    this.encodeError,
    this.decodeError,
  }) : encoded = encoded ?? Uint8List(0);

  @override
  Future<DeviceSpecDto> loadDeviceSpec(String yaml) async {
    if (loadError != null) throw loadError!;
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
}
