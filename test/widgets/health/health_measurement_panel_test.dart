// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/core/health_reference.dart';
import 'package:liberated_bread_mobile/core/web_link.dart';
import 'package:liberated_bread_mobile/models/health_measurement_plan.dart';
import 'package:liberated_bread_mobile/providers/ble_provider.dart';
import 'package:liberated_bread_mobile/providers/health_measurement_codec_provider.dart';
import 'package:liberated_bread_mobile/services/health_measurement_codec.dart';
import 'package:liberated_bread_mobile/services/spec_codec.dart';
import 'package:liberated_bread_mobile/widgets/health/health_measurement_panel.dart';
import 'package:liberated_bread_mobile/widgets/health/measurement_trend_chart.dart';

import '../../fakes/fake_ble_service.dart';
import '../../fakes/fake_health_measurement_codec.dart';

DeviceSpecDto _spec({String manufacturer = 'Beurer GmbH'}) => DeviceSpecDto(
  deviceName: 'Test health device',
  manufacturer: manufacturer,
  manufacturerStatus: 'active',
  protocol: 'ble',
  category: 'health',
  categoryHierarchy: const ['measurement', 'health', 'pulse_oximetry'],
  localNamePrefixes: const [],
  localNames: const [],
  serviceUuids: const [],
  companyIds: Uint16List(0),
  macPrefixes: const [],
  mdnsServiceTypes: const [],
  ssdpSearchTargets: const [],
  lanProtocols: const [],
  nameMatchers: const [],
  txtMatchGroups: const [],
  platformFallbackTypes: const [],
  services: const [],
  entities: const [],
  hiddenEntityNames: const [],
);

HealthMeasurementPlan _plan(HealthMeasurementMode mode) =>
    HealthMeasurementPlan(
      kind: mode == HealthMeasurementMode.savedRecords
          ? HealthMeasurementKind.bloodPressure
          : HealthMeasurementKind.pulseOximeter,
      mode: mode,
      serviceUuid: 'service',
      commandUuid: mode == HealthMeasurementMode.savedRecords
          ? null
          : 'command',
      responseUuid: 'response',
      handledCharacteristicUuids: const {'response'},
    );

Widget _wrap({
  required HealthMeasurementMode mode,
  required FakeBleService ble,
  required FakeHealthMeasurementCodec codec,
  DeviceSpecDto? spec,
  DateTime Function()? now,
  LinkLauncher? launcher,
}) => ProviderScope(
  overrides: [
    bleServiceProvider.overrideWithValue(ble),
    healthMeasurementCodecProvider.overrideWithValue(codec),
  ],
  child: MaterialApp(
    home: Scaffold(
      body: SingleChildScrollView(
        child: SizedBox(
          width: 340,
          child: HealthMeasurementPanel(
            deviceId: 'device',
            specYaml: 'yaml',
            spec: spec ?? _spec(),
            plan: _plan(mode),
            now: now,
            linkLauncher: launcher ?? (_) async => true,
          ),
        ),
      ),
    ),
  ),
);

PulseOxSessionDto _session(int index, int spo2, int pulse) => PulseOxSessionDto(
  recordIndex: index,
  startedAt: '2026-11-08T14:${30 + index}:00',
  endedAt: '2026-11-08T14:${31 + index}:00',
  spo2Min: spo2 - 2,
  spo2Max: spo2 + 1,
  spo2Avg: spo2,
  pulseMinBpm: pulse - 5,
  pulseMaxBpm: pulse + 5,
  pulseAvgBpm: pulse,
);

void main() {
  testWidgets('live pulse values go stale without losing the last sample', (
    tester,
  ) async {
    final notify = StreamController<List<int>>.broadcast();
    addTearDown(notify.close);
    var now = DateTime(2026, 11, 8, 14, 32, 15);
    final codec = FakeHealthMeasurementCodec(
      sample: const HealthSampleDto(
        pulseOximeter: PulseOxSampleDto(
          spo2Percent: 97,
          pulseBpm: 72,
          perfusionIndexPercent: 1.5,
        ),
      ),
    );
    await tester.pumpWidget(
      _wrap(
        mode: HealthMeasurementMode.livePoll,
        ble: FakeBleService(notifyStream: notify.stream),
        codec: codec,
        now: () => now,
      ),
    );
    await tester.pump();
    notify.add([1]);
    await tester.pump();
    await tester.pump();

    expect(find.text('97'), findsOneWidget);
    expect(find.text('72'), findsOneWidget);
    expect(find.text('Perfusion index 1.5%'), findsOneWidget);
    expect(find.text('Last sample 14:32:15'), findsOneWidget);
    expect(find.text('Common adult range'), findsOneWidget);
    expect(find.text('Normal range'), findsOneWidget);
    expect(find.text('Good'), findsNothing);

    now = now.add(const Duration(seconds: 6));
    await tester.pump(const Duration(seconds: 6));
    await tester.pump();
    expect(find.textContaining('Stale sample'), findsOneWidget);
    expect(find.text('97'), findsOneWidget);
  });

  testWidgets('source sheet explains both scales and opens the NIH source', (
    tester,
  ) async {
    final notify = StreamController<List<int>>.broadcast();
    addTearDown(notify.close);
    final opened = <Uri>[];
    final codec = FakeHealthMeasurementCodec(
      sample: const HealthSampleDto(
        pulseOximeter: PulseOxSampleDto(spo2Percent: 97, pulseBpm: 72),
      ),
    );
    await tester.pumpWidget(
      _wrap(
        mode: HealthMeasurementMode.livePoll,
        ble: FakeBleService(notifyStream: notify.stream),
        codec: codec,
        launcher: (uri) async {
          opened.add(uri);
          return true;
        },
      ),
    );
    await tester.pump();
    notify.add([1]);
    await tester.pump();
    await tester.pump();
    await tester.tap(find.text('Ranges & sources'));
    await tester.pumpAndSettle();

    expect(find.text('Pulse-oximetry references'), findsOneWidget);
    expect(find.text('94–99% SpO₂'), findsOneWidget);
    expect(find.text('95–100% SpO₂'), findsOneWidget);
    expect(find.textContaining('pre-existing conditions'), findsOneWidget);
    await tester.tap(find.text('Open public source').first);
    await tester.pump();
    expect(opened.single.toString(), nihPulseOximetryUrl);
  });

  testWidgets('PO60 renders stored summaries and trends, not a live waveform', (
    tester,
  ) async {
    final notify = StreamController<List<int>>.broadcast();
    addTearDown(notify.close);
    final sessions = [_session(0, 96, 70), _session(1, 98, 74)];
    final codec = FakeHealthMeasurementCodec(
      historyFor: (bytes) => PulseOxHistoryChunkDto(
        consumed: bytes.length,
        sessions: sessions,
        records: 2,
        skipped: 0,
        endOfTransfer: true,
      ),
    );
    await tester.pumpWidget(
      _wrap(
        mode: HealthMeasurementMode.historySync,
        ble: FakeBleService(notifyStream: notify.stream),
        codec: codec,
      ),
    );
    await tester.pump();
    notify.add([0xF3, 0x00]);
    await tester.pump();
    await tester.pump();
    notify.add([1, 2, 3]);
    await tester.pump();
    await tester.pump();

    expect(find.text('2 stored sessions'), findsOneWidget);
    expect(find.text('98%'), findsOneWidget);
    expect(find.text('74 bpm'), findsOneWidget);
    expect(find.text('Earlier sessions (1)'), findsOneWidget);
    expect(find.byType(MeasurementTrendChart), findsNWidgets(2));
    expect(find.text('SpO₂ session averages'), findsOneWidget);
    expect(find.text('Pulse session averages'), findsOneWidget);
    expect(find.text('Live waveform'), findsNothing);
  });

  testWidgets('blood pressure keeps NIH and Beurer categories separate', (
    tester,
  ) async {
    final notify = StreamController<List<int>>.broadcast();
    addTearDown(notify.close);
    const reading = BloodPressureReadingDto(
      systolicMmhg: 135,
      diastolicMmhg: 85,
      meanArterialMmhg: 101,
      pulseBpm: 72,
      measuredAt: '2026-11-08T14:32:15',
      userSlot: 2,
      irregularHeartbeat: true,
      sufficientRest: false,
      convertedFromKpa: false,
    );
    final codec = FakeHealthMeasurementCodec(
      sample: const HealthSampleDto(bloodPressure: reading),
    );
    await tester.pumpWidget(
      _wrap(
        mode: HealthMeasurementMode.savedRecords,
        ble: FakeBleService(notifyStream: notify.stream),
        codec: codec,
      ),
    );
    await tester.pump();
    notify.add([1]);
    await tester.pump();
    await tester.pump();

    expect(find.text('135/85'), findsOneWidget);
    expect(find.text('Pulse 72 bpm'), findsOneWidget);
    expect(find.text('MAP 101 mmHg'), findsOneWidget);
    expect(find.text('User slot 2'), findsOneWidget);
    expect(find.text('High blood pressure · stage 1'), findsOneWidget);
    expect(find.text('High normal'), findsOneWidget);
    expect(
      find.textContaining('Irregular-heartbeat flag is set'),
      findsOneWidget,
    );
    expect(find.text('Monitor reports insufficient rest'), findsOneWidget);
    expect(find.byType(MeasurementTrendChart), findsNothing);
  });

  testWidgets('two timestamped blood-pressure records make one paired trend', (
    tester,
  ) async {
    final notify = StreamController<List<int>>.broadcast();
    addTearDown(notify.close);
    final readings = [
      const BloodPressureReadingDto(
        systolicMmhg: 118,
        diastolicMmhg: 76,
        measuredAt: '2026-11-08T14:31:00',
        convertedFromKpa: false,
      ),
      const BloodPressureReadingDto(
        systolicMmhg: 120,
        diastolicMmhg: 78,
        measuredAt: '2026-11-08T14:30:00',
        convertedFromKpa: false,
      ),
    ];
    final codec = FakeHealthMeasurementCodec(
      sampleFor: (bytes) =>
          HealthSampleDto(bloodPressure: readings[bytes.single - 1]),
    );
    await tester.pumpWidget(
      _wrap(
        mode: HealthMeasurementMode.savedRecords,
        ble: FakeBleService(notifyStream: notify.stream),
        codec: codec,
      ),
    );
    await tester.pump();
    notify.add([2]);
    await tester.pump();
    await tester.pump();
    notify.add([1]);
    await tester.pump();
    await tester.pump();
    notify.add([1]);
    await tester.pump();
    await tester.pump();

    expect(find.text('118/76'), findsOneWidget);
    expect(find.byType(MeasurementTrendChart), findsOneWidget);
    expect(find.text('Recorded blood pressure'), findsOneWidget);
    expect(find.text('Earlier readings (1)'), findsOneWidget);
  });

  testWidgets('blood-pressure trends stay separate by monitor user slot', (
    tester,
  ) async {
    final notify = StreamController<List<int>>.broadcast();
    addTearDown(notify.close);
    final readings = [
      const BloodPressureReadingDto(
        systolicMmhg: 120,
        diastolicMmhg: 80,
        measuredAt: '2026-11-08T14:30:00',
        userSlot: 1,
        convertedFromKpa: false,
      ),
      const BloodPressureReadingDto(
        systolicMmhg: 122,
        diastolicMmhg: 81,
        measuredAt: '2026-11-08T14:31:00',
        userSlot: 1,
        convertedFromKpa: false,
      ),
      const BloodPressureReadingDto(
        systolicMmhg: 130,
        diastolicMmhg: 85,
        measuredAt: '2026-11-08T14:32:00',
        userSlot: 2,
        convertedFromKpa: false,
      ),
      const BloodPressureReadingDto(
        systolicMmhg: 128,
        diastolicMmhg: 83,
        measuredAt: '2026-11-08T14:33:00',
        userSlot: 2,
        convertedFromKpa: false,
      ),
    ];
    final codec = FakeHealthMeasurementCodec(
      sampleFor: (bytes) =>
          HealthSampleDto(bloodPressure: readings[bytes.single - 1]),
    );
    await tester.pumpWidget(
      _wrap(
        mode: HealthMeasurementMode.savedRecords,
        ble: FakeBleService(notifyStream: notify.stream),
        codec: codec,
      ),
    );
    await tester.pump();
    for (var index = 1; index <= readings.length; index++) {
      notify.add([index]);
      await tester.pump();
      await tester.pump();
    }

    expect(find.byType(MeasurementTrendChart), findsNWidgets(2));
    expect(find.text('Recorded blood pressure · User 1'), findsOneWidget);
    expect(find.text('Recorded blood pressure · User 2'), findsOneWidget);
    expect(find.text('Recorded blood pressure'), findsNothing);
  });

  testWidgets('a narrow live panel has no layout overflow', (tester) async {
    tester.view.physicalSize = const Size(320, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final notify = StreamController<List<int>>.broadcast();
    addTearDown(notify.close);
    final codec = FakeHealthMeasurementCodec(
      sample: const HealthSampleDto(
        pulseOximeter: PulseOxSampleDto(
          spo2Percent: 97,
          pulseBpm: 72,
          perfusionIndexPercent: 1.5,
        ),
      ),
    );
    await tester.pumpWidget(
      _wrap(
        mode: HealthMeasurementMode.livePoll,
        ble: FakeBleService(notifyStream: notify.stream),
        codec: codec,
      ),
    );
    await tester.pump();
    notify.add([1]);
    await tester.pump();
    await tester.pump();
    expect(tester.takeException(), isNull);
  });
}
