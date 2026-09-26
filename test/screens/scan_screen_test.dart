// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/core/device_category.dart';
import 'package:liberated_bread_mobile/models/iot_device.dart';
import 'package:liberated_bread_mobile/providers/ble_provider.dart';
import 'package:liberated_bread_mobile/providers/device_spec_provider.dart';
import 'package:liberated_bread_mobile/providers/ha_provider.dart';
import 'package:liberated_bread_mobile/providers/spec_codec_provider.dart';
import 'package:liberated_bread_mobile/services/ble_service.dart';
import 'package:liberated_bread_mobile/services/device_manager.dart';
import 'package:liberated_bread_mobile/services/spec_codec.dart';
import 'package:liberated_bread_mobile/screens/device_screen.dart';
import 'package:liberated_bread_mobile/screens/ha_settings_screen.dart';
import 'package:liberated_bread_mobile/screens/radio_device_screen.dart';
import 'package:liberated_bread_mobile/screens/scan_screen.dart';
import 'package:liberated_bread_mobile/services/baofeng_ble_programmer.dart'
    show baofengUartService;
import 'package:liberated_bread_mobile/widgets/device_list_tile.dart';
import 'package:liberated_bread_mobile/providers/saved_device_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../fakes/fake_ble_service.dart';
import '../fakes/fake_ha_api_client.dart';
import '../fakes/fake_spec_codec.dart';
import '../fakes/in_memory_settings_store.dart';

/// Resolved in [setUp] so the scan screen can read saved devices synchronously
/// during build, the same way `main()` wires it in production.
late SharedPreferences _prefs;

Widget _wrap(FakeBleService fake) => ProviderScope(
  overrides: [
    bleServiceProvider.overrideWithValue(fake),
    sharedPreferencesProvider.overrideWithValue(_prefs),
  ],
  child: const MaterialApp(home: ScanScreen()),
);

/// A scanned device, last heard [seenAgo] before now.
///
/// The stamp is relative to the real clock rather than a fixed date because
/// that is what the screen classifies rows against — a fixture pinned to
/// January would render every row as months stale.
IoTDevice _device(
  String id, {
  String? name,
  int rssi = -40,
  bool connectable = true,
  Duration seenAgo = Duration.zero,
  List<String> services = const [],
}) {
  final seen = DateTime.now().subtract(seenAgo);
  return IoTDevice(
    id: id,
    name: name ?? 'dev-$id',
    rssi: rssi,
    isConnectable: connectable,
    discoveredAt: seen,
    lastSeen: seen,
    serviceUuids: services,
  );
}

/// A fake that holds its scan teardown open until the test lets go — the
/// window a second tap on the same row lands in.
class _GatedStopFakeBleService extends FakeBleService {
  /// Held stops. Nulled by [release], after which stops answer at once — the
  /// screen's dispose calls one, and it must not be left outstanding.
  Completer<void>? _gate = Completer<void>();

  _GatedStopFakeBleService({super.devicesToEmit});

  void release() {
    _gate?.complete();
    _gate = null;
  }

  @override
  Future<void> stopScan() async {
    await _gate?.future;
    return super.stopScan();
  }
}

/// A fake whose platform can refuse the app Bluetooth permission after the
/// fact — what iOS reports as an `unauthorized` adapter state.
class _DenyingFakeBleService extends FakeBleService
    implements BleAuthorizationWatcher {
  _DenyingFakeBleService(
    this.unauthorizedStream, {
    super.devicesToEmit,
    super.scanStepDelay,
    super.scanError,
  });

  final Stream<bool> unauthorizedStream;

  /// What [isAuthorized] answers — the platform's word, asked without a
  /// prompt. Refused until a test grants it in "Settings" between two
  /// resumes.
  bool authorized = false;
  int authorizationChecks = 0;

  @override
  Stream<bool> adapterUnauthorized() => unauthorizedStream;

  @override
  Future<bool> isAuthorized() async {
    authorizationChecks++;
    return authorized;
  }
}

/// The one spec in the catalogue for the ranking tests below.
final _catalogueSpec = DeviceSpecDto(
  nameMatchers: const [],
  platformFallbackTypes: const [],
  txtMatchGroups: const [],
  hiddenEntityNames: const [],
  deviceName: 'Example Smart Bulb',
  manufacturer: 'Acme',
  manufacturerStatus: 'abandoned',
  protocol: 'ble',
  category: 'light',
  localNamePrefixes: const ['ACME_'],
  localNames: const [],
  serviceUuids: const [],
  companyIds: Uint16List(0),
  macPrefixes: const [],
  mdnsServiceTypes: const [],
  ssdpSearchTargets: const [],
  lanProtocols: const [],
  defaultPort: null,
  entities: const <EntityDto>[],
  services: const [],
);

ScanMatch _scanMatch(
  MatchConfidence confidence, {
  String? category = 'light',
}) => ScanMatch(
  specIndex: 0,
  deviceName: 'Example Smart Bulb',
  manufacturer: 'Acme',
  category: category,
  confidence: confidence,
  matchedByNamePrefix: false,
  matchedServiceUuids: const [],
  matchedCompanyIds: Uint16List(0),
  matchedMacPrefix: null,
  matchedServiceTypes: const [],
);

void main() {
  group('ageTickNeedsRepaint', () {
    test('a tick with nothing stale and nothing dropped draws nothing', () {
      expect(
        ageTickNeedsRepaint(
          dropped: false,
          stale: const {},
          previouslyStale: const {},
        ),
        isFalse,
      );
    });

    test('a row crossing into stale is drawn', () {
      expect(
        ageTickNeedsRepaint(
          dropped: false,
          stale: const {'a'},
          previouslyStale: const {},
        ),
        isTrue,
      );
    });

    test('a row coming back from stale is drawn', () {
      expect(
        ageTickNeedsRepaint(
          dropped: false,
          stale: const {},
          previouslyStale: const {'a'},
        ),
        isTrue,
      );
    });

    test('an unchanged stale row is STILL drawn, because its count moves', () {
      // The one that is easy to get wrong: comparing the sets alone leaves
      // "Not seen for 90s" frozen at 90s for the minutes before the row is
      // dropped, and nothing else will ever repaint it — a device that
      // stopped advertising does not advertise.
      expect(
        ageTickNeedsRepaint(
          dropped: false,
          stale: const {'a'},
          previouslyStale: const {'a'},
        ),
        isTrue,
      );
    });

    test('an eviction is drawn even with nothing stale left', () {
      expect(
        ageTickNeedsRepaint(
          dropped: true,
          stale: const {},
          previouslyStale: const {},
        ),
        isTrue,
      );
    });
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    _prefs = await SharedPreferences.getInstance();
  });

  testWidgets('scans on arrival, without being asked', (tester) async {
    // Discovery is not a thing to press a button for: a device powered on
    // after the screen opened should turn up by itself.
    final fake = FakeBleService(devicesToEmit: [_device('01', name: 'ACME_A')]);
    await tester.pumpWidget(_wrap(fake));

    expect(find.text('Searching for devices...'), findsOneWidget);
    expect(find.text('Found'), findsNothing);

    await tester.pumpAndSettle();

    expect(find.text('ACME_A'), findsOneWidget);
    expect(find.text('Found'), findsOneWidget);
  });

  testWidgets('asks for a scan with no window of its own', (tester) async {
    // A bounded scan would answer "what was on air during those 30 seconds";
    // the screen wants "what is on air", which is a scan with no timeout.
    final fake = FakeBleService();
    await tester.pumpWidget(_wrap(fake));
    await tester.pumpAndSettle();

    expect(fake.scanTimeouts, [null]);
  });

  testWidgets('populates the list after scan', (tester) async {
    final fake = FakeBleService(
      devicesToEmit: [
        _device('01', name: 'ACME_A', rssi: -40),
        _device('02', name: 'ACME_B', rssi: -60),
      ],
    );
    await tester.pumpWidget(_wrap(fake));

    await tester.tap(find.byType(FloatingActionButton));
    await tester.pumpAndSettle();

    expect(find.text('ACME_A'), findsOneWidget);
    expect(find.text('Found'), findsOneWidget);
    expect(find.text('2 devices found'), findsOneWidget);
    // The docked ad bar costs the list a row of viewport; the second device
    // sits below the fold until scrolled to.
    await tester.scrollUntilVisible(find.text('ACME_B'), 80);
    expect(find.text('ACME_B'), findsOneWidget);
  });

  group('app lifecycle', () {
    testWidgets('stops scanning in the background and resumes on return', (
      tester,
    ) async {
      // A continuous scan is the most expensive thing this app does, and in
      // the background it is expensive for nothing: the OS stops delivering.
      final fake = FakeBleService(
        devicesToEmit: [_device('01')],
        scanStepDelay: const Duration(milliseconds: 200),
      );
      await tester.pumpWidget(_wrap(fake));
      await tester.pump(const Duration(milliseconds: 50));
      expect(fake.scanTimeouts, hasLength(1));

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pumpAndSettle();
      expect(fake.stopScanCount, greaterThan(0));

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(
        fake.scanTimeouts,
        hasLength(2),
        reason: 'coming back to the screen means looking again',
      );
    });

    testWidgets('coming back to a device screen does not restart the scan', (
      tester,
    ) async {
      // Opening a device stops the scan on purpose — a connect on a scanning
      // adapter is flaky. Backgrounding the app from the device screen and
      // returning must not undo that behind the pushed route.
      final fake = FakeBleService(
        devicesToEmit: [_device('01', name: 'ACME_A')],
      );
      await tester.pumpWidget(_wrap(fake));
      await tester.pumpAndSettle();

      await tester.tap(find.text('ACME_A'));
      await tester.pumpAndSettle();
      final scansBefore = fake.scanTimeouts.length;

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pumpAndSettle();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();

      expect(
        fake.scanTimeouts,
        hasLength(scansBefore),
        reason: 'the device screen is still open; the radio stays off',
      );
    });

    testWidgets('the find flow keeps its RSSI ping and the scan stays off', (
      tester,
    ) async {
      // The Find Device view navigates by pinging the CONNECTION's RSSI once
      // a second — a connected peripheral stops advertising, so no amount of
      // scanning can see it, and a scan restarting behind the route would
      // only add radio contention to the very readings the user is walking
      // by. This walks the real stack (scan list → device screen → find) and
      // checks both halves survive a background/resume cycle.
      final fake = FakeBleService(
        devicesToEmit: [_device('01', name: 'ACME_A')],
      );
      await tester.pumpWidget(_wrap(fake));
      await tester.pumpAndSettle();

      await tester.tap(find.text('ACME_A'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Find device'));
      await tester.pumpAndSettle();

      final scansBefore = fake.scanTimeouts.length;
      final pingsBefore = fake.rssiReadCount;
      expect(
        pingsBefore,
        greaterThan(0),
        reason: 'the find screen pings the device from the moment it opens',
      );

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pumpAndSettle();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump(const Duration(seconds: 2));

      expect(
        fake.scanTimeouts,
        hasLength(scansBefore),
        reason:
            'no scan may start behind the find screen: it cannot see '
            'a connected device and competes with the link being measured',
      );
      expect(
        fake.rssiReadCount,
        greaterThan(pingsBefore),
        reason: 'the aliveness ping keeps running',
      );
    });

    testWidgets('a scan the user stopped is not resurrected by the OS', (
      tester,
    ) async {
      final fake = FakeBleService(
        devicesToEmit: [_device('01')],
        scanStepDelay: const Duration(milliseconds: 200),
      );
      await tester.pumpWidget(_wrap(fake));
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tap(find.byType(FloatingActionButton));
      await tester.pumpAndSettle();

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pumpAndSettle();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();

      expect(
        fake.scanTimeouts,
        hasLength(1),
        reason: 'off means off, however the app came and went',
      );
    });
  });

  group('scan intensity', () {
    testWidgets('everything the screen starts by itself is ambient', (
      tester,
    ) async {
      // Nobody pressed anything: the launch scan must take the duty-cycled
      // mode, or the energy story only holds for people who never open the
      // app.
      final fake = FakeBleService(devicesToEmit: [_device('01')]);
      await tester.pumpWidget(_wrap(fake));
      await tester.pumpAndSettle();

      expect(fake.scanIntensities, [ScanIntensity.ambient]);
    });

    testWidgets('pressing Scan buys a low-latency burst', (tester) async {
      final fake = FakeBleService(
        devicesToEmit: [_device('01')],
        scanHold: Completer<void>(),
      );
      await tester.pumpWidget(_wrap(fake));
      await tester.pump(const Duration(milliseconds: 50));

      // Stop the ambient scan, then ask for one explicitly.
      await tester.tap(find.byType(FloatingActionButton));
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tap(find.byType(FloatingActionButton));
      await tester.pump(const Duration(milliseconds: 50));

      expect(fake.scanIntensities, [
        ScanIntensity.ambient,
        ScanIntensity.active,
      ]);
    });

    testWidgets('the burst downshifts to ambient after its window', (
      tester,
    ) async {
      // A press buys thirty seconds of continuous listening, not a permanent
      // mode — otherwise one tap re-pins the radio for the whole session.
      final fake = FakeBleService(
        devicesToEmit: [_device('01')],
        scanHold: Completer<void>(),
      );
      await tester.pumpWidget(_wrap(fake));
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tap(find.byType(FloatingActionButton)); // stop
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tap(find.byType(FloatingActionButton)); // active burst
      await tester.pump(const Duration(milliseconds: 50));

      await tester.pump(const Duration(seconds: 31));

      expect(fake.scanIntensities, [
        ScanIntensity.ambient,
        ScanIntensity.active,
        ScanIntensity.ambient,
      ]);
      // Seamless: still scanning, still a stop button on screen.
      expect(find.byIcon(Icons.stop), findsOneWidget);
    });

    testWidgets('retry after a failure is an explicit ask, so it bursts', (
      tester,
    ) async {
      final fake = FakeBleService(scanError: StateError('boom'));
      await tester.pumpWidget(_wrap(fake));
      await tester.pumpAndSettle();

      fake.scanError = null;
      await tester.tap(find.widgetWithText(ElevatedButton, 'Retry'));
      await tester.pumpAndSettle();

      expect(fake.scanIntensities.last, ScanIntensity.active);
    });
  });

  group('radio recovery', () {
    testWidgets('resumes by itself when Bluetooth comes back on', (
      tester,
    ) async {
      // On Android the radio is toggled from quick settings, without the app
      // ever losing focus — no lifecycle event will announce the fix. The
      // adapter stream is the only messenger.
      // Broadcast: matches fbp's adapterState, and a single-subscription
      // controller that never gains a listener hangs its own close() in
      // teardown — turning a would-be assertion failure into a timeout.
      final radio = StreamController<bool>.broadcast();
      addTearDown(radio.close);
      final fake = FakeBleService(
        scanError: const BleUnavailableException(),
        adapterReadyStream: radio.stream,
        devicesToEmit: [_device('01', name: 'ACME_A')],
      );
      await tester.pumpWidget(_wrap(fake));
      await tester.pumpAndSettle();
      expect(find.textContaining('Bluetooth is turned off'), findsOneWidget);

      fake.scanError = null; // the radio works again
      radio.add(true);
      await tester.pumpAndSettle();

      expect(find.text('ACME_A'), findsOneWidget);
      expect(find.textContaining('Bluetooth is turned off'), findsNothing);
      expect(fake.scanTimeouts, hasLength(2));
    });

    testWidgets('does not resurrect a scan the user stopped', (tester) async {
      // Broadcast: matches fbp's adapterState, and a single-subscription
      // controller that never gains a listener hangs its own close() in
      // teardown — turning a would-be assertion failure into a timeout.
      final radio = StreamController<bool>.broadcast();
      addTearDown(radio.close);
      final fake = FakeBleService(
        devicesToEmit: [_device('01')],
        scanStepDelay: const Duration(milliseconds: 200),
        adapterReadyStream: radio.stream,
      );
      await tester.pumpWidget(_wrap(fake));
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tap(find.byType(FloatingActionButton));
      await tester.pumpAndSettle();

      radio.add(true);
      await tester.pumpAndSettle();

      expect(
        fake.scanTimeouts,
        hasLength(1),
        reason: 'a ready radio is an opportunity, not an instruction',
      );
    });

    testWidgets('a ready signal during a healthy scan changes nothing', (
      tester,
    ) async {
      // fbp replays the current adapter state to every new listener, so this
      // exact event arrives moments after every launch.
      // Broadcast: matches fbp's adapterState, and a single-subscription
      // controller that never gains a listener hangs its own close() in
      // teardown — turning a would-be assertion failure into a timeout.
      final radio = StreamController<bool>.broadcast();
      addTearDown(radio.close);
      final fake = FakeBleService(
        devicesToEmit: [_device('01')],
        scanHold: Completer<void>(),
        adapterReadyStream: radio.stream,
      );
      await tester.pumpWidget(_wrap(fake));
      await tester.pump(const Duration(milliseconds: 50));

      radio.add(true);
      await tester.pump(const Duration(milliseconds: 100));

      expect(fake.scanTimeouts, hasLength(1));
      expect(fake.stopScanCount, 0);
    });
  });

  group('tab visibility', () {
    /// The screen as the shell mounts it: alive either way, told whether it is
    /// the tab being looked at.
    Widget wrapActive(FakeBleService fake, {required bool active}) =>
        ProviderScope(
          overrides: [
            bleServiceProvider.overrideWithValue(fake),
            sharedPreferencesProvider.overrideWithValue(_prefs),
          ],
          child: MaterialApp(home: ScanScreen(active: active)),
        );

    testWidgets('a tab nobody is looking at does not run the radio', (
      tester,
    ) async {
      final fake = FakeBleService(devicesToEmit: [_device('01')]);
      await tester.pumpWidget(wrapActive(fake, active: false));
      await tester.pumpAndSettle();

      expect(fake.scanTimeouts, isEmpty);
    });

    testWidgets('leaving the tab pauses the scan and returning resumes it', (
      tester,
    ) async {
      // scanHold keeps the fake's scan open, the way the real continuous
      // scan stays open, so the deferred stop finds one running.
      final fake = FakeBleService(
        devicesToEmit: [_device('01')],
        scanHold: Completer<void>(),
      );
      await tester.pumpWidget(wrapActive(fake, active: true));
      await tester.pump(const Duration(milliseconds: 50));
      expect(fake.scanTimeouts, hasLength(1));

      await tester.pumpWidget(wrapActive(fake, active: false));
      // The stop is deferred a couple of seconds so a glance away does not
      // cycle the radio; a real departure outlasts it.
      await tester.pump(const Duration(seconds: 3));
      expect(fake.stopScanCount, greaterThan(0));

      await tester.pumpWidget(wrapActive(fake, active: true));
      // Bounded pumps, not pumpAndSettle: the resumed scan holds the radar
      // animation live, so there is no settled frame to wait for.
      await tester.pump(const Duration(milliseconds: 100));
      expect(fake.scanTimeouts, hasLength(2));
    });

    testWidgets('a quick glance at another tab never touches the radio', (
      tester,
    ) async {
      // Every return is a native scan START, and Android blocks an app that
      // starts more than five in thirty seconds — so a fidgety afternoon of
      // tab flipping must not become a stop/start each way.
      final fake = FakeBleService(
        devicesToEmit: [_device('01')],
        scanHold: Completer<void>(),
      );
      await tester.pumpWidget(wrapActive(fake, active: true));
      await tester.pump(const Duration(milliseconds: 50));

      await tester.pumpWidget(wrapActive(fake, active: false));
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pumpWidget(wrapActive(fake, active: true));
      await tester.pump(const Duration(milliseconds: 100));

      expect(
        fake.stopScanCount,
        0,
        reason: 'the glance ended inside the grace window',
      );
      expect(
        fake.scanTimeouts,
        hasLength(1),
        reason: 'the original scan never stopped, so nothing restarted',
      );
    });

    testWidgets('what the scan already found survives the trip', (
      tester,
    ) async {
      // Keeping the state is the whole reason the shell holds the tab alive;
      // pausing the radio must not throw the list away with it.
      final fake = FakeBleService(
        devicesToEmit: [_device('01', name: 'ACME_A')],
      );
      await tester.pumpWidget(wrapActive(fake, active: true));
      await tester.pumpAndSettle();
      expect(find.text('ACME_A'), findsOneWidget);

      await tester.pumpWidget(wrapActive(fake, active: false));
      await tester.pumpAndSettle();
      await tester.pumpWidget(wrapActive(fake, active: true));
      await tester.pumpAndSettle();

      expect(find.text('ACME_A'), findsOneWidget);
    });

    testWidgets('coming back does not restart a scan the user stopped', (
      tester,
    ) async {
      final fake = FakeBleService(
        devicesToEmit: [_device('01')],
        scanStepDelay: const Duration(milliseconds: 200),
      );
      await tester.pumpWidget(wrapActive(fake, active: true));
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tap(find.byType(FloatingActionButton));
      await tester.pumpAndSettle();

      await tester.pumpWidget(wrapActive(fake, active: false));
      await tester.pumpAndSettle();
      await tester.pumpWidget(wrapActive(fake, active: true));
      await tester.pumpAndSettle();

      expect(fake.scanTimeouts, hasLength(1));
    });
  });

  group('devices that go quiet', () {
    testWidgets('a device not heard from lately is flagged, not dropped', (
      tester,
    ) async {
      // Both rows have to be laid out at once to compare their positions, and
      // the docked ad bar leaves no room for the second on the default surface.
      tester.view.physicalSize = const Size(1200, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final fake = FakeBleService(
        devicesToEmit: [
          // The quiet one has by far the better *last* reading, which is exactly
          // the trap: that number is a memory, not a measurement.
          _device('01', name: 'ACME_Here', rssi: -80),
          _device(
            '02',
            name: 'ACME_Quiet',
            rssi: -30,
            seenAgo: DeviceManager.staleAfter * 2,
          ),
        ],
      );
      await tester.pumpWidget(_wrap(fake));
      await tester.pumpAndSettle();

      // Still listed — advertising is lossy and it is probably still there —
      // but no longer claiming a live signal, and no longer above the devices
      // the scan can actually still hear.
      expect(find.text('ACME_Quiet'), findsOneWidget);
      expect(find.byIcon(Icons.warning_amber_rounded), findsOneWidget);
      expect(find.textContaining('Not seen for'), findsOneWidget);
      expect(
        tester.getTopLeft(find.text('ACME_Here')).dy,
        lessThan(tester.getTopLeft(find.text('ACME_Quiet')).dy),
      );
    });

    testWidgets('a device still advertising carries no warning', (
      tester,
    ) async {
      final fake = FakeBleService(
        devicesToEmit: [_device('01', name: 'ACME_Here')],
      );
      await tester.pumpWidget(_wrap(fake));
      await tester.pumpAndSettle();

      expect(find.byIcon(Icons.warning_amber_rounded), findsNothing);
      expect(find.text('Strong signal'), findsOneWidget);
    });

    testWidgets('a device silent long enough is dropped from the list', (
      tester,
    ) async {
      // Past the point where a tap could do anything but time out, the row
      // stops being an offer.
      final fake = FakeBleService(
        devicesToEmit: [
          _device(
            '01',
            name: 'ACME_Gone',
            seenAgo: DeviceManager.forgetAfter + const Duration(seconds: 1),
          ),
        ],
      );
      await tester.pumpWidget(_wrap(fake));
      await tester.pumpAndSettle();
      expect(find.text('ACME_Gone'), findsOneWidget);

      // The screen re-examines freshness on a clock tick, so a device that
      // simply stopped talking still ages out with nothing arriving.
      await tester.pump(const Duration(seconds: 6));

      expect(find.text('ACME_Gone'), findsNothing);
      expect(find.text('No devices found'), findsOneWidget);
    });
  });

  group('ranking recognised devices', () {
    /// Wires the scan screen with a spec catalogue, so the scan-time matcher
    /// actually runs. [matchFor] answers per device name.
    Widget wrapWithCatalogue(
      FakeBleService fake, {
      required List<ScanMatch> Function(String deviceName) matchFor,
    }) => ProviderScope(
      overrides: [
        bleServiceProvider.overrideWithValue(fake),
        sharedPreferencesProvider.overrideWithValue(_prefs),
        deviceSpecsProvider.overrideWith((ref) => {'bulb.yaml': 'yaml'}),
        specCodecProvider.overrideWithValue(
          FakeSpecCodec(
            spec: _catalogueSpec,
            scanMatches: (device) => matchFor(device.name),
          ),
        ),
      ],
      child: const MaterialApp(home: ScanScreen()),
    );

    testWidgets('a matched device is drawn with its device-type icon', (
      tester,
    ) async {
      final fake = FakeBleService(
        devicesToEmit: [_device('01', name: 'ACME_Bulb')],
      );
      await tester.pumpWidget(
        wrapWithCatalogue(
          fake,
          matchFor: (_) => [_scanMatch(MatchConfidence.strong)],
        ),
      );

      await tester.tap(find.byType(FloatingActionButton));
      await tester.pumpAndSettle();

      expect(find.byIcon(DeviceCategory.light.icon), findsOneWidget);
      // The generic glyph the radar draws is not in a row.
      expect(
        find.descendant(
          of: find.byType(DeviceListTile),
          matching: find.byIcon(unknownDeviceIcon),
        ),
        findsNothing,
      );
    });

    testWidgets('an unmatched device keeps the anonymous glyph', (
      tester,
    ) async {
      // The icon is only ever drawn from a matched spec. "LEDBlue-A1B2C3"
      // reads like a light, and reading it would put a guess in the same
      // glyph as a real match.
      final fake = FakeBleService(
        devicesToEmit: [_device('01', name: 'LEDBlue-A1B2C3')],
      );
      await tester.pumpWidget(
        wrapWithCatalogue(fake, matchFor: (_) => const []),
      );

      await tester.tap(find.byType(FloatingActionButton));
      await tester.pumpAndSettle();

      expect(find.byIcon(DeviceCategory.light.icon), findsNothing);
      expect(
        find.descendant(
          of: find.byType(DeviceListTile),
          matching: find.byIcon(unknownDeviceIcon),
        ),
        findsOneWidget,
      );
    });

    testWidgets('an OUI-only match still shows the type it agrees on', (
      tester,
    ) async {
      // The badge stays hedged — "Possibly Acme", not a product name — while
      // the icon says the one thing the tie does agree on.
      final fake = FakeBleService(
        devicesToEmit: [_device('01', name: 'Mystery')],
      );
      await tester.pumpWidget(
        wrapWithCatalogue(
          fake,
          matchFor: (_) => [
            _scanMatch(MatchConfidence.possible),
            _scanMatch(MatchConfidence.possible),
          ],
        ),
      );

      await tester.tap(find.byType(FloatingActionButton));
      await tester.pumpAndSettle();

      expect(find.text('Possibly Acme'), findsOneWidget);
      expect(find.text('Example Smart Bulb'), findsNothing);
      expect(find.byIcon(DeviceCategory.light.icon), findsOneWidget);
    });

    testWidgets('recognised devices get their own section, above the rest', (
      tester,
    ) async {
      // This asserts on the relative vertical positions of both section
      // headers, so both have to be laid out at once. The list is lazy and the
      // docked ad bar takes a slice of the viewport, which on the default test
      // surface leaves the second header unbuilt — and scrolling to it would
      // unbuild the first. A taller window is the honest fix: the ordering
      // rule under test has nothing to do with how much of it fits on screen.
      tester.view.physicalSize = const Size(1200, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final fake = FakeBleService(
        devicesToEmit: [
          // The unknown device has the far better signal, so ordering can only
          // come from what the catalogue knows.
          _device('01', name: 'Anonymous Thing', rssi: -30),
          _device('02', name: 'ACME_Bulb', rssi: -92),
        ],
      );
      await tester.pumpWidget(
        wrapWithCatalogue(
          fake,
          matchFor: (name) {
            return name == 'ACME_Bulb'
                ? [_scanMatch(MatchConfidence.strong)]
                : const [];
          },
        ),
      );

      await tester.tap(find.byType(FloatingActionButton));
      await tester.pumpAndSettle();

      expect(find.text('Likely supported'), findsOneWidget);
      expect(find.text('Other devices'), findsOneWidget);
      // The matched device carries the product name from the spec.
      expect(find.text('Example Smart Bulb'), findsOneWidget);

      final likelyHeader = tester.getTopLeft(find.text('Likely supported')).dy;
      final otherHeader = tester.getTopLeft(find.text('Other devices')).dy;
      final matched = tester.getTopLeft(find.text('ACME_Bulb')).dy;
      expect(likelyHeader, lessThan(matched));
      expect(matched, lessThan(otherHeader));

      // The louder unknown device is still listed, just below the fold.
      await tester.scrollUntilVisible(find.text('Anonymous Thing'), 200);
      expect(find.text('Anonymous Thing'), findsOneWidget);
    });

    testWidgets('an OUI-only match is a hint, not a supported-device claim', (
      tester,
    ) async {
      final fake = FakeBleService(
        devicesToEmit: [_device('01', name: 'Mystery')],
      );
      await tester.pumpWidget(
        wrapWithCatalogue(
          fake,
          matchFor: (_) => [_scanMatch(MatchConfidence.possible)],
        ),
      );

      await tester.tap(find.byType(FloatingActionButton));
      await tester.pumpAndSettle();

      expect(find.text('Likely supported'), findsNothing);
      expect(find.text('Possibly Acme'), findsOneWidget);
      // Never the product name off a shared OUI.
      expect(find.text('Example Smart Bulb'), findsNothing);
    });

    testWidgets('an unrecognised list keeps the plain Found header', (
      tester,
    ) async {
      final fake = FakeBleService(devicesToEmit: [_device('01')]);
      await tester.pumpWidget(
        wrapWithCatalogue(fake, matchFor: (_) => const []),
      );

      await tester.tap(find.byType(FloatingActionButton));
      await tester.pumpAndSettle();

      expect(find.text('Found'), findsOneWidget);
      expect(find.text('Other devices'), findsNothing);
    });
  });

  testWidgets('a scan in flight offers a small stop button, and it stops', (
    tester,
  ) async {
    // While scanning the control is a compact stop — the radar already says
    // "scanning", and the results are what the screen is for. It has to
    // actually stop the radio, not just restyle itself.
    final fake = FakeBleService(
      devicesToEmit: [_device('01')],
      scanStepDelay: const Duration(milliseconds: 200),
    );
    await tester.pumpWidget(_wrap(fake));
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.byIcon(Icons.stop), findsOneWidget);
    expect(find.byTooltip('Stop scanning — saves battery'), findsOneWidget);
    expect(find.text('Scan'), findsNothing);

    await tester.tap(find.byType(FloatingActionButton));
    await tester.pumpAndSettle();

    expect(fake.stopScanCount, greaterThan(0));
    // Stopped, nothing is happening, so the way back has to be the loud one.
    expect(find.widgetWithText(FloatingActionButton, 'Scan'), findsOneWidget);
    expect(find.byIcon(Icons.stop), findsNothing);
  });

  testWidgets('a stopped scan stays stopped until asked again', (tester) async {
    // Someone who turned the scan off wants it off: nothing may restart it
    // behind their back.
    final fake = FakeBleService(
      devicesToEmit: [_device('01')],
      scanStepDelay: const Duration(milliseconds: 200),
    );
    await tester.pumpWidget(_wrap(fake));
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(find.byType(FloatingActionButton));
    await tester.pumpAndSettle();

    final scansAfterStop = fake.scanTimeouts.length;
    await tester.pump(const Duration(seconds: 30));
    expect(fake.scanTimeouts.length, scansAfterStop);

    // ...and the button starts it again.
    await tester.tap(find.byType(FloatingActionButton));
    await tester.pumpAndSettle();
    expect(fake.scanTimeouts.length, scansAfterStop + 1);
  });

  testWidgets('renders error state when scan throws', (tester) async {
    final fake = FakeBleService(scanError: StateError('boom'));
    await tester.pumpWidget(_wrap(fake));

    await tester.tap(find.byType(FloatingActionButton));
    await tester.pumpAndSettle();

    // The user gets guidance, not the exception. 'Bad state:' is Dart's
    // rendering of a StateError and must never reach the screen.
    expect(find.textContaining('Scanning failed'), findsOneWidget);
    expect(find.textContaining('Bad state'), findsNothing);
    expect(find.textContaining('boom'), findsNothing);
  });

  testWidgets('settings gear opens the Home Assistant screen', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          bleServiceProvider.overrideWithValue(FakeBleService()),
          sharedPreferencesProvider.overrideWithValue(_prefs),
          settingsStoreProvider.overrideWithValue(InMemorySettingsStore()),
          haApiClientProvider.overrideWithValue(FakeHaApiClient()),
        ],
        child: const MaterialApp(home: ScanScreen()),
      ),
    );

    await tester.tap(find.byIcon(Icons.settings));
    await tester.pumpAndSettle();

    expect(find.byType(HaSettingsScreen), findsOneWidget);
  });

  testWidgets('shows a distinct no-results state after an empty scan', (
    tester,
  ) async {
    // Searching-and-found-nothing-yet vs done-and-found-nothing must not be
    // the same dead-end.
    final fake = FakeBleService();
    await tester.pumpWidget(_wrap(fake));

    // While the scan is live: no verdict yet.
    expect(find.text('Searching for devices...'), findsOneWidget);
    expect(find.text('No devices found'), findsNothing);

    await tester.pumpAndSettle();

    // After an empty scan: the distinct guidance + rescan action.
    expect(find.text('No devices found'), findsOneWidget);
    expect(find.textContaining('Move closer'), findsOneWidget);
    expect(find.text('Scan again'), findsOneWidget);
    expect(find.text('Scan for BLE Devices'), findsNothing);
  });

  testWidgets('permission denial shows specific guidance and open-settings', (
    tester,
  ) async {
    final fake = FakeBleService(
      scanError: const BlePermissionDeniedException(),
    );
    await tester.pumpWidget(_wrap(fake));

    await tester.tap(find.byType(FloatingActionButton));
    await tester.pumpAndSettle();

    expect(find.text('Bluetooth permission needed'), findsOneWidget);
    // The open-settings action uses a settings icon, not the refresh default.
    final openSettingsButton = find.widgetWithText(
      ElevatedButton,
      'Open settings',
    );
    expect(openSettingsButton, findsOneWidget);
    expect(
      find.descendant(
        of: openSettingsButton,
        matching: find.byIcon(Icons.settings),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: openSettingsButton,
        matching: find.byIcon(Icons.refresh),
      ),
      findsNothing,
    );
    await tester.scrollUntilVisible(find.text('Retry'), 80);
    expect(find.text('Retry'), findsOneWidget);
  });

  testWidgets(
    'a permission refused after the fact lands on the same guidance',
    (tester) async {
      // On iOS the denial can arrive as an adapter transition, not as the
      // answer to any scan: the user reads the system prompt for a while, or
      // revokes the grant in Settings. A screen between scans — here, one the
      // user stopped — would otherwise keep showing its older state, with no
      // route to the settings app (F-002).
      final denial = StreamController<bool>.broadcast();
      addTearDown(denial.close);
      final fake = _DenyingFakeBleService(
        denial.stream,
        devicesToEmit: [_device('01', name: 'ACME_A')],
        scanStepDelay: const Duration(milliseconds: 200),
      );
      await tester.pumpWidget(_wrap(fake));
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tap(find.byType(FloatingActionButton)); // stop
      await tester.pumpAndSettle();
      expect(find.text('Bluetooth permission needed'), findsNothing);

      denial.add(true);
      await tester.pumpAndSettle();

      expect(find.text('Bluetooth permission needed'), findsOneWidget);
      expect(
        find.widgetWithText(ElevatedButton, 'Open settings'),
        findsOneWidget,
      );
      expect(find.byIcon(Icons.stop), findsNothing);
      // The refusal is a fact about the app, not a reason to start scanning
      // into it: no automatic restart.
      final scansAtDenial = fake.scanTimeouts.length;
      await tester.pump(const Duration(seconds: 5));
      expect(fake.scanTimeouts.length, scansAtDenial);
    },
  );

  testWidgets('a grant arriving the way the refusal did clears the guidance', (
    tester,
  ) async {
    // iOS: allowing Bluetooth in Settings moves the adapter out of
    // `unauthorized`, and the watcher that carried the refusal carries the
    // grant. The guidance goes, and the screen looks again by itself — the
    // scan the denial ended was not one the user had stopped.
    final denial = StreamController<bool>.broadcast();
    addTearDown(denial.close);
    final fake = _DenyingFakeBleService(
      denial.stream,
      devicesToEmit: [_device('01', name: 'ACME_A')],
      scanStepDelay: const Duration(milliseconds: 200),
    );
    await tester.pumpWidget(_wrap(fake));
    await tester.pump(const Duration(milliseconds: 50));
    denial.add(true);
    await tester.pumpAndSettle();
    expect(find.text('Bluetooth permission needed'), findsOneWidget);
    final scansAtDenial = fake.scanTimeouts.length;

    denial.add(false);
    await tester.pumpAndSettle();

    expect(find.text('Bluetooth permission needed'), findsNothing);
    expect(
      fake.scanTimeouts,
      hasLength(scansAtDenial + 1),
      reason: 'permission back means looking again',
    );
  });

  testWidgets('coming back from Settings with the grant clears the guidance', (
    tester,
  ) async {
    // Android: a scan's permission request was refused, and the grant made
    // later in Settings restarts nothing and streams nothing. Returning to the
    // foreground on the guidance asks the platform — without a prompt — and
    // only a yes leaves the state; a no leaves it exactly as it was, with no
    // scan started into the refusal.
    final fake = _DenyingFakeBleService(
      const Stream<bool>.empty(),
      scanError: const BlePermissionDeniedException(),
    );
    await tester.pumpWidget(_wrap(fake));
    await tester.pumpAndSettle();
    expect(find.text('Bluetooth permission needed'), findsOneWidget);
    final scansAtDenial = fake.scanTimeouts.length;

    // Still refused: a phone call, answered and ended.
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pumpAndSettle();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(fake.authorizationChecks, 1, reason: 'asked, not prompted');
    expect(find.text('Bluetooth permission needed'), findsOneWidget);
    expect(fake.scanTimeouts, hasLength(scansAtDenial));

    // Granted in Settings, and back.
    fake
      ..authorized = true
      ..scanError = null;
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pumpAndSettle();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();

    expect(find.text('Bluetooth permission needed'), findsNothing);
    expect(fake.scanTimeouts, hasLength(scansAtDenial + 1));
  });

  testWidgets('a denial mid-scan ends the scan on the guidance, once', (
    tester,
  ) async {
    // The scan in flight hears the same denial from its own adapter watch;
    // the screen must not flip twice or leave the stop control up.
    final denial = StreamController<bool>.broadcast();
    addTearDown(denial.close);
    final fake = _DenyingFakeBleService(
      denial.stream,
      devicesToEmit: [_device('01', name: 'ACME_A')],
      scanStepDelay: const Duration(milliseconds: 200),
    );
    await tester.pumpWidget(_wrap(fake));
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.byIcon(Icons.stop), findsOneWidget);

    denial.add(true);
    await tester.pumpAndSettle();

    expect(find.text('Bluetooth permission needed'), findsOneWidget);
    expect(find.byIcon(Icons.stop), findsNothing);
    expect(find.widgetWithText(FloatingActionButton, 'Scan'), findsOneWidget);
  });

  // R-091: _resumeIfIdle had no idea the permission had been refused, and
  // every resume runs _startScan, which clears the flag on its way in. So a
  // glance at another tab, or a phone call, replaced the guidance with a
  // fresh scan — and on Android that scan asks the platform for the
  // permission all over again.
  testWidgets('a refusal survives the app coming back to the foreground', (
    tester,
  ) async {
    final fake = FakeBleService(
      scanError: const BlePermissionDeniedException(),
    );
    await tester.pumpWidget(_wrap(fake));
    await tester.pumpAndSettle();
    expect(find.text('Bluetooth permission needed'), findsOneWidget);
    final scansAtDenial = fake.scanTimeouts.length;

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();

    expect(find.text('Bluetooth permission needed'), findsOneWidget);
    expect(
      find.widgetWithText(ElevatedButton, 'Open settings'),
      findsOneWidget,
    );
    expect(
      fake.scanTimeouts.length,
      scansAtDenial,
      reason: 'the resume must not re-ask the platform',
    );
  });

  testWidgets('a refusal survives the tab being re-selected', (tester) async {
    final fake = FakeBleService(
      scanError: const BlePermissionDeniedException(),
    );
    Widget shell({required bool active}) => ProviderScope(
      overrides: [
        bleServiceProvider.overrideWithValue(fake),
        sharedPreferencesProvider.overrideWithValue(_prefs),
      ],
      child: MaterialApp(home: ScanScreen(active: active)),
    );

    await tester.pumpWidget(shell(active: true));
    await tester.pumpAndSettle();
    expect(find.text('Bluetooth permission needed'), findsOneWidget);
    final scansAtDenial = fake.scanTimeouts.length;

    await tester.pumpWidget(shell(active: false));
    await tester.pumpAndSettle();
    await tester.pumpWidget(shell(active: true));
    await tester.pumpAndSettle();

    expect(find.text('Bluetooth permission needed'), findsOneWidget);
    expect(fake.scanTimeouts.length, scansAtDenial);
  });

  // R-085: the stop before the push is a platform round trip, and a second
  // tap landing inside it opened a second DeviceScreen over the first, each
  // with its own connect to the same peripheral.
  testWidgets('a double tap opens one device screen, not two', (tester) async {
    // The stop is held open, as the platform call it stands in for can be —
    // that wait IS the window the second tap lands in.
    final fake = _GatedStopFakeBleService(
      devicesToEmit: [_device('01', name: 'ACME_A')],
    );
    await tester.pumpWidget(_wrap(fake));
    await tester.pumpAndSettle();

    await tester.tap(find.text('ACME_A'));
    // Deliberately NOT settled: the stop has not answered, so nothing has
    // been pushed and the row is still sitting there under the finger.
    await tester.pump();
    await tester.tap(find.text('ACME_A'), warnIfMissed: false);
    await tester.pump();

    fake.release();
    await tester.pumpAndSettle();

    // skipOffstage: false — a route fully covered by another is offstage, so
    // the default finder would report the second push as one screen.
    expect(find.byType(DeviceScreen, skipOffstage: false), findsOneWidget);
    expect(
      fake.stopScanCount,
      1,
      reason: 'the second tap is refused before it stops anything',
    );
  });

  testWidgets('tapping a device stops the scan before navigating', (
    tester,
  ) async {
    final fake = FakeBleService(devicesToEmit: [_device('01', name: 'ACME_A')]);
    await tester.pumpWidget(_wrap(fake));

    // The scan starts itself, and nothing has asked it to stop yet.
    await tester.pumpAndSettle();
    expect(fake.stopScanCount, 0);

    await tester.tap(find.text('ACME_A'));
    await tester.pump();

    // Scan is stopped before the device screen is pushed / connect begins.
    expect(fake.stopScanCount, greaterThan(0));

    await tester.pumpAndSettle();
  });

  testWidgets('non-connectable device tile has no chevron', (tester) async {
    final fake = FakeBleService(
      devicesToEmit: [_device('01', name: 'nope', connectable: false)],
    );
    await tester.pumpWidget(_wrap(fake));

    await tester.tap(find.byType(FloatingActionButton));
    await tester.pumpAndSettle();

    // Scoped to the list: the docked ad bar legitimately carries a chevron of
    // its own.
    expect(
      find.descendant(
        of: find.byType(ListView),
        matching: find.byIcon(Icons.chevron_right),
      ),
      findsNothing,
    );
  });

  group('radios', () {
    testWidgets('a radio gets a section of its own, above everything else', (
      tester,
    ) async {
      // Two sections compared by position: both must be laid out at once, and
      // the lazy list leaves the second unbuilt on the default surface.
      tester.view.physicalSize = const Size(1200, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final fake = FakeBleService(
        devicesToEmit: [
          _device('01', name: 'dev-anon'),
          _device('02', name: 'UV-5R Mini', services: [baofengUartService]),
        ],
      );
      await tester.pumpWidget(_wrap(fake));
      await tester.pumpAndSettle();

      expect(find.text('Radios'), findsOneWidget);
      expect(find.text('Radio'), findsOneWidget, reason: 'the badge');
      expect(find.text('Programs over Bluetooth'), findsOneWidget);
      // Above the rest, which is now "Other devices" rather than "Found".
      expect(find.text('Other devices'), findsOneWidget);
      expect(
        tester.getTopLeft(find.text('UV-5R Mini')).dy,
        lessThan(tester.getTopLeft(find.text('dev-anon')).dy),
      );
    });

    testWidgets('the programming service alone does not make a radio', (
      tester,
    ) async {
      // FFE0 is the generic HM-10 serial service: LED strips advertise it too,
      // and a score of catalogue devices declare it.
      final fake = FakeBleService(
        devicesToEmit: [
          _device('01', name: 'LEDBlue-1234', services: [baofengUartService]),
        ],
      );
      await tester.pumpWidget(_wrap(fake));
      await tester.pumpAndSettle();

      expect(find.text('Radios'), findsNothing);
      expect(find.text('LEDBlue-1234'), findsOneWidget);
    });

    testWidgets('"mini" alone does not make a radio', (tester) async {
      final fake = FakeBleService(
        devicesToEmit: [
          _device('01', name: 'Mini Speaker', services: [baofengUartService]),
        ],
      );
      await tester.pumpWidget(_wrap(fake));
      await tester.pumpAndSettle();

      expect(find.text('Radios'), findsNothing);
    });

    testWidgets('a name without the service is shown, but as a hint', (
      tester,
    ) async {
      final fake = FakeBleService(
        devicesToEmit: [_device('01', name: 'Baofeng radio')],
      );
      await tester.pumpWidget(_wrap(fake));
      await tester.pumpAndSettle();

      expect(find.text('Radios'), findsOneWidget);
      expect(
        find.textContaining('not advertising its programming service'),
        findsOneWidget,
      );
      final tile = tester.widget<DeviceListTile>(
        find.ancestor(
          of: find.text('Baofeng radio'),
          matching: find.byType(DeviceListTile),
        ),
      );
      expect(tile.badgeIsClaim, isFalse);
    });

    testWidgets('tapping a radio opens the radio screen, not the explorer', (
      tester,
    ) async {
      final fake = FakeBleService(
        devicesToEmit: [
          _device('02', name: 'UV-5R Mini', services: [baofengUartService]),
        ],
      );
      await tester.pumpWidget(_wrap(fake));
      await tester.pumpAndSettle();

      await tester.tap(find.text('UV-5R Mini'));
      await tester.pumpAndSettle();

      expect(
        fake.stopScanCount,
        greaterThan(0),
        reason: 'the scan stops before a radio is opened, as for any device',
      );
      expect(find.byType(RadioDeviceScreen), findsOneWidget);
      expect(find.byType(DeviceScreen), findsNothing);
      final screen = tester.widget<RadioDeviceScreen>(
        find.byType(RadioDeviceScreen),
      );
      expect(screen.target.id, '02');
      expect(
        screen.initialProfile?.id,
        'uv-5r-mini',
        reason: 'the advertised name suggests the model it spells',
      );
    });
  });
}
