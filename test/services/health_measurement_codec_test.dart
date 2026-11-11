// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/models/ble_discovered_service.dart';
import 'package:liberated_bread_mobile/models/health_measurement_plan.dart';
import 'package:liberated_bread_mobile/services/health_measurement_codec.dart';
import 'package:liberated_bread_mobile/services/real_spec_codec.dart';
import 'package:liberated_bread_mobile/services/spec_codec.dart';

import '../helpers/host_rust_lib.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final specCodec = RealSpecCodec();
  const healthCodec = RustHealthMeasurementCodec();
  late final bool rustReady;
  late final String f7Yaml;
  late final String po60Yaml;
  late final String bpYaml;
  late final DeviceSpecDto f7;
  late final DeviceSpecDto po60;
  late final DeviceSpecDto bp;

  setUpAll(() async {
    rustReady = await initHostRustLib();
    f7Yaml = await rootBundle.loadString(
      'vendor/protocol-specs/device-specs/devices/ble-pulse-oximeter.yaml',
    );
    po60Yaml = await rootBundle.loadString(
      'vendor/protocol-specs/device-specs/devices/beurer-po60-pulse-oximeter.yaml',
    );
    bpYaml = await rootBundle.loadString(
      'vendor/protocol-specs/device-specs/devices/beurer-series800-blood-pressure.yaml',
    );
    if (rustReady) {
      f7 = await specCodec.loadDeviceSpec(f7Yaml);
      po60 = await specCodec.loadDeviceSpec(po60Yaml);
      bp = await specCodec.loadDeviceSpec(bpYaml);
    }
  });

  test('catalogue hierarchy resolves live, history and saved-record plans', () {
    if (!rustReady) {
      markTestSkipped('Rust lib not loaded');
      return;
    }
    final live = healthMeasurementPlan(f7, _discovered(f7));
    final history = healthMeasurementPlan(po60, _discovered(po60));
    final saved = healthMeasurementPlan(bp, _discovered(bp));
    expect(live?.mode, HealthMeasurementMode.livePoll);
    expect(history?.mode, HealthMeasurementMode.historySync);
    expect(saved?.mode, HealthMeasurementMode.savedRecords);
    expect(live?.handledCharacteristicUuids, hasLength(2));
    expect(history?.handledCharacteristicUuids, hasLength(2));
    expect(saved?.handledCharacteristicUuids, isNotEmpty);
  });

  test(
    'a cuff whose record the decoder cannot read keeps its own cards',
    () async {
      if (!rustReady) {
        markTestSkipped('Rust lib not loaded');
        return;
      }
      // QardioArm has the same systolic/diastolic entities on 0x2A35, but
      // names each flag bit instead of a `flags` byte. Claimed by the panel,
      // its entity cards were hidden and no record ever decoded.
      final qardio = await specCodec.loadDeviceSpec(
        await rootBundle.loadString(
          'vendor/protocol-specs/device-specs/devices/qardio-arm.yaml',
        ),
      );
      expect(healthMeasurementPlan(qardio, _discovered(qardio)), isNull);
    },
  );

  test('F7 frame crosses the real FFI as a typed live sample', () async {
    if (!rustReady) {
      markTestSkipped('Rust lib not loaded');
      return;
    }
    final sample = await healthCodec.decodeSample(
      specYaml: f7Yaml,
      charUuid: '6e400003-b5a3-f393-e0a9-e50e24dcca9e',
      bytes: [0xAB, 0, 3, 0xFF, 0x30, 0x80, 72, 97, 15],
    );
    expect(sample.pulseOximeter?.spo2Percent, 97);
    expect(sample.pulseOximeter?.pulseBpm, 72);
    expect(sample.pulseOximeter?.perfusionIndexPercent, 1.5);
    expect(sample.bloodPressure, isNull);
  });

  test(
    'Beurer record crosses the real FFI with timestamp and record flags',
    () async {
      if (!rustReady) {
        markTestSkipped('Rust lib not loaded');
        return;
      }
      final sample = await healthCodec.decodeSample(
        specYaml: bpYaml,
        charUuid: '00002a35-0000-1000-8000-00805f9b34fb',
        bytes: [
          0x02,
          0x00,
          0x78,
          0x00,
          0x50,
          0x00,
          0x5D,
          0xEA,
          0x07,
          11,
          8,
          14,
          32,
          15,
          0x00,
          0x48,
          2,
          0,
          0x44,
        ],
      );
      final reading = sample.bloodPressure;
      expect(reading?.systolicMmhg, 120);
      expect(reading?.diastolicMmhg, 80);
      expect(reading?.pulseBpm, 72);
      expect(reading?.measuredAt, '2026-11-08T14:32:15');
      expect(reading?.irregularHeartbeat, isTrue);
      expect(reading?.sufficientRest, isTrue);
    },
  );

  test('PO60 history command and 24-byte record cross the real FFI', () async {
    if (!rustReady) {
      markTestSkipped('Rust lib not loaded');
      return;
    }
    final start = await healthCodec.encodeCommand(
      specYaml: po60Yaml,
      commandName: 'get_measurements_page',
      page: 0,
    );
    expect(start.bytes, [0x99, 0x00, 0x19]);

    final record = List<int>.filled(48, 0);
    for (var index = 0; index < 2; index++) {
      final offset = index * 24;
      record[offset] = 0xE9;
      record[offset + 1] = index == 0 ? 1 : 0x42;
      // The second, end-of-transfer record is a later session of its own.
      record.setRange(offset + 2, offset + 8, [26, 11, 8, 14 + index, 30, 1]);
      record.setRange(offset + 8, offset + 14, [26, 11, 8, 14 + index, 31, 2]);
      record[offset + 17] = 99;
      record[offset + 18] = 94;
      record[offset + 19] = 97;
      record[offset + 20] = 80;
      record[offset + 21] = 65;
      record[offset + 22] = 72;
    }
    final history = await healthCodec.decodeHistory(
      specYaml: po60Yaml,
      bytes: record,
    );
    expect(history.consumed, 48);
    expect(history.endOfTransfer, isTrue);
    // The record that ends the transfer carries the last session too.
    expect(history.sessions, hasLength(2));
    expect(history.skipped, 0);
    expect(history.sessions.first.spo2Avg, 97);
    expect(history.sessions.first.startedAt, '2026-11-08T14:30:01');
    expect(history.sessions.last.startedAt, '2026-11-08T15:30:01');
  });
}

List<BleDiscoveredService> _discovered(DeviceSpecDto spec) => [
  for (final service in spec.services)
    BleDiscoveredService(
      uuid: service.uuid,
      characteristics: [
        for (final char in service.characteristics)
          BleDiscoveredCharacteristic(
            uuid: char.uuid,
            canRead: char.canRead,
            canWrite: char.canWrite,
            canNotify: char.canNotify,
          ),
      ],
    ),
];
