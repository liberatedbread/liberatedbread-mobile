// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:typed_data';

import '../src/rust/api/device_api.dart';

// Re-export the flutter_rust_bridge DTOs so widgets and tests depend on this
// abstraction instead of importing the generated bindings directly. The DTOs
// are plain value types (const constructors, value equality), so a fake codec
// can build them by hand in tests without the native library.
export '../src/rust/api/device_api.dart'
    show
        DeviceSpecDto,
        ServiceDto,
        CharacteristicDto,
        CommandDto,
        ParameterDto,
        FormatFieldDto,
        DecodedValueDto,
        MatchResult,
        ProfileInfoDto,
        ProfileCharacteristicDto;

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

  /// Find every spec matching a scanned device, with the reasons it matched.
  Future<List<MatchResult>> matchDeviceToSpec({
    required List<DeviceSpecDto> specs,
    required String deviceName,
    required List<String> advertisedServiceUuids,
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
}
