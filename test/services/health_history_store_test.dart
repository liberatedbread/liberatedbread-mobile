// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/models/health_measurement_plan.dart';
import 'package:liberated_bread_mobile/services/health_history_store.dart';
import 'package:liberated_bread_mobile/services/health_measurement_codec.dart';
import 'package:liberated_bread_mobile/services/health_measurement_session.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../fakes/fake_ble_service.dart';
import '../fakes/fake_health_measurement_codec.dart';

const _reading = BloodPressureReadingDto(
  systolicMmhg: 120,
  diastolicMmhg: 80,
  meanArterialMmhg: 93,
  pulseBpm: 72,
  measuredAt: '2026-11-08T14:30:00',
  userSlot: 1,
  irregularHeartbeat: false,
  sufficientRest: true,
  convertedFromKpa: false,
);

PulseOxSessionDto _session(int index, String start) => PulseOxSessionDto(
  recordIndex: index,
  startedAt: start,
  endedAt: '${start.substring(0, 17)}59',
  spo2Min: 94,
  spo2Max: 99,
  spo2Avg: 97,
  pulseMinBpm: 65,
  pulseMaxBpm: 80,
  pulseAvgBpm: 72,
);

const _plan = HealthMeasurementPlan(
  kind: HealthMeasurementKind.bloodPressure,
  mode: HealthMeasurementMode.savedRecords,
  serviceUuid: 'health-service',
  responseUuid: 'health-response',
  handledCharacteristicUuids: {'health-response'},
);

void main() {
  late HealthHistoryStore store;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    store = HealthHistoryStore(await SharedPreferences.getInstance());
  });

  test(
    'what is saved for a device comes back, and only for that device',
    () async {
      final first = _session(1, '2026-11-08T14:30:00');
      await store.save(
        'cuff',
        HealthHistory(
          sessions: [first],
          bloodPressureReadings: const [_reading],
        ),
      );
      final loaded = store.load('cuff');
      expect(loaded.sessions, [first]);
      expect(loaded.bloodPressureReadings, [_reading]);
      expect(store.load('someone-elses').isEmpty, isTrue);

      await store.clear('cuff');
      expect(store.load('cuff').isEmpty, isTrue);
    },
  );

  test('a record this build cannot read is no history, not a crash', () async {
    SharedPreferences.setMockInitialValues({
      'health_history_v1:cuff': '{"sessions": [{"started_at": 7}]}',
    });
    final broken = HealthHistoryStore(await SharedPreferences.getInstance());
    expect(broken.load('cuff').isEmpty, isTrue);
  });

  test('the same session under a new record index is the same session', () {
    expect(
      sameSession(
        _session(1, '2026-11-08T14:30:00'),
        _session(4, '2026-11-08T14:30:00'),
      ),
      isTrue,
    );
    expect(
      sameSession(
        _session(1, '2026-11-08T14:30:00'),
        _session(1, '2026-11-09T14:30:00'),
      ),
      isFalse,
    );
  });

  test('a session shows what was kept, keeps what arrives, and can forget', () {
    fakeAsync((async) {
      unawaited(
        store.save(
          'cuff',
          const HealthHistory(bloodPressureReadings: [_reading]),
        ),
      );
      async.flushMicrotasks();
      const later = BloodPressureReadingDto(
        systolicMmhg: 118,
        diastolicMmhg: 78,
        measuredAt: '2026-11-09T08:00:00',
        convertedFromKpa: false,
      );
      final notify = StreamController<List<int>>.broadcast();
      HealthMeasurementSession open() => HealthMeasurementSession(
        ble: FakeBleService(notifyStream: notify.stream),
        codec: FakeHealthMeasurementCodec(
          // An empty frame decodes to no reading at all.
          sampleFor: (bytes) => bytes.isEmpty
              ? const HealthSampleDto()
              : const HealthSampleDto(bloodPressure: later),
        ),
        plan: _plan,
        deviceId: 'cuff',
        specYaml: 'spec',
        store: store,
      );

      final session = open();
      addTearDown(notify.close);
      // On screen before the cuff has said anything.
      expect(session.state.bloodPressureReadings, [_reading]);
      expect(session.hasSavedHistory, isTrue);

      session.start();
      async.flushMicrotasks();
      // A frame with no measurement is neither a reading nor an error.
      notify.add(const []);
      async.elapse(Duration.zero);
      expect(session.state.error, isNull);
      expect(session.state.bloodPressureReadings, [_reading]);

      notify.add([1]);
      async.elapse(Duration.zero);
      expect(session.state.bloodPressureReadings, [later, _reading]);
      session.dispose();
      async.flushMicrotasks();

      // The next connection starts from both.
      final again = open();
      expect(again.state.bloodPressureReadings, [later, _reading]);
      unawaited(again.clearSaved());
      async.flushMicrotasks();
      expect(again.state.bloodPressureReadings, isEmpty);
      expect(store.load('cuff').isEmpty, isTrue);
      again.dispose();
    });
  });
}
