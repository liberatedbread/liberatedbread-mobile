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
  Future<PanelResolutionDto?> advertisedResolution({
    required String specYaml,
    required Map<int, List<int>> manufacturerData,
  }) =>
      rust.advertisedResolution(
        specYaml: specYaml,
        manufacturerData: [
          for (final e in manufacturerData.entries)
            (e.key, Uint8List.fromList(e.value)),
        ],
      );

  @override
  Future<PanelResolutionDto?> deviceInfoResolution({
    required List<List<int>> notifications,
  }) =>
      rust.deviceInfoResolution(
        notifications: [
          for (final n in notifications) Uint8List.fromList(n),
        ],
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
  Future<KasaRequestDto> renderNetworkKasaCommand({
    required String specYaml,
    required String commandName,
    required Map<String, String> values,
  }) =>
      rust.renderNetworkKasaCommand(
        specYaml: specYaml,
        commandName: commandName,
        values: values,
      );

  @override
  Future<KasaRequestDto> renderNetworkKasaStateRequest({
    required String specYaml,
    required String stateCommand,
  }) =>
      rust.renderNetworkKasaStateRequest(
          specYaml: specYaml, stateCommand: stateCommand);

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
  Future<RabbitAirRequestDto> renderNetworkRabbitAirCommand({
    required String specYaml,
    required String commandName,
    required Map<String, String> values,
    required int requestId,
    required int deviceTs,
  }) =>
      rust.renderNetworkRabbitAirCommand(
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
  }) =>
      rust.renderNetworkRabbitAirStateRequest(
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
  }) =>
      rust.rabbitAirEncryptDatagram(userKey: userKey, plaintext: plaintext);

  @override
  Future<String> rabbitAirDecryptDatagram({
    required String userKey,
    required List<int> datagram,
  }) =>
      rust.rabbitAirDecryptDatagram(userKey: userKey, datagram: datagram);

  @override
  Future<int> rabbitAirTimeSyncOffset({
    required String replyJson,
    required int localNowSecs,
  }) =>
      rust.rabbitAirTimeSyncOffset(
          replyJson: replyJson, localNowSecs: localNowSecs);

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
    required int sequence,
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
        sequence: sequence,
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
    required int sequence,
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
        sequence: sequence,
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
    required int sequence,
  }) =>
      rust.encodeStoredAnimation(
        specYaml: specYaml,
        width: width,
        height: height,
        frames: frames.map(Uint8List.fromList).toList(),
        name: name,
        cid: cid,
        frameMs: frameMs,
        sequence: sequence,
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
    required int sequence,
  }) =>
      rust.encodeStoredPlay(specYaml: specYaml, cid: cid, sequence: sequence);

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
  }) =>
      rust.renderLifxSetAccessPoint(
        ssid: ssid,
        password: password,
        security: security,
        sequence: sequence,
      );

  @override
  Future<LifxAccessPointDto> decodeLifxAccessPoint(
          {required List<int> bytes}) =>
      rust.decodeLifxAccessPoint(bytes: bytes);

  @override
  Future<List<SoftApProfileDto>> softApProfiles(List<String> specYamls) =>
      rust.softApProfiles(specYamls: specYamls);

  @override
  Future<int?> matchSoftApSsid({
    required List<SoftApProfileDto> profiles,
    required String ssid,
  }) =>
      rust.matchSoftApSsid(profiles: profiles, ssid: ssid);

  @override
  Future<List<WemoPasswordCandidateDto>> wemoPasswordCandidates({
    required String metaInfo,
    required String passphrase,
    int? rtos,
    int? iot,
  }) =>
      rust.wemoPasswordCandidates(
        metaInfo: metaInfo,
        passphrase: passphrase,
        rtos: rtos,
        iot: iot,
      );

  @override
  Future<List<WemoAccessPointDto>> parseWemoApList({required String apList}) =>
      rust.parseWemoApList(apList: apList);

  @override
  Future<PlaylistWritesDto> encodeSetPlaylist({
    required String specYaml,
    required List<int> cids,
    required List<int> slots,
    required int sequence,
  }) =>
      rust.encodeSetPlaylist(
        specYaml: specYaml,
        cids: cids,
        slots: slots,
        sequence: sequence,
      );

  @override
  Future<List<EffectEntryDto>> decodeEffectList({
    required String specYaml,
    required List<int> bytes,
  }) =>
      rust.decodeEffectList(
        specYaml: specYaml,
        bytes: Uint8List.fromList(bytes),
      );

  @override
  Future<StoredPlayDto> encodePlaySpeed({
    required String specYaml,
    required int speed,
    required int sequence,
  }) =>
      rust.encodePlaySpeed(
          specYaml: specYaml, speed: speed, sequence: sequence);

  @override
  Future<StoredPlayDto> encodeAutorunMode({
    required String specYaml,
    required int mode,
    required int sequence,
  }) =>
      rust.encodeAutorunMode(
          specYaml: specYaml, mode: mode, sequence: sequence);

  @override
  Future<StoredPlayDto> encodeBookmarkEnable({
    required String specYaml,
    required int listId,
    required int sequence,
  }) =>
      rust.encodeBookmarkEnable(
          specYaml: specYaml, listId: listId, sequence: sequence);

  @override
  Future<StoredPlayDto> encodeBookmarkClear({
    required String specYaml,
    required int listId,
    required int sequence,
  }) =>
      rust.encodeBookmarkClear(
          specYaml: specYaml, listId: listId, sequence: sequence);

  @override
  Future<StoredPlayDto> encodeRemoveApp({
    required String specYaml,
    required int cid,
    required int sequence,
  }) =>
      rust.encodeRemoveApp(specYaml: specYaml, cid: cid, sequence: sequence);

  @override
  Future<StoredPlayDto> encodeRemoveAllApps({
    required String specYaml,
    required int sequence,
  }) =>
      rust.encodeRemoveAllApps(specYaml: specYaml, sequence: sequence);
}
