// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:async';

import 'package:flutter/foundation.dart';

import '../core/error_text.dart';
import '../core/hex.dart';
import '../models/ble_discovered_service.dart';
import 'ble_service.dart';
import 'ipl_codec.dart';
import 'spec_codec.dart';

enum IplSetupPhase { checking, needsAction, ready, working, error }

class IplSetupState {
  final IplSetupPhase phase;
  final bool? locked;
  final bool? wakeupEnabled;
  final int? operationState;
  final int? skinTone;
  final int? energyLevel;
  final int? mountedHead;
  final int? flashes;
  final String? notice;
  final String? error;

  const IplSetupState({
    required this.phase,
    this.locked,
    this.wakeupEnabled,
    this.operationState,
    this.skinTone,
    this.energyLevel,
    this.mountedHead,
    this.flashes,
    this.notice,
    this.error,
  });
}

class IplSetupSession extends ChangeNotifier {
  final BleService ble;
  final SpecCodec specCodec;
  final IplCodec iplCodec;
  final String deviceId;
  final String specYaml;
  final DeviceSpecDto spec;
  final List<BleDiscoveredService> discoveredServices;

  IplSetupState _state;
  IplSetupState get state => _state;
  bool _busy = false;
  ForeoActivationDto? _activation;

  IplSetupSession({
    required this.ble,
    required this.specCodec,
    required this.iplCodec,
    required this.deviceId,
    required this.specYaml,
    required this.spec,
    required this.discoveredServices,
  }) : _state = const IplSetupState(phase: IplSetupPhase.checking);

  String get handler => spec.protocolHandler ?? '';

  void start() {
    if (_busy) return;
    _busy = true;
    unawaited(
      _start()
          .catchError((Object error) {
            _fail(error, 'Could not read the device setup state.');
          })
          .whenComplete(() => _busy = false),
    );
  }

  Future<void> _start() async {
    switch (handler) {
      case 'ipl_foreo':
        await _checkForeo();
      case 'ipl_silkn':
        await _checkSilkn();
      case 'ipl_braun':
        _update(phase: IplSetupPhase.ready, error: null);
    }
  }

  Future<void> activate() async {
    if (_busy) return;
    _busy = true;
    _update(phase: IplSetupPhase.working, error: null, notice: null);
    try {
      switch (handler) {
        case 'ipl_foreo':
          await _activateForeo();
        case 'ipl_silkn':
          await _unlockSilkn();
      }
    } catch (error) {
      _fail(error, 'The device did not confirm the unlock.');
    } finally {
      _busy = false;
    }
  }

  Future<void> measureSkinTone() => _executeBraun(5, 'measure_skin_tone');

  Future<void> startPatchTest() => _executeBraun(11, 'start_patch_test');

  Future<void> _checkForeo() async {
    final activation = await iplCodec.activation(deviceId);
    _activation = activation;
    await _writeRaw(
      '00000a10-0000-1000-8000-00805f9b34fb',
      activation.securityAccess,
    );
    await _readRaw('00002a28-0000-1000-8000-00805f9b34fb');
    final status = await _readForeoStatus();
    _update(
      phase: status.locked || !status.wakeupEnabled
          ? IplSetupPhase.needsAction
          : IplSetupPhase.ready,
      locked: status.locked,
      wakeupEnabled: status.wakeupEnabled,
      error: null,
      notice: status.locked
          ? 'This device is locked. Activate it before using the controls.'
          : !status.wakeupEnabled
          ? 'Wake-up is disabled. Enable it to finish setup.'
          : 'Device activated and wake-up enabled.',
    );
  }

  Future<void> _activateForeo() async {
    if (_state.locked == null) await _checkForeo();
    if (_state.phase == IplSetupPhase.error) return;
    final activation = _activation ?? await iplCodec.activation(deviceId);
    _activation = activation;
    if (_state.locked == true) {
      await _writeRaw(
        '00000a20-0000-1000-8000-00805f9b34fb',
        activation.activationWrite,
      );
    }
    if (_state.wakeupEnabled == false) {
      await _send('00000a30-0000-1000-8000-00805f9b34fb', 'set_wakeup');
    }
    final status = await _readForeoStatus();
    if (status.locked || !status.wakeupEnabled) {
      throw const _IplError(
        'The device did not confirm activation and wake-up.',
      );
    }
    _update(
      phase: IplSetupPhase.ready,
      locked: false,
      wakeupEnabled: true,
      error: null,
      notice: 'Device activated and wake-up enabled.',
    );
  }

  Future<ForeoStatusDto> _readForeoStatus() async {
    final activation = await _readRaw('00000a20-0000-1000-8000-00805f9b34fb');
    final wakeup = await _readRaw('00000a30-0000-1000-8000-00805f9b34fb');
    return iplCodec.decodeStatus(activation: activation, wakeup: wakeup);
  }

  Future<void> _checkSilkn() async {
    final locked = await _readSilknLock();
    _update(
      phase: locked ? IplSetupPhase.needsAction : IplSetupPhase.ready,
      locked: locked,
      error: null,
      notice: locked
          ? 'The optional app lock is enabled. Unlock it to continue.'
          : 'Device is released and unlocked.',
    );
  }

  Future<void> _unlockSilkn() async {
    await _send('12345678-9012-3456-7890-123456789033', 'release_and_unlock');
    final locked = await _readSilknLock();
    if (locked) {
      throw const _IplError('The device did not confirm Released + Unlocked.');
    }
    _update(
      phase: IplSetupPhase.ready,
      locked: false,
      error: null,
      notice: 'Device is released and unlocked.',
    );
  }

  Future<bool> _readSilknLock() async {
    final decoded = await _readDecoded('12345678-9012-3456-7890-123456789033');
    return _rawInt(decoded, 'state') == 0x31;
  }

  Future<void> _executeBraun(int commandId, String commandName) async {
    if (_busy || handler != 'ipl_braun') return;
    _busy = true;
    _update(phase: IplSetupPhase.working, error: null, notice: null);
    const statusChar = 'a0f03c03-5047-4d53-8208-4f72616c2d42';
    StreamSubscription<List<int>>? subscription;
    try {
      final notifications = ble.subscribeCharacteristic(
        deviceId,
        _serviceFor(statusChar),
        statusChar,
      );
      final outcome = Completer<int>();
      subscription = notifications.listen((bytes) async {
        if (outcome.isCompleted) return;
        try {
          final decoded = await _readDecodedFrom(statusChar, bytes);
          final status = _rawInt(decoded, 'status');
          if (_rawInt(decoded, 'opcode') == 0xC3 &&
              _rawInt(decoded, 'cmd_id') == commandId &&
              status != null &&
              !outcome.isCompleted) {
            outcome.complete(status);
          }
        } catch (error) {
          if (!outcome.isCompleted) outcome.completeError(error);
        }
      }, onError: outcome.completeError);
      if (notifications case final BleReadyNotificationStream ready) {
        await ready.ready;
      }
      await _send('a0f03c00-5047-4d53-8208-4f72616c2d42', commandName);
      final status = await outcome.future.timeout(const Duration(seconds: 10));
      if (status != 0) {
        throw _IplError(
          status == 1
              ? 'The device is busy. Wait for the current operation to finish.'
              : 'The device refused the command (status $status).',
        );
      }
      await _send('a0f03c00-5047-4d53-8208-4f72616c2d42', 'get_session_data');
      final session = await _readDecoded(
        'a0f03c01-5047-4d53-8208-4f72616c2d42',
      );
      _update(
        phase: IplSetupPhase.ready,
        operationState: _rawInt(session, 'operation_state'),
        skinTone: _rawInt(session, 'skin_tone'),
        energyLevel: _rawInt(session, 'energy_level'),
        mountedHead: _rawInt(session, 'mounted_head'),
        flashes: _rawInt(session, 'flashes_this_session'),
        error: null,
        notice: commandId == 5
            ? 'Skin-tone measurement complete. The raw sensor value is shown without a tone category.'
            : 'Patch-test command acknowledged. Follow the device instructions for the observation period.',
      );
    } catch (error) {
      _fail(error, 'The device did not acknowledge the command.');
    } finally {
      await subscription?.cancel();
      _busy = false;
    }
  }

  Future<void> _send(String charUuid, String commandName) async {
    final bytes = await specCodec.encodeCommand(
      specYaml: specYaml,
      serviceUuid: _serviceFor(charUuid),
      charUuid: charUuid,
      commandName: commandName,
      params: const {},
    );
    await _writeRaw(charUuid, bytes);
  }

  Future<List<int>> _readRaw(String charUuid) =>
      ble.readCharacteristic(deviceId, _serviceFor(charUuid), charUuid);

  Future<void> _writeRaw(String charUuid, List<int> bytes) =>
      ble.writeCharacteristic(deviceId, _serviceFor(charUuid), charUuid, bytes);

  Future<List<DecodedValueDto>> _readDecoded(String charUuid) async =>
      _readDecodedFrom(charUuid, await _readRaw(charUuid));

  Future<List<DecodedValueDto>> _readDecodedFrom(
    String charUuid,
    List<int> bytes,
  ) => specCodec.decodeValue(
    specYaml: specYaml,
    serviceUuid: _serviceFor(charUuid),
    charUuid: charUuid,
    bytes: bytes,
  );

  String _serviceFor(String charUuid) {
    final target = normalizeUuid(charUuid);
    for (final service in discoveredServices) {
      for (final characteristic in service.characteristics) {
        if (normalizeUuid(characteristic.uuid) == target) return service.uuid;
      }
    }
    throw const _IplError(
      'This device does not expose the required characteristic.',
    );
  }

  int? _rawInt(List<DecodedValueDto> decoded, String name) {
    final field = decoded.where((field) => field.name == name).firstOrNull;
    return field?.uintValue ?? field?.intValue;
  }

  void _fail(Object error, String fallback) {
    _update(
      phase: IplSetupPhase.error,
      error: error is UserFacingException ? error.message : fallback,
    );
  }

  void _update({
    IplSetupPhase? phase,
    bool? locked,
    bool? wakeupEnabled,
    int? operationState,
    int? skinTone,
    int? energyLevel,
    int? mountedHead,
    int? flashes,
    String? notice,
    String? error,
  }) {
    _state = IplSetupState(
      phase: phase ?? _state.phase,
      locked: locked ?? _state.locked,
      wakeupEnabled: wakeupEnabled ?? _state.wakeupEnabled,
      operationState: operationState ?? _state.operationState,
      skinTone: skinTone ?? _state.skinTone,
      energyLevel: energyLevel ?? _state.energyLevel,
      mountedHead: mountedHead ?? _state.mountedHead,
      flashes: flashes ?? _state.flashes,
      notice: notice,
      error: error,
    );
    notifyListeners();
  }
}

class _IplError implements UserFacingException {
  @override
  final String message;
  const _IplError(this.message);
}
