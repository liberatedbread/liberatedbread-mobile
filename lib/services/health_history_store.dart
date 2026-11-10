// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../core/log.dart';
import '../src/rust/api/health_api.dart';

/// What a health device has handed over on earlier connections.
class HealthHistory {
  final List<PulseOxSessionDto> sessions;
  final List<BloodPressureReadingDto> bloodPressureReadings;

  const HealthHistory({
    this.sessions = const [],
    this.bloodPressureReadings = const [],
  });

  bool get isEmpty => sessions.isEmpty && bloodPressureReadings.isEmpty;
}

/// Whether [a] and [b] are the same stored session. By its times, not by
/// equality: the record index is a position in one transfer, and the same
/// session comes back under another on the next sync.
bool sameSession(PulseOxSessionDto a, PulseOxSessionDto b) =>
    a.startedAt == b.startedAt && a.endedAt == b.endedAt;

/// Measurements read from a health device, kept on this phone so a reading
/// is still here after the device's own memory has moved on — an oximeter
/// hands its sessions over once, and a cuff keeps a few dozen.
///
/// PRIVACY: this is health data. It is written to the app's own preferences
/// and nowhere else: nothing here is sent, synced or put in a device report,
/// and [clear] removes it. Keyed by device, so one person's cuff is not
/// another's history.
class HealthHistoryStore {
  final SharedPreferences _prefs;

  HealthHistoryStore(this._prefs);

  /// Kept per device and kind. Sessions arrive oldest first and readings are
  /// held newest first, so each is trimmed from its own old end.
  static const maxPerKind = 500;

  static String _key(String deviceId) => 'health_history_v1:$deviceId';

  HealthHistory load(String deviceId) {
    final stored = _prefs.getString(_key(deviceId));
    if (stored == null) return const HealthHistory();
    try {
      final json = jsonDecode(stored) as Map<String, dynamic>;
      return HealthHistory(
        sessions: [
          for (final s in json['sessions'] as List? ?? const [])
            _session(s as Map<String, dynamic>),
        ],
        bloodPressureReadings: [
          for (final r in json['blood_pressure'] as List? ?? const [])
            _reading(r as Map<String, dynamic>),
        ],
      );
    } on Object catch (e) {
      // A record this build cannot read is not worth failing the panel for.
      Log.app.warning('ignoring unreadable saved health history', error: e);
      return const HealthHistory();
    }
  }

  Future<void> save(String deviceId, HealthHistory history) async {
    if (history.isEmpty) {
      await clear(deviceId);
      return;
    }
    final sessions = history.sessions;
    final newestSessions = sessions.length <= maxPerKind
        ? sessions
        : sessions.sublist(sessions.length - maxPerKind);
    await _prefs.setString(
      _key(deviceId),
      jsonEncode({
        'sessions': [for (final s in newestSessions) _sessionJson(s)],
        'blood_pressure': [
          for (final r in history.bloodPressureReadings.take(maxPerKind))
            _readingJson(r),
        ],
      }),
    );
  }

  Future<void> clear(String deviceId) => _prefs.remove(_key(deviceId));

  static Map<String, Object?> _sessionJson(PulseOxSessionDto s) => {
    'record_index': s.recordIndex,
    'started_at': s.startedAt,
    'ended_at': s.endedAt,
    'spo2_min': s.spo2Min,
    'spo2_max': s.spo2Max,
    'spo2_avg': s.spo2Avg,
    'pulse_min_bpm': s.pulseMinBpm,
    'pulse_max_bpm': s.pulseMaxBpm,
    'pulse_avg_bpm': s.pulseAvgBpm,
  };

  static PulseOxSessionDto _session(Map<String, dynamic> j) =>
      PulseOxSessionDto(
        recordIndex: j['record_index'] as int,
        startedAt: j['started_at'] as String,
        endedAt: j['ended_at'] as String,
        spo2Min: j['spo2_min'] as int,
        spo2Max: j['spo2_max'] as int,
        spo2Avg: j['spo2_avg'] as int,
        pulseMinBpm: j['pulse_min_bpm'] as int,
        pulseMaxBpm: j['pulse_max_bpm'] as int,
        pulseAvgBpm: j['pulse_avg_bpm'] as int,
      );

  static Map<String, Object?> _readingJson(BloodPressureReadingDto r) => {
    'systolic_mmhg': r.systolicMmhg,
    'diastolic_mmhg': r.diastolicMmhg,
    'mean_arterial_mmhg': r.meanArterialMmhg,
    'pulse_bpm': r.pulseBpm,
    'measured_at': r.measuredAt,
    'user_slot': r.userSlot,
    'irregular_heartbeat': r.irregularHeartbeat,
    'sufficient_rest': r.sufficientRest,
    'converted_from_kpa': r.convertedFromKpa,
  };

  static BloodPressureReadingDto _reading(Map<String, dynamic> j) =>
      BloodPressureReadingDto(
        systolicMmhg: (j['systolic_mmhg'] as num).toDouble(),
        diastolicMmhg: (j['diastolic_mmhg'] as num).toDouble(),
        meanArterialMmhg: (j['mean_arterial_mmhg'] as num?)?.toDouble(),
        pulseBpm: (j['pulse_bpm'] as num?)?.toDouble(),
        measuredAt: j['measured_at'] as String?,
        userSlot: j['user_slot'] as int?,
        irregularHeartbeat: j['irregular_heartbeat'] as bool?,
        sufficientRest: j['sufficient_rest'] as bool?,
        convertedFromKpa: j['converted_from_kpa'] as bool? ?? false,
      );
}
