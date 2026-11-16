// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../core/error_text.dart';
import '../core/hex.dart';
import '../models/ble_discovered_service.dart';
import 'ble_service.dart';
import 'ipl_codec.dart';
import 'spec_codec.dart';

enum IplSetupPhase { checking, needsAction, ready, working, error }

const _foreoCommandChar = '0000fff1-0000-1000-8000-00805f9b34fb';
const _foreoWakeupChar = '00000a30-0000-1000-8000-00805f9b34fb';
const _foreoSwRevisionChar = '00002a28-0000-1000-8000-00805f9b34fb';

/// The spec's FFF1 command names the FOREO removal-mode section sends.
const foreoProModeCommands = {
  'set_removal_mode_pro',
  'set_removal_mode_basic',
  'get_removal_mode',
};

/// How many times an FFF1 exchange is tried while the device reads back busy
/// (all FF) — the stock app's limit, per the spec.
const _foreoBusyAttempts = 5;
const _unset = Object();

class IplSetupState {
  final IplSetupPhase phase;
  final bool? locked;

  /// Null when the unit has no 0A30 wake-up characteristic (the captured
  /// new-dialect PEACH2): nothing to enable.
  final bool? wakeupEnabled;

  /// FOREO SW revision (2A28), which picks the command dialect.
  final String? swRevision;

  /// Whether this FOREO gets the Basic/Pro switch at all.
  final bool? proModeSupported;

  /// FOREO removal mode: true Pro, false Basic, null not (yet) read.
  final bool? proMode;

  /// A failure of the removal-mode section alone. Kept apart from [error] so
  /// a failed Pro write does not read as failed activation.
  final String? proModeError;
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
    this.swRevision,
    this.proModeSupported,
    this.proMode,
    this.proModeError,
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
  bool _disposed = false;
  final List<StreamSubscription<List<int>>> _subscriptions = [];
  final Set<Completer<dynamic>> _outcomes = {};
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
    if (_busy || _disposed) return;
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
    if (_busy || _disposed) return;
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

  /// The spec's own warning for the Pro write, shown at the opt-in.
  String? get proModeWarning {
    final target = normalizeUuid(_foreoCommandChar);
    for (final service in spec.services) {
      for (final characteristic in service.characteristics) {
        if (normalizeUuid(characteristic.uuid) != target) continue;
        for (final command in characteristic.commands) {
          if (command.name == 'set_removal_mode_pro') {
            return command.advancedReason;
          }
        }
      }
    }
    return null;
  }

  /// Switch a FOREO between Pro ([pro] true) and Basic removal mode, then
  /// read the mode back: the write is only reported done once 0BD0 agrees.
  Future<void> setProMode(bool pro) async {
    if (_busy || _disposed || handler != 'ipl_foreo') return;
    if (_state.proModeSupported != true || _state.locked != false) return;
    _busy = true;
    _update(
      phase: IplSetupPhase.working,
      error: null,
      notice: null,
      proModeError: null,
    );
    try {
      final reply = await _foreoExchange(
        pro ? 'set_removal_mode_pro' : 'set_removal_mode_basic',
      );
      if (!iplCodec.writeAcknowledged(reply)) {
        throw const _IplError(
          'The device did not acknowledge the mode change.',
        );
      }
      final now = await _readRemovalMode();
      if (now != pro) {
        throw _IplError(
          pro
              ? 'The device acknowledged but still reports Basic mode.'
              : 'The device acknowledged but still reports Pro mode.',
        );
      }
      _update(
        phase: _foreoIdlePhase(),
        proMode: now,
        error: null,
        notice: pro
            ? 'Pro mode unlocked. The same five handset levels now most '
                  'likely give higher output: patch-test again before '
                  'treating. Pro stays set after you disconnect until you '
                  'disable it here.'
            : 'Pro mode disabled. The handset is back in Basic mode.',
      );
    } catch (error) {
      bool? mode;
      try {
        if (!_disposed) mode = await _readRemovalMode();
      } catch (_) {}
      _update(
        phase: _foreoIdlePhase(),
        proMode: mode,
        error: null,
        proModeError: error is UserFacingException
            ? error.message
            : 'The device did not confirm the mode change.',
      );
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
    final swRevision = _decodeRevision(await _readRaw(_foreoSwRevisionChar));
    final status = await _readForeoStatus();
    final needsWakeup = status.wakeupEnabled == false;
    final proSupported =
        _exposes(_foreoCommandChar) && iplCodec.proModeSupported(swRevision);
    bool? proMode;
    String? proModeError;
    if (proSupported && !status.locked) {
      try {
        proMode = await _readRemovalMode();
      } catch (error) {
        proModeError = error is UserFacingException
            ? error.message
            : 'The removal mode could not be read.';
      }
    }
    _update(
      phase: status.locked || needsWakeup
          ? IplSetupPhase.needsAction
          : IplSetupPhase.ready,
      locked: status.locked,
      wakeupEnabled: status.wakeupEnabled,
      swRevision: swRevision,
      proModeSupported: proSupported,
      proMode: proMode,
      proModeError: proModeError,
      error: null,
      notice: status.locked
          ? 'This device is locked. Activate it before using the controls.'
          : needsWakeup
          ? 'Wake-up is disabled. Enable it to finish setup.'
          : _foreoReadyText(status.wakeupEnabled),
    );
  }

  static String _foreoReadyText(bool? wakeupEnabled) => wakeupEnabled == true
      ? 'Device activated and wake-up enabled.'
      : 'Device activated.';

  /// The phase a FOREO rests in once an operation ends, from what is known
  /// of it: a mode change must not hide a pending activation or wake-up.
  IplSetupPhase _foreoIdlePhase() =>
      _state.locked == true || _state.wakeupEnabled == false
      ? IplSetupPhase.needsAction
      : IplSetupPhase.ready;

  /// 2A28 as text, without the NUL padding some firmware sends.
  static String _decodeRevision(List<int> bytes) =>
      utf8.decode(bytes, allowMalformed: true).replaceAll('\u0000', '').trim();

  Future<bool> _readRemovalMode() async =>
      iplCodec.decodeRemovalMode(await _foreoExchange('get_removal_mode'));

  /// Write one spec command to FFF1 and read its answer back, retrying while
  /// the device reads back busy.
  Future<List<int>> _foreoExchange(String commandName) async {
    final bytes = await specCodec.encodeCommand(
      specYaml: specYaml,
      serviceUuid: _serviceFor(_foreoCommandChar),
      charUuid: _foreoCommandChar,
      commandName: commandName,
      params: const {},
    );
    for (var attempt = 1; ; attempt++) {
      await _writeRaw(_foreoCommandChar, bytes);
      final reply = await _readRaw(_foreoCommandChar);
      if (!iplCodec.replyBusy(reply)) return reply;
      if (attempt >= _foreoBusyAttempts) {
        throw const _IplError(
          'The device stayed busy. Wait a moment and try again.',
        );
      }
      await Future<void>.delayed(const Duration(milliseconds: 150));
    }
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
      await _writeRaw(_foreoWakeupChar, activation.wakeupWrite);
    }
    final status = await _readForeoStatus();
    if (status.locked || status.wakeupEnabled == false) {
      throw const _IplError(
        'The device did not confirm activation and wake-up.',
      );
    }
    _update(
      phase: IplSetupPhase.ready,
      locked: false,
      wakeupEnabled: status.wakeupEnabled,
      error: null,
      notice: _foreoReadyText(status.wakeupEnabled),
    );
    // A unit that was locked could not be asked its mode before.
    if (_state.proModeSupported == true && _state.proMode == null) {
      try {
        _update(proMode: await _readRemovalMode());
      } catch (_) {}
    }
  }

  /// 0A20, plus 0A30 only on firmware that exposes it — the spec's setup
  /// step skips wake-up where the characteristic is absent.
  Future<ForeoStatusDto> _readForeoStatus() async {
    final activation = await _readRaw('00000a20-0000-1000-8000-00805f9b34fb');
    final wakeup = _exposes(_foreoWakeupChar)
        ? await _readRaw(_foreoWakeupChar)
        : null;
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
    if (_busy || _disposed || handler != 'ipl_braun') return;
    _busy = true;
    _update(phase: IplSetupPhase.working, error: null, notice: null);
    const statusChar = 'a0f03c03-5047-4d53-8208-4f72616c2d42';
    const pushChar = 'a0f03c04-5047-4d53-8208-4f72616c2d42';
    final acknowledgement = Completer<int>();
    final completion = Completer<int>();
    final acknowledgementOutcome = _observeOutcome(acknowledgement);
    final completionOutcome = _observeOutcome(completion);
    Object? notificationFailure;
    void failOutcomes(Object error) {
      notificationFailure ??= error;
      if (!acknowledgement.isCompleted) acknowledgement.completeError(error);
      if (!completion.isCompleted) completion.completeError(error);
    }

    _outcomes.addAll([acknowledgement, completion]);
    final subscriptions = <StreamSubscription<List<int>>>[];
    try {
      final statusNotifications = ble.subscribeCharacteristic(
        deviceId,
        _serviceFor(statusChar),
        statusChar,
      );
      subscriptions.add(
        statusNotifications.listen((bytes) async {
          if (acknowledgement.isCompleted) return;
          try {
            final decoded = await _readDecodedFrom(statusChar, bytes);
            final status = _rawInt(decoded, 'status');
            if (_rawInt(decoded, 'opcode') == 0xC3 &&
                _rawInt(decoded, 'cmd_id') == commandId &&
                status != null &&
                !acknowledgement.isCompleted) {
              acknowledgement.complete(status);
            }
          } catch (error) {
            failOutcomes(error);
          }
        }, onError: failOutcomes),
      );
      final pushNotifications = ble.subscribeCharacteristic(
        deviceId,
        _serviceFor(pushChar),
        pushChar,
      );
      subscriptions.add(
        pushNotifications.listen((bytes) async {
          if (completion.isCompleted) return;
          try {
            final decoded = await _readDecodedFrom(pushChar, bytes);
            final reason = _rawInt(decoded, 'reason');
            if (_rawInt(decoded, 'command') == commandId &&
                (reason == 1 || reason == 2) &&
                !completion.isCompleted) {
              completion.complete(reason);
            }
          } catch (error) {
            failOutcomes(error);
          }
        }, onError: failOutcomes),
      );
      _subscriptions.addAll(subscriptions);
      await Future.wait<void>([
        for (final notifications in [statusNotifications, pushNotifications])
          if (notifications case final BleReadyNotificationStream ready)
            ready.ready,
      ], eagerError: true);
      final earlyError = notificationFailure;
      if (earlyError != null) throw earlyError;
      await _send('a0f03c00-5047-4d53-8208-4f72616c2d42', commandName);
      final acknowledged = await acknowledgementOutcome.timeout(
        const Duration(seconds: 10),
      );
      if (acknowledged.error != null) throw acknowledged.error!;
      final status = acknowledged.value!;
      if (status != 0) {
        throw _IplError(
          status == 1
              ? 'The device is busy. Wait for the current operation to finish.'
              : 'The device refused the command (status $status).',
        );
      }
      // The device HAS acknowledged by here. A completion that does not
      // arrive in time must not read as "did not acknowledge": the device
      // may be mid patch test and able to flash.
      final completed = await completionOutcome.timeout(
        const Duration(seconds: 10),
        onTimeout: () => throw const _IplError(
          'The device accepted the command but has not reported finishing '
          'it. It may still be running — check the device before trying '
          'again.',
        ),
      );
      if (completed.error != null) throw completed.error!;
      final reason = completed.value!;
      if (reason != 1) {
        throw const _IplError('The device reported a command-end failure.');
      }
      await _send('a0f03c00-5047-4d53-8208-4f72616c2d42', 'get_session_data');
      final session = await _readDecoded(
        'a0f03c01-5047-4d53-8208-4f72616c2d42',
      );
      final operationState = _rawInt(session, 'operation_state');
      if (commandId == 5 && operationState == 6) {
        throw const _IplError(
          'The device is still measuring. Wait for it to finish.',
        );
      }
      _update(
        phase: IplSetupPhase.ready,
        operationState: operationState,
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
      failOutcomes(error);
      _fail(error, 'The device did not acknowledge the command.');
    } finally {
      _outcomes.removeAll([acknowledgement, completion]);
      for (final subscription in subscriptions) {
        _subscriptions.remove(subscription);
        await subscription.cancel();
      }
      _busy = false;
    }
  }

  Future<({int? value, Object? error})> _observeOutcome(
    Completer<int> outcome,
  ) async {
    try {
      return (value: await outcome.future, error: null);
    } catch (error) {
      return (value: null, error: error);
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

  Future<List<int>> _readRaw(String charUuid) {
    _requireAlive();
    return ble.readCharacteristic(deviceId, _serviceFor(charUuid), charUuid);
  }

  Future<void> _writeRaw(String charUuid, List<int> bytes) {
    _requireAlive();
    return ble.writeCharacteristic(
      deviceId,
      _serviceFor(charUuid),
      charUuid,
      bytes,
    );
  }

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

  bool _exposes(String charUuid) {
    final target = normalizeUuid(charUuid);
    return discoveredServices.any(
      (service) => service.characteristics.any(
        (characteristic) => normalizeUuid(characteristic.uuid) == target,
      ),
    );
  }

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
    String? swRevision,
    bool? proModeSupported,
    Object? proMode = _unset,
    Object? proModeError = _unset,
    int? operationState,
    int? skinTone,
    int? energyLevel,
    int? mountedHead,
    int? flashes,
    String? notice,
    String? error,
  }) {
    if (_disposed) return;
    _state = IplSetupState(
      phase: phase ?? _state.phase,
      locked: locked ?? _state.locked,
      wakeupEnabled: wakeupEnabled ?? _state.wakeupEnabled,
      swRevision: swRevision ?? _state.swRevision,
      proModeSupported: proModeSupported ?? _state.proModeSupported,
      proMode: identical(proMode, _unset) ? _state.proMode : proMode as bool?,
      proModeError: identical(proModeError, _unset)
          ? _state.proModeError
          : proModeError as String?,
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

  void _requireAlive() {
    if (_disposed) throw const _IplError('Setup was cancelled.');
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    for (final outcome in _outcomes) {
      if (!outcome.isCompleted) outcome.complete(2);
    }
    _outcomes.clear();
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    _subscriptions.clear();
    super.dispose();
  }
}

class _IplError implements UserFacingException {
  @override
  final String message;
  const _IplError(this.message);
}
