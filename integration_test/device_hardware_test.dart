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
// The hardware sign-off checklist these runs answer is kept out of the
// repo (it names the paired phone); ask a maintainer for the current one.
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
//                                its services, read MTU and RSSI, disconnect.
//                                "Laser Distance Meter" additionally runs the
//                                JLX meter's whole session: it subscribes to
//                                f154 and WRITES init / link / measure to f151
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

import 'dart:async' show Completer, StreamSubscription, Timer, unawaited;
import 'dart:convert' show jsonDecode;
import 'dart:io' show Platform;
import 'dart:typed_data' show Uint16List;

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_blue_plus/flutter_blue_plus.dart'
    show BluetoothAdapterState, FlutterBluePlus;
import 'package:flutter_riverpod/flutter_riverpod.dart' show ProviderContainer;
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:liberated_bread_mobile/app.dart';
import 'package:liberated_bread_mobile/core/constants.dart';
import 'package:liberated_bread_mobile/core/error_text.dart'
    show UserFacingException;
import 'package:liberated_bread_mobile/core/hex.dart'
    show bytesToHex, normalizeUuid;
import 'package:liberated_bread_mobile/main.dart' as app;
import 'package:liberated_bread_mobile/models/iot_device.dart';
import 'package:liberated_bread_mobile/models/network_device.dart';
import 'package:liberated_bread_mobile/providers/network_scan_provider.dart'
    show NetworkIdentity;
import 'package:liberated_bread_mobile/providers/scan_match_provider.dart'
    show specIdentitiesProvider;
import 'package:liberated_bread_mobile/providers/device_spec_provider.dart'
    show specAssetPath, specManifestPath;
import 'package:liberated_bread_mobile/providers/device_spec_match_provider.dart'
    show specCatalogueProvider;
import 'package:liberated_bread_mobile/providers/spec_codec_provider.dart'
    show specCodecProvider;
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
    show NetworkDeviceDto, ScannedDeviceDto, identifyStandardProfiles;
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

/// The Johnson JLX LDM330 laser distance meter, as
/// vendor/protocol-specs/device-specs/devices/jlx-laser-distance-meter.yaml
/// describes it: the name it advertises, its spec's file in the catalogue,
/// and the vendor service with its write (f151) and notify (f154) pair.
const String _ldmName = 'Laser Distance Meter';
const String _ldmSpecFile = 'jlx-laser-distance-meter.yaml';
const String _ldmService = '0000f150-0000-1000-8000-00805f9b34fb';
const String _ldmWrite = '0000f151-0000-1000-8000-00805f9b34fb';
const String _ldmNotify = '0000f154-0000-1000-8000-00805f9b34fb';

/// The three commands the spec declares on f151 as plain `value:` byte
/// lists, restated so the test can hold the app's codec to them: init is a
/// fixed 6-byte frame; the other two are '#' LF `<command>` NUL-padded to 12
/// bytes plus an 8-bit sum checksum (0xBB for "Link", 0x9A for "m").
const List<int> _ldmInit = [0x03, 0x0D, 0x0A, 0x03, 0x0D, 0x0A];
const List<int> _ldmLink = [
  0x23, 0x0A, 0x4C, 0x69, 0x6E, 0x6B, // '#' LF "Link"
  0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xBB,
];
const List<int> _ldmMeasure = [
  0x23, 0x0A, 0x6D, // '#' LF "m"
  0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x9A,
];

/// Byte 7 of a measurement frame: the unit the meter's DISPLAY is set to.
/// The value itself is always metres. A code outside a..j is reported as
/// unknown — the vendor app's default branch shows one as "Zbleoff", a
/// power-down, which the spec's parse_rules say not to copy.
const Map<String, String> _ldmDisplayUnits = {
  'a': 'm',
  'b': 'ft',
  'c': 'in',
  'd': "ft'in\" 1/32",
  'e': 'in 1/32',
  'f': 'in 1/16',
  'g': 'in 1/8',
  'h': 'in 1/4',
  'i': 'in 1/2',
  'j': 'Taiwanese foot',
};

/// A meter frame as text: printable ASCII as is, everything else (the NUL
/// padding, mostly) as \xNN, so a garbled frame is still legible in the log.
String _ldmShow(List<int> bytes) => bytes
    .map(
      (b) => b >= 0x20 && b < 0x7f
          ? String.fromCharCode(b)
          : '\\x${b.toRadixString(16).padLeft(2, '0')}',
    )
    .join();

/// A non-control f154 frame read per the spec's parse_rules: byte 0 a prefix
/// the vendor app discards, bytes 1-6 a fixed-width decimal ALWAYS in
/// metres, byte 7 the display-unit code, bytes 8-9 NUL. Null for anything
/// that is not a reading — an 'errorN' failure frame (bytes 1-6 are "rrorN",
/// not a number; the vendor app crashes on it) or a short frame.
///
/// In Dart rather than through the codec: the spec describes f154's frames
/// in prose and payload_formats, not as a `format:` on the characteristic,
/// so `decodeValue` has nothing to decode with and reports "no format".
({double metres, String unit, String prefix})? _ldmReading(List<int> bytes) {
  if (bytes.length < 8) return null;
  final text = String.fromCharCodes(bytes);
  final metres = double.tryParse(text.substring(1, 7));
  if (metres == null) return null;
  return (
    metres: metres,
    unit:
        _ldmDisplayUnits[text[7]] ??
        'unknown unit code ${_ldmShow([bytes[7]])}',
    prefix: text[0],
  );
}

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

    final codec = RealSpecCodec();
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
          // Settled states only, judged by the SAME predicate the service
          // uses: iOS maps CBManagerStateResetting to turningOn, which
          // RealBleService.scan() waits out and then scans normally — so a
          // radio resetting at this instant used to fail the suite for
          // correct behaviour ("adapter state is turningOn but scan()
          // completed").
          .where((s) => !isAdapterStateSettling(s))
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
      final service = RealNetworkScanService(codec: RealSpecCodec());
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
        final codec = RealSpecCodec();
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
        // Which advertisers were in the room, strongest first — the operator
        // put a device next to the phone and needs to see whether that is the
        // one this connected to, or a neighbour's.
        final ranked = seen.values.toList()
          ..sort((x, y) => y.rssi.compareTo(x.rssi));
        _say('${ranked.length} connectable advertiser(s), strongest first:');
        for (final d in ranked.take(5)) {
          _say(
            '  ${d.rssi} dBm  "${d.name.isEmpty ? '(no name)' : d.name}"  '
            '${d.id}',
          );
        }
        target = ranked.first;
      }
      final id = target!.id;
      _say('found "${target.name}" as $id (rssi ${target.rssi}); connecting');

      // What the shipped catalogue makes of a REAL advertisement. The host
      // suites match against advertisements a test wrote, so this is the only
      // place the identity projection and the Rust matcher meet a device
      // nobody designed the fixture for — the BLE half of the LAN catalogue
      // check above.
      {
        final container = ProviderContainer();
        addTearDown(container.dispose);
        final identities = await container.read(specIdentitiesProvider.future);
        final codec = RealSpecCodec();
        final matches = await codec.matchScannedDevice(
          identities: identities,
          device: ScannedDeviceDto(
            name: target.name,
            serviceUuids: target.serviceUuids,
            companyIds: Uint16List.fromList(target.companyIds),
            macAddress: null,
          ),
        );
        if (matches.isEmpty) {
          _say(
            'catalogue: nothing in ${identities.length} identities claims '
            'this advertiser (name "${target.name}", '
            '${target.serviceUuids.length} service uuid(s), '
            '${target.companyIds.length} company id(s))',
          );
        } else {
          final best = matches.first;
          _say(
            'catalogue: -> ${best.deviceName} (${best.manufacturer}, '
            '${best.confidence.name}; ${matches.length} candidate(s))',
          );
        }
      }

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

        // READ every readable characteristic, and survive whatever comes
        // back. This is F-006's whole test, and it needs a device: the
        // pinned darwin plugin built an NSDictionary with an unguarded nil
        // value on the characteristic ERROR path, so a read that failed
        // before anything had been cached — which is exactly what an
        // encrypted characteristic on a lock does to an unpaired central —
        // took the process down with NSInvalidArgumentException. An
        // uncatchable native abort, so the only proof is that the app is
        // still here afterwards.
        //
        // A refusal is the EXPECTED outcome on a device that wants pairing,
        // and it must arrive as one of this app's own exception types, not
        // as a crash and not as a raw platform error. Reads only: nothing
        // here writes to somebody's lock.
        var attempted = 0;
        var answered = 0;
        var refused = 0;
        for (final service in services) {
          for (final characteristic in service.characteristics) {
            if (!characteristic.canRead) continue;
            attempted++;
            try {
              final value = await ble.readCharacteristic(
                id,
                service.uuid,
                characteristic.uuid,
              );
              answered++;
              _say(
                '  read ${characteristic.uuid}: ${value.length} byte(s)'
                '${value.length <= 24 ? ' $value' : ''}',
              );
            } on UserFacingException catch (e) {
              refused++;
              _say('  read ${characteristic.uuid} refused: ${e.message}');
            } catch (e) {
              refused++;
              _say(
                '  read ${characteristic.uuid} failed as ${e.runtimeType}: $e',
              );
              fail(
                'a failed read surfaced as ${e.runtimeType} rather than one '
                'of this app\'s own exception types: $e',
              );
            }
          }
        }
        _say(
          'reads: $attempted attempted, $answered answered, $refused refused '
          '— and the app is still running, which is what F-006 is about',
        );
      } finally {
        await ble.disconnect(id);
      }
    },
  );

  testWidgets(
    'live BLE: the JLX laser meter, end to end through the shipping services',
    (tester) async {
      if (_skipUnlessHardware()) return;
      if (_liveBleName != _ldmName) {
        markTestSkipped(
          'pass --dart-define=LB_LIVE_BLE_NAME="$_ldmName" '
          '(run-ios-device-tests.sh --live-ble-name) with a JLX meter in '
          'range and its Bluetooth on',
        );
        return;
      }
      if (!MockBleService.rustAvailable) await RustLib.init();

      // The generic live test above proves the phone can connect to whatever
      // LB_LIVE_BLE_NAME names. This one is device-specific: it drives the
      // meter's whole session — handshake, keep-alives, a reading — through
      // the SAME services and codec the device screen uses, so it is the
      // end-to-end check that the catalogue still names the meter, that the
      // spec's commands still encode to the bytes the meter wants, and that
      // the phone holds the link the way the spec describes.
      // test/live/direct_att_live_test.dart is the Linux-only twin of this,
      // over a raw ATT channel; nothing here is shared with it.

      // SCAN, as the generic test does.
      final ble = RealBleService();
      IoTDevice? target;
      _say('scanning up to 30 s for an advertiser named "$_ldmName"');
      await for (final device in ble.scan(
        timeout: const Duration(seconds: 30),
      )) {
        if (device.name == _ldmName) {
          target = device;
          break; // cancels the subscription, which stops the native scan
        }
      }
      expect(
        target,
        isNotNull,
        reason:
            'no advertiser named "$_ldmName" was heard in 30 s — hold the '
            'meter\'s Bluetooth button until its icon shows',
      );
      final id = target!.id;
      _say(
        'found "${target.name}" as $id (rssi ${target.rssi}; advertised '
        '${target.serviceUuids.length} service uuid(s))',
      );

      // CATALOGUE: the real assertion of this test. The merged catalogue must
      // still name the JLX spec as its best match for a REAL advertisement —
      // through the provider the scan screen reads and the matcher it calls,
      // so a refresh that changed the spec's identity block, or a sibling
      // spec that now outranks it, fails here with the winner named.
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final catalogue = await container.read(specCatalogueProvider.future);
      final identities = await container.read(specIdentitiesProvider.future);
      final codec = container.read(specCodecProvider);
      final matches = await codec.matchScannedDevice(
        identities: identities,
        device: ScannedDeviceDto(
          name: target.name,
          serviceUuids: target.serviceUuids,
          companyIds: Uint16List.fromList(target.companyIds),
          macAddress: null,
        ),
      );
      expect(
        matches,
        isNotEmpty,
        reason:
            'nothing in ${identities.length} identities claims a '
            '"$_ldmName" advertising ${target.serviceUuids}',
      );
      final best = matches.first;
      // specIndex indexes the identities list, which specIdentitiesProvider
      // builds in catalogue order, so it is the catalogue index too.
      final spec = catalogue.specs[best.specIndex];
      _say(
        'catalogue: -> ${best.deviceName} (${best.manufacturer}, '
        '${best.confidence.name}; ${matches.length} candidate(s)) from '
        '${spec.key}',
      );
      expect(
        spec.key,
        endsWith(_ldmSpecFile),
        reason:
            'the catalogue\'s best match for the meter is ${spec.key}, not '
            'the JLX spec: the merged catalogue no longer recognises it',
      );

      // ENCODE the spec's three f151 commands through the app's codec — the
      // call the typed command widget makes, with the YAML the catalogue
      // holds — and hold the bytes to the spec's literals. They are plain
      // `value:` commands, which the codec hands back verbatim; the check is
      // that the spec still declares them and the codec still finds them.
      Future<List<int>> encode(String command) async =>
          (await codec.encodeCommand(
            specYaml: spec.yaml,
            charUuid: _ldmWrite,
            commandName: command,
            params: const {},
          )).toList();
      final init = await encode('init');
      final link = await encode('link_keepalive');
      final measure = await encode('measure');
      _say(
        'codec: init [${bytesToHex(init)}], link_keepalive '
        '[${bytesToHex(link)}], measure [${bytesToHex(measure)}]',
      );
      expect(init, _ldmInit, reason: 'init is not the spec\'s fixed frame');
      expect(link, _ldmLink, reason: 'link_keepalive is not "#\\nLink" + 0xBB');
      expect(measure, _ldmMeasure, reason: 'measure is not "#\\nm" + 0x9A');

      // CONNECT. The meter refuses connections outright while its radio is
      // transitioning ("retry rather than diagnose", says the spec), so up
      // to three attempts, 2 s apart.
      Object? refusal;
      for (var attempt = 1; attempt <= 3; attempt++) {
        try {
          await ble.connect(id);
          refusal = null;
          break;
        } catch (e) {
          refusal = e;
          _say('connect attempt $attempt of 3 failed: $e');
          if (attempt == 3) break;
          // Best-effort: clear whatever half-open link the attempt left
          // before asking again.
          await ble.disconnect(id);
          await Future<void>.delayed(const Duration(seconds: 2));
        }
      }
      if (refusal != null) {
        await ble.disconnect(id);
        fail('the meter refused three connection attempts; last: $refusal');
      }
      _say('connected');

      StreamSubscription<List<int>>? sub;
      final timers = <Timer>[];
      try {
        // DISCOVER: the vendor pair the whole session runs over.
        final services = await ble.discoverServices(id);
        _say(
          '${services.length} service(s): '
          '${services.map((s) => s.uuid.substring(4, 8)).join(' ')}',
        );
        final ldm = services.where(
          (s) => normalizeUuid(s.uuid) == normalizeUuid(_ldmService),
        );
        expect(ldm, hasLength(1), reason: 'service f150 was not discovered');
        final chars = {
          for (final c in ldm.single.characteristics) normalizeUuid(c.uuid): c,
        };
        final write = chars[normalizeUuid(_ldmWrite)];
        final notify = chars[normalizeUuid(_ldmNotify)];
        expect(write, isNotNull, reason: 'f150 has no f151 (command_rx)');
        expect(notify, isNotNull, reason: 'f150 has no f154 (data_tx)');
        expect(notify!.canNotify, isTrue, reason: 'f154 does not notify');
        // BleService offers no write-mode choice: the shipping service picks
        // per characteristic, and prefers with-response whenever the
        // peripheral declares it. f151 declares both (props 0x0c), so where
        // the vendor app writes without response this app writes WITH — the
        // meter accepting that is one of the things this run shows.
        final withoutResponse = useWriteWithoutResponse(
          canWriteWithResponse: write!.canWriteWithResponse,
          canWriteWithoutResponse: write.canWriteWithoutResponse,
        );
        _say(
          'f151 declares write=${write.canWriteWithResponse} '
          'write-without-response=${write.canWriteWithoutResponse}; '
          'the service writes ${withoutResponse ? 'without' : 'with'} '
          'response',
        );

        // SESSION: 25 s on f154. Every Ztest01 is answered with init and
        // every Ztest02 with the link frame, or the meter says Zbleoff and
        // hangs up ~44 s in; init goes once at 2 s (the spec's setup step,
        // whether or not a Ztest01 ever asks — one live session never sent
        // one) and measure once at 5 s. Real time throughout: this binding
        // has no fake clock, so the window is a Completer that the timer, a
        // Zbleoff or a dead stream completes.
        final clock = Stopwatch()..start();
        String at() =>
            '${(clock.elapsedMilliseconds / 1000).toStringAsFixed(1)} s';
        var handshakes = 0;
        var keepAlives = 0;
        var keepAlivesAnswered = 0;
        var writeFailures = 0;
        final readings = <double>[];
        final done = Completer<String>();
        void finish(String why) {
          if (!done.isCompleted) done.complete(why);
        }

        Future<bool> send(String what, List<int> bytes) async {
          try {
            await ble.writeCharacteristic(id, _ldmService, _ldmWrite, bytes);
            _say('${at()} -> $what');
            return true;
          } catch (e) {
            // Reported, not thrown: a write that fails as the meter hangs up
            // is part of the story, and an error escaping a listener would
            // end the test without the summary below.
            writeFailures++;
            _say('${at()} -> $what FAILED: $e');
            return false;
          }
        }

        sub = ble
            .subscribeCharacteristic(id, _ldmService, _ldmNotify)
            .listen(
              (frame) {
                final text = _ldmShow(frame);
                final control = String.fromCharCodes(frame.take(7));
                switch (control) {
                  case 'Ztest01':
                    handshakes++;
                    _say('${at()} <- Ztest01 (handshake): answering with init');
                    unawaited(send('init', init));
                  case 'Ztest02':
                    keepAlives++;
                    _say(
                      '${at()} <- Ztest02 (keep-alive): answering with Link',
                    );
                    unawaited(
                      send('link_keepalive', link).then((ok) {
                        if (ok) keepAlivesAnswered++;
                      }),
                    );
                  case 'Zbleoff':
                    _say(
                      '${at()} <- Zbleoff: the meter is powering its '
                      'radio down',
                    );
                    finish('the meter sent Zbleoff at ${at()}');
                  default:
                    final reading = _ldmReading(frame);
                    if (reading == null) {
                      final kind = control.startsWith('error')
                          ? 'a measurement failure frame'
                          : 'not a measurement frame';
                      _say(
                        '${at()} <- "$text": $kind (${frame.length} byte(s))',
                      );
                    } else {
                      readings.add(reading.metres);
                      final metres = reading.metres.toStringAsFixed(3);
                      _say(
                        '${at()} <- reading $metres m (display unit '
                        '${reading.unit}; prefix ${reading.prefix}; '
                        'raw "$text")',
                      );
                    }
                }
              },
              onError: (Object e) {
                _say('${at()} f154 subscription failed: $e');
                finish('the f154 subscription failed: $e');
              },
              onDone: () => finish('the f154 stream closed at ${at()}'),
            );
        timers.add(
          Timer(const Duration(seconds: 2), () {
            unawaited(send('init (the setup step)', init));
          }),
        );
        timers.add(
          Timer(const Duration(seconds: 5), () {
            unawaited(send('measure', measure));
          }),
        );
        timers.add(
          Timer(
            const Duration(seconds: 25),
            () => finish('the 25 s window elapsed'),
          ),
        );
        _say(
          'subscribed to f154; 25 s session: init at 2 s, measure at 5 s, '
          'every Ztest01/Ztest02 answered — press the meter\'s button too',
        );
        final why = await done.future;
        _say(
          'session over: $why. $handshakes Ztest01, $keepAlives Ztest02 '
          '($keepAlivesAnswered answered), ${readings.length} reading(s), '
          '$writeFailures failed write(s)',
        );
        // A meter whose display has slept still sends Ztest02 every ~5.5 s,
        // so a session with no answered keep-alive is one where the
        // subscription or the writes are not reaching it. A reading alone
        // would not do: the meter pushes one whenever its button is pressed,
        // whether or not a single write ever got through. A Zbleoff AFTER a
        // keep-alive is the meter's normal way of ending a session it decided
        // was over, and is reported above rather than failed.
        expect(
          keepAlivesAnswered,
          greaterThan(0),
          reason:
              'in the window no keep-alive was answered ($why; $keepAlives '
              'Ztest02 heard, ${readings.length} reading(s), $writeFailures '
              'failed write(s))',
        );
      } finally {
        for (final timer in timers) {
          timer.cancel();
        }
        await sub?.cancel();
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
