// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// The whole app, over the REAL BLE path, against an emulated peripheral.
//
// Every other app-level test in this repo substitutes the BLE layer — either
// FakeBleService (a test double for BleService) or MockBleService (demo mode).
// Both are fine for widget behaviour, and both mean the code that talks to
// flutter_blue_plus never runs. That gap has bitten this project before: the
// iOS permission bug documented in RealBleService.requestPermissions shipped
// because "only mock/simulator paths were exercised in CI".
//
// So this file overrides NOTHING about the BLE layer. `flutter test` compiles
// without --dart-define=LIBERATED_BREAD_MOCK, so bleServiceProvider builds a
// real RealBleService; test/fakes/emulated_ble.dart supplies the radio
// underneath flutter_blue_plus. The chain under test is the shipping one:
//
//   ScanScreen/DeviceScreen → providers → RealBleService → flutter_blue_plus
//     → EmulatedBleAdapter → EmulatedPeripheral
//
// plus real spec matching and command encoding over FFI, which is what turns a
// discovered GATT tree into the typed controls the user actually touches.
//
// The concrete regression this locks down: flutter_blue_plus reports discovered
// UUIDs in their SHORTEST form (`180f`), while device specs and the app's
// well-known-UUID tables use the 128-bit form. Until normalizeUuid canonicalized
// the two, a real device matched no spec at all — it rendered raw hex rows and a
// service called "Service" — while mock mode, whose GATT tree is derived from
// the spec itself, looked perfect. No test could see the difference, because no
// test ran this path.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/app.dart';
import 'package:liberated_bread_mobile/providers/ble_provider.dart';
import 'package:liberated_bread_mobile/providers/saved_device_provider.dart';
import 'package:liberated_bread_mobile/screens/scan_screen.dart';
import 'package:liberated_bread_mobile/services/real_ble_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fakes/emulated_ble.dart';
import 'helpers/host_rust_lib.dart';

const _bulbId = 'AA:BB:CC:DD:EE:01';
const _lockId = 'AA:BB:CC:DD:EE:03';

late SharedPreferences _prefs;

/// One step of the hybrid clock these tests run on: let real time pass, then
/// hand the SAME amount to the test binding's clock.
///
/// Both halves are load-bearing. The real delay is what lets the emulated
/// adapter, flutter_blue_plus's timers and the FFI codec make progress —
/// they are outside the harness's control. The duration passed to `pump` is
/// what advances Flutter's own animations; `pump()` with no argument runs a
/// frame WITHOUT moving the clock, so a route transition never finishes and
/// the pushed page sits frozen part-way through its slide-in. That is not
/// hypothetical: it put the device screen's buttons off the right edge of the
/// viewport, where `tap()` quietly hit the page underneath instead.
Future<void> _tick(WidgetTester tester) async {
  const step = Duration(milliseconds: 25);
  await Future<void>.delayed(step);
  await tester.pump(step);
}

/// Pump until [finder] matches, or the deadline passes.
///
/// `pumpAndSettle` is unusable here: it spins the fake clock with no real time
/// passing, so the work these tests are waiting on never advances. Polling also
/// keeps the fast path fast — spec matching parses the whole bundled catalogue
/// across the FFI boundary, and that cost varies by machine — instead of
/// pinning every test to a fixed worst-case sleep.
Future<void> _pumpUntil(
  WidgetTester tester,
  Finder finder, {
  Duration timeout = const Duration(seconds: 90),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    await _tick(tester);
    if (finder.evaluate().isNotEmpty) return;
  }
  // Deliberately no throw: the expect() that follows reports what was actually
  // on screen, which is far more useful than "timed out".
}

/// Pump a few frames without waiting for anything in particular.
Future<void> _pumpAWhile(WidgetTester tester, {int rounds = 8}) async {
  for (var i = 0; i < rounds; i++) {
    await _tick(tester);
  }
}

/// Run [body] on the real clock, then dispose the widget tree while the test
/// can still pump.
///
/// The teardown is not tidiness, it is required. DeviceScreen disconnects in
/// `dispose()`, and the harness's own teardown runs after the last pump — so a
/// tree left standing issues that disconnect into a stopped clock, where the
/// emulated radio's reply is never delivered and flutter_blue_plus waits for it
/// forever while holding the per-operation mutex that the NEXT test's connect
/// needs. Left alone, that shows up as the second test in this file hanging on
/// a connect that passes when the test runs by itself. Disposing here puts the
/// disconnect inside the window where it completes.
Future<void> _scenario(WidgetTester tester, Future<void> Function() body) {
  return tester.runAsync(() async {
    try {
      await body();
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await _pumpAWhile(tester, rounds: 12);
    }
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late EmulatedBleAdapter ble;
  late bool rustReady;

  setUpAll(() async {
    ble = EmulatedBleAdapter.install();
    rustReady = await initHostRustLib();
  });

  setUp(() async {
    await ble.reset();
    SharedPreferences.setMockInitialValues({});
    _prefs = await SharedPreferences.getInstance();
  });

  /// Give the test surface room for the whole scan screen.
  ///
  /// The default 800x600 is smaller than a phone, and the scan screen spends
  /// most of it on chrome before the first device row: radar, headline,
  /// subhead, then a section header. In a lazily-built ListView a row below the
  /// fold is never CONSTRUCTED, so `find.text` cannot see it and the failure
  /// reads as "the device was never discovered" — which is the one thing it is
  /// not. Assert on a viewport that would actually show the list.
  void useTallSurface(WidgetTester tester) {
    tester.view.physicalSize = const Size(1000, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  Widget app() => ProviderScope(
        // Only SharedPreferences, which main() resolves before runApp.
        // bleServiceProvider is deliberately left alone: it builds a real
        // RealBleService, which is the entire point of this file.
        overrides: [sharedPreferencesProvider.overrideWithValue(_prefs)],
        child: const LiberatedBreadApp(),
      );

  testWidgets('the app scans, connects and discovers over RealBleService',
      (tester) async {
    ble.add(EmulatedPeripheral.bulb(id: _bulbId, name: 'ACME_Living_Room'));

    useTallSurface(tester);
    await _scenario(tester, () async {
      await tester.pumpWidget(app());
      await _pumpAWhile(tester, rounds: 4);

      // Guard against silently testing demo mode instead.
      final container = ProviderScope.containerOf(
        tester.element(find.byType(ScanScreen)),
      );
      expect(container.read(bleServiceProvider), isA<RealBleService>());

      await tester.tap(find.byType(FloatingActionButton));
      await _pumpUntil(tester, find.text('ACME_Living_Room'));
      expect(find.text('ACME_Living_Room'), findsOneWidget,
          reason: 'the emulated advertisement should reach the device list');

      await tester.tap(find.text('ACME_Living_Room'));
      await _pumpUntil(tester, find.text('Battery Service'));

      // Discovery mapped the GATT tree into the UI. "Battery Service" (rather
      // than a bare "Service") is the well-known-UUID lookup succeeding, which
      // it cannot do when discovery reports the short-form UUID.
      expect(find.text('Battery Service'), findsOneWidget);
    });
  });

  // One test, not three, for the spec journey: matching parses the entire
  // bundled catalogue over FFI, and paying that once is worth more than the
  // isolation three separate cases would buy.
  testWidgets(
      'a discovered device matches its spec, and its typed command reaches '
      'the peripheral as bytes', (tester) async {
    if (!rustReady) {
      markTestSkipped('Rust lib not loaded; spec matching needs the FFI codec');
      return;
    }
    final bulb =
        ble.add(EmulatedPeripheral.bulb(id: _bulbId, name: 'ACME_Living_Room'));

    useTallSurface(tester);
    await _scenario(tester, () async {
      await tester.pumpWidget(app());
      await _pumpAWhile(tester, rounds: 4);
      await tester.tap(find.byType(FloatingActionButton));
      await _pumpUntil(tester, find.text('ACME_Living_Room'));
      await tester.tap(find.text('ACME_Living_Room'));
      await _pumpUntil(tester, find.text('Control Service'));

      // Both labels come from assets/device_specs/example-bulb.yaml, reached by
      // matching the device's advertised name prefix together with its
      // discovered service UUIDs. Nothing in the app knows what an ACME bulb is.
      expect(find.text('Control Service'), findsOneWidget,
          reason: 'the spec names the service; a failed match would leave the '
              'generic "Service" label');
      expect(find.text('Power on'), findsWidgets,
          reason: 'typed command buttons only exist when a spec matched');

      // The read path, decoded: the peripheral's battery characteristic holds
      // the single byte 85, and the spec is what turns that into a labelled
      // percentage. Raw controls would show "55" — the hex. The reads are
      // issued after the match resolves, so wait for them separately.
      await _pumpUntil(tester, find.text('85'));
      expect(find.text('Battery'), findsWidgets);
      expect(find.text('85'), findsWidgets);
      expect(find.text('Power state: on'), findsOneWidget,
          reason: 'the state characteristic was read over the real service and '
              'decoded by the spec');

      // widgetWithText, not find.text: "Power on" is on screen twice — once as
      // the command's name and once on the button that sends it. ensureVisible
      // first, because the spec's controls are taller than the test viewport
      // and tapping a widget below the fold hits whatever IS there.
      final powerOn = find.widgetWithText(ElevatedButton, 'Power on');
      await tester.ensureVisible(powerOn);
      await _pumpAWhile(tester, rounds: 4);
      await tester.tap(powerOn);
      await _pumpUntil(tester, find.text('Sent'));
      expect(find.text('Sent'), findsWidgets,
          reason: 'the button reports the write it made');

      // [0x01, 0x01] is the `power_on` command in the spec's YAML. It travelled
      // spec → Rust encoder → RealBleService → flutter_blue_plus → peripheral,
      // and it had to go out write-WITHOUT-response because that is the only
      // mode this characteristic advertises.
      final command = bulb.characteristic(EmulatedUuids.controlCommand)!;
      expect(command.writes, isNotEmpty);
      expect(command.writes.last.value, [0x01, 0x01]);
      expect(command.writes.last.type, EmulatedWriteType.withoutResponse);
    });
    // Generous, and deliberately so: this one test parses the whole bundled
    // spec catalogue across the FFI boundary against a DEBUG build of the Rust
    // crate. It costs about ten seconds in practice; the bound only exists so a
    // genuine hang fails instead of running to the harness default.
  }, timeout: const Timeout(Duration(minutes: 3)));

  // A pairing-required device and an open one, side by side. They are identical
  // right up to the first read: both advertise, both connect, both hand over
  // their GATT table. Only then does one of them refuse.
  //
  // Neither carries a name prefix or service UUID any bundled spec claims, so
  // both render the raw characteristic browser — which reads on build, making
  // this the shortest path from "device in range" to "what the user is told".
  // It also means these two cases need no FFI codec and stay fast.
  EmulatedPeripheral sensor(
      {required String id, required bool requiresPairing}) {
    return EmulatedPeripheral(
      id: id,
      name: requiresPairing ? 'Vault Sensor' : 'Open Sensor',
      requiresPairing: requiresPairing,
      services: [
        EmulatedService(
          uuid: '7b2c0001-4f1a-4a3e-9b6d-2f8a1c5e0d31',
          characteristics: [
            EmulatedCharacteristic(
              uuid: '7b2c0002-4f1a-4a3e-9b6d-2f8a1c5e0d31',
              value: const [0xab, 0xcd],
              canRead: true,
            ),
          ],
        ),
      ],
    );
  }

  testWidgets(
      'a device that needs pairing says so, in words the user can act '
      'on', (tester) async {
    ble.add(sensor(id: _lockId, requiresPairing: true));

    useTallSurface(tester);
    await _scenario(tester, () async {
      await tester.pumpWidget(app());
      await _pumpAWhile(tester, rounds: 4);
      await tester.tap(find.byType(FloatingActionButton));
      await _pumpUntil(tester, find.text('Vault Sensor'));
      await tester.tap(find.text('Vault Sensor'));

      // Connecting and discovery must still succeed — an unpaired device is not
      // a broken one, and hiding its services would leave the user with nothing
      // to act on.
      await _pumpUntil(tester, find.textContaining('needs to be paired'));
      expect(find.text('7b2c0001-4f1a-4a3e-9b6d-2f8a1c5e0d31'), findsOneWidget,
          reason: 'the GATT table still came across; only the read was '
              'refused');
      expect(find.textContaining('needs to be paired'), findsWidgets,
          reason: 'the refusal has to name pairing; the generic fallback '
              'sends the user looking at the wrong thing');
      expect(find.textContaining('GATT'), findsNothing,
          reason: 'the native error code is for the log, not the screen');
    });
  });

  testWidgets('an identical device that needs no pairing just reads',
      (tester) async {
    ble.add(sensor(id: _bulbId, requiresPairing: false));

    useTallSurface(tester);
    await _scenario(tester, () async {
      await tester.pumpWidget(app());
      await _pumpAWhile(tester, rounds: 4);
      await tester.tap(find.byType(FloatingActionButton));
      await _pumpUntil(tester, find.text('Open Sensor'));
      await tester.tap(find.text('Open Sensor'));

      // The peripheral's two bytes, straight off the wire and rendered as hex
      // by the raw browser. Chosen not to collide with any digits in the UUIDs
      // on the same screen.
      await _pumpUntil(tester, find.textContaining('ab cd'));
      expect(find.textContaining('ab cd'), findsWidgets);
      expect(find.textContaining('needs to be paired'), findsNothing);
    });
  });

  testWidgets('a radio that is switched off is reported, not swallowed',
      (tester) async {
    ble.adapterState = EmulatedAdapterState.off;

    useTallSurface(tester);
    await _scenario(tester, () async {
      await tester.pumpWidget(app());
      await _pumpAWhile(tester, rounds: 4);
      await tester.tap(find.byType(FloatingActionButton));
      await _pumpUntil(tester, find.textContaining('Bluetooth is turned off'));

      expect(find.textContaining('Bluetooth is turned off'), findsOneWidget);
      // Never the raw Dart rendering of an internal error.
      expect(find.textContaining('Bad state'), findsNothing);
    });
  });

  testWidgets('a denied Bluetooth permission gets its own recovery path',
      (tester) async {
    ble.adapterState = EmulatedAdapterState.unauthorized;

    useTallSurface(tester);
    await _scenario(tester, () async {
      await tester.pumpWidget(app());
      await _pumpAWhile(tester, rounds: 4);
      await tester.tap(find.byType(FloatingActionButton));
      await _pumpUntil(tester, find.text('Bluetooth permission needed'));

      expect(find.text('Bluetooth permission needed'), findsOneWidget);
    });
  });
}
