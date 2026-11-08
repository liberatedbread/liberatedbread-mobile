// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:async';

import 'package:flutter/foundation.dart';

import '../core/log.dart';
import '../src/rust/api/readonly_api.dart';
import '../src/rust/protocol/yummly.dart';
import 'ble_service.dart';
import 'read_only_ble_session.dart';

const _service = '6e40abcd-b5a3-f393-e0a9-e50e4159414d';
const _request = '6e40aa02-b5a3-f393-e0a9-e50e4159414d';
const _notify = '6e40aa03-b5a3-f393-e0a9-e50e4159414d';

/// Everything the dock has told this session so far.
@immutable
class YummlyReading {
  final double? coreF;
  final bool coreAtLimit;
  final double? bodyF;
  final bool bodyAtLimit;
  final int? dockBars;
  final int? probeBars;
  final String? dockFirmware;
  final String? probeName;

  /// No temperature frame arrived within the stall window, so the numbers on
  /// screen are old.
  final bool stale;

  const YummlyReading({
    this.coreF,
    this.coreAtLimit = false,
    this.bodyF,
    this.bodyAtLimit = false,
    this.dockBars,
    this.probeBars,
    this.dockFirmware,
    this.probeName,
    this.stale = false,
  });

  YummlyReading copyWith({
    double? coreF,
    bool? coreAtLimit,
    double? bodyF,
    bool? bodyAtLimit,
    int? dockBars,
    int? probeBars,
    String? dockFirmware,
    String? probeName,
    bool? stale,
  }) => YummlyReading(
    coreF: coreF ?? this.coreF,
    coreAtLimit: coreAtLimit ?? this.coreAtLimit,
    bodyF: bodyF ?? this.bodyF,
    bodyAtLimit: bodyAtLimit ?? this.bodyAtLimit,
    dockBars: dockBars ?? this.dockBars,
    probeBars: probeBars ?? this.probeBars,
    dockFirmware: dockFirmware ?? this.dockFirmware,
    probeName: probeName ?? this.probeName,
    stale: stale ?? this.stale,
  );
}

abstract interface class YummlyClient {
  /// Readings as they arrive, with a [ReadOnlyBleException] on the stream when
  /// the session cannot go on. Listening starts the session; closing ends it.
  Stream<YummlyReading> watch();

  Future<void> close();
}

/// Reads a Yummly T1 dock and its P1 probe (XW2).
///
/// What it writes, all of it from Rust: the three-byte reply to the dock's
/// challenge, and the named reads in [YummlyReadKind]. Those are the only
/// writes the spec's connect sequence needs and none of them changes anything
/// on the dock. The request that drops a probe into its bootloader has no
/// encoder.
class YummlyBleClient implements YummlyClient {
  final ReadOnlyBleSession _session;

  /// How long to wait for the challenge ping before answering regardless, as
  /// the spec's setup steps say to.
  final Duration pingWait;

  /// The source client's pacing between requests, 0.8-1.5 s.
  final Duration requestGap;

  /// The stream runs about every 2 s. A dock that says nothing valid within
  /// this is reported rather than waited on for ever.
  final Duration answerWait;

  /// How long without a temperature before the reading is marked stale.
  final Duration staleAfter;

  final _output = StreamController<YummlyReading>.broadcast();
  final _ping = Completer<void>();
  YummlyReading _reading = const YummlyReading();
  Uint8List? _probeAddress;
  Future<void> _queue = Future<void>.value();
  Timer? _answerTimer;
  Timer? _staleTimer;
  bool _sawValidFrame = false;
  bool _sawGarbage = false;
  bool _started = false;

  YummlyBleClient({
    required BleService ble,
    required String deviceId,
    this.pingWait = const Duration(seconds: 6),
    this.requestGap = const Duration(seconds: 1),
    this.answerWait = const Duration(seconds: 15),
    this.staleAfter = const Duration(seconds: 10),
  }) : _session = ReadOnlyBleSession(
         ble: ble,
         deviceId: deviceId,
         serviceUuid: _service,
         writeUuid: _request,
         notifyUuid: _notify,
       );

  @override
  Stream<YummlyReading> watch() {
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
        missingService:
            'This dock does not carry the T1 service. The T3 and P3 generation '
            'has never been run by anyone this project knows of, so this app '
            'does not read it.',
      );
      if (_session.isClosed) return;
      _answerTimer = Timer(answerWait, () {
        _fail(
          ReadOnlyBleException(
            _sawGarbage
                ? 'The dock answered, but not with frames this app can read.'
                : 'The dock did not answer. Lift the probe out to wake the '
                      'dock, and keep it in range.',
          ),
        );
      });
      await _ping.future.timeout(pingWait, onTimeout: () {});
      if (_session.isClosed) return;
      await _session.write(await yummlyEncodeChallengeReply(selector: 0));
      for (final kind in const [
        YummlyReadKind.dockFirmware,
        YummlyReadKind.dockBattery,
        YummlyReadKind.probeMac,
      ]) {
        await Future<void>.delayed(requestGap);
        if (_session.isClosed) return;
        await _session.write(await yummlyEncodeRead(kind: kind));
      }
      for (final kind in const [
        YummlyReadKind.probeName,
        YummlyReadKind.probeBattery,
      ]) {
        await Future<void>.delayed(requestGap);
        final address = _probeAddress;
        if (_session.isClosed || address == null) return;
        await _session.write(
          await yummlyEncodeRead(kind: kind, probeAddressReversed: address),
        );
      }
    } on Object catch (e) {
      _fail(e);
    }
  }

  void _onBytes(List<int> bytes) {
    final copy = List<int>.of(bytes);
    _queue = _queue.then((_) => _decode(copy)).catchError(_fail);
  }

  Future<void> _decode(List<int> bytes) async {
    if (_session.isClosed) return;
    final YummlyFrameDto frame;
    try {
      frame = await yummlyDecodeFrame(frame: bytes);
    } on Object catch (e) {
      // One bad notification is not the end of a session: the stream repeats
      // every 2 s. The answer timer deals with a dock that only sends these.
      Log.ble.debug('Yummly frame not understood', error: e);
      _sawGarbage = true;
      return;
    }
    if (_session.isClosed) return;
    _sawValidFrame = true;
    _answerTimer?.cancel();
    final address = frame.probeAddressReversed;
    if (address != null) _probeAddress = address;
    switch (frame.kind) {
      case YummlyFrameKind.challengePing:
        if (!_ping.isCompleted) _ping.complete();
        return;
      case YummlyFrameKind.coreTemperature:
        _reading = _reading.copyWith(
          coreF: frame.temperatureF,
          coreAtLimit: frame.atLimit,
          stale: false,
        );
        _armStale();
      case YummlyFrameKind.bodyTemperature:
        _reading = _reading.copyWith(
          bodyF: frame.temperatureF,
          bodyAtLimit: frame.atLimit,
          stale: false,
        );
        _armStale();
      case YummlyFrameKind.dockBattery:
        _reading = _reading.copyWith(dockBars: frame.batteryBars);
      case YummlyFrameKind.probeBattery:
        _reading = _reading.copyWith(probeBars: frame.batteryBars);
      case YummlyFrameKind.dockFirmware:
        _reading = _reading.copyWith(dockFirmware: frame.text);
      case YummlyFrameKind.probeName:
        _reading = _reading.copyWith(probeName: frame.text);
      case YummlyFrameKind.probeAddress:
      case YummlyFrameKind.probeStatus:
      case YummlyFrameKind.probeFirmware:
      case YummlyFrameKind.other:
        return;
    }
    if (!_output.isClosed) _output.add(_reading);
  }

  void _armStale() {
    _staleTimer?.cancel();
    _staleTimer = Timer(staleAfter, () {
      _reading = _reading.copyWith(stale: true);
      if (!_output.isClosed) _output.add(_reading);
    });
  }

  void _fail(Object error) {
    if (_session.isClosed) return;
    Log.ble.warning('Yummly session failed', error: error);
    if (!_output.isClosed) _output.addError(error);
    unawaited(close());
  }

  /// Whether the dock has said anything this client understood.
  @visibleForTesting
  bool get sawValidFrame => _sawValidFrame;

  @override
  Future<void> close() async {
    _answerTimer?.cancel();
    _staleTimer?.cancel();
    await _session.close();
    if (!_output.isClosed) await _output.close();
  }
}
