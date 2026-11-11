// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:async';

import 'package:clock/clock.dart';
import 'package:flutter/foundation.dart';

import '../core/error_text.dart';
import '../models/health_measurement_plan.dart';
import 'ble_service.dart';
import 'health_history_store.dart';
import 'health_measurement_codec.dart';

enum HealthSessionPhase { waiting, syncing, ready, error }

class HealthMeasurementState {
  final HealthSessionPhase phase;
  final PulseOxSampleDto? liveSample;
  final DateTime? lastSampleAt;
  final bool stale;
  final List<PulseOxSessionDto> sessions;
  final List<BloodPressureReadingDto> bloodPressureReadings;

  /// Stored records this sync received whole and could not read.
  final int skippedRecords;

  /// The live samples of this connection, oldest first, for the trend: the
  /// most recent [HealthMeasurementSession.maxLiveTrend] of them.
  final List<PulseOxSampleDto> liveTrend;
  final String? error;

  const HealthMeasurementState({
    required this.phase,
    this.liveSample,
    this.lastSampleAt,
    this.stale = false,
    this.sessions = const [],
    this.bloodPressureReadings = const [],
    this.skippedRecords = 0,
    this.liveTrend = const [],
    this.error,
  });
}

class HealthMeasurementSession extends ChangeNotifier {
  final BleService ble;
  final HealthMeasurementCodec codec;
  final HealthMeasurementPlan plan;
  final String deviceId;
  final String specYaml;
  final DateTime Function() now;
  final Duration pollInterval;
  final Duration staleAfter;
  final Duration syncTimeout;

  /// Where readings are kept between connections; null keeps nothing.
  final HealthHistoryStore? store;

  HealthMeasurementState _state;
  HealthMeasurementState get state => _state;

  StreamSubscription<List<int>>? _subscription;
  Timer? _pollTimer;
  Timer? _staleTimer;
  Timer? _syncTimer;
  Future<void> _eventChain = Future.value();
  Completer<void>? _clockAck;
  List<int> _historyBuffer = [];
  int _recordsTowardPage = 0;
  int _generation = 0;
  bool _started = false;
  bool _disposed = false;
  bool _pollInFlight = false;
  bool _historyStarted = false;
  bool _syncComplete = false;

  HealthMeasurementSession({
    required this.ble,
    required this.codec,
    required this.plan,
    required this.deviceId,
    required this.specYaml,
    DateTime Function()? now,
    this.pollInterval = const Duration(seconds: 1),
    this.staleAfter = const Duration(seconds: 5),
    this.syncTimeout = const Duration(seconds: 15),
    this.store,
  }) : now = now ?? clock.now,
       _state = HealthMeasurementState(
         phase: plan.mode == HealthMeasurementMode.historySync
             ? HealthSessionPhase.syncing
             : HealthSessionPhase.waiting,
       ) {
    // What this device handed over before, so it is on screen from the
    // start: an oximeter gives its sessions up once.
    final saved = store?.load(deviceId);
    if (saved != null && !saved.isEmpty) {
      _state = HealthMeasurementState(
        phase: _state.phase,
        sessions: saved.sessions,
        bloodPressureReadings: saved.bloodPressureReadings,
      );
    }
  }

  /// Ten minutes of one-second samples: what the live trend draws.
  static const maxLiveTrend = 600;

  /// A live run shorter than this is a finger settling, not a session.
  static const minLiveSamplesToKeep = 10;

  /// How many samples pass between saves of the run in progress, so an app
  /// that is killed mid-measurement has lost seconds, not the session.
  static const liveSaveEvery = 30;

  // The live run in progress: its start, last sample, and what its summary
  // is made of.
  DateTime? _liveStart;
  DateTime? _liveEnd;
  int _liveCount = 0;
  double _spo2Sum = 0, _pulseSum = 0;
  double _spo2Min = 0, _spo2Max = 0, _pulseMin = 0, _pulseMax = 0;

  void _addLiveSample(PulseOxSampleDto sample, DateTime at) {
    if (_liveCount == 0) {
      _liveStart = at;
      _spo2Min = _spo2Max = sample.spo2Percent;
      _pulseMin = _pulseMax = sample.pulseBpm;
    }
    _liveEnd = at;
    _liveCount++;
    _spo2Sum += sample.spo2Percent;
    _pulseSum += sample.pulseBpm;
    if (sample.spo2Percent < _spo2Min) _spo2Min = sample.spo2Percent;
    if (sample.spo2Percent > _spo2Max) _spo2Max = sample.spo2Percent;
    if (sample.pulseBpm < _pulseMin) _pulseMin = sample.pulseBpm;
    if (sample.pulseBpm > _pulseMax) _pulseMax = sample.pulseBpm;
  }

  /// The live run so far as a session like the ones an oximeter stores:
  /// when, and the least, most and average of each value. Kept under its
  /// start time, so saving again as it grows replaces rather than repeats.
  /// Returns the sessions to show; null when there is nothing worth keeping.
  List<PulseOxSessionDto>? _withLiveSummary() {
    final start = _liveStart;
    final end = _liveEnd;
    if (start == null || end == null || _liveCount < minLiveSamplesToKeep) {
      return null;
    }
    final summary = PulseOxSessionDto(
      recordIndex: 0,
      startedAt: _stamp(start),
      endedAt: _stamp(end),
      spo2Min: _spo2Min.round(),
      spo2Max: _spo2Max.round(),
      spo2Avg: (_spo2Sum / _liveCount).round(),
      pulseMinBpm: _pulseMin.round(),
      pulseMaxBpm: _pulseMax.round(),
      pulseAvgBpm: (_pulseSum / _liveCount).round(),
    );
    return [
      for (final s in _state.sessions)
        if (s.startedAt != summary.startedAt) s,
      summary,
    ];
  }

  void _saveLiveSummary() {
    final store = this.store;
    final sessions = _withLiveSummary();
    if (store == null || sessions == null) return;
    unawaited(
      store
          .save(
            deviceId,
            HealthHistory(
              sessions: sessions,
              bloodPressureReadings: _state.bloodPressureReadings,
            ),
          )
          .catchError((Object _) {}),
    );
  }

  /// `2026-11-08T14:30:01`, the form the stored sessions carry.
  static String _stamp(DateTime at) => at.toIso8601String().substring(0, 19);

  /// Whether anything is kept on this phone for the device.
  bool get hasSavedHistory =>
      store != null &&
      (_state.sessions.isNotEmpty || _state.bloodPressureReadings.isNotEmpty);

  /// Forget every reading kept for this device, on screen and on the phone.
  Future<void> clearSaved() async {
    if (_disposed) return;
    _state = HealthMeasurementState(
      phase: _state.phase,
      liveSample: _state.liveSample,
      lastSampleAt: _state.lastSampleAt,
      stale: _state.stale,
      liveTrend: _state.liveTrend,
      error: _state.error,
    );
    // The run in progress goes with the rest: cleared means cleared, not
    // "back at the next save".
    _liveCount = 0;
    _liveStart = _liveEnd = null;
    _spo2Sum = _pulseSum = 0;
    _notify();
    await store?.clear(deviceId);
  }

  void _persist() {
    final store = this.store;
    if (store == null) return;
    unawaited(
      store
          .save(
            deviceId,
            HealthHistory(
              sessions: _state.sessions,
              bloodPressureReadings: _state.bloodPressureReadings,
            ),
          )
          .catchError((Object _) {}),
    );
  }

  void start() {
    if (_started || _disposed) return;
    _started = true;
    final generation = ++_generation;
    final notifications = ble.subscribeCharacteristic(
      deviceId,
      plan.serviceUuid,
      plan.responseUuid,
    );
    _subscription = notifications.listen(
      (bytes) => _enqueue(bytes, generation),
      // A failed subscribe arrives here too, and says why: a monitor that
      // needs pairing first must read as that, not as a dropped connection.
      onError: (Object error) => error is UserFacingException
          ? _fail(error.message, generation)
          : _connectionEnded(generation),
      onDone: () => _connectionEnded(generation),
    );
    unawaited(_startMode(generation, notifications));
  }

  Future<void> retry() async {
    if (_disposed) return;
    await _stop();
    final lastSampleAt = _state.lastSampleAt;
    final retainedStale =
        _state.stale ||
        (_state.liveSample != null &&
            (_state.phase == HealthSessionPhase.error ||
                (lastSampleAt != null &&
                    now().difference(lastSampleAt) > staleAfter)));
    _state = HealthMeasurementState(
      phase: plan.mode == HealthMeasurementMode.historySync
          ? HealthSessionPhase.syncing
          : HealthSessionPhase.waiting,
      liveSample: _state.liveSample,
      lastSampleAt: lastSampleAt,
      stale: retainedStale,
      sessions: _state.sessions,
      bloodPressureReadings: _state.bloodPressureReadings,
      liveTrend: _state.liveTrend,
    );
    _started = false;
    _notify();
    start();
  }

  Future<void> _startMode(
    int generation,
    Stream<List<int>> notifications,
  ) async {
    try {
      if (notifications case final BleReadyNotificationStream ready) {
        await ready.ready;
      }
      if (!_isCurrent(generation) || _state.phase == HealthSessionPhase.error) {
        return;
      }
      switch (plan.mode) {
        case HealthMeasurementMode.livePoll:
          await _poll(generation);
          if (!_isCurrent(generation)) return;
          _pollTimer = Timer.periodic(pollInterval, (_) => _poll(generation));
          _staleTimer = Timer.periodic(pollInterval, (_) {
            final at = _state.lastSampleAt;
            if (at == null || _state.stale || !_isCurrent(generation)) return;
            if (now().difference(at) > staleAfter) {
              _update(generation, stale: true);
            }
          });
        case HealthMeasurementMode.savedRecords:
          return;
        case HealthMeasurementMode.historySync:
          _armSyncTimer(generation);
          _clockAck = Completer<void>();
          await _write('set_datetime', generation, clock: now());
          await _clockAck!.future.timeout(syncTimeout);
          if (!_isCurrent(generation)) return;
          _historyStarted = true;
          await _write('get_measurements_page', generation, page: 0);
      }
    } catch (error) {
      _fail(_startError(error), generation);
    }
  }

  /// The sync fails when the oximeter goes quiet for [syncTimeout] — armed at
  /// the start and again on every record, so a long transfer that is still
  /// arriving is not called timed out for being long.
  void _armSyncTimer(int generation) {
    _syncTimer?.cancel();
    _syncTimer = Timer(syncTimeout, () {
      if (!_syncComplete) {
        _fail(
          'History sync timed out. Enter SYNC on the oximeter, then retry.',
          generation,
        );
      }
    });
  }

  Future<void> _poll(int generation) async {
    if (_pollInFlight || !_isCurrent(generation)) return;
    _pollInFlight = true;
    try {
      await _write('poll_measurement', generation);
    } catch (_) {
      if (_state.liveSample == null) {
        _update(
          generation,
          phase: HealthSessionPhase.error,
          error: 'No fresh sample. Check the oximeter and try again.',
        );
      }
    } finally {
      _pollInFlight = false;
    }
  }

  Future<void> _write(
    String commandName,
    int generation, {
    int? page,
    DateTime? clock,
  }) async {
    final write = await codec.encodeCommand(
      specYaml: specYaml,
      commandName: commandName,
      page: page,
      clock: clock == null
          ? null
          : HealthClockDto(
              year: clock.year,
              month: clock.month,
              day: clock.day,
              hour: clock.hour,
              minute: clock.minute,
              second: clock.second,
            ),
    );
    if (!_isCurrent(generation)) return;
    await ble.writeCharacteristic(
      deviceId,
      write.serviceUuid,
      write.characteristicUuid,
      write.bytes,
    );
  }

  void _enqueue(List<int> bytes, int generation) {
    _eventChain = _eventChain
        .then((_) async {
          if (!_isCurrent(generation)) return;
          if (plan.mode == HealthMeasurementMode.historySync) {
            await _historyBytes(bytes, generation);
          } else {
            await _sampleBytes(bytes, generation);
          }
        })
        .catchError((_) {
          _fail(
            'The device sent a measurement this app could not decode. '
            'No value was added.',
            generation,
          );
        });
  }

  Future<void> _sampleBytes(List<int> bytes, int generation) async {
    final sample = await codec.decodeSample(
      specYaml: specYaml,
      charUuid: plan.responseUuid,
      bytes: bytes,
    );
    if (!_isCurrent(generation)) return;
    final pulse = sample.pulseOximeter;
    final bloodPressure = sample.bloodPressure;
    // A frame with no measurement in it (no finger in the sensor, another
    // frame type): nothing to show and nothing wrong. A sample already on
    // screen goes stale by its own timer.
    if (pulse == null && bloodPressure == null) return;
    if (pulse != null && plan.kind == HealthMeasurementKind.pulseOximeter) {
      final at = now();
      _addLiveSample(pulse, at);
      final trend = [..._state.liveTrend, pulse];
      _update(
        generation,
        phase: HealthSessionPhase.ready,
        liveSample: pulse,
        liveTrend: trend.length > maxLiveTrend
            ? trend.sublist(trend.length - maxLiveTrend)
            : trend,
        lastSampleAt: at,
        stale: false,
        error: null,
      );
      if (_liveCount % liveSaveEvery == 0) _saveLiveSummary();
      return;
    }
    if (bloodPressure != null &&
        plan.kind == HealthMeasurementKind.bloodPressure) {
      final readings = _state.bloodPressureReadings;
      if (readings.contains(bloodPressure)) return;
      _update(
        generation,
        phase: HealthSessionPhase.ready,
        bloodPressureReadings: [bloodPressure, ...readings],
        lastSampleAt: now(),
        error: null,
      );
      _persist();
      return;
    }
    throw const FormatException('wrong health measurement kind');
  }

  Future<void> _historyBytes(List<int> bytes, int generation) async {
    if (bytes.length >= 2 && bytes[0] == 0xF3 && bytes[1] == 0x00) {
      if (_clockAck?.isCompleted == false) _clockAck!.complete();
    }
    if (!_historyStarted || _syncComplete) return;
    _historyBuffer = [..._historyBuffer, ...bytes];
    final chunk = await codec.decodeHistory(
      specYaml: specYaml,
      bytes: _historyBuffer,
    );
    if (!_isCurrent(generation)) return;
    if (chunk.consumed < 0 || chunk.consumed > _historyBuffer.length) {
      throw const FormatException('invalid history consumption');
    }
    _historyBuffer = _historyBuffer.sublist(chunk.consumed);
    final sessions = _state.sessions;
    final additions = <PulseOxSessionDto>[];
    for (final session in chunk.sessions) {
      if (![...sessions, ...additions].any((s) => sameSession(s, session))) {
        additions.add(session);
      }
    }
    if (additions.isNotEmpty || chunk.skipped > 0) {
      _update(
        generation,
        sessions: [...sessions, ...additions],
        skippedRecords: _state.skippedRecords + chunk.skipped,
        error: _state.error,
      );
      if (additions.isNotEmpty) _persist();
    }
    if (chunk.consumed > 0 && !chunk.endOfTransfer) _armSyncTimer(generation);
    _recordsTowardPage += chunk.records;
    if (chunk.endOfTransfer) {
      _syncComplete = true;
      _syncTimer?.cancel();
      _update(generation, phase: HealthSessionPhase.ready, error: null);
      return;
    }
    if (_recordsTowardPage >= 12) {
      _recordsTowardPage = 0;
      await _write('get_measurements_page', generation, page: 1);
    }
  }

  void _connectionEnded(int generation) {
    if (!_isCurrent(generation)) return;
    // Nothing is left to poll; without this a live session kept writing its
    // request at a dead link every second until the panel went away.
    _pollTimer?.cancel();
    _pollTimer = null;
    _saveLiveSummary();
    switch (plan.mode) {
      case HealthMeasurementMode.historySync:
        if (_syncComplete) return;
        _fail(
          _state.sessions.isEmpty
              ? 'History sync lost its connection. Enter SYNC on the oximeter, '
                    'then retry.'
              : 'History sync was interrupted. Sessions received so far are '
                    'shown; enter SYNC and retry to finish.',
          generation,
        );
      case HealthMeasurementMode.livePoll:
        if (_state.liveSample != null) {
          _update(
            generation,
            phase: HealthSessionPhase.error,
            stale: true,
            error: 'The connection ended. The last sample is shown.',
          );
        } else {
          _fail(
            'The measurement connection ended before a sample arrived.',
            generation,
          );
        }
      case HealthMeasurementMode.savedRecords:
        _fail(
          _state.bloodPressureReadings.isEmpty
              ? 'The measurement connection ended before a reading arrived.'
              : 'The connection ended. Readings received so far are shown.',
          generation,
        );
    }
  }

  String _startError(Object error) {
    if (error is UserFacingException) return error.message;
    return switch (plan.mode) {
      HealthMeasurementMode.historySync =>
        'Could not sync sessions. Enter SYNC on the oximeter, then retry.',
      _ => 'Could not start measurement updates. Check the device and retry.',
    };
  }

  void _fail(String message, int generation) {
    _update(generation, phase: HealthSessionPhase.error, error: message);
  }

  void _update(
    int generation, {
    HealthSessionPhase? phase,
    PulseOxSampleDto? liveSample,
    DateTime? lastSampleAt,
    bool? stale,
    List<PulseOxSessionDto>? sessions,
    List<BloodPressureReadingDto>? bloodPressureReadings,
    int? skippedRecords,
    List<PulseOxSampleDto>? liveTrend,
    String? error,
  }) {
    if (!_isCurrent(generation)) return;
    _state = HealthMeasurementState(
      phase: phase ?? _state.phase,
      liveSample: liveSample ?? _state.liveSample,
      lastSampleAt: lastSampleAt ?? _state.lastSampleAt,
      stale: stale ?? _state.stale,
      sessions: sessions ?? _state.sessions,
      bloodPressureReadings:
          bloodPressureReadings ?? _state.bloodPressureReadings,
      skippedRecords: skippedRecords ?? _state.skippedRecords,
      liveTrend: liveTrend ?? _state.liveTrend,
      error: error,
    );
    _notify();
  }

  bool _isCurrent(int generation) => !_disposed && _generation == generation;

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  Future<void> _stop() async {
    ++_generation;
    _pollTimer?.cancel();
    _staleTimer?.cancel();
    _syncTimer?.cancel();
    _pollTimer = null;
    _staleTimer = null;
    _syncTimer = null;
    _pollInFlight = false;
    _historyStarted = false;
    _syncComplete = false;
    _recordsTowardPage = 0;
    _historyBuffer = [];
    _clockAck = null;
    await _subscription?.cancel();
    _subscription = null;
  }

  @override
  void dispose() {
    if (_disposed) return;
    _saveLiveSummary();
    _disposed = true;
    unawaited(_stop());
    super.dispose();
  }
}
