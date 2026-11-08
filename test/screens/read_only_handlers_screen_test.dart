// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// The read-only handlers' screens: readings shown honestly, commands listed
// and refused, and no control drawn. Nothing here may offer a way to change a
// device: some of these specs drive mains power, an inverter's export or a
// door.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/models/iot_device.dart';
import 'package:liberated_bread_mobile/models/network_device.dart';
import 'package:liberated_bread_mobile/providers/network_control_provider.dart';
import 'package:liberated_bread_mobile/providers/read_only_ble_provider.dart';
import 'package:liberated_bread_mobile/providers/saved_device_provider.dart';
import 'package:liberated_bread_mobile/providers/spec_codec_provider.dart';
import 'package:liberated_bread_mobile/screens/sunspec_status_screen.dart';
import 'package:liberated_bread_mobile/services/acinfinity_ble_client.dart';
import 'package:liberated_bread_mobile/services/read_only_ble_session.dart';
import 'package:liberated_bread_mobile/services/spec_codec.dart';
import 'package:liberated_bread_mobile/services/sunspec_client.dart';
import 'package:liberated_bread_mobile/services/yummly_ble_client.dart';
import 'package:liberated_bread_mobile/src/rust/protocol/acinfinity.dart';
import 'package:liberated_bread_mobile/src/rust/protocol/modbus_sunspec.dart';
import 'package:liberated_bread_mobile/widgets/read_only_ble_panels.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../fakes/fake_spec_codec.dart';

const _surface = ReadOnlySurfaceDto(
  handler: 'test',
  commands: [
    ReadOnlyCommandDto(name: 'read_inverter_block', sent: true),
    ReadOnlyCommandDto(
      name: 'set_active_power_limit',
      sent: false,
      refusal: 'Read-only in this app: it changes what an inverter produces.',
    ),
  ],
);

const _inverter = SunSpecInverterDto(
  modelId: 103,
  acPowerW: 8650,
  lifetimeEnergyWh: null,
  statusCode: 4,
  statusLabel: 'Producing',
);

const _common = SunSpecCommonDto(
  manufacturer: 'SolarEdge',
  model: 'SE8K',
  version: '0004.0020.0000',
  serial: '00000000-00',
  unitId: 1,
);

class _FakeSunSpec implements SunSpecClient {
  Object? error;
  SunSpecMeterPowerDto? power;
  var reads = 0;

  @override
  Future<SunSpecReading> read() async {
    reads++;
    if (error != null) throw error!;
    return SunSpecReading(
      common: _common,
      inverter: _inverter,
      lifetimeEnergyWh: 12345678,
      meter: power == null
          ? null
          : const SunSpecMeterDto(
              manufacturer: 'SolarEdge',
              model: 'M',
              role: 'Export+Import',
              serial: '1',
            ),
      meterPower: power,
    );
  }
}

class _FakeYummly implements YummlyClient {
  final _controller = StreamController<YummlyReading>.broadcast();
  var closed = false;

  void push(YummlyReading reading) => _controller.add(reading);

  @override
  Stream<YummlyReading> watch() => _controller.stream;

  @override
  Future<void> close() async {
    closed = true;
    await _controller.close();
  }
}

class _FakeAcInfinity implements AcInfinityClient {
  final _controller = StreamController<AcInfinityReading>.broadcast();

  void push(AcInfinityReading reading) => _controller.add(reading);
  void fail(Object error) => _controller.addError(error);

  @override
  Stream<AcInfinityReading> watch() => _controller.stream;

  @override
  Future<void> close() async {
    await _controller.close();
  }
}

/// A screen with a reading on it has these only: one button that starts or
/// stops reading, or a refresh. Nothing that looks like a control of the device.
void _expectNoControls(WidgetTester tester) {
  expect(find.byType(Switch), findsNothing);
  expect(find.byType(Slider), findsNothing);
  expect(find.byType(DropdownButton<String>), findsNothing);
  expect(find.byType(SegmentedButton<String>), findsNothing);
}

const _noPadding = Size(800, 2000);

void main() {
  group('SunSpecStatusScreen', () {
    final device = NetworkDevice(
      host: '192.168.1.50',
      name: 'Inverter',
      port: 1502,
      sources: const {NetworkDiscoverySource.mdns},
      discoveredAt: DateTime(2026),
    );

    Future<void> pump(WidgetTester tester, _FakeSunSpec client) async {
      tester.view.physicalSize = _noPadding;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            sharedPreferencesProvider.overrideWithValue(prefs),
            specCodecProvider.overrideWithValue(
              FakeSpecCodec(readOnlySurfaceResult: _surface),
            ),
            sunSpecClientFactoryProvider.overrideWithValue((_, _, _) => client),
          ],
          child: MaterialApp(
            home: SunSpecStatusScreen(
              device: device,
              controls: const NetworkControls(
                specYaml: 'solaredge',
                entities: [],
                sunSpecStatus: true,
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
    }

    Future<void> leave(WidgetTester tester) async {
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    }

    testWidgets('shows readings, and no control of any kind', (tester) async {
      final client = _FakeSunSpec();
      await pump(tester, client);
      expect(find.text('Read-only'), findsOneWidget);
      expect(find.text('8650 W'), findsOneWidget);
      expect(find.text('Producing'), findsOneWidget);
      expect(find.text('SE8K'), findsOneWidget);
      _expectNoControls(tester);
      await leave(tester);
    });

    testWidgets('never states a direction for meter power', (tester) async {
      final client = _FakeSunSpec()
        ..power = const SunSpecMeterPowerDto(magnitudeW: 1520);
      await pump(tester, client);
      expect(find.text('1520.0 W'), findsOneWidget);
      expect(find.text('Power (magnitude)'), findsOneWidget);
      expect(find.textContaining('does not guess'), findsOneWidget);
      expect(find.text('Exporting'), findsNothing);
      expect(find.text('Importing'), findsNothing);
      await leave(tester);
    });

    testWidgets('says so when no meter answered', (tester) async {
      await pump(tester, _FakeSunSpec());
      expect(find.text('None answered at its address'), findsOneWidget);
      await leave(tester);
    });

    testWidgets('lists every command and refuses the writes', (tester) async {
      await pump(tester, _FakeSunSpec());
      expect(find.text('1 of 2 are refused by this app'), findsOneWidget);
      await tester.ensureVisible(find.text('Commands in the device spec'));
      await tester.tap(find.text('Commands in the device spec'));
      await tester.pumpAndSettle(const Duration(milliseconds: 100));
      expect(find.text('set_active_power_limit'), findsOneWidget);
      expect(find.textContaining('Read-only in this app'), findsOneWidget);
      expect(find.text('Sent by this app, to read.'), findsOneWidget);
      _expectNoControls(tester);
      await leave(tester);
    });

    testWidgets('a read that fails says why', (tester) async {
      final client = _FakeSunSpec()
        ..error = const SunSpecException(
          'The inverter did not answer in time.',
        );
      await pump(tester, client);
      expect(find.textContaining('did not answer in time'), findsOneWidget);
      await leave(tester);
    });

    testWidgets('polls while open and stops after', (tester) async {
      final client = _FakeSunSpec();
      await pump(tester, client);
      final before = client.reads;
      await tester.pump(const Duration(seconds: 11));
      await tester.pump();
      expect(client.reads, greaterThan(before));
      await leave(tester);
      final after = client.reads;
      await tester.pump(const Duration(seconds: 30));
      expect(client.reads, after);
    });
  });

  group('ReadOnlyBlePanel', () {
    IoTDevice device(String name) => IoTDevice(
      id: 'AA:BB',
      name: name,
      rssi: -40,
      isConnectable: true,
      discoveredAt: DateTime(2026),
    );

    Future<void> pump(
      WidgetTester tester, {
      required ReadOnlyBleProfile profile,
      required String name,
      YummlyClient? yummly,
      AcInfinityClient? acInfinity,
    }) async {
      tester.view.physicalSize = _noPadding;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            sharedPreferencesProvider.overrideWithValue(prefs),
            specCodecProvider.overrideWithValue(
              FakeSpecCodec(readOnlySurfaceResult: _surface),
            ),
            if (yummly != null)
              yummlyClientProvider.overrideWithValue((_) => yummly),
            if (acInfinity != null)
              acInfinityClientProvider.overrideWithValue((_) => acInfinity),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: ReadOnlyBlePanel(device: device(name), profile: profile),
            ),
          ),
        ),
      );
      await tester.pump();
    }

    const yummlyProfile = ReadOnlyBleProfile(
      handler: yummlyHandler,
      specKey: 'yummly',
      specYaml: 'yummly',
      category: 'sensor',
    );
    const acProfile = ReadOnlyBleProfile(
      handler: acInfinityHandler,
      specKey: 'ac',
      specYaml: 'ac',
      category: 'climate',
    );

    testWidgets('Yummly does not connect until asked, and shows the probe', (
      tester,
    ) async {
      final yummly = _FakeYummly();
      await pump(
        tester,
        profile: yummlyProfile,
        name: 'Yummly T1',
        yummly: yummly,
      );
      expect(find.text('Start reading'), findsOneWidget);
      await tester.tap(find.text('Start reading'));
      await tester.pump();
      yummly.push(const YummlyReading(coreF: 132.4, bodyF: 275, dockBars: 3));
      await tester.pump();
      expect(find.text('132.4 °F'), findsOneWidget);
      expect(find.text('275 °F'), findsOneWidget);
      expect(find.text('3 of 4'), findsOneWidget);
      expect(find.textContaining('instant-read'), findsOneWidget);
      _expectNoControls(tester);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      expect(yummly.closed, isTrue);
    });

    testWidgets('a pinned reading says so', (tester) async {
      final yummly = _FakeYummly();
      await pump(
        tester,
        profile: yummlyProfile,
        name: 'Yummly T1',
        yummly: yummly,
      );
      await tester.tap(find.text('Start reading'));
      await tester.pump();
      yummly.push(const YummlyReading(coreF: 212, coreAtLimit: true));
      await tester.pump();
      expect(find.textContaining('at its limit'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    });

    testWidgets('a T3 is refused without connecting', (tester) async {
      final yummly = _FakeYummly();
      await pump(
        tester,
        profile: yummlyProfile,
        name: 'Yummly T3',
        yummly: yummly,
      );
      expect(find.textContaining('never been run'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    });

    testWidgets('AC Infinity shows ports as readings only', (tester) async {
      final client = _FakeAcInfinity();
      await pump(tester, profile: acProfile, name: 'ACI', acInfinity: client);
      await tester.tap(find.text('Start reading'));
      await tester.pump();
      client.push(
        const AcInfinityReading(
          status: AcInfinityStatusDto(
            displayCelsius: true,
            selectedPort: 1,
            temperatureCentiC: 2250,
            humidityCentiPercent: null,
            vpdCentiKpa: 122,
            ports: [
              AcInfinityPortDto(
                port: 1,
                occupied: true,
                loadId: 10000,
                loadType: 'heater',
                level: 6,
                outputOn: true,
                fault: false,
                overcurrent: false,
                modeCode: 2,
                mode: 'on',
              ),
              AcInfinityPortDto(
                port: 2,
                occupied: false,
                outputOn: false,
                fault: false,
                overcurrent: false,
                modeCode: 0,
              ),
            ],
            undecodedPorts: 4,
          ),
        ),
      );
      await tester.pump();
      expect(find.text('22.50 °C'), findsOneWidget);
      expect(find.text('No probe'), findsOneWidget);
      expect(find.text('heater'), findsOneWidget);
      expect(find.text('Nothing'), findsOneWidget);
      expect(find.textContaining('4 more ports'), findsOneWidget);
      _expectNoControls(tester);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    });

    testWidgets('a stale status says the ports may have changed', (
      tester,
    ) async {
      final client = _FakeAcInfinity();
      await pump(tester, profile: acProfile, name: 'ACI', acInfinity: client);
      await tester.tap(find.text('Start reading'));
      await tester.pump();
      client.push(
        const AcInfinityReading(
          stale: true,
          status: AcInfinityStatusDto(
            displayCelsius: true,
            selectedPort: 1,
            ports: [],
            undecodedPorts: 0,
          ),
        ),
      );
      await tester.pump();
      expect(find.textContaining('may have changed'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    });

    testWidgets('a failing session says why', (tester) async {
      final client = _FakeAcInfinity();
      await pump(tester, profile: acProfile, name: 'ACI', acInfinity: client);
      await tester.tap(find.text('Start reading'));
      await tester.pump();
      client.fail(const ReadOnlyBleException('The controller did not send.'));
      await tester.pump();
      expect(find.text('The controller did not send.'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    });
  });
}
