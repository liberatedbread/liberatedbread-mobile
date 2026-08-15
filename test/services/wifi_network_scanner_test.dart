// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// The OS Wi-Fi list reader behind the adoption hint. Everything here is about
// one property: the reader is best-effort and never throws, so a screen that
// leans on it for a spinning icon cannot be broken by a platform that will not
// answer.

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/services/wifi_network_scanner.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('ca.pigscanfly.liberatedbread/wifi_scan');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  void handle(Future<Object?>? Function(MethodCall call)? handler) {
    messenger.setMockMethodCallHandler(channel, handler);
  }

  tearDown(() => handle(null));

  test('an unsupported platform never touches the channel', () async {
    var called = false;
    handle((_) async {
      called = true;
      return <String>[];
    });
    final scanner = WifiNetworkScanner(isSupported: false);
    expect(await scanner.visibleSsids(), isEmpty);
    expect(called, isFalse,
        reason: 'must not invoke the channel where it cannot work');
  });

  test('returns the SSIDs the channel reports, trimmed and de-duplicated',
      () async {
    handle((call) async {
      expect(call.method, 'scanResults');
      return <String>['Wemo.Mini.4A2', '  LIFX Z 04A3C1  ', 'Wemo.Mini.4A2'];
    });
    final scanner = WifiNetworkScanner(isSupported: true);
    final ssids = await scanner.visibleSsids();
    expect(ssids, ['Wemo.Mini.4A2', 'LIFX Z 04A3C1']);
  });

  test('drops blank SSIDs (hidden networks report an empty name)', () async {
    handle((call) async => <String>['', '   ', 'HomeNet']);
    final scanner = WifiNetworkScanner(isSupported: true);
    expect(await scanner.visibleSsids(), ['HomeNet']);
  });

  test('a null result becomes an empty list, not a crash', () async {
    handle((call) async => null);
    final scanner = WifiNetworkScanner(isSupported: true);
    expect(await scanner.visibleSsids(), isEmpty);
  });

  test('a platform error is swallowed into an empty list', () async {
    // The real failure in the field: getScanResults throws SecurityException
    // when the location permission is absent. A hint is not worth a crash.
    handle((call) async =>
        throw PlatformException(code: 'PERMISSION', message: 'no location'));
    final scanner = WifiNetworkScanner(isSupported: true);
    expect(await scanner.visibleSsids(), isEmpty);
  });
}
