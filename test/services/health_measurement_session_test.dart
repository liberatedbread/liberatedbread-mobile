// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/models/health_measurement_plan.dart';
import 'package:liberated_bread_mobile/services/health_measurement_codec.dart';
import 'package:liberated_bread_mobile/services/health_measurement_session.dart';

import '../fakes/fake_ble_service.dart';
import '../fakes/fake_health_measurement_codec.dart';

const _response = 'health-response';

HealthMeasurementPlan _plan(HealthMeasurementMode mode) =>
    HealthMeasurementPlan(
      kind: mode == HealthMeasurementMode.savedRecords
          ? HealthMeasurementKind.bloodPressure
          : HealthMeasurementKind.pulseOximeter,
      mode: mode,
      serviceUuid: 'health-service',
      commandUuid: mode == HealthMeasurementMode.savedRecords
          ? null
          : 'command',
      responseUuid: _response,
      handledCharacteristicUuids: const {_response},
    );

void main() {
  test('live polling emits fresh values and marks the last sample stale', () {
    fakeAsync((async) {
      final notify = StreamController<List<int>>.broadcast();
      final now = DateTime(2026, 11, 8, 14, 30);
      var currentTime = now;
      final ble = FakeBleService(notifyStream: notify.stream);
      final codec = FakeHealthMeasurementCodec(
        sample: const HealthSampleDto(
          pulseOximeter: PulseOxSampleDto(
            spo2Percent: 97,
            pulseBpm: 72,
            perfusionIndexPercent: 1.5,
          ),
        ),
      );
      final session = HealthMeasurementSession(
        ble: ble,
        codec: codec,
        plan: _plan(HealthMeasurementMode.livePoll),
        deviceId: 'device',
        specYaml: 'spec',
        now: () => currentTime,
      );
      addTearDown(() {
        session.dispose();
        notify.close();
      });

      session.start();
      async.flushMicrotasks();
      expect(codec.commands.map((command) => command.commandName), [
        'poll_measurement',
      ]);
      expect(ble.subscriptions, [_response]);

      currentTime = now.add(const Duration(seconds: 1));
      notify.add([1]);
      async.elapse(Duration.zero);
      expect(session.state.phase, HealthSessionPhase.ready);
      expect(session.state.liveSample?.spo2Percent, 97);
      expect(session.state.lastSampleAt, currentTime);
      expect(session.state.stale, isFalse);

      currentTime = currentTime.add(const Duration(seconds: 6));
      async.elapse(const Duration(seconds: 6));
      expect(session.state.stale, isTrue);
      expect(session.state.liveSample?.pulseBpm, 72);
      unawaited(session.retry());
      async.flushMicrotasks();
      expect(session.state.stale, isTrue);
      expect(
        codec.commands
            .where((command) => command.commandName == 'poll_measurement')
            .length,
        greaterThan(1),
      );
    });
  });

  test('saved blood-pressure records are paired and deduplicated', () {
    fakeAsync((async) {
      final notify = StreamController<List<int>>.broadcast();
      const first = BloodPressureReadingDto(
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
      const second = BloodPressureReadingDto(
        systolicMmhg: 118,
        diastolicMmhg: 78,
        measuredAt: '2026-11-08T14:31:00',
        convertedFromKpa: false,
      );
      final codec = FakeHealthMeasurementCodec(
        sampleFor: (bytes) =>
            HealthSampleDto(bloodPressure: bytes.single == 1 ? first : second),
      );
      final ble = FakeBleService(notifyStream: notify.stream);
      final session = HealthMeasurementSession(
        ble: ble,
        codec: codec,
        plan: _plan(HealthMeasurementMode.savedRecords),
        deviceId: 'device',
        specYaml: 'spec',
      );
      addTearDown(() {
        session.dispose();
        notify.close();
      });

      session.start();
      async.flushMicrotasks();
      expect(ble.writes, isEmpty);
      notify.add([1]);
      async.elapse(Duration.zero);
      notify.add([1]);
      async.elapse(Duration.zero);
      expect(session.state.bloodPressureReadings, [first]);

      notify.add([2]);
      async.elapse(Duration.zero);
      expect(session.state.bloodPressureReadings, [second, first]);
      expect(session.state.phase, HealthSessionPhase.ready);
    });
  });

  test(
    'PO60 waits for clock ack, pages after 12 records and stops at the end',
    () {
      fakeAsync((async) {
        final notify = StreamController<List<int>>.broadcast();
        const sessionDto = PulseOxSessionDto(
          recordIndex: 1,
          startedAt: '2026-11-08T14:30:00',
          endedAt: '2026-11-08T14:31:00',
          spo2Min: 94,
          spo2Max: 99,
          spo2Avg: 97,
          pulseMinBpm: 65,
          pulseMaxBpm: 80,
          pulseAvgBpm: 72,
        );
        final chunks = <PulseOxHistoryChunkDto>[
          const PulseOxHistoryChunkDto(
            consumed: 2,
            sessions: [sessionDto],
            records: 12,
            skipped: 0,
            endOfTransfer: false,
          ),
          const PulseOxHistoryChunkDto(
            consumed: 1,
            sessions: [],
            records: 0,
            skipped: 0,
            endOfTransfer: true,
          ),
        ];
        final codec = FakeHealthMeasurementCodec(
          historyFor: (_) => chunks.removeAt(0),
        );
        final ble = FakeBleService(notifyStream: notify.stream);
        final session = HealthMeasurementSession(
          ble: ble,
          codec: codec,
          plan: _plan(HealthMeasurementMode.historySync),
          deviceId: 'device',
          specYaml: 'spec',
          now: () => DateTime(2026, 11, 8, 14, 32),
        );
        addTearDown(() {
          session.dispose();
          notify.close();
        });

        session.start();
        async.flushMicrotasks();
        expect(codec.commands.map((command) => command.commandName), [
          'set_datetime',
        ]);
        expect(codec.commands.single.clock?.year, 2026);
        expect(codec.commands.single.clock?.second, 0);

        notify.add([0xF3, 0x00]);
        async.elapse(Duration.zero);
        expect(codec.commands.map((command) => command.commandName), [
          'set_datetime',
          'get_measurements_page',
        ]);
        expect(codec.commands.last.page, 0);

        notify.add([1, 2]);
        async.elapse(Duration.zero);
        expect(session.state.sessions, [sessionDto]);
        expect(codec.commands.last.commandName, 'get_measurements_page');
        expect(codec.commands.last.page, 1);
        expect(session.state.phase, HealthSessionPhase.syncing);

        notify.add([3]);
        async.elapse(Duration.zero);
        expect(session.state.phase, HealthSessionPhase.ready);
        expect(chunks, isEmpty);
        expect(
          codec.commands.where((command) => command.page == 1),
          hasLength(1),
        );
      });
    },
  );

  test('PO60 waits for notification readiness before its clock write', () {
    fakeAsync((async) {
      final notify = StreamController<List<int>>.broadcast();
      final ready = Completer<void>();
      final codec = FakeHealthMeasurementCodec();
      final session = HealthMeasurementSession(
        ble: FakeBleService(
          notifyStream: notify.stream,
          notificationReadyCompleter: ready,
        ),
        codec: codec,
        plan: _plan(HealthMeasurementMode.historySync),
        deviceId: 'device',
        specYaml: 'spec',
      );
      addTearDown(() {
        session.dispose();
        notify.close();
      });

      session.start();
      async.flushMicrotasks();
      expect(codec.commands, isEmpty);
      ready.complete();
      async.flushMicrotasks();
      expect(codec.commands.map((command) => command.commandName), [
        'set_datetime',
      ]);
    });
  });

  test('PO60 timeout does not start history without a clock ack', () {
    fakeAsync((async) {
      final notify = StreamController<List<int>>.broadcast();
      final codec = FakeHealthMeasurementCodec();
      final ble = FakeBleService(notifyStream: notify.stream);
      final session = HealthMeasurementSession(
        ble: ble,
        codec: codec,
        plan: _plan(HealthMeasurementMode.historySync),
        deviceId: 'device',
        specYaml: 'spec',
      );
      addTearDown(() {
        session.dispose();
        notify.close();
      });

      session.start();
      async.elapse(const Duration(seconds: 16));
      expect(session.state.phase, HealthSessionPhase.error);
      expect(session.state.error, contains('Could not sync'));
      expect(codec.commands, hasLength(1));
      expect(codec.commands.single.commandName, 'set_datetime');
      expect(codec.historyCalls, isEmpty);
    });
  });

  test('late PO60 data does not silently clear an earlier timeout', () {
    fakeAsync((async) {
      final notify = StreamController<List<int>>.broadcast();
      const sessionDto = PulseOxSessionDto(
        recordIndex: 1,
        startedAt: '2026-11-08T14:30:00',
        endedAt: '2026-11-08T14:31:00',
        spo2Min: 94,
        spo2Max: 99,
        spo2Avg: 97,
        pulseMinBpm: 65,
        pulseMaxBpm: 80,
        pulseAvgBpm: 72,
      );
      final codec = FakeHealthMeasurementCodec(
        historyFor: (bytes) => PulseOxHistoryChunkDto(
          consumed: bytes.length,
          sessions: const [sessionDto],
          records: 0,
          skipped: 0,
          endOfTransfer: false,
        ),
      );
      final session = HealthMeasurementSession(
        ble: FakeBleService(notifyStream: notify.stream),
        codec: codec,
        plan: _plan(HealthMeasurementMode.historySync),
        deviceId: 'device',
        specYaml: 'spec',
        syncTimeout: const Duration(seconds: 1),
      );
      addTearDown(() {
        session.dispose();
        notify.close();
      });

      session.start();
      async.flushMicrotasks();
      notify.add([0xF3, 0x00]);
      async.elapse(Duration.zero);
      async.elapse(const Duration(seconds: 2));
      expect(session.state.phase, HealthSessionPhase.error);
      final timeoutMessage = session.state.error;

      notify.add([1, 2, 3]);
      async.elapse(Duration.zero);
      expect(session.state.sessions, [sessionDto]);
      expect(session.state.phase, HealthSessionPhase.error);
      expect(session.state.error, timeoutMessage);
    });
  });

  test(
    'disconnect keeps received readings and says why they are not live',
    () async {
      final notify = StreamController<List<int>>.broadcast();
      const reading = BloodPressureReadingDto(
        systolicMmhg: 120,
        diastolicMmhg: 80,
        convertedFromKpa: false,
      );
      final session = HealthMeasurementSession(
        ble: FakeBleService(notifyStream: notify.stream),
        codec: FakeHealthMeasurementCodec(
          sample: const HealthSampleDto(bloodPressure: reading),
        ),
        plan: _plan(HealthMeasurementMode.savedRecords),
        deviceId: 'device',
        specYaml: 'spec',
      );
      addTearDown(session.dispose);

      session.start();
      await Future<void>.delayed(Duration.zero);
      notify.add([1]);
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      expect(session.state.bloodPressureReadings, [reading]);
      await notify.close();
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      expect(session.state.phase, HealthSessionPhase.error);
      expect(session.state.error, contains('received so far'));
      expect(session.state.bloodPressureReadings, [reading]);
    },
  );

  test('decode failures do not echo raw health bytes into the UI', () {
    fakeAsync((async) {
      final notify = StreamController<List<int>>.broadcast();
      final codec = FakeHealthMeasurementCodec(
        decodeError: const FormatException('bad packet'),
      );
      final session = HealthMeasurementSession(
        ble: FakeBleService(notifyStream: notify.stream),
        codec: codec,
        plan: _plan(HealthMeasurementMode.savedRecords),
        deviceId: 'device',
        specYaml: 'spec',
      );
      addTearDown(() {
        session.dispose();
        notify.close();
      });

      session.start();
      notify.add([1, 2, 3]);
      async.elapse(Duration.zero);
      expect(session.state.phase, HealthSessionPhase.error);
      expect(session.state.error, contains('could not decode'));
      expect(session.state.error, isNot(contains('[1, 2, 3]')));
      expect(session.state.bloodPressureReadings, isEmpty);
    });
  });
}
