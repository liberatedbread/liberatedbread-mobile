// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:async';

import 'package:flutter/foundation.dart';

import '../core/log.dart';
import '../src/rust/api/readonly_api.dart';
import '../src/rust/protocol/inmotion.dart';
import 'ble_service.dart';
import 'read_only_ble_session.dart';

const _service = '6e400001-b5a3-f393-e0a9-e50e24dcca9e';
const _write = '6e400002-b5a3-f393-e0a9-e50e24dcca9e';
const _notify = '6e400003-b5a3-f393-e0a9-e50e24dcca9e';

/// What the wheel has said so far.
@immutable
class InMotionReading {
  final InMotionModelDto model;
  final InMotionTelemetryDto? telemetry;
  final InMotionTotalsDto? totals;

  /// No real-time reply arrived within the stall window, so this is old.
  final bool stale;

  const InMotionReading({
    required this.model,
    this.telemetry,
    this.totals,
    this.stale = false,
  });

  InMotionReading copyWith({
    InMotionTelemetryDto? telemetry,
    InMotionTotalsDto? totals,
    bool? stale,
  }) => InMotionReading(
    model: model,
    telemetry: telemetry ?? this.telemetry,
    totals: totals ?? this.totals,
    stale: stale ?? this.stale,
  );
}

abstract interface class InMotionClient {
  /// Readings as they arrive, with a [ReadOnlyBleException] on the stream when
  /// the session cannot go on. Listening starts the session; closing ends it.
  Stream<InMotionReading> watch();

  Future<void> close();
}

/// Reads an INMOTION V2 wheel's telemetry (`inmotion_euc`).
///
/// A vehicle someone may be riding, so this client asks and nothing else.
/// Every byte it writes is one of [InMotionRead]'s four requests, built in
/// Rust: car type until the wheel answers, its board versions (a V11's layout
/// depends on them), then real-time and total statistics in turn. A legacy
/// wheel is refused once its services show it. A model whose real-time
/// layout the spec does not state is reported, not guessed at.
class InMotionBleClient implements InMotionClient {
  final ReadOnlyBleSession _session;

  /// How long the wheel gets to say what model it is.
  final Duration answerWait;

  /// One request per tick, as the spec's polling loop paces them.
  final Duration tick;

  /// How long without real-time data before the reading is marked stale.
  final Duration staleAfter;

  final _output = StreamController<InMotionReading>.broadcast();
  Uint8List _buffer = Uint8List(0);
  Future<void> _queue = Future<void>.value();
  InMotionModelDto? _model;
  InMotionLayout? _layout;
  InMotionReading? _reading;
  bool _versionsAsked = false;
  bool _versionsAnswered = false;
  var _dropped = 0;
  var _turn = 0;
  Timer? _answerTimer;
  Timer? _pollTimer;
  Timer? _staleTimer;
  bool _started = false;

  InMotionBleClient({
    required BleService ble,
    required String deviceId,
    this.answerWait = const Duration(seconds: 10),
    this.tick = const Duration(milliseconds: 250),
    this.staleAfter = const Duration(seconds: 5),
  }) : _session = ReadOnlyBleSession(
         ble: ble,
         deviceId: deviceId,
         serviceUuid: _service,
         writeUuid: _write,
         notifyUuid: _notify,
       );

  @override
  Stream<InMotionReading> watch() {
    if (!_started) {
      _started = true;
      unawaited(_run());
    }
    return _output.stream;
  }

  Future<void> _run() async {
    try {
      await _session.open(
        onBytes: _onBytes,
        onError: _fail,
        missingService: 'This wheel does not carry the InMotion V2 service.',
        vet: (services) => inmotionWheelRefusal(
          serviceUuids: [for (final s in services) s.uuid],
        ),
      );
      if (_session.isClosed) return;
      _answerTimer = Timer(answerWait, () {
        if (_layout != null) return;
        _fail(
          ReadOnlyBleException(
            _model != null
                ? 'The wheel said what it is but not its board versions, so '
                      'its telemetry layout is not known.'
                : _dropped > 0
                ? 'The wheel answered, but nothing it sent was a whole frame.'
                : 'The wheel did not answer.',
          ),
        );
      });
      await _poll();
      _pollTimer = Timer.periodic(tick, (_) => unawaited(_poll()));
    } on Object catch (e) {
      _fail(e);
    }
  }

  /// The one request this tick: car type until it is known, the versions
  /// once, then real-time and total statistics in turn.
  Future<void> _poll() async {
    if (_session.isClosed) return;
    final InMotionRead read;
    if (_model == null) {
      read = InMotionRead.carType;
    } else if (_layout == null) {
      if (_versionsAsked && !_versionsAnswered && _turn++ % 4 != 0) return;
      _versionsAsked = true;
      read = InMotionRead.versions;
    } else {
      read = _turn++ % 5 == 4 ? InMotionRead.totalStats : InMotionRead.realTime;
    }
    try {
      await _session.write(await inmotionEncodeRead(read: read));
    } on Object catch (e) {
      Log.ble.debug('InMotion request not written', error: e);
    }
  }

  void _onBytes(List<int> bytes) {
    final copy = List<int>.of(bytes);
    _queue = _queue.then((_) => _assemble(copy)).catchError(_fail);
  }

  Future<void> _assemble(List<int> chunk) async {
    if (_session.isClosed) return;
    final fed = await inmotionFeed(buffer: _buffer, chunk: chunk);
    _buffer = fed.buffer;
    _dropped += fed.dropped;
    for (final frame in fed.frames) {
      await _onFrame(frame);
    }
  }

  Future<void> _onFrame(InMotionFrameDto frame) async {
    switch (frame.kind) {
      case InMotionFrameKind.carType:
        if (_model != null) return;
        final model = _model = await inmotionDecodeCarType(data: frame.data);
        _reading = InMotionReading(model: model);
        _publish();
        // Every listed model but the V11 is settled by the model alone.
        final layout = model.layout;
        if (layout != null) {
          _settle(layout);
        } else if (model.code != 61) {
          _fail(
            ReadOnlyBleException(
              'This wheel reports model ${model.code}'
              '${model.name == null ? '' : ' (${model.name})'}, whose '
              'telemetry layout the spec does not state, so nothing is shown '
              'rather than a wrong reading.',
            ),
          );
        }
      case InMotionFrameKind.versions:
        final model = _model;
        if (model == null || _layout != null) return;
        final versions = await inmotionDecodeVersions(data: frame.data);
        _versionsAnswered = true;
        final layout = await inmotionLayoutFor(
          modelCode: model.code,
          mainBoard: versions.main,
        );
        if (layout != null) _settle(layout);
      case InMotionFrameKind.realTime:
        final layout = _layout;
        final reading = _reading;
        if (layout == null || reading == null) return;
        final InMotionTelemetryDto telemetry;
        try {
          telemetry = await inmotionDecodeRealtime(
            layout: layout,
            data: frame.data,
          );
        } on Object catch (e) {
          Log.ble.debug('InMotion real-time not decoded', error: e);
          return;
        }
        _reading = reading.copyWith(telemetry: telemetry, stale: false);
        _publish();
        _staleTimer?.cancel();
        _staleTimer = Timer(staleAfter, () {
          _reading = _reading?.copyWith(stale: true);
          _publish();
        });
      case InMotionFrameKind.totalStats:
        final reading = _reading;
        if (reading == null) return;
        try {
          final totals = await inmotionDecodeTotals(data: frame.data);
          _reading = reading.copyWith(totals: totals);
          _publish();
        } on Object catch (e) {
          Log.ble.debug('InMotion totals not decoded', error: e);
        }
      case InMotionFrameKind.other:
        return;
    }
  }

  void _settle(InMotionLayout layout) {
    _layout = layout;
    _answerTimer?.cancel();
  }

  void _publish() {
    final reading = _reading;
    if (reading != null && !_output.isClosed) _output.add(reading);
  }

  void _fail(Object error) {
    if (_session.isClosed) return;
    Log.ble.warning('InMotion session failed', error: error);
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
