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
        ImageWritePlanDto,
        MatchResult,
        MatchConfidence,
        ScanMatch,
        ScannedDeviceDto,
        NetworkDeviceDto,
        SpecIdentityDto,
        ProfileInfoDto,
        ProfileCharacteristicDto;

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
}
