// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../core/log.dart';
import '../src/rust/api/readonly_api.dart';
import '../src/rust/protocol/pax.dart';
import 'ble_service.dart';
import 'read_only_ble_session.dart';

const _service = '8e320200-64d2-11e6-bdf4-0800200c9a66';
const _read = '8e320201-64d2-11e6-bdf4-0800200c9a66';
const _write = '8e320202-64d2-11e6-bdf4-0800200c9a66';
const _notify = '8e320203-64d2-11e6-bdf4-0800200c9a66';
const _disService = '0000180a-0000-1000-8000-00805f9b34fb';
const _serialChar = '00002a25-0000-1000-8000-00805f9b34fb';

/// What the unit has said so far.
@immutable
class PaxReading {
  final double? temperatureC;
  final int? batteryPercent;

  /// Nothing new arrived within the stall window, so this is old.
  final bool stale;

  const PaxReading({
    this.temperatureC,
    this.batteryPercent,
    this.stale = false,
  });

  PaxReading copyWith({
    double? temperatureC,
    int? batteryPercent,
    bool? stale,
  }) => PaxReading(
    temperatureC: temperatureC ?? this.temperatureC,
    batteryPercent: batteryPercent ?? this.batteryPercent,
    stale: stale ?? this.stale,
  );
}

abstract interface class PaxClient {
  /// Readings as they arrive, with a [ReadOnlyBleException] on the stream when
  /// the session cannot go on. Listening starts the session; closing ends it.
  Stream<PaxReading> watch();

  Future<void> close();
}

/// Reads a PAX 3 or PAX Era's temperature and battery (`pax_ofb`).
///
/// A heating device, so this client can ask and nothing else: the one frame
/// it writes is [paxEncodeStatusRequest]'s status update for temperature and
/// battery, built and encrypted in Rust, which takes no attribute to name.
/// The unit says a value is ready on the notify characteristic and this reads
/// it from the read characteristic. The key comes from the unit's Device
/// Information serial number, read first. An Era Pro is refused once its
/// services show it, before anything is subscribed or written.
class PaxBleClient implements PaxClient {
  final ReadOnlyBleSession _session;

  /// How long the unit gets to say anything this app can decrypt.
  final Duration answerWait;

  /// How often the status update is asked for again.
  final Duration pollEvery;

  /// How long without a new value before the reading is marked stale.
  final Duration staleAfter;

  final _output = StreamController<PaxReading>.broadcast();
  PaxReading _reading = const PaxReading();
  String? _serial;
  Timer? _answerTimer;
  Timer? _pollTimer;
  Timer? _staleTimer;
  Future<void> _queue = Future<void>.value();
  bool _answered = false;
  bool _undecodable = false;
  bool _started = false;

  PaxBleClient({
    required BleService ble,
    required String deviceId,
    this.answerWait = const Duration(seconds: 10),
    this.pollEvery = const Duration(seconds: 5),
    this.staleAfter = const Duration(seconds: 20),
  }) : _session = ReadOnlyBleSession(
         ble: ble,
         deviceId: deviceId,
         serviceUuid: _service,
         writeUuid: _write,
         notifyUuid: _notify,
       );

  BleService get _ble => _session.ble;
  String get _deviceId => _session.deviceId;

  @override
  Stream<PaxReading> watch() {
    if (!_started) {
      _started = true;
      unawaited(_run());
    }
    return _output.stream;
  }

  Future<void> _run() async {
    try {
      await _session.open(
        onBytes: (_) => _readReady(),
        onError: _fail,
        missingService: 'This device does not carry the PAX service.',
        vet: (services) =>
            paxModelRefusal(serviceUuids: [for (final s in services) s.uuid]),
      );
      if (_session.isClosed) return;
      final raw = await _ble.readCharacteristic(
        _deviceId,
        _disService,
        _serialChar,
      );
      _serial = latin1.decode(raw, allowInvalid: true);
      _answerTimer = Timer(answerWait, () {
        if (_answered) return;
        _fail(
          ReadOnlyBleException(
            _undecodable
                ? 'The unit answered, but nothing it sent decrypted to a '
                      'reading. It may not be a PAX 3 or Era.'
                : 'The unit did not answer the status request.',
          ),
        );
      });
      await _ask();
      _pollTimer = Timer.periodic(pollEvery, (_) => unawaited(_ask()));
    } on Object catch (e) {
      _fail(e);
    }
  }

  Future<void> _ask() async {
    final serial = _serial;
    if (serial == null || _session.isClosed) return;
    try {
      // One write, never split to the MTU: the IV is the packet's last 16
      // bytes, and halves of a packet are two packets the unit cannot
      // decrypt. The connect asks for a 512-byte MTU; a link that refused
      // it fails this write rather than splitting it.
      await _ble.writeCharacteristic(
        _deviceId,
        _service,
        _write,
        await paxEncodeStatusRequest(serial: serial),
      );
    } on Object catch (e) {
      // A serial the key cannot be made from ends the session; a write that
      // failed once is tried again on the next tick.
      if (!_answered) _fail(e);
    }
  }

  /// The notify carries one byte and means "read me". Reads are queued so
  /// two notifications do not race one read characteristic.
  void _readReady() {
    _queue = _queue.then((_) => _readOnce()).catchError(_fail);
  }

  Future<void> _readOnce() async {
    final serial = _serial;
    if (serial == null || _session.isClosed) return;
    final packet = await _ble.readCharacteristic(_deviceId, _service, _read);
    final PaxReadingDto decoded;
    try {
      decoded = await paxDecodeRead(serial: serial, packet: packet);
    } on Object catch (e) {
      _undecodable = true;
      Log.ble.debug('PAX read not decoded', error: e);
      return;
    }
    switch (decoded.kind) {
      case PaxReadingKind.temperature:
        _reading = _reading.copyWith(
          temperatureC: decoded.temperatureC,
          stale: false,
        );
      case PaxReadingKind.battery:
        _reading = _reading.copyWith(
          batteryPercent: decoded.batteryPercent,
          stale: false,
        );
      case PaxReadingKind.other:
        return;
    }
    _answered = true;
    _answerTimer?.cancel();
    _publish();
    _staleTimer?.cancel();
    _staleTimer = Timer(staleAfter, () {
      _reading = _reading.copyWith(stale: true);
      _publish();
    });
  }

  void _publish() {
    if (!_output.isClosed) _output.add(_reading);
  }

  void _fail(Object error) {
    if (_session.isClosed) return;
    Log.ble.warning('PAX session failed', error: error);
    if (!_output.isClosed) _output.addError(error);
    unawaited(close());
  }

  @override
  Future<void> close() async {
    _answerTimer?.cancel();
    _pollTimer?.cancel();
    _staleTimer?.cancel();
    await _session.close();
    if (!_output.isClosed) await _output.close();
  }
}
