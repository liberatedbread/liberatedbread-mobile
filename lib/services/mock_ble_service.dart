// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:async';
import 'dart:math';
import 'package:flutter/services.dart' show rootBundle;
import '../core/hex.dart';
import '../models/ble_discovered_service.dart';
import '../models/iot_device.dart';
import '../src/rust/api/mock_api.dart' as rust;
import '../src/rust/frb_generated.dart' show RustLib;
import 'ble_service.dart';

/// Mock device definition for demo mode.
class _MockDeviceDef {
  final String id;
  final String name;
  final int rssi;
  final List<BleDiscoveredService> services;

  const _MockDeviceDef({
    required this.id,
    required this.name,
    required this.rssi,
    required this.services,
  });
}

// Service definitions shared by all mock devices. Keep this in sync with
// assets/device_specs/example-bulb.yaml.
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
/// Enabled at runtime via `--dart-define=OPENGREENIOT_MOCK=true`.
class MockBleService implements BleService {
  /// Path under `rootBundle` that resolves to the device spec YAML used for
  /// Rust-side decoding. Overridable for tests; defaults to the example bulb.
  final Future<String> Function() _loadSpec;
  String? _cachedSpec;

  final _random = Random(42);
  final Map<String, bool> _connected = {};
  final Map<String, Map<String, List<int>>> _writtenValues = {};
  final Map<String, StreamController<BleConnectionState>> _connectionStreams =
      {};

  MockBleService({Future<String> Function()? loadSpec})
      : _loadSpec = loadSpec ?? _defaultLoader;

  static Future<String> _defaultLoader() =>
      rootBundle.loadString('assets/device_specs/example-bulb.yaml');

  Future<String> _spec() async => _cachedSpec ??= await _loadSpec();

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

  static const List<_MockDeviceDef> _mockDevices = [
    _MockDeviceDef(
      id: 'AA:BB:CC:DD:EE:01',
      name: 'ACME_Living_Room',
      rssi: -45,
      services: [_controlService, _batteryService],
    ),
    _MockDeviceDef(
      id: 'AA:BB:CC:DD:EE:02',
      name: 'ACME_Bedroom',
      rssi: -62,
      services: [_controlService, _batteryService],
    ),
  ];

  // Dart fallback defaults used when the Rust library is unavailable.
  // These intentionally match `rust/src/mock/simulator.rs` output for the
  // example-bulb spec so both code paths produce the same bytes.
  static final Map<String, List<int>> _defaults = {
    // power=on, brightness=80, r=255, g=180, b=50
    '0000fff2-0000-1000-8000-00805f9b34fb': [1, 80, 255, 180, 50],
    // battery=85%
    '00002a19-0000-1000-8000-00805f9b34fb': [85],
  };

  @override
  Future<bool> requestPermissions() async => true;

  @override
  Stream<IoTDevice> scan(
      {Duration timeout = const Duration(seconds: 10)}) async* {
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
      );
    }
    await Future<void>.delayed(Duration(seconds: timeout.inSeconds ~/ 3));
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
  /// connection-state controller so they don't leak when the service is
  /// discarded. Safe to call more than once.
  Future<void> dispose() async {
    final controllers = _connectionStreams.values.toList();
    _connectionStreams.clear();
    for (final controller in controllers) {
      if (!controller.isClosed) await controller.close();
    }
  }

  @override
  Future<List<BleDiscoveredService>> discoverServices(String deviceId) async {
    await Future<void>.delayed(const Duration(milliseconds: 200));
    final device = _mockDevices.firstWhere(
      (d) => d.id == deviceId,
      orElse: () => throw StateError('Unknown mock device: $deviceId'),
    );
    return device.services;
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
        final spec = await _spec();
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
            if (!controller.isClosed) controller.close();
            return;
          }
          readCharacteristic(deviceId, serviceUuid, charUuid).then(
            (value) {
              if (!controller.isClosed) controller.add(value);
            },
          );
        });
      },
      onCancel: () async {
        timer?.cancel();
      },
    );
    return controller.stream;
  }
}
