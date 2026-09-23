// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/models/radio_target.dart';
import 'package:liberated_bread_mobile/providers/radio_programmer_provider.dart';
import 'package:liberated_bread_mobile/providers/saved_device_provider.dart';
import 'package:liberated_bread_mobile/providers/serial_port_provider.dart';
import 'package:liberated_bread_mobile/providers/spec_pack_provider.dart';
import 'package:liberated_bread_mobile/screens/radio_device_screen.dart';
import 'package:liberated_bread_mobile/screens/radio_program_screen.dart';
import 'package:liberated_bread_mobile/screens/usb_scan_screen.dart';
import 'package:liberated_bread_mobile/services/serial_port_service.dart';
import 'package:liberated_bread_mobile/services/unsupported_serial_port_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../fakes/fake_codeplug_backup_store.dart';
import '../fakes/fake_radio_programmer.dart';
import '../fakes/in_memory_settings_store.dart';

late SharedPreferences _prefs;

/// Ports that can be changed between listings, and a count of listings.
class _Ports implements SerialPortService {
  List<SerialPortInfo> ports;
  Object? error;
  int listings = 0;

  _Ports(this.ports);

  @override
  SerialAvailability get availability => const SerialAvailability.supported();

  @override
  Future<List<SerialPortInfo>> listPorts() async {
    listings++;
    final failure = error;
    if (failure != null) throw failure;
    return ports;
  }

  @override
  Future<SerialLink> open(SerialPortInfo port, {required int baudRate}) =>
      Future.error(const SerialPortException('not in this test'));
}

const _ch340 = SerialPortInfo(
  id: '/dev/ttyUSB0',
  name: '/dev/ttyUSB0',
  vendorId: 0x1A86,
  productId: 0x7523,
  manufacturer: 'QinHeng',
);

const _pl2303 = SerialPortInfo(
  id: '/dev/ttyUSB1',
  name: '/dev/ttyUSB1',
  vendorId: 0x067B,
  productId: 0x2303,
);

Widget _wrap(SerialPortService ports, {bool active = true}) => ProviderScope(
      overrides: [
        serialPortServiceProvider.overrideWithValue(ports),
        serialRadioProgrammerProvider.overrideWithValue(FakeRadioProgrammer()),
        codeplugBackupStoreProvider
            .overrideWithValue(FakeCodeplugBackupStore()),
        sharedPreferencesProvider.overrideWithValue(_prefs),
        prefsSettingsStoreProvider
            .overrideWith((ref) async => InMemorySettingsStore()),
      ],
      child: MaterialApp(home: UsbScanScreen(active: active)),
    );

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    _prefs = await SharedPreferences.getInstance();
  });

  testWidgets('lists each cable with the chip it is built on', (tester) async {
    await tester.pumpWidget(_wrap(_Ports([_ch340])));
    await tester.pumpAndSettle();

    expect(find.text('1 cable plugged in'), findsOneWidget);
    expect(find.textContaining('/dev/ttyUSB0'), findsOneWidget);
    // A cable that gives no product name is called by its chip — once, not
    // as its title and again beneath it.
    expect(find.text('WCH CH340'), findsOneWidget);
    expect(find.text('USB serial'), findsOneWidget);
    expect(find.textContaining('1a86:7523'), findsOneWidget);
  });

  testWidgets('a cable that names itself keeps its chip beneath the name',
      (tester) async {
    await tester.pumpWidget(_wrap(_Ports([
      const SerialPortInfo(
        id: '/dev/ttyUSB0',
        name: '/dev/ttyUSB0',
        vendorId: 0x1A86,
        productId: 0x7523,
        product: 'USB Serial',
      ),
    ])));
    await tester.pumpAndSettle();

    expect(find.text('USB Serial'), findsOneWidget);
    expect(find.text('WCH CH340'), findsOneWidget);
  });

  testWidgets('warns about a cable built on a chip often counterfeited',
      (tester) async {
    await tester.pumpWidget(_wrap(_Ports([_pl2303])));
    await tester.pumpAndSettle();
    expect(find.textContaining('Counterfeit PL2303'), findsOneWidget);
  });

  testWidgets('with nothing plugged in, says how to plug a cable in',
      (tester) async {
    await tester.pumpWidget(_wrap(_Ports([])));
    await tester.pumpAndSettle();

    expect(find.text('No cable plugged in'), findsOneWidget);
    expect(find.textContaining('USB-OTG adapter'), findsOneWidget);
    // And that the Bluetooth radios need no cable at all.
    expect(find.textContaining('Nearby tab'), findsOneWidget);
  });

  testWidgets('a listing that fails says so, and can be tried again',
      (tester) async {
    final ports = _Ports([_ch340])..error = StateError('usb stack went away');
    await tester.pumpWidget(_wrap(ports));
    await tester.pumpAndSettle();

    expect(find.text('Could not look for cables'), findsOneWidget);
    ports.error = null;
    await tester.tap(find.text('Try again'));
    await tester.pumpAndSettle();
    expect(find.text('1 cable plugged in'), findsOneWidget);
  });

  testWidgets('looks only while it is the tab on screen, and again on return',
      (tester) async {
    final ports = _Ports([]);
    await tester.pumpWidget(_wrap(ports, active: false));
    await tester.pumpAndSettle();
    expect(ports.listings, 0);

    // The shell switches to it; a cable was plugged in meanwhile.
    ports.ports = [_ch340];
    await tester.pumpWidget(_wrap(ports));
    await tester.pumpAndSettle();
    expect(ports.listings, 1);
    expect(find.text('1 cable plugged in'), findsOneWidget);
  });

  testWidgets('tapping a cable opens the radio on the other end',
      (tester) async {
    await tester.pumpWidget(_wrap(_Ports([_ch340])));
    await tester.pumpAndSettle();

    await tester.tap(find.textContaining('/dev/ttyUSB0'));
    await tester.pumpAndSettle();

    final screen =
        tester.widget<RadioDeviceScreen>(find.byType(RadioDeviceScreen));
    expect(screen.target.transport, RadioTransport.usb);
    expect(screen.target.id, '/dev/ttyUSB0');
  });

  testWidgets('on iPhone, explains why and what works instead', (tester) async {
    tester.view.physicalSize = const Size(1200, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(_wrap(const UnsupportedSerialPortService(
        UnsupportedSerialPortService.iosReason)));
    await tester.pumpAndSettle();

    expect(find.text('No programming cables here'), findsOneWidget);
    expect(find.textContaining('iPhone and iPad'), findsOneWidget);
    expect(find.textContaining('Nearby tab'), findsOneWidget);
    expect(find.textContaining('BT-A1D'), findsOneWidget);
    expect(find.textContaining('does not support them yet'), findsOneWidget);
    expect(find.textContaining('CHIRP'), findsOneWidget);
    expect(find.byTooltip('Look again'), findsNothing,
        reason: 'there is nothing to look for');
  });
}
