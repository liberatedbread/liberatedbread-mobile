// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/models/channel_plan.dart';
import 'package:liberated_bread_mobile/models/iot_device.dart';
import 'package:liberated_bread_mobile/models/radio_channel.dart';
import 'package:liberated_bread_mobile/models/radio_profile.dart';
import 'package:liberated_bread_mobile/providers/ble_provider.dart';
import 'package:liberated_bread_mobile/providers/radio_programmer_provider.dart';
import 'package:liberated_bread_mobile/screens/radio_program_screen.dart';
import 'package:liberated_bread_mobile/services/baofeng_ble_programmer.dart';
import 'package:liberated_bread_mobile/services/codeplug_backup_store.dart';
import 'package:liberated_bread_mobile/services/radio_programmer.dart';

import '../fakes/fake_ble_service.dart';
import '../fakes/fake_radio_programmer.dart';

IoTDevice _radio({
  String id = 'AA:BB:CC:DD:EE:99',
  String name = 'UV-5R Mini',
  List<String> services = const [],
}) =>
    IoTDevice(
      id: id,
      name: name,
      rssi: -50,
      isConnectable: true,
      discoveredAt: DateTime.utc(2026, 8),
      serviceUuids: services,
    );

ChannelPlan _plan() => ChannelPlan(
      id: 'p1',
      name: 'Local repeaters',
      radioProfileId: 'uv-5r-mini',
      channels: const [
        RadioChannel(name: 'W1AW', rxFreqHz: 146940000, txFreqHz: 146340000),
      ],
      createdAt: DateTime.utc(2026, 8),
      modifiedAt: DateTime.utc(2026, 8),
    );

/// A backup store that keeps everything in memory.
///
/// `testWidgets` runs its body inside a fake-async zone where real file I/O
/// never completes -- a disk write in a screen test is not a slow test, it is
/// a hang. The store's own suite covers the filesystem; what this screen test
/// is for is whether the backup happens before the write.
class _FakeBackupStore implements CodeplugBackupStore {
  final List<RadioCodeplug> saved = [];

  @override
  Future<CodeplugBackup> save(RadioCodeplug codeplug) async {
    saved.add(codeplug);
    return CodeplugBackup(
      file: File('/in-memory/${codeplug.modelId}_1.bin'),
      modelId: codeplug.modelId,
      takenAt: codeplug.readAt,
      length: codeplug.length,
    );
  }

  @override
  Future<List<CodeplugBackup>> list() async => [
        for (final codeplug in saved)
          CodeplugBackup(
            file: File('/in-memory/${codeplug.modelId}_1.bin'),
            modelId: codeplug.modelId,
            takenAt: codeplug.readAt,
            length: codeplug.length,
          ),
      ];

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Harness {
  final FakeRadioProgrammer programmer;
  final _FakeBackupStore backups;

  _Harness(this.programmer, this.backups);
}

Future<_Harness> _pump(
  WidgetTester tester, {
  List<IoTDevice> devices = const [],
  FakeRadioProgrammer? programmer,
}) async {
  final prog = programmer ?? FakeRadioProgrammer();
  final backups = _FakeBackupStore();

  await tester.pumpWidget(ProviderScope(
    overrides: [
      bleServiceProvider
          .overrideWithValue(FakeBleService(devicesToEmit: devices)),
      radioProgrammerProvider.overrideWithValue(prog),
      codeplugBackupStoreProvider.overrideWithValue(backups),
    ],
    child: MaterialApp(
      home: RadioProgramScreen(plan: _plan(), profile: uv5rMiniProfile),
    ),
  ));
  await tester.pumpAndSettle();
  return _Harness(prog, backups);
}

void main() {
  testWidgets('says what will happen before anything does', (tester) async {
    await _pump(tester);
    expect(find.textContaining('Local repeaters'), findsOneWidget);
    expect(find.textContaining('read first'), findsOneWidget);
    expect(find.textContaining('put back'), findsOneWidget);
  });

  testWidgets('lists radios it recognises and ignores everything else',
      (tester) async {
    await _pump(
      tester,
      devices: [
        _radio(name: 'UV-5R Mini'),
        _radio(id: 'BB:00', name: 'ACME_Living_Room'),
        _radio(id: 'CC:00', name: 'anonymous', services: [baofengUartService]),
      ],
    );

    expect(find.text('UV-5R Mini'), findsOneWidget);
    // Matched on its advertised service rather than its name.
    expect(find.text('anonymous'), findsOneWidget);
    expect(find.text('ACME_Living_Room'), findsNothing);
  });

  testWidgets('says what to do when nothing turns up', (tester) async {
    await _pump(tester);
    expect(find.textContaining('No radios found'), findsOneWidget);
    expect(find.textContaining('its own menu'), findsOneWidget);
  });

  testWidgets('asks before writing, and cancelling writes nothing',
      (tester) async {
    final harness = await _pump(tester, devices: [_radio()]);

    await tester.tap(find.text('UV-5R Mini'));
    await tester.pumpAndSettle();

    expect(find.textContaining('Write to UV-5R Mini?'), findsOneWidget);
    expect(find.textContaining('saved first'), findsOneWidget);

    await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
    await tester.pumpAndSettle();

    expect(harness.programmer.readCalls, 0);
    expect(harness.programmer.written, isEmpty);
  });

  testWidgets('reads, backs up, then writes — in that order', (tester) async {
    final harness = await _pump(tester, devices: [_radio()]);

    await tester.tap(find.text('UV-5R Mini'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Write'));
    await tester.pumpAndSettle();

    expect(harness.programmer.readCalls, 1);
    expect(harness.programmer.written, hasLength(1));
    expect(harness.programmer.written.single.single.name, 'W1AW');

    // The backup exists on disk, not merely in a message.
    final saved = await harness.backups.list();
    expect(saved, hasLength(1));
    expect(saved.single.length, 0x8240);

    expect(find.textContaining('1 channels written'), findsOneWidget);
    expect(find.textContaining('Backup saved as'), findsOneWidget);
  });

  testWidgets('a failure explains itself and leaves no backup claim',
      (tester) async {
    final harness = await _pump(
      tester,
      devices: [_radio()],
      programmer: FakeRadioProgrammer(error: const RadioTimeoutException()),
    );

    await tester.tap(find.text('UV-5R Mini'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Write'));
    await tester.pumpAndSettle();

    expect(find.textContaining('stopped responding'), findsWidgets);
    expect(await harness.backups.list(), isEmpty);
    expect(harness.programmer.written, isEmpty);
  });

  testWidgets('refuses a radio the programmer cannot drive', (tester) async {
    final harness = await _pump(
      tester,
      devices: [_radio()],
      programmer: FakeRadioProgrammer(supported: false),
    );

    await tester.tap(find.text('UV-5R Mini'));
    await tester.pumpAndSettle();

    expect(find.textContaining('cannot program that radio'), findsOneWidget);
    expect(harness.programmer.readCalls, 0);
    // ...and it never even asked.
    expect(find.textContaining('Write to'), findsNothing);
  });

  testWidgets('an unconfirmed model says so before it is used', (tester) async {
    final backups = _FakeBackupStore();
    await tester.pumpWidget(ProviderScope(
      overrides: [
        bleServiceProvider.overrideWithValue(FakeBleService()),
        radioProgrammerProvider.overrideWithValue(FakeRadioProgrammer()),
        codeplugBackupStoreProvider.overrideWithValue(backups),
      ],
      child: MaterialApp(
        home: RadioProgramScreen(plan: _plan(), profile: uv32Profile),
      ),
    ));
    await tester.pumpAndSettle();

    expect(uv32Profile.programmerSupport, ProgrammerSupport.unverified);
    expect(find.textContaining('not been confirmed on this exact model'),
        findsOneWidget);
  });
}
