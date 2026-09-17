// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// What only a PHYSICAL phone can answer.
//
// The iOS Simulator has no Bluetooth radio, does not implement Local Network
// privacy, ignores entitlements, and keeps a keychain that is not the one a
// shipped app gets. So every suite in ci_all_test.dart runs in mock mode and
// proves the state machines, not the platform. This suite is the other half:
// it runs the SHIPPING services — RealBleService, RealNetworkScanService,
// SecureSettingsStore, the bundled Rust core — against the real radio, the
// real Wi-Fi and the real keychain, and reports what the phone actually did.
// HARDWARE_LATER.md is the checklist these runs sign off.
//
// It is opt-in three ways, so nothing here can run by accident:
//   * @Tags(['hardware']) keeps it out of the CI aggregate and the Linux
//     per-file loop (test/platform/integration_aggregate_test.dart and
//     scripts/ci-linux-tests.sh both know the tag);
//   * every test skips itself unless the build carries
//     --dart-define=LB_HARDWARE=true;
//   * even then it refuses the Simulator, where every assertion below would
//     be about a platform that is not there.
//
// scripts/run-ios-device-tests.sh does the setup: finds the paired iPhone,
// handles the multicast entitlement (its header says how), passes the defines
// and runs this file. By hand:
//
//   flutter test integration_test/device_hardware_test.dart \
//     -d <udid> --dart-define=LB_HARDWARE=true
//
// Extra defines, each read below where it is used:
//   LB_MULTICAST_ENTITLED=false  the build was signed WITHOUT the multicast
//                                entitlement, so a silent Wi-Fi scan is the
//                                expected outcome rather than a finding
//   LB_EXPECT_LAN_DEVICES=true   the phone is on a Wi-Fi network with at least
//                                one discoverable device, so hearing nothing
//                                is a failure and not a note
//   LB_LIVE_BLE_NAME=<name>      a BLE peripheral advertising under that name
//                                is in range: scan for it, connect, discover
//                                its services, read MTU and RSSI, disconnect
//   LB_LIVE_BLE_ANY=true         the same, against the strongest CONNECTABLE
//                                advertiser in range. Read-only: connect,
//                                discover, disconnect — nothing is written
//
// Every test prints what it measured under a `[hardware]` prefix, because a
// green run is only half the point — the numbers (catalogue parse time on a
// phone, advertisers heard, hosts found) are what the audit's estimates were
// missing.
//
// ORDER. Service-level tests first, each on its own instance; the shipped
// entrypoint boots LAST. main() starts a continuous scan the moment the scan
// screen appears, and FlutterBluePlus is one static radio, so anything
// scanning after it would be sharing the adapter with the app.
@Tags(['hardware'])
library;

import 'dart:convert' show jsonDecode;
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_blue_plus/flutter_blue_plus.dart'
    show BluetoothAdapterState, FlutterBluePlus;
import 'package:flutter_riverpod/flutter_riverpod.dart' show ProviderContainer;
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:liberated_bread_mobile/app.dart';
import 'package:liberated_bread_mobile/core/constants.dart';
import 'package:liberated_bread_mobile/main.dart' as app;
import 'package:liberated_bread_mobile/models/iot_device.dart';
import 'package:liberated_bread_mobile/models/network_device.dart';
import 'package:liberated_bread_mobile/providers/network_scan_provider.dart'
    show NetworkIdentity;
import 'package:liberated_bread_mobile/providers/scan_match_provider.dart'
    show specIdentitiesProvider;
import 'package:liberated_bread_mobile/providers/device_spec_provider.dart'
    show specAssetPath, specManifestPath;
import 'package:liberated_bread_mobile/screens/scan_screen.dart';
import 'package:liberated_bread_mobile/screens/terms_screen.dart';
import 'package:liberated_bread_mobile/services/mock_ble_service.dart'
    show MockBleService;
import 'package:liberated_bread_mobile/services/network_scan_service.dart';
import 'package:liberated_bread_mobile/services/real_ble_service.dart';
import 'package:liberated_bread_mobile/services/real_network_scan_service.dart';
import 'package:liberated_bread_mobile/services/real_spec_codec.dart';
import 'package:liberated_bread_mobile/services/secure_settings_store.dart';
import 'package:liberated_bread_mobile/src/rust/api/device_api.dart'
    show NetworkDeviceDto, identifyStandardProfiles;
import 'package:liberated_bread_mobile/src/rust/frb_generated.dart'
    show RustLib;

const bool _hardwareRun = bool.fromEnvironment('LB_HARDWARE');
const bool _multicastEntitled = bool.fromEnvironment(
  'LB_MULTICAST_ENTITLED',
  defaultValue: true,
);
const bool _expectLanDevices = bool.fromEnvironment('LB_EXPECT_LAN_DEVICES');
const String _liveBleName = String.fromEnvironment('LB_LIVE_BLE_NAME');
const bool _liveBleAny = bool.fromEnvironment('LB_LIVE_BLE_ANY');

/// The Battery Service, the same probe native_core_test.dart uses: a standard
/// profile the Rust side recognises without any spec loaded.
const String _batteryService = '0000180f-0000-1000-8000-00805f9b34fb';

/// Whether this process is the iOS Simulator.
///
/// By the executable's path: a simulator app lives under the host's
/// `.../CoreSimulator/Devices/<udid>/...` container, a device app under
/// `/private/var/containers/...`. NOT by the `SIMULATOR_*` environment
/// variables — CoreSimulator sets those for processes it spawns itself, and
/// an app launched by `flutter test` does not see them: the first version of
/// this check let the whole suite run on a simulator, where it happily
/// scanned the Mac's own network and called the missing radio a result.
bool get _onSimulator =>
    Platform.resolvedExecutable.contains('/CoreSimulator/') ||
    Platform.environment.containsKey('SIMULATOR_DEVICE_NAME') ||
    Platform.environment.containsKey('SIMULATOR_UDID');

/// Skips the current test with the reason, unless this is a hardware run on a
/// real device. Returns true when the caller should return immediately.
bool _skipUnlessHardware() {
  if (!_hardwareRun) {
    markTestSkipped(
      'not a hardware run: pass --dart-define=LB_HARDWARE=true '
      '(scripts/run-ios-device-tests.sh does)',
    );
    return true;
  }
  if (_onSimulator) {
    markTestSkipped(
      'this is the iOS Simulator: no radio, no Local Network '
      'privacy, and not the keychain a shipped app gets',
    );
    return true;
  }
  return false;
}

void _say(String line) => debugPrint('[hardware] $line');

/// The adapter state the Bluetooth test observed, so the entrypoint test at
/// the end can hold the scan screen to the same standard.
BluetoothAdapterState? _observedAdapterState;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('the bundled Rust core loads and answers on this phone', (
    tester,
  ) async {
    if (_skipUnlessHardware()) return;
    // No try/catch: main() swallows a failed init by design, this suite does
    // not. The default loader is the subject — a framework inside Runner.app
    // that dyld cannot resolve is exactly the failure a host test cannot see.
    if (!MockBleService.rustAvailable) {
      await RustLib.init();
    }
    expect(MockBleService.rustAvailable, isTrue);
    final profiles = await identifyStandardProfiles(
      serviceUuids: <String>[_batteryService],
    );
    expect(profiles, hasLength(1));
    expect(profiles.single.profileName, 'Battery Service');
  });

  testWidgets('every bundled spec parses on this phone, and how long it takes', (
    tester,
  ) async {
    if (_skipUnlessHardware()) return;
    if (!MockBleService.rustAvailable) await RustLib.init();

    // The same index the app's catalogue provider reads, without the provider:
    // this measures the two costs the audit could only estimate from a Mac
    // mini — asset round trips and FFI parse time — on the phone that pays
    // them at startup (F-024, F-059).
    final raw = await rootBundle.loadString(specManifestPath);
    final index = jsonDecode(raw);
    expect(index, isA<List<dynamic>>());
    final paths = <String>[
      for (final entry in index as List<dynamic>)
        if (entry is Map && entry['path'] is String)
          specAssetPath(entry['path'] as String),
    ];
    expect(paths, isNotEmpty, reason: 'the vendored index lists no specs');

    final loading = Stopwatch()..start();
    final yamls = await Future.wait(paths.map(rootBundle.loadString));
    loading.stop();

    const codec = RealSpecCodec();
    final failures = <String>[];
    var slowest = Duration.zero;
    var slowestPath = '';
    final parsing = Stopwatch()..start();
    for (var i = 0; i < yamls.length; i++) {
      final one = Stopwatch()..start();
      try {
        await codec.loadDeviceSpec(yamls[i]);
      } catch (e) {
        failures.add('${paths[i]}: $e');
      }
      if (one.elapsed > slowest) {
        slowest = one.elapsed;
        slowestPath = paths[i];
      }
    }
    parsing.stop();

    _say(
      'catalogue: ${paths.length} specs; assets loaded in '
      '${loading.elapsedMilliseconds} ms; parsed in '
      '${parsing.elapsedMilliseconds} ms '
      '(slowest ${slowest.inMilliseconds} ms: $slowestPath)',
    );
    expect(
      failures,
      isEmpty,
      reason: 'specs the bundled core cannot parse:\n${failures.join('\n')}',
    );
    // Generous on purpose: this is a ceiling against a phone that is
    // unusably slow, not a performance target. The printed number is the
    // measurement.
    expect(
      parsing.elapsed,
      lessThan(const Duration(seconds: 15)),
      reason: 'parsing the catalogue took ${parsing.elapsed} on this phone',
    );
  });

  testWidgets(
    'Bluetooth: the radio reports a real state, and scan() classifies it',
    (tester) async {
      if (_skipUnlessHardware()) return;

      // On a fresh install this is the moment CoreBluetooth raises its
      // permission alert; the state stays `unknown` until it is answered. The
      // wait is long so a person can answer it.
      _say(
        'waiting for CoreBluetooth to report an adapter state — if the '
        'Bluetooth permission alert is up, answer it now',
      );
      final state = await FlutterBluePlus.adapterState
          .where((s) => s != BluetoothAdapterState.unknown)
          .first
          .timeout(
            const Duration(seconds: 60),
            onTimeout: () => BluetoothAdapterState.unknown,
          );
      _observedAdapterState = state;
      _say('adapter state: ${state.name}');
      expect(
        state,
        isNot(BluetoothAdapterState.unknown),
        reason:
            'CoreBluetooth reported no state in 60 s. Either the alert '
            'went unanswered, or the plugin never saw '
            'centralManagerDidUpdateState (F-002 territory).',
      );

      // What the service is contractually expected to surface for this state —
      // the same pure mapping the scan screen's recovery buttons are built on.
      final expected = adapterStateError(state);

      final ble = RealBleService();
      final seen = <String, IoTDevice>{};
      Object? failure;
      final scanning = Stopwatch()..start();
      try {
        await for (final device in ble.scan(
          timeout: const Duration(seconds: 8),
        )) {
          seen[device.id] = device;
        }
      } catch (e) {
        failure = e;
      }
      scanning.stop();
      _say(
        'scan: ${seen.length} advertiser(s) in ${scanning.elapsed}; '
        'error: ${failure ?? 'none'}',
      );
      final named = seen.values.where((d) => d.name.isNotEmpty).take(12);
      for (final d in named) {
        _say('  ${d.name}  rssi ${d.rssi}  ${d.id}');
      }

      if (expected == null) {
        expect(
          failure,
          isNull,
          reason: 'the radio is on but scan() failed with: $failure',
        );
        // No lower bound on advertisers: an empty room is a legitimate answer.
      } else {
        expect(
          failure,
          isNotNull,
          reason:
              'adapter state is ${state.name} but scan() completed as if '
              'the radio were usable — the screen would show an empty list '
              'with no recovery',
        );
        expect(
          failure.runtimeType,
          expected.runtimeType,
          reason:
              'scan() must surface ${expected.runtimeType} for adapter '
              'state ${state.name}, so the screen can offer the matching '
              'recovery (F-002, F-023): got $failure',
        );
      }
    },
  );

  testWidgets(
    'Wi-Fi: a real discovery scan completes on this network and classifies '
    'its outcome',
    (tester) async {
      if (_skipUnlessHardware()) return;
      if (!MockBleService.rustAvailable) await RustLib.init();

      // The codec runs the Kasa cipher on the discovery datagram, as production
      // wires it; without it that transport does not run.
      final service = RealNetworkScanService(codec: const RealSpecCodec());
      final found = <String, NetworkDevice>{};
      Object? failure;
      final scanning = Stopwatch()..start();
      try {
        await for (final device in service.scan(
          timeout: const Duration(seconds: 8),
        )) {
          found[device.host] = device;
        }
      } catch (e) {
        failure = e;
      }
      scanning.stop();
      _say(
        'network scan: ${found.length} host(s) in ${scanning.elapsed}; '
        'error: ${failure ?? 'none'}; '
        'multicast entitlement in this build: $_multicastEntitled',
      );
      for (final d in found.values) {
        _say(
          '  ${d.host}  ${d.name}  mdns=${d.serviceTypes} '
          'ssdp=${d.ssdpTargets}',
        );
      }

      // What the catalogue makes of each host, through the same matcher the
      // Wi-Fi tab uses. A recognised printer or hub on the operator's network
      // is the end-to-end proof that discovery, the identity projection and
      // the Rust matcher agree on a real device; a row that should have
      // matched and did not is a finding with its evidence already printed.
      if (found.isNotEmpty) {
        final container = ProviderContainer();
        addTearDown(container.dispose);
        final identities = await container.read(specIdentitiesProvider.future);
        const codec = RealSpecCodec();
        var recognised = 0;
        for (final d in found.values) {
          final identity = NetworkIdentity.of(d);
          final matches = await codec.matchNetworkDevice(
            identities: identities,
            device: NetworkDeviceDto(
              name: identity.name,
              hostname: identity.hostname,
              serviceTypes: identity.serviceTypes,
              ssdpTargets: identity.ssdpTargets,
              answeredLanProtocols: identity.answeredLanProtocols,
              port: identity.port,
              txt: identity.txt,
              mac: identity.mac,
            ),
          );
          if (matches.isEmpty) continue;
          recognised++;
          final best = matches.first;
          _say(
            '  ${d.host} -> ${best.deviceName} (${best.manufacturer}, '
            '${best.confidence.name}; ${matches.length} candidate(s))',
          );
        }
        _say(
          'catalogue: $recognised of ${found.length} host(s) recognised '
          'against ${identities.length} identities',
        );
      }

      // The scan's own contract, whatever the network: it ends near its budget,
      // and the only errors it surfaces are its own user-facing types. A raw
      // SocketException or OSError here is a bug in error classification.
      expect(
        scanning.elapsed,
        lessThan(const Duration(seconds: 30)),
        reason: 'an 8 s scan ran for ${scanning.elapsed}',
      );
      expect(
        failure,
        anyOf(
          isNull,
          isA<LocalNetworkDeniedException>(),
          isA<NetworkUnavailableException>(),
        ),
        reason: 'scan() leaked an unclassified error: $failure',
      );

      if (!_multicastEntitled) {
        // Signed without com.apple.developer.networking.multicast: iOS refuses
        // every multicast and broadcast send, so silence is the expected
        // outcome and the app is expected to say so.
        if (failure is! LocalNetworkDeniedException) {
          _say(
            'NOTE: this build has no multicast entitlement yet the scan '
            'heard something (${found.length} host(s), error '
            '${failure ?? 'none'}). Worth understanding: it means at least '
            'one transport works without the entitlement.',
          );
        }
        return;
      }
      if (_expectLanDevices) {
        expect(
          failure,
          isNull,
          reason:
              'the operator says discoverable devices are on this '
              'network, but the scan reported: $failure. Local Network '
              'permission denied, the entitlement missing from the profile, '
              'or the probes leaving on the wrong interface (F-014).',
        );
        expect(
          found,
          isNotEmpty,
          reason:
              'the operator says discoverable devices are on this '
              'network, but the scan found none',
        );
      } else if (failure is LocalNetworkDeniedException) {
        _say(
          'NOTE: heard nothing. If this phone is on a Wi-Fi network with '
          'devices, this is F-001/F-015 in the wild — the entitled build '
          'reports a denial for a network that may just be quiet. Re-run '
          'with --expect-lan-devices to make that a failure.',
        );
      }
    },
  );

  testWidgets(
    'keychain: the shipping store writes, enumerates and deletes under the '
    'device-scoped class',
    (tester) async {
      if (_skipUnlessHardware()) return;

      // A real device keychain, not the simulator's. The write class
      // (first_unlock_this_device) and the read/delete class (any) differ on
      // purpose — see SecureSettingsStore — and this is the only place that
      // difference is exercised against the keychain a user has.
      final store = SecureSettingsStore();
      const key = 'hardware_probe';
      await store.delete(key);
      expect(await store.read(key), isNull);

      await store.write(key, 'v1');
      expect(await store.read(key), 'v1');
      expect(
        (await store.readAll())[key],
        'v1',
        reason:
            'readAll() cannot see what write() stored. Every enumerating '
            'caller — DeviceCredentialStore.credentials(), "forget this '
            'device" — is blind on this phone.',
      );

      await store.write(key, 'v2');
      expect(await store.read(key), 'v2', reason: 'overwrite did not take');

      await store.delete(key);
      expect(await store.read(key), isNull, reason: 'delete left the item');
      expect(await store.readAll(), isNot(contains(key)));
    },
  );

  testWidgets(
    'live BLE: scan for LB_LIVE_BLE_NAME, connect, discover, disconnect',
    (tester) async {
      if (_skipUnlessHardware()) return;
      if (_liveBleName.isEmpty && !_liveBleAny) {
        markTestSkipped(
          'pass --dart-define=LB_LIVE_BLE_NAME=<advertised name> '
          '(or LB_LIVE_BLE_ANY=true) with a peripheral in range',
        );
        return;
      }
      if (!MockBleService.rustAvailable) await RustLib.init();

      final ble = RealBleService();
      IoTDevice? target;
      if (_liveBleName.isNotEmpty) {
        _say('scanning up to 30 s for an advertiser named "$_liveBleName"');
        await for (final device in ble.scan(
          timeout: const Duration(seconds: 30),
        )) {
          if (device.name == _liveBleName) {
            target = device;
            break; // cancels the subscription, which stops the native scan
          }
        }
        expect(
          target,
          isNotNull,
          reason: 'no advertiser named "$_liveBleName" was heard in 30 s',
        );
      } else {
        // Read-only, so any connectable advertiser is fair game: the
        // strongest one after a 10 s window. Connect + discover + disconnect
        // writes nothing, and a peripheral that objects to being connected
        // to is itself worth knowing about.
        _say('scanning 10 s for the strongest connectable advertiser');
        final seen = <String, IoTDevice>{};
        await for (final device in ble.scan(
          timeout: const Duration(seconds: 10),
        )) {
          if (device.isConnectable) seen[device.id] = device;
        }
        expect(
          seen,
          isNotEmpty,
          reason: 'no connectable advertiser was heard in 10 s',
        );
        target = seen.values.reduce((x, y) => x.rssi >= y.rssi ? x : y);
      }
      final id = target!.id;
      _say('found "${target.name}" as $id (rssi ${target.rssi}); connecting');

      await ble.connect(id);
      try {
        final services = await ble.discoverServices(id);
        _say('${services.length} service(s):');
        for (final s in services) {
          _say('  ${s.uuid}  ${s.characteristics.length} characteristic(s)');
        }
        expect(
          services,
          isNotEmpty,
          reason:
              'connected but discovered no services — a GATT peripheral '
              'always has at least Generic Access',
        );
        final mtu = await ble.mtu(id);
        final rssi = await ble.readRssi(id);
        _say('mtu $mtu, rssi $rssi dBm while connected');
        expect(mtu, greaterThanOrEqualTo(23));
      } finally {
        await ble.disconnect(id);
      }
    },
  );

  // LAST — see the header.
  testWidgets('the shipped entrypoint boots to the scan screen in real mode', (
    tester,
  ) async {
    if (_skipUnlessHardware()) return;

    await app.main();

    const step = Duration(milliseconds: 100);
    // A fresh install shows the terms gate first; accept it, exactly as
    // app_launch_test.dart does, so the boot proceeds.
    for (
      var waited = Duration.zero;
      waited < const Duration(seconds: 20) &&
          find.byType(TermsScreen).evaluate().isEmpty &&
          find.byType(ScanScreen).evaluate().isEmpty;
      waited += step
    ) {
      await tester.pump(step);
    }
    if (find.byType(TermsScreen).evaluate().isNotEmpty) {
      final accept = find.text('I understand and agree');
      await tester.ensureVisible(accept);
      await tester.pump();
      await tester.tap(accept);
      await tester.pump();
    }
    for (
      var waited = Duration.zero;
      waited < const Duration(seconds: 20) &&
          find.byType(ScanScreen).evaluate().isEmpty;
      waited += step
    ) {
      await tester.pump(step);
    }
    expect(find.byType(LiberatedBreadApp), findsOneWidget);
    expect(find.byType(ScanScreen), findsOneWidget);
    expect(find.text(AppConstants.appName), findsOneWidget);

    // Let the launch scan run for a moment. With the radio on, the screen
    // must not be showing a failure headline: that is the first-launch
    // impression F-002 describes.
    for (
      var waited = Duration.zero;
      waited < const Duration(seconds: 5);
      waited += step
    ) {
      await tester.pump(step);
    }
    final failed = find.textContaining('Scan failed').evaluate().isNotEmpty;
    _say(
      'scan screen after 5 s: ${failed ? 'shows "Scan failed"' : 'no '
                'failure headline'}; adapter state seen earlier: '
      '${_observedAdapterState?.name ?? 'not observed'}',
    );
    if (_observedAdapterState == BluetoothAdapterState.on) {
      expect(
        failed,
        isFalse,
        reason:
            'the radio was on a moment ago, yet the launch scan shows '
            '"Scan failed"',
      );
    }
  });
}
