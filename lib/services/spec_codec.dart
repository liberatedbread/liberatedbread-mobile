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
        ImageWriteDto,
        ImageWritePlanDto,
        StoredUploadDto,
        StoredUploadPlanDto,
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
        SoapRequestDto,
        HttpRequestDto,
        QuerySourceDto;

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

  /// Render the argument-less request that reads a state command's values.
  Future<SoapRequestDto> renderNetworkStateRequest({
    required String specYaml,
    required String stateCommand,
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
  });

  /// Encode the BLE writes that persist a multi-frame animation on the device.
  ///
  /// [frames] are the screens in play order, each row-major RGB888
  /// `width * height * 3` bytes, ≤16 colours each.
  Future<StoredUploadPlanDto> encodeStoredAnimation({
    required String specYaml,
    required int width,
    required int height,
    required List<List<int>> frames,
    required String name,
    required int cid,
  });
}
