// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:async';
import 'dart:math';
import 'package:flutter/services.dart' show rootBundle;
import '../core/constants.dart';
import '../core/hex.dart';
import '../models/ble_discovered_service.dart';
import '../models/iot_device.dart';
import '../src/rust/api/device_api.dart' as device_api;
import '../src/rust/api/mock_api.dart' as rust;
import '../src/rust/frb_generated.dart' show RustLib;
import 'ble_service.dart';

/// Mock device definition for demo mode.
///
/// A mock device is a name, a signal strength, and the spec it pretends to be.
/// Its GATT tree is derived from that spec rather than written out here, so
/// demoing another device is a one-line catalogue entry — the same "the spec is
/// the source of truth" rule the app follows for real hardware.
class _MockDeviceDef {
  final String id;
  final String name;
  final int rssi;

  /// Asset path of the spec this device advertises.
  final String specAsset;

  /// GATT tree used when the spec cannot be parsed — i.e. when the native
  /// library isn't loaded, as in plain unit tests.
  final List<BleDiscoveredService> fallbackServices;

  /// Service UUIDs this device pretends to advertise. Separate from
  /// [fallbackServices]: an advertisement is 31 bytes and rarely carries the
  /// whole GATT tree, and the difference is exactly what the scan-time matcher
  /// has to work with.
  final List<String> serviceUuids;

  /// Company IDs this device pretends to advertise under.
  final List<int> companyIds;

  const _MockDeviceDef({
    required this.id,
    required this.name,
    required this.rssi,
    required this.specAsset,
    this.fallbackServices = const [],
    this.serviceUuids = const [],
    this.companyIds = const [],
  });
}

// Service definitions shared by all mock devices. Keep this in sync with
// vendor/protocol-specs/device-specs/examples/example-bulb.yaml.
const _controlService = BleDiscoveredService(
  uuid: '0000fff0-0000-1000-8000-00805f9b34fb',
  characteristics: [
    BleDiscoveredCharacteristic(
        uuid: '0000fff1-0000-1000-8000-00805f9b34fb',
        canRead: false,
        canWrite: true,
        // Matches typical BLE control chars (write-without-response only) and
        // keeps the write-mode invariant: a writable char supports >=1 mode.
        canWriteWithoutResponse: true,
        canNotify: false),
    BleDiscoveredCharacteristic(
        uuid: '0000fff2-0000-1000-8000-00805f9b34fb',
        canRead: true,
        canWrite: false,
        canNotify: true),
  ],
);

const _batteryService = BleDiscoveredService(
  uuid: '0000180f-0000-1000-8000-00805f9b34fb',
  characteristics: [
    BleDiscoveredCharacteristic(
        uuid: '00002a19-0000-1000-8000-00805f9b34fb',
        canRead: true,
        canWrite: false,
        canNotify: true),
  ],
);

/// Mock BLE service — transport simulation for demo mode.
///
/// Transport plumbing (scan/connect/notify) is pure Dart. Byte-level logic
/// (characteristic defaults, write-through state) delegates to the Rust
/// `mock_api` via flutter_rust_bridge when the native library is loaded.
/// If [RustLib] isn't initialized — e.g. when the Rust library isn't bundled
/// into the APK or when a unit test skips `RustLib.init()` — a small Dart
/// fallback table is used instead so mock mode still works.
///
/// Enabled at runtime via `--dart-define=LIBERATED_BREAD_MOCK=true`.
class MockBleService implements BleService {
  /// Loads a spec YAML by asset path. Overridable for tests, which run without
  /// an asset bundle; defaults to `rootBundle`.
  final Future<String> Function(String asset) _loadAsset;

  /// Parsed-once spec text, keyed by asset path.
  final Map<String, String> _specCache = {};

  /// Derived-once GATT tree, keyed by asset path. Deriving means an FFI parse,
  /// and `discoverServices` is called on every connect.
  final Map<String, List<BleDiscoveredService>> _servicesCache = {};

  final _random = Random(42);
  final Map<String, bool> _connected = {};
  final Map<String, Map<String, List<int>>> _writtenValues = {};
  final Map<String, StreamController<BleConnectionState>> _connectionStreams =
      {};

  /// Live notify controllers from [subscribeCharacteristic], tracked so
  /// [dispose] can close them instead of leaving their timers polling.
  final Set<StreamController<List<int>>> _notifyControllers = {};

  /// [loadSpec] is a legacy convenience for tests that only care about the
  /// bulb: it supplies that one spec's text regardless of asset path.
  MockBleService({
    Future<String> Function()? loadSpec,
    Future<String> Function(String asset)? loadAsset,
  }) : _loadAsset = loadAsset ??
            (loadSpec == null ? rootBundle.loadString : ((_) => loadSpec()));

  Future<String> _specForAsset(String asset) async =>
      _specCache[asset] ??= await _loadAsset(asset);

  _MockDeviceDef _defFor(String deviceId) => _mockDevices.firstWhere(
        (d) => d.id == deviceId,
        orElse: () => throw StateError('Unknown mock device: $deviceId'),
      );

  /// True once `RustLib.init()` has successfully loaded the native library.
  /// Exposed as a static so tests and the provider can check initialization.
  static bool get rustAvailable {
    try {
      // ignore: invalid_use_of_internal_member
      return RustLib.instance.initialized;
    } catch (_) {
      return false;
    }
  }

  static const _bulbSpec =
      'vendor/protocol-specs/device-specs/examples/example-bulb.yaml';

  // The four entries deliberately advertise different things, so demo mode
  // exercises every rung of the scan-time confidence ladder rather than only
  // the easy one. See MatchConfidence in the Rust api.
  static const List<_MockDeviceDef> _mockDevices = [
    // Advertises its service UUID: the strongest pre-connect signal there is.
    _MockDeviceDef(
      id: 'AA:BB:CC:DD:EE:01',
      name: 'ACME_Living_Room',
      rssi: -45,
      specAsset: _bulbSpec,
      fallbackServices: [_controlService, _batteryService],
      serviceUuids: ['0000fff0-0000-1000-8000-00805f9b34fb'],
    ),
    // Same product, but advertising nothing except its name — the common case
    // for a device whose advertisement is already full.
    _MockDeviceDef(
      id: 'AA:BB:CC:DD:EE:02',
      name: 'ACME_Bedroom',
      rssi: -62,
      specAsset: _bulbSpec,
      fallbackServices: [_controlService, _batteryService],
    ),
    // A second, unrelated spec from the vendored catalogue. Nothing about this
    // device is written into the app: its services, characteristics and six
    // readings all come out of the YAML, which is the point — it is the same
    // path a real Airthings would take, minus the radio. It is recognised by
    // its manufacturer-data company ID, which is what the real spec declares.
    _MockDeviceDef(
      id: 'AA:BB:CC:DD:EE:03',
      name: 'Airthings Wave Plus',
      rssi: -58,
      specAsset:
          'vendor/protocol-specs/device-specs/devices/airthings-wave-family.yaml',
      companyIds: [820],
    ),
    // Nameless, silent, and identifiable only by its address. Present because
    // this is the case the scan list used to bury: an unhelpfully anonymous
    // device that is nonetheless worth a second look.
    //
    // The last nibble is load-bearing. C4:7C:8D is an IEEE Registration
    // Authority block subdivided among fifteen unrelated companies, and only
    // C4:7C:8D:6 is HHCC Plant Technology's — the OEM behind the HHCCJCY01
    // model number. An address ending anywhere else in the block resolves to
    // someone else entirely (…:1 is LYNX Innovation), which titled the demo
    // row with one company while badging it with another.
    _MockDeviceDef(
      id: 'C4:7C:8D:61:22:04',
      name: '',
      rssi: -78,
      specAsset:
          'vendor/protocol-specs/device-specs/devices/xiaomi-miflora.yaml',
    ),
  ];

  // Dart fallback defaults used when the Rust library is unavailable.
  // These intentionally match `rust/src/mock/simulator.rs` output for the
  // example-bulb spec so both code paths produce the same bytes.
  /// Keys are run through [normalizeUuid] so they match however a lookup
  /// spells the UUID (the specs' 128-bit form here, a stack's short form
  /// elsewhere); the literals stay in the readable full form.
  static final Map<String, List<int>> _defaults = {
    // power=on, brightness=80, r=255, g=180, b=50
    '0000fff2-0000-1000-8000-00805f9b34fb': [1, 80, 255, 180, 50],
    // battery=85%
    '00002a19-0000-1000-8000-00805f9b34fb': [85],
  }.map((uuid, value) => MapEntry(normalizeUuid(uuid), value));

  @override
  Future<bool> requestPermissions() async => true;

  @override
  Stream<IoTDevice> scan({
    Duration timeout =
        const Duration(seconds: AppConstants.defaultScanDuration),
  }) async* {
    // Fresh mock state per scan when Rust is driving the simulator.
    if (rustAvailable) {
      try {
        await rust.mockReset();
      } catch (_) {/* keep going with Dart fallback */}
    }
    for (final device in _mockDevices) {
      await Future<void>.delayed(const Duration(milliseconds: 400));
      yield IoTDevice(
        id: device.id,
        name: device.name,
        rssi: device.rssi + _random.nextInt(10) - 5,
        isConnectable: true,
        discoveredAt: DateTime.now(),
        serviceUuids: device.serviceUuids,
        companyIds: device.companyIds,
      );
    }
    // Duration division, not `inSeconds ~/ 3`, which truncates to zero for
    // sub-3-second timeouts.
    await Future<void>.delayed(timeout ~/ 3);
  }

  @override
  Future<void> stopScan() async {}

  @override
  Future<void> connect(String deviceId) async {
    await Future<void>.delayed(const Duration(milliseconds: 500));
    _connected[deviceId] = true;
    _connectionStream(deviceId).add(BleConnectionState.connected);
  }

  @override
  Future<void> disconnect(String deviceId) async {
    _connected.remove(deviceId);
    _connectionStream(deviceId).add(BleConnectionState.disconnected);
  }

  @override
  Stream<BleConnectionState> connectionState(String deviceId) {
    return _connectionStream(deviceId).stream;
  }

  StreamController<BleConnectionState> _connectionStream(String deviceId) {
    return _connectionStreams.putIfAbsent(
      deviceId,
      () => StreamController<BleConnectionState>.broadcast(),
    );
  }

  /// Release resources held by this mock service. Closes every per-device
  /// connection-state controller and active notify stream so their timers
  /// stop, and drops connection state so nothing keeps "notifying" a
  /// discarded service. Safe to call more than once.
  Future<void> dispose() async {
    _connected.clear();
    final notifyControllers = _notifyControllers.toList();
    _notifyControllers.clear();
    for (final controller in notifyControllers) {
      // Not awaited: a single-subscription controller's close() future only
      // completes once a listener has received the done event, so awaiting a
      // never-listened subscription would hang dispose.
      if (!controller.isClosed) unawaited(controller.close());
    }
    final controllers = _connectionStreams.values.toList();
    _connectionStreams.clear();
    for (final controller in controllers) {
      if (!controller.isClosed) await controller.close();
    }
  }

  @override
  Future<List<BleDiscoveredService>> discoverServices(String deviceId) async {
    await Future<void>.delayed(const Duration(milliseconds: 200));
    final device = _defFor(deviceId);

    final cached = _servicesCache[device.specAsset];
    if (cached != null) return cached;

    if (rustAvailable) {
      try {
        final spec = await device_api.loadDeviceSpec(
          yaml: await _specForAsset(device.specAsset),
        );
        final services = [
          for (final service in spec.services)
            BleDiscoveredService(
              uuid: service.uuid,
              characteristics: [
                for (final char in service.characteristics)
                  BleDiscoveredCharacteristic(
                    uuid: char.uuid,
                    canRead: char.canRead,
                    canWrite: char.canWrite,
                    // A spec says a characteristic is writable without saying
                    // which write mode, and the model requires a writable
                    // characteristic to declare at least one. Write-without-
                    // response is the common BLE control case.
                    canWriteWithoutResponse: char.canWrite,
                    canNotify: char.canNotify,
                  ),
              ],
            ),
        ];
        return _servicesCache[device.specAsset] = services;
      } catch (_) {/* fall through to the static tree */}
    }
    return device.fallbackServices;
  }

  @override
  Future<List<int>> readCharacteristic(
    String deviceId,
    String serviceUuid,
    String charUuid,
  ) async {
    await Future<void>.delayed(const Duration(milliseconds: 50));
    if (rustAvailable) {
      try {
        final spec = await _specForAsset(_defFor(deviceId).specAsset);
        final bytes = await rust.mockReadCharacteristic(
          deviceId: deviceId,
          charUuid: charUuid,
          specYaml: spec,
        );
        return bytes.toList();
      } catch (_) {/* fall through to Dart fallback */}
    }
    return _dartFallbackRead(deviceId, charUuid);
  }

  List<int> _dartFallbackRead(String deviceId, String charUuid) {
    final key = normalizeUuid(charUuid);
    final deviceWrites = _writtenValues[deviceId];
    if (deviceWrites != null && deviceWrites.containsKey(key)) {
      return deviceWrites[key]!;
    }
    return _defaults[key] ?? [0];
  }

  @override
  Future<void> writeCharacteristic(
    String deviceId,
    String serviceUuid,
    String charUuid,
    List<int> value,
  ) async {
    await Future<void>.delayed(const Duration(milliseconds: 50));
    if (rustAvailable) {
      try {
        await rust.mockWriteCharacteristic(
          deviceId: deviceId,
          charUuid: charUuid,
          value: value,
        );
        return;
      } catch (_) {/* fall through to Dart fallback */}
    }
    final key = normalizeUuid(charUuid);
    _writtenValues.putIfAbsent(deviceId, () => {});
    _writtenValues[deviceId]![key] = value;
  }

  @override
  Future<int> mtu(String deviceId) async {
    // Demo mode pretends to be a modern link (the fbp Android default request
    // is 512) so bulk features like image upload exercise their chunking at a
    // realistic size instead of the 23-byte floor.
    return 512;
  }

  /// Reads served so far, per device. Drives the simulated wander from a
  /// counter rather than the wall clock: `DateTime.now()` is not the widget
  /// tests' fake clock, so a clock-driven value would be unassertable and
  /// flaky, and it would make demo output differ run to run.
  final Map<String, int> _rssiReadCounts = {};

  /// Deterministic jitter, kept off the shared [_random] so reading RSSI
  /// cannot shift the scan results drawn from that seeded stream.
  final _rssiRandom = Random(1337);

  @override
  Future<int> readRssi(String deviceId) async {
    await Future<void>.delayed(const Duration(milliseconds: 80));
    if (!(_connected[deviceId] ?? false)) {
      throw StateError('Not connected to $deviceId');
    }
    // A slow approach/retreat cycle (16 reads per period, ±9 dBm) plus
    // per-read jitter, so the Find Device view demonstrably reacts in demo
    // mode instead of pinning to one value.
    final reads = _rssiReadCounts.update(
      deviceId,
      (n) => n + 1,
      ifAbsent: () => 0,
    );
    final base = _defFor(deviceId).rssi;
    final phase = reads / 16 * 2 * pi;
    return (base + sin(phase) * 9).round() + _rssiRandom.nextInt(5) - 2;
  }

  @override
  Stream<List<int>> subscribeCharacteristic(
    String deviceId,
    String serviceUuid,
    String charUuid,
  ) {
    late StreamController<List<int>> controller;
    Timer? timer;
    controller = StreamController<List<int>>(
      onListen: () {
        timer = Timer.periodic(const Duration(seconds: 2), (t) {
          if (controller.isClosed || !(_connected[deviceId] ?? false)) {
            t.cancel();
            _notifyControllers.remove(controller);
            if (!controller.isClosed) controller.close();
            return;
          }
          readCharacteristic(deviceId, serviceUuid, charUuid).then(
            (value) {
              if (!controller.isClosed) controller.add(value);
            },
            // Without an onError, a failed read would surface as an
            // unhandled async error instead of on the notify stream.
            onError: (Object e) {
              if (!controller.isClosed) controller.addError(e);
            },
          );
        });
      },
      onCancel: () async {
        timer?.cancel();
        _notifyControllers.remove(controller);
      },
    );
    _notifyControllers.add(controller);
    return controller.stream;
  }
}
