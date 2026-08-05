@Tags(['e2e'])
library;

// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// Scripted end-to-end walkthrough of the whole app, driven on a real device or
// simulator. Every screen the app can show is visited in order and captured as
// a screenshot, so a build can be reviewed by looking at the images instead of
// by tapping through by hand.
//
// Screenshots are taken by `scripts/e2e_shot_server.py` running on the host:
// the app pauses on a blocking HTTP request while the host grabs the
// framebuffer, so each PNG is the exact frame the surrounding assertions just
// checked. When the server is not running the requests fail fast and the
// walkthrough still runs (and still asserts) — it just produces no images.
//
// Launch via scripts/e2e-walkthrough.sh, or by hand:
//   python3 scripts/e2e_shot_server.py &
//   flutter test integration_test/e2e_walkthrough_test.dart \
//     -d <simulator-udid> --dart-define=LIBERATED_BREAD_MOCK=true
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:liberated_bread_mobile/app.dart';
import 'package:liberated_bread_mobile/core/theme.dart';
import 'package:liberated_bread_mobile/models/ble_discovered_service.dart';
import 'package:liberated_bread_mobile/models/iot_device.dart';
import 'package:liberated_bread_mobile/providers/ble_provider.dart';
import 'package:liberated_bread_mobile/screens/device_screen.dart';
import 'package:liberated_bread_mobile/screens/scan_screen.dart';
import 'package:liberated_bread_mobile/services/ble_service.dart';
import 'package:liberated_bread_mobile/src/rust/frb_generated.dart';

/// Port `scripts/e2e_shot_server.py` listens on. The iOS Simulator shares the
/// host's loopback interface, so 127.0.0.1 reaches the host directly.
const _shotPort = int.fromEnvironment('E2E_SHOT_PORT', defaultValue: 8099);

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  // Keep frames flowing continuously so what is on screen when a screenshot is
  // taken matches what the test has pumped.
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;

  // Registered before any test so it runs last: a screenshot the host captured
  // but rejected (blank/black frame) must fail the run, not be swallowed.
  tearDownAll(_assertAllShotsCaptured);

  setUpAll(() async {
    // Same initialization main() does: the Rust core backs mock reads/writes
    // and all spec parsing/encoding.
    try {
      await RustLib.init();
    } catch (e) {
      debugPrint('[e2e] RustLib.init failed: $e');
    }
  });

  testWidgets('01 scan: launch, scan, devices appear', (tester) async {
    await tester.pumpWidget(const ProviderScope(child: LiberatedBreadApp()));
    await _soak(tester, const Duration(seconds: 2));

    expect(find.text('Scan for BLE Devices'), findsOneWidget);
    expect(find.text('MOCK'), findsOneWidget,
        reason: 'run with --dart-define=LIBERATED_BREAD_MOCK=true');
    await _shot(tester, '01_launch_scan_idle');

    await tester.tap(find.byType(FloatingActionButton));
    await _soak(tester, const Duration(milliseconds: 400));
    expect(find.text('Scanning...'), findsOneWidget);
    await _shot(tester, '02_scan_in_progress');

    await _soak(tester, const Duration(seconds: 2));
    expect(find.text('ACME_Living_Room'), findsOneWidget);
    expect(find.text('ACME_Bedroom'), findsOneWidget);
    await _shot(tester, '03_devices_found');

    // The mock scan self-terminates a few seconds after the last device.
    await _soak(tester, const Duration(seconds: 5));
    expect(find.text('Scan'), findsOneWidget);
    await _shot(tester, '04_scan_finished');
  });

  testWidgets('02 device: connect, typed controls, commands', (tester) async {
    await tester.pumpWidget(const ProviderScope(child: LiberatedBreadApp()));
    await _soak(tester, const Duration(seconds: 1));
    await tester.tap(find.byType(FloatingActionButton));
    await _soak(tester, const Duration(seconds: 2));

    await tester.tap(find.text('ACME_Living_Room'));
    await _soak(tester, const Duration(milliseconds: 300));
    expect(find.textContaining('...'), findsWidgets);
    await _shot(tester, '05_device_connecting');

    await _soak(tester, const Duration(seconds: 3));
    // The mock device matches assets/device_specs/example-bulb.yaml, so the
    // spec-typed controls render instead of the raw hex browser.
    expect(find.text('Control Service'), findsOneWidget);
    expect(find.text('Power on'), findsWidgets);
    await _shot(tester, '06_device_typed_controls');

    // Fixed command: one tap writes the spec-encoded bytes.
    await tester.tap(find.widgetWithText(ElevatedButton, 'Power on'));
    await _soak(tester, const Duration(seconds: 1));
    expect(find.text('Sent'), findsWidgets);
    await _shot(tester, '07_fixed_command_sent');

    // Parameterized command: move the brightness slider, then send. The Send
    // button is an ElevatedButton.icon, whose runtime type is private, so match
    // on its label instead of its type.
    await tester.drag(find.byType(Slider).first, const Offset(90, 0));
    await _soak(tester, const Duration(milliseconds: 500));
    final send = find.text('Send').first;
    await tester.ensureVisible(send);
    await _soak(tester, const Duration(milliseconds: 300));
    await tester.tap(send);
    await _soak(tester, const Duration(seconds: 1));
    await _shot(tester, '08_parameterized_command_sent');

    // Decoded (spec-formatted) values live further down the list.
    await tester.drag(find.byType(ListView).first, const Offset(0, -600));
    await _soak(tester, const Duration(seconds: 2));
    await _shot(tester, '09_decoded_values');

    // Battery service sits at the bottom.
    await tester.drag(find.byType(ListView).first, const Offset(0, -600));
    await _soak(tester, const Duration(seconds: 2));
    await _shot(tester, '10_battery_service');

    // Back out to the scan list.
    await tester.pageBack();
    await _soak(tester, const Duration(seconds: 1));
    expect(find.text('ACME_Living_Room'), findsOneWidget);
    await _shot(tester, '11_back_on_scan_list');
  });

  testWidgets('03 spec packs: list, validation, install', (tester) async {
    await tester.pumpWidget(const ProviderScope(child: LiberatedBreadApp()));
    await _soak(tester, const Duration(seconds: 1));

    await tester.tap(find.byTooltip('Device Spec Packs'));
    await _soak(tester, const Duration(seconds: 2));
    expect(find.text('Device Spec Packs'), findsOneWidget);
    await _shot(tester, '12_spec_packs_screen');

    // Client-side URL validation.
    await _type(tester, find.byType(TextField), 'not-a-url');
    await tester.tap(find.text('Install / Refresh'));
    await _soak(tester, const Duration(seconds: 1));
    expect(find.text('Enter a valid http:// or https:// URL.'), findsOneWidget);
    await _shot(tester, '13_spec_pack_invalid_url');

    // A syntactically valid but unreachable host exercises the network error
    // path deterministically, with no dependency on outbound connectivity.
    await _type(tester, find.byType(TextField), 'http://127.0.0.1:9/pack.json');
    await tester.tap(find.text('Install / Refresh'));
    // Either error is a pass here: a refused connection reports "could not
    // reach", a blackholed one reports a timeout. Both mention the connection.
    await _waitFor(tester, find.textContaining('your connection'));
    await _shot(tester, '14_spec_pack_network_error');
    expect(find.textContaining('your connection'), findsOneWidget);

    // The host-side fixture pack: a real download + parse + cache round trip.
    await _type(tester, find.byType(TextField),
        'http://127.0.0.1:$_shotPort/pack/pack.json');
    await tester.tap(find.text('Install / Refresh'));
    await _waitFor(tester, find.textContaining('Installed "E2E Demo Pack"'));
    await _soak(tester, const Duration(seconds: 1));
    await _shot(tester, '15_spec_pack_installed');
    expect(find.textContaining('Installed "E2E Demo Pack"'), findsOneWidget);
    expect(find.textContaining('E2E Demo Pack  ·  v1.0.0'), findsOneWidget);

    // The app's shipped default URL — recorded as-is, success or failure.
    await tester.tap(find.text('Reset URL'));
    await _soak(tester, const Duration(seconds: 1));
    await tester.tap(find.text('Install / Refresh'));
    await _soak(tester, const Duration(seconds: 20));
    await _shot(tester, '16_spec_pack_default_url_result');

    await tester.tap(find.byTooltip('Clear all packs'));
    await _soak(tester, const Duration(seconds: 1));
    expect(find.text('Clear all packs?'), findsOneWidget);
    await _shot(tester, '17_spec_pack_clear_all_dialog');

    await tester.tap(find.widgetWithText(FilledButton, 'Clear all'));
    await _soak(tester, const Duration(seconds: 2));
    await _shot(tester, '18_spec_packs_cleared');
  });

  testWidgets('04 home assistant settings', (tester) async {
    await tester.pumpWidget(const ProviderScope(child: LiberatedBreadApp()));
    await _soak(tester, const Duration(seconds: 1));

    await tester.tap(find.byTooltip('Home Assistant'));
    await _soak(tester, const Duration(seconds: 2));
    expect(find.text('Home Assistant'), findsWidgets);
    expect(find.text('Connect'), findsOneWidget);
    await _shot(tester, '19_ha_settings_form');

    // Empty form -> inline validation.
    await tester.tap(find.text('Connect'));
    await _soak(tester, const Duration(seconds: 1));
    expect(find.text('Enter both a URL and an access token.'), findsOneWidget);
    await _shot(tester, '20_ha_missing_fields');

    // A non-local URL surfaces the Tailscale remote-access hint.
    await _type(tester, find.byType(TextField).first, 'http://192.0.2.10:8123');
    await _shot(tester, '21_ha_url_hint');

    // 192.0.2.0/24 is TEST-NET-1: routable-looking but guaranteed dead, so the
    // connect attempt always ends in the network-error message.
    await _type(tester, find.byType(TextField).last, 'not-a-real-token');
    await tester.tap(find.text('Connect'));
    await _waitFor(tester, find.textContaining('Could not reach the server'));
    await _shot(tester, '22_ha_connect_failure');
    expect(find.textContaining('Could not reach the server'), findsOneWidget);
  });

  testWidgets('05 raw GATT browser for an unmatched device', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          bleServiceProvider.overrideWithValue(_UnmatchedBleService())
        ],
        child: MaterialApp(
          theme: LiberatedBreadTheme.light,
          home: DeviceScreen(device: _unmatchedDevice),
        ),
      ),
    );
    await _soak(tester, const Duration(seconds: 2));

    // No bundled spec matches, so the raw hex browser renders.
    expect(find.text('Write hex'), findsOneWidget);
    expect(find.text('0a 1b 2c'), findsOneWidget);
    await _shot(tester, '23_raw_gatt_browser');

    // The write row sits at the top of this screen, so the keyboard never
    // covers it and plain enterText is enough.
    await tester.enterText(find.byType(TextField), 'zz');
    await tester.tap(find.byTooltip('Write'));
    await _waitFor(tester, find.textContaining('Invalid hex'));
    await _shot(tester, '24_raw_write_invalid_hex');
    expect(find.textContaining('Invalid hex'), findsOneWidget);

    await tester.enterText(find.byType(TextField), '01 ff 42');
    await tester.tap(find.byTooltip('Write'));
    await _waitFor(tester, find.textContaining('Wrote'));
    await _shot(tester, '25_raw_write_ok');
    expect(find.text('Wrote 01 ff 42'), findsOneWidget);
  });

  testWidgets('06 scan empty / error / permission states', (tester) async {
    // Permission denied.
    await _pumpScan(tester,
        _ScriptedBleService(scanError: const BlePermissionDeniedException()));
    await tester.tap(find.byType(FloatingActionButton));
    await _soak(tester, const Duration(seconds: 2));
    expect(find.text('Bluetooth permission needed'), findsOneWidget);
    await _shot(tester, '26_permission_denied');

    // Scan completed with nothing in range.
    await _pumpScan(tester, _ScriptedBleService());
    await tester.tap(find.byType(FloatingActionButton));
    await _soak(tester, const Duration(seconds: 2));
    expect(find.text('No devices found'), findsOneWidget);
    await _shot(tester, '27_no_devices_found');

    // Radio off — the typed failure RealBleService raises when the adapter is
    // not on. The user gets guidance; "Bad state:" (Dart's rendering of a
    // StateError) must never reach the screen.
    await _pumpScan(tester,
        _ScriptedBleService(scanError: const BleUnavailableException()));
    await tester.tap(find.byType(FloatingActionButton));
    await _soak(tester, const Duration(seconds: 2));
    expect(find.textContaining('Bluetooth is turned off'), findsOneWidget);
    expect(find.textContaining('Bad state'), findsNothing);
    await _shot(tester, '28_scan_error');
  });

  testWidgets('07 device connect failure and disconnect', (tester) async {
    final service = _ScriptedBleService(connectError: StateError('link lost'));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [bleServiceProvider.overrideWithValue(service)],
        child: MaterialApp(
          theme: LiberatedBreadTheme.light,
          home: DeviceScreen(device: _unmatchedDevice),
        ),
      ),
    );
    await _soak(tester, const Duration(seconds: 2));
    expect(find.text('Retry'), findsOneWidget);
    // An untyped failure takes the generic path: guidance, never the raw
    // exception text the fake threw.
    expect(find.textContaining('Could not connect to this device'),
        findsOneWidget);
    expect(find.textContaining('link lost'), findsNothing);
    expect(find.textContaining('Bad state'), findsNothing);
    await _shot(tester, '29_device_connect_error');

    // Let the retry succeed, then drop the link out from under the screen.
    service.connectError = null;
    await tester.tap(find.text('Retry'));
    await _soak(tester, const Duration(seconds: 2));
    service.dropConnection();
    await _soak(tester, const Duration(seconds: 2));
    expect(find.text('Device disconnected'), findsOneWidget);
    await _shot(tester, '30_device_disconnected');
  });
}

// ── walkthrough helpers ──────────────────────────────────────────────────────

/// Pump real frames for [total]. Used instead of `pumpAndSettle` because the
/// app legitimately never settles on several screens (progress spinners, the
/// 2-second notify poll), which would make `pumpAndSettle` time out.
Future<void> _soak(WidgetTester tester, Duration total) async {
  const step = Duration(milliseconds: 100);
  for (var elapsed = Duration.zero; elapsed < total; elapsed += step) {
    await tester.pump(step);
  }
}

/// Pump until [finder] matches something, or [timeout] elapses. Used for steps
/// that wait on real network I/O, where a fixed sleep is either flaky or slow.
Future<void> _waitFor(
  WidgetTester tester,
  Finder finder, [
  Duration timeout = const Duration(seconds: 30),
]) async {
  const slice = Duration(milliseconds: 250);
  for (var waited = Duration.zero; waited < timeout; waited += slice) {
    if (finder.evaluate().isNotEmpty) return;
    await tester.pump(slice);
  }
}

/// Enter [text] into [field] and dismiss the on-screen keyboard again. The
/// keyboard shrinks the viewport, and the settings screens are lazy [ListView]s,
/// so leaving it up culls the buttons below the fold out of the widget tree.
Future<void> _type(WidgetTester tester, Finder field, String text) async {
  // Tap first: a previous _type dropped focus, and re-focusing explicitly keeps
  // the text-input connection in sync before the value is replaced.
  await tester.tap(field);
  await _soak(tester, const Duration(milliseconds: 500));
  await tester.enterText(field, text);
  await _soak(tester, const Duration(milliseconds: 500));
  // On a real device the keyboard is the platform's, not TestTextInput, so
  // dropping focus is what dismisses it.
  FocusManager.instance.primaryFocus?.unfocus();
  await _soak(tester, const Duration(seconds: 1));
}

/// Screenshots the server accepted the request for but rejected the *frame* of
/// — e.g. a blank or black capture. Collected rather than thrown at the point
/// of failure so one bad frame doesn't hide the rest of the walkthrough, then
/// reported by [_assertAllShotsCaptured] in tearDownAll.
final _badShots = <String>[];

/// Ask the host to capture the simulator/device screen. Blocking, so the frame
/// captured is the one currently on screen.
///
/// Two failure modes, deliberately treated differently:
///
///  * **No server** (connection refused/timed out) — tolerated. Running the
///    walkthrough without `e2e_shot_server.py` is a supported mode: the steps
///    and their assertions still run, there are simply no images.
///  * **Server rejected the frame** (HTTP 422 — capture failed, or the PNG is
///    too small to be anything but a blank screen) — recorded and failed at the
///    end. A screenshot harness that silently accepts garbage is worse than no
///    harness, because it produces evidence that isn't.
Future<void> _shot(WidgetTester tester, String name) async {
  await tester.runAsync(() async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 5);
    try {
      final request = await client
          .getUrl(Uri.parse('http://127.0.0.1:$_shotPort/shot?name=$name'));
      final response = await request.close();
      final body = await response.transform(const Utf8Decoder()).join();
      if (response.statusCode == 200) {
        debugPrint('[e2e] screenshot $name -> ok');
      } else {
        _badShots.add('$name (HTTP ${response.statusCode}: ${body.trim()})');
        debugPrint('[e2e] screenshot $name -> REJECTED: ${body.trim()}');
      }
    } on SocketException catch (e) {
      // No server listening: supported, no images this run.
      debugPrint(
          '[e2e] screenshot $name skipped, no shot server: ${e.message}');
    } on HttpException catch (e) {
      debugPrint(
          '[e2e] screenshot $name skipped, no shot server: ${e.message}');
    } finally {
      client.close(force: true);
    }
  });
}

/// Fail the run if the shot server reported any capture as bad. Registered as a
/// tearDownAll so it reports every bad frame at once instead of aborting the
/// walkthrough at the first one.
void _assertAllShotsCaptured() {
  if (_badShots.isEmpty) return;
  final list = _badShots.map((s) => '  - $s').join('\n');
  fail('${_badShots.length} screenshot(s) were captured but rejected as not '
      'showing real UI:\n$list');
}

/// Mount a fresh [ScanScreen] over [service]. The key is per-call so pumping a
/// second scenario replaces the State (which caches the BLE service and the
/// last scan outcome) instead of reusing the previous one.
int _scanScreenGeneration = 0;

Future<void> _pumpScan(WidgetTester tester, BleService service) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [bleServiceProvider.overrideWithValue(service)],
      child: MaterialApp(
        theme: LiberatedBreadTheme.light,
        home: ScanScreen(key: ValueKey('scan-${_scanScreenGeneration++}')),
      ),
    ),
  );
  await _soak(tester, const Duration(seconds: 1));
}

// ── scripted services ────────────────────────────────────────────────────────

final _unmatchedDevice = IoTDevice(
  id: 'AA:BB:CC:DD:EE:99',
  name: 'Generic_Sensor',
  rssi: -55,
  isConnectable: true,
  discoveredAt: DateTime(2026, 6, 24),
);

/// A device whose name and services match no bundled spec, so [DeviceScreen]
/// falls back to the raw hex GATT browser.
class _UnmatchedBleService implements BleService {
  final _values = <String, List<int>>{
    '0000ab01-0000-1000-8000-00805f9b34fb': [0x0a, 0x1b, 0x2c],
  };

  @override
  Future<bool> requestPermissions() async => true;

  @override
  Future<int> mtu(String deviceId) async => 23;

  @override
  Stream<IoTDevice> scan({Duration timeout = const Duration(seconds: 10)}) =>
      const Stream.empty();

  @override
  Future<void> stopScan() async {}

  @override
  Future<void> connect(String deviceId) async {}

  @override
  Future<void> disconnect(String deviceId) async {}

  @override
  Stream<BleConnectionState> connectionState(String deviceId) =>
      const Stream.empty();

  @override
  Future<List<BleDiscoveredService>> discoverServices(String deviceId) async {
    return const [
      BleDiscoveredService(
        uuid: '0000ab00-0000-1000-8000-00805f9b34fb',
        characteristics: [
          BleDiscoveredCharacteristic(
            uuid: '0000ab01-0000-1000-8000-00805f9b34fb',
            canRead: true,
            canWrite: true,
            canNotify: false,
          ),
        ],
      ),
    ];
  }

  @override
  Future<List<int>> readCharacteristic(String d, String s, String c) async =>
      _values[c] ?? const [0];

  @override
  Future<void> writeCharacteristic(
      String d, String s, String c, List<int> value) async {
    _values[c] = value;
  }

  @override
  Stream<List<int>> subscribeCharacteristic(String d, String s, String c) =>
      const Stream.empty();
}

/// A BLE service whose scan and connect outcomes are set by the test, used to
/// reach the empty, permission-denied, error and disconnected screens.
class _ScriptedBleService implements BleService {
  _ScriptedBleService({this.scanError, this.connectError});

  Object? scanError;
  Object? connectError;
  final _connection = StreamController<BleConnectionState>.broadcast();

  void dropConnection() => _connection.add(BleConnectionState.disconnected);

  @override
  Future<bool> requestPermissions() async => scanError == null;

  @override
  Future<int> mtu(String deviceId) async => 23;

  @override
  Stream<IoTDevice> scan({Duration timeout = const Duration(seconds: 10)}) {
    if (scanError case final Object error) {
      return Stream<IoTDevice>.error(error);
    }
    return const Stream<IoTDevice>.empty();
  }

  @override
  Future<void> stopScan() async {}

  @override
  Future<void> connect(String deviceId) async {
    if (connectError case final Object error) throw error;
    _connection.add(BleConnectionState.connected);
  }

  @override
  Future<void> disconnect(String deviceId) async {}

  @override
  Stream<BleConnectionState> connectionState(String deviceId) =>
      _connection.stream;

  @override
  Future<List<BleDiscoveredService>> discoverServices(String deviceId) async =>
      const [];

  @override
  Future<List<int>> readCharacteristic(String d, String s, String c) async =>
      const [];

  @override
  Future<void> writeCharacteristic(
      String d, String s, String c, List<int> v) async {}

  @override
  Stream<List<int>> subscribeCharacteristic(String d, String s, String c) =>
      const Stream.empty();
}
