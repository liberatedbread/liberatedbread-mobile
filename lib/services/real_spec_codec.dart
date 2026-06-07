// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:typed_data';

import '../src/rust/api/device_api.dart' as rust;
import 'spec_codec.dart';

/// Production [SpecCodec] backed by the Rust core via flutter_rust_bridge.
///
/// Every method is a thin pass-through to the generated FFI function so the
/// behavior is identical to calling the bindings directly — the indirection
/// exists only so the UI can be tested against a fake.
class RealSpecCodec implements SpecCodec {
  const RealSpecCodec();

  @override
  Future<DeviceSpecDto> loadDeviceSpec(String yaml) =>
      rust.loadDeviceSpec(yaml: yaml);

  @override
  Future<List<MatchResult>> matchDeviceToSpec({
    required List<DeviceSpecDto> specs,
    required String deviceName,
    required List<String> advertisedServiceUuids,
  }) =>
      rust.matchDeviceToSpec(
        specs: specs,
        deviceName: deviceName,
        advertisedServiceUuids: advertisedServiceUuids,
      );

  @override
  Future<Uint8List> encodeCommand({
    String? specYaml,
    String? serviceUuid,
    required String charUuid,
    required String commandName,
    required Map<String, double> params,
  }) =>
      rust.encodeCommand(
        specYaml: specYaml,
        serviceUuid: serviceUuid,
        charUuid: charUuid,
        commandName: commandName,
        params: params,
      );

  @override
  Future<List<DecodedValueDto>> decodeValue({
    String? specYaml,
    String? serviceUuid,
    required String charUuid,
    required List<int> bytes,
  }) =>
      rust.decodeValue(
        specYaml: specYaml,
        serviceUuid: serviceUuid,
        charUuid: charUuid,
        bytes: bytes,
      );

  @override
  Future<List<ProfileInfoDto>> identifyStandardProfiles(
    List<String> serviceUuids,
  ) =>
      rust.identifyStandardProfiles(serviceUuids: serviceUuids);
}
