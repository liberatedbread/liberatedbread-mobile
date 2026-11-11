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

  test('a live run is kept as a session of its least, most and average', () {
    fakeAsync((async) {
      var clockNow = DateTime(2026, 11, 10, 9);
      var spo2 = 96.0;
      final notify = StreamController<List<int>>.broadcast();
      addTearDown(notify.close);
      HealthMeasurementSession open() => HealthMeasurementSession(
        ble: FakeBleService(notifyStream: notify.stream),
        codec: FakeHealthMeasurementCodec(
          sampleFor: (_) => HealthSampleDto(
            pulseOximeter: PulseOxSampleDto(spo2Percent: spo2, pulseBpm: 70),
          ),
        ),
        plan: const HealthMeasurementPlan(
          kind: HealthMeasurementKind.pulseOximeter,
          mode: HealthMeasurementMode.livePoll,
          serviceUuid: 'health-service',
          commandUuid: 'command',
          responseUuid: 'health-response',
          handledCharacteristicUuids: {'health-response'},
        ),
        deviceId: 'oximeter',
        specYaml: 'spec',
        now: () => clockNow,
        store: store,
      );

      final session = open()..start();
      async.flushMicrotasks();
      for (var i = 0; i < 12; i++) {
        spo2 = i.isEven ? 96 : 98;
        notify.add([i]);
        async.elapse(Duration.zero);
        clockNow = clockNow.add(const Duration(seconds: 1));
      }
      expect(session.state.liveTrend, hasLength(12));
      // Nothing earlier to show yet: the run in progress is not "earlier".
      expect(session.state.sessions, isEmpty);
      session.dispose();
      async.flushMicrotasks();

      final kept = store.load('oximeter').sessions.single;
      expect(kept.startedAt, '2026-11-10T09:00:00');
      expect(kept.endedAt, '2026-11-10T09:00:11');
      expect((kept.spo2Min, kept.spo2Avg, kept.spo2Max), (96, 97, 98));
      expect(kept.pulseAvgBpm, 70);

      // The next connection offers it as an earlier session.
      final again = open();
      expect(again.state.sessions, [kept]);
      again.dispose();
    });
  });

  test('a few seconds of settling is not kept as a session', () {
    fakeAsync((async) {
      final notify = StreamController<List<int>>.broadcast();
      addTearDown(notify.close);
      final session = HealthMeasurementSession(
        ble: FakeBleService(notifyStream: notify.stream),
        codec: FakeHealthMeasurementCodec(
          sample: const HealthSampleDto(
            pulseOximeter: PulseOxSampleDto(spo2Percent: 97, pulseBpm: 70),
          ),
        ),
        plan: const HealthMeasurementPlan(
          kind: HealthMeasurementKind.pulseOximeter,
          mode: HealthMeasurementMode.livePoll,
          serviceUuid: 'health-service',
          commandUuid: 'command',
          responseUuid: 'health-response',
          handledCharacteristicUuids: {'health-response'},
        ),
        deviceId: 'oximeter',
        specYaml: 'spec',
        store: store,
      )..start();
      async.flushMicrotasks();
      notify.add([1]);
      async.elapse(Duration.zero);
      session.dispose();
      async.flushMicrotasks();
      expect(store.load('oximeter').isEmpty, isTrue);
    });
  });
}
