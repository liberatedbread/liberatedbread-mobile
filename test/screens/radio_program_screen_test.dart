// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/models/channel_plan.dart';
import 'package:liberated_bread_mobile/models/iot_device.dart';
import 'package:liberated_bread_mobile/models/radio_channel.dart';
import 'package:liberated_bread_mobile/models/radio_profile.dart';
import 'package:liberated_bread_mobile/models/radio_target.dart';
import 'package:liberated_bread_mobile/providers/ble_provider.dart';
import 'package:liberated_bread_mobile/providers/radio_programmer_provider.dart';
import 'package:liberated_bread_mobile/providers/saved_device_provider.dart';
import 'package:liberated_bread_mobile/providers/saved_radio_provider.dart';
import 'package:liberated_bread_mobile/providers/serial_port_provider.dart';
import 'package:liberated_bread_mobile/screens/radio_program_screen.dart';
import 'package:liberated_bread_mobile/services/baofeng_ble_programmer.dart';
import 'package:liberated_bread_mobile/services/mock_serial_port_service.dart';
import 'package:liberated_bread_mobile/services/radio_programmer.dart';
import 'package:liberated_bread_mobile/services/serial_port_service.dart';
import 'package:liberated_bread_mobile/services/unsupported_serial_port_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../fakes/fake_ble_service.dart';
import '../fakes/fake_codeplug_backup_store.dart';
import '../fakes/fake_radio_programmer.dart';

late SharedPreferences _prefs;

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

class _Harness {
  final FakeRadioProgrammer programmer;
  final FakeCodeplugBackupStore backups;

  _Harness(this.programmer, this.backups);
}

Future<_Harness> _pump(
  WidgetTester tester, {
  List<IoTDevice> devices = const [],
  FakeRadioProgrammer? programmer,
  RadioProfile profile = uv5rMiniProfile,
  RadioTarget? target,
}) async {
  final prog = programmer ?? FakeRadioProgrammer();
  final backups = FakeCodeplugBackupStore();

  await tester.pumpWidget(ProviderScope(
    overrides: [
      bleServiceProvider
          .overrideWithValue(FakeBleService(devicesToEmit: devices)),
      radioProgrammerProvider.overrideWithValue(prog),
      codeplugBackupStoreProvider.overrideWithValue(backups),
      sharedPreferencesProvider.overrideWithValue(_prefs),
    ],
    child: MaterialApp(
      home: RadioProgramScreen(
        plan: _plan(),
        profile: profile,
        target: target,
      ),
    ),
  ));
  await tester.pumpAndSettle();
  return _Harness(prog, backups);
}

/// The confirm dialog's Write, as opposed to the target row's.
Finder get _dialogWrite => find.descendant(
      of: find.byType(AlertDialog),
      matching: find.widgetWithText(FilledButton, 'Write'),
    );

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    _prefs = await SharedPreferences.getInstance();
  });

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
    // It once promised a restore "from the Radio tab", which had none. The
    // restore lives on the radio's own screen, and the dialog says so.
    expect(find.textContaining('Restore a backup'), findsOneWidget);
    expect(find.textContaining('Radio tab'), findsNothing);

    await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
    await tester.pumpAndSettle();

    expect(harness.programmer.readCalls, 0);
    expect(harness.programmer.written, isEmpty);
  });

  testWidgets('reads, backs up, then writes — in that order', (tester) async {
    final harness = await _pump(tester, devices: [_radio()]);

    await tester.tap(find.text('UV-5R Mini'));
    await tester.pumpAndSettle();
    await tester.tap(_dialogWrite);
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
    await tester.tap(_dialogWrite);
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
    await _pump(tester, profile: uv32Profile);

    expect(uv32Profile.programmerSupport, ProgrammerSupport.unverified);
    expect(find.textContaining('not been confirmed on this exact model'),
        findsOneWidget);
  });

  testWidgets('a radio that answers is saved, with the model it was used as',
      (tester) async {
    await _pump(tester, devices: [_radio()]);

    await tester.tap(find.text('UV-5R Mini'));
    await tester.pumpAndSettle();
    await tester.tap(_dialogWrite);
    await tester.pumpAndSettle();

    final container = ProviderScope.containerOf(
        tester.element(find.byType(RadioProgramScreen)));
    final saved = container.read(savedRadiosProvider).single;
    expect(saved.transport, RadioTransport.ble);
    expect(saved.id, 'AA:BB:CC:DD:EE:99');
    expect(saved.radioProfileId, uv5rMiniProfile.id);
  });

  testWidgets('a failed session does not save the radio', (tester) async {
    await _pump(
      tester,
      devices: [_radio()],
      programmer: FakeRadioProgrammer(error: const RadioTimeoutException()),
    );

    await tester.tap(find.text('UV-5R Mini'));
    await tester.pumpAndSettle();
    await tester.tap(_dialogWrite);
    await tester.pumpAndSettle();

    final container = ProviderScope.containerOf(
        tester.element(find.byType(RadioProgramScreen)));
    expect(container.read(savedRadiosProvider), isEmpty);
  });

  group('handed a radio', () {
    const target = RadioTarget(
      transport: RadioTransport.ble,
      id: 'AA:BB:CC:DD:EE:01',
      name: 'Base radio',
    );

    testWidgets('does not scan, and offers only that radio', (tester) async {
      await _pump(
        tester,
        target: target,
        // Were it scanning, this one would be listed.
        devices: [_radio(name: 'UV-5R Mini')],
      );

      expect(find.text('Base radio'), findsOneWidget);
      expect(find.text('UV-5R Mini'), findsNothing);
      expect(find.text('Radios nearby'), findsNothing);
      expect(find.textContaining('Press Write'), findsOneWidget);
    });

    testWidgets('writes to exactly that radio', (tester) async {
      final harness = await _pump(tester, target: target);

      await tester.tap(find.widgetWithText(FilledButton, 'Write'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Write to Base radio?'), findsOneWidget);
      await tester.tap(_dialogWrite);
      await tester.pumpAndSettle();

      expect(harness.programmer.written, hasLength(1));
      expect(harness.programmer.deviceIds.toSet(), {target.id});
      expect(find.textContaining('written to Base radio'), findsOneWidget);
    });
  });

  group('a cable radio', () {
    Future<FakeRadioProgrammer> pumpCable(
      WidgetTester tester, {
      required SerialPortService ports,
      FakeBleService? ble,
    }) async {
      final cable = FakeRadioProgrammer();
      await tester.pumpWidget(ProviderScope(
        overrides: [
          bleServiceProvider.overrideWithValue(ble ?? FakeBleService()),
          radioProgrammerProvider.overrideWithValue(FakeRadioProgrammer()),
          serialRadioProgrammerProvider.overrideWithValue(cable),
          serialPortServiceProvider.overrideWithValue(ports),
          codeplugBackupStoreProvider
              .overrideWithValue(FakeCodeplugBackupStore()),
          sharedPreferencesProvider.overrideWithValue(_prefs),
        ],
        child: MaterialApp(
          home: RadioProgramScreen(plan: _plan(), profile: uv5rProfile),
        ),
      ));
      await tester.pumpAndSettle();
      return cable;
    }

    testWidgets('lists the cables plugged in, and does not scan the air',
        (tester) async {
      final ble = FakeBleService(devicesToEmit: [_radio(name: 'UV-5R Mini')]);
      await pumpCable(tester, ports: MockSerialPortService(), ble: ble);

      expect(find.text('Cables'), findsOneWidget);
      expect(find.text('Demo programming cable'), findsOneWidget);
      expect(find.text('Radios nearby'), findsNothing);
      expect(find.text('UV-5R Mini'), findsNothing);
      expect(find.textContaining('Pick the cable'), findsOneWidget);
    });

    testWidgets('writes through the cable driver, to the cable picked',
        (tester) async {
      final cable = await pumpCable(tester, ports: MockSerialPortService());

      await tester.tap(find.text('Demo programming cable'));
      await tester.pumpAndSettle();
      await tester.tap(_dialogWrite);
      await tester.pumpAndSettle();

      expect(cable.written, hasLength(1));
      expect(cable.deviceIds.toSet(), {MockSerialPortService.demoCable.id});
    });

    testWidgets('with no cable plugged in, says how to plug one in',
        (tester) async {
      await pumpCable(tester, ports: _NoPorts());
      expect(find.textContaining('No cable found'), findsOneWidget);
      expect(find.textContaining('USB-OTG'), findsOneWidget);
    });

    testWidgets('on a platform with no serial ports, says why', (tester) async {
      await pumpCable(
        tester,
        ports: const UnsupportedSerialPortService(
            UnsupportedSerialPortService.iosReason),
      );
      expect(find.textContaining('iPhone and iPad'), findsOneWidget);
      expect(find.textContaining('No cable found'), findsNothing);
    });
  });
}

class _NoPorts implements SerialPortService {
  @override
  SerialAvailability get availability => const SerialAvailability.supported();

  @override
  Future<List<SerialPortInfo>> listPorts() async => const [];

  @override
  Future<SerialLink> open(SerialPortInfo port, {required int baudRate}) =>
      Future.error(const SerialPortException('no ports'));
}
