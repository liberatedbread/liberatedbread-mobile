// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// The Wi-Fi tab, over the real discovery path, against emulated devices.
//
// The BLE twin of this file is app_real_ble_path_test.dart, and the reasoning
// is the same: nothing about the discovery layer is overridden. `flutter test`
// compiles without --dart-define=LIBERATED_BREAD_MOCK, so
// networkScanServiceProvider builds a real RealNetworkScanService, and
// scripts/net_virtual_device.py answers its queries on the actual multicast
// groups. The chain under test is the shipping one:
//
//   HomeShell/WifiScanScreen → providers → RealNetworkScanService
//     → mDNS + SSDP sockets → the emulated devices
//
// See real_network_scan_service_live_test.dart for what the transports are
// asserted to do on their own; this file is about the tab actually showing
// what they found.
@Tags(['netdisco'])
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/app.dart';
import 'package:liberated_bread_mobile/providers/network_scan_provider.dart';
import 'package:liberated_bread_mobile/providers/saved_device_provider.dart';
import 'package:liberated_bread_mobile/services/real_network_scan_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

late SharedPreferences _prefs;

/// One step of the hybrid clock: let real time pass, then hand the same amount
/// to the test binding's clock. The real delay is what lets datagrams arrive;
/// the duration passed to `pump` is what advances Flutter's own animations, and
/// `pump()` with no argument would leave a tab transition frozen part-way.
Future<void> _tick(WidgetTester tester) async {
  const step = Duration(milliseconds: 50);
  await Future<void>.delayed(step);
  await tester.pump(step);
}

Future<void> _pumpUntil(
  WidgetTester tester,
  Finder finder, {
  Duration timeout = const Duration(seconds: 40),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    await _tick(tester);
    if (finder.evaluate().isNotEmpty) return;
  }
}

Future<void> _pumpAWhile(WidgetTester tester, {int rounds = 6}) async {
  for (var i = 0; i < rounds; i++) {
    await _tick(tester);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Process? responder;
  Directory? work;

  setUpAll(() async {
    work = await Directory.systemTemp.createTemp('lb-virtual-net-app');
    final ready = File('${work!.path}/ready');
    responder = await Process.start('python3', [
      'scripts/net_virtual_device.py',
      '--ready-file',
      ready.path,
    ]);
    final deadline = DateTime.now().add(const Duration(seconds: 10));
    while (DateTime.now().isBefore(deadline) && !ready.existsSync()) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    if (!ready.existsSync()) {
      throw StateError('the virtual network device did not start listening; '
          'ports 5353 and 1900 must be free');
    }
  });

  tearDownAll(() async {
    responder?.kill();
    await work?.delete(recursive: true);
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    _prefs = await SharedPreferences.getInstance();
  });

  testWidgets('the Wi-Fi tab finds and lists an emulated network device',
      (tester) async {
    // The scan screen's chrome fills the default 800x600 before the first row;
    // in a lazily-built list a row below the fold is never constructed, and the
    // failure would read as "nothing was discovered".
    tester.view.physicalSize = const Size(1000, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.runAsync(() async {
      try {
        await tester.pumpWidget(ProviderScope(
          overrides: [sharedPreferencesProvider.overrideWithValue(_prefs)],
          child: const LiberatedBreadApp(),
        ));
        await _pumpAWhile(tester);

        // Guard against silently testing demo mode instead.
        final container =
            ProviderScope.containerOf(tester.element(find.byType(MaterialApp)));
        expect(container.read(networkScanServiceProvider),
            isA<RealNetworkScanService>());

        await tester.tap(find.text('Wi-Fi'));
        await _pumpAWhile(tester);
        expect(find.text('Scan your Wi-Fi network'), findsOneWidget);

        await tester.tap(find.byType(FloatingActionButton));
        // The name comes from the emulated bridge's DNS-SD instance label, so
        // seeing it means the meta-query, the type PTR, SRV, TXT and A all
        // completed and the row was built from the result.
        await _pumpUntil(tester, find.text('Philips Hue - 123456'));
        expect(find.text('Philips Hue - 123456'), findsOneWidget);

        // The SSDP-only device has no mDNS name at all, so it is listed by the
        // host from its LOCATION URL — which is the fallback in displayName,
        // and the reason the scan runs both transports.
        expect(find.text('198.51.100.12'), findsOneWidget);
      } finally {
        // Dispose while the test can still pump: the screen stops its scan in
        // dispose(), and a teardown that lands after the last pump leaves that
        // work unfinished.
        await tester.pumpWidget(const SizedBox.shrink());
        await _pumpAWhile(tester, rounds: 10);
      }
    });
  });
}
