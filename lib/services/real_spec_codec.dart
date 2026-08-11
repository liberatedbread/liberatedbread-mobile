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
  Future<List<ScanMatch>> matchScannedDevice({
    required List<SpecIdentityDto> identities,
    required ScannedDeviceDto device,
  }) =>
      rust.matchScannedDevice(identities: identities, device: device);

  @override
  Future<List<ScanMatch>> matchNetworkDevice({
    required List<SpecIdentityDto> identities,
    required NetworkDeviceDto device,
  }) =>
      rust.matchNetworkDevice(identities: identities, device: device);

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

  @override
  Future<EntityWriteDto> encodeEntityValue({
    required String specYaml,
    required String entityName,
    required double value,
  }) =>
      rust.encodeEntityValue(
        specYaml: specYaml,
        entityName: entityName,
        value: value,
      );

  @override
  Future<ImageWritePlanDto> encodeImageFrame({
    required String specYaml,
    required int width,
    required int height,
    required List<int> rgb,
    required int frameIndex,
    required int maxPayloadPerWrite,
  }) =>
      rust.encodeImageFrame(
        specYaml: specYaml,
        width: width,
        height: height,
        rgb: rgb,
        frameIndex: frameIndex,
        maxPayloadPerWrite: maxPayloadPerWrite,
      );

  @override
  Future<List<NetworkEntityDto>> networkEntitiesForDevice({
    required String specYaml,
    required List<String> ssdpTargets,
  }) =>
      rust.networkEntitiesForDevice(
          specYaml: specYaml, ssdpTargets: ssdpTargets);

  @override
  Future<SoapRequestDto> renderNetworkCommand({
    required String specYaml,
    required String commandName,
    required Map<String, String> values,
  }) =>
      rust.renderNetworkCommand(
        specYaml: specYaml,
        commandName: commandName,
        values: values,
      );

  @override
  Future<HttpRequestDto> renderNetworkHttpCommand({
    required String specYaml,
    required String commandName,
    required Map<String, String> values,
  }) =>
      rust.renderNetworkHttpCommand(
        specYaml: specYaml,
        commandName: commandName,
        values: values,
      );

  @override
  Future<HttpRequestDto> renderNetworkHttpStateRequest({
    required String specYaml,
    required String stateCommand,
    required Map<String, String> values,
  }) =>
      rust.renderNetworkHttpStateRequest(
        specYaml: specYaml,
        stateCommand: stateCommand,
        values: values,
      );

  @override
  Future<List<NetworkInstanceDto>> listNetworkInstances({
    required String specYaml,
    required String entityName,
    required String stateReply,
  }) =>
      rust.listNetworkInstances(
        specYaml: specYaml,
        entityName: entityName,
        stateReply: stateReply,
      );

  @override
  Future<List<NetworkRoleReadingDto>> readNetworkInstance({
    required String specYaml,
    required String entityName,
    required String stateReply,
    required String instanceId,
  }) =>
      rust.readNetworkInstance(
        specYaml: specYaml,
        entityName: entityName,
        stateReply: stateReply,
        instanceId: instanceId,
      );

  @override
  Future<SoapRequestDto> renderNetworkStateRequest({
    required String specYaml,
    required String stateCommand,
  }) =>
      rust.renderNetworkStateRequest(
          specYaml: specYaml, stateCommand: stateCommand);

  @override
  Future<NetworkReadingDto?> readNetworkEntity({
    required String specYaml,
    required String entityName,
    required Map<String, String> returned,
  }) =>
      rust.readNetworkEntity(
        specYaml: specYaml,
        entityName: entityName,
        returned: returned,
      );

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
  }) =>
      rust.encodeStoredImage(
        specYaml: specYaml,
        width: width,
        height: height,
        rgb: rgb,
        name: name,
        cid: cid,
        timeSecs: timeSecs,
        scroll: scroll,
        speed: speed,
      );

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
  }) =>
      rust.encodeStoredText(
        specYaml: specYaml,
        textWidth: textWidth,
        textHeight: textHeight,
        bits: bits,
        name: name,
        cid: cid,
        timeSecs: timeSecs,
        scroll: scroll,
        speed: speed,
      );

  @override
  Future<StoredUploadPlanDto> encodeStoredAnimation({
    required String specYaml,
    required int width,
    required int height,
    required List<List<int>> frames,
    required String name,
    required int cid,
    required int frameMs,
  }) =>
      rust.encodeStoredAnimation(
        specYaml: specYaml,
        width: width,
        height: height,
        frames: frames.map(Uint8List.fromList).toList(),
        name: name,
        cid: cid,
        frameMs: frameMs,
      );

  @override
  Future<StoredUploadEventDto?> decodeStoredUploadEvent({
    required String specYaml,
    required List<int> bytes,
  }) =>
      rust.decodeStoredUploadEvent(
        specYaml: specYaml,
        bytes: Uint8List.fromList(bytes),
      );

  @override
  Future<StoredPlayDto> encodeStoredPlay({
    required String specYaml,
    required int cid,
  }) =>
      rust.encodeStoredPlay(specYaml: specYaml, cid: cid);

  @override
  Future<int> lifxPort() => rust.lifxPort();

  @override
  Future<Uint8List> renderLifxCommand({
    required String action,
    required Map<String, double> params,
    required String targetMac,
    required int sequence,
  }) =>
      rust.renderLifxCommand(
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
  }) =>
      rust.buildLifxStateRequest(targetMac: targetMac, sequence: sequence);

  @override
  Future<Uint8List> buildLifxZonesRequest({
    required String targetMac,
    required int start,
    required int end,
    required int sequence,
  }) =>
      rust.buildLifxZonesRequest(
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
}
