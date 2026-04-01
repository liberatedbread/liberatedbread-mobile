// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:async';
import 'dart:math';
import '../models/ble_discovered_service.dart';
import '../models/iot_device.dart';
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

/// Mock BLE service — thin Dart transport shim for demo mode.
///
/// This is ONLY the transport simulation (scan/connect plumbing).
/// All byte-level logic (mock data generation, value encoding/decoding)
/// lives in Rust (rust/src/mock/simulator.rs and rust/src/api/mock_api.rs).
/// Once FRB codegen is connected, readCharacteristic/writeCharacteristic
/// will call through to Rust's mock_read_characteristic/mock_write_characteristic.
///
/// Used when the app runs with --dart-define=OPENGREENIOT_MOCK=true.
class MockBleService implements BleService {
  final _random = Random(42);
  final Map<String, bool> _connected = {};
  final Map<String, Map<String, List<int>>> _writtenValues = {};
  final Map<String, StreamController<BleConnectionState>> _connectionStreams = {};

  // Mock devices matching the example-bulb spec
  static const List<_MockDeviceDef> _mockDevices = [
    _MockDeviceDef(
      id: 'AA:BB:CC:DD:EE:01',
      name: 'ACME_Living_Room',
      rssi: -45,
      services: [
        BleDiscoveredService(
          uuid: '0000fff0-0000-1000-8000-00805f9b34fb',
          characteristics: [
            BleDiscoveredCharacteristic(uuid: '0000fff1-0000-1000-8000-00805f9b34fb', canRead: false, canWrite: true, canNotify: false),
            BleDiscoveredCharacteristic(uuid: '0000fff2-0000-1000-8000-00805f9b34fb', canRead: true, canWrite: false, canNotify: true),
          ],
        ),
        BleDiscoveredService(
          uuid: '0000180f-0000-1000-8000-00805f9b34fb',
          characteristics: [
            BleDiscoveredCharacteristic(uuid: '00002a19-0000-1000-8000-00805f9b34fb', canRead: true, canWrite: false, canNotify: true),
          ],
        ),
      ],
    ),
    _MockDeviceDef(
      id: 'AA:BB:CC:DD:EE:02',
      name: 'ACME_Bedroom',
      rssi: -62,
      services: [
        BleDiscoveredService(
          uuid: '0000fff0-0000-1000-8000-00805f9b34fb',
          characteristics: [
            BleDiscoveredCharacteristic(uuid: '0000fff1-0000-1000-8000-00805f9b34fb', canRead: false, canWrite: true, canNotify: false),
            BleDiscoveredCharacteristic(uuid: '0000fff2-0000-1000-8000-00805f9b34fb', canRead: true, canWrite: false, canNotify: true),
          ],
        ),
        BleDiscoveredService(
          uuid: '0000180f-0000-1000-8000-00805f9b34fb',
          characteristics: [
            BleDiscoveredCharacteristic(uuid: '00002a19-0000-1000-8000-00805f9b34fb', canRead: true, canWrite: false, canNotify: true),
          ],
        ),
      ],
    ),
  ];

  // Temporary Dart-side defaults until FRB bridge is connected.
  // These will be replaced by calls to Rust mock_read_characteristic().
  static final Map<String, List<int>> _defaults = {
    '0000fff2-0000-1000-8000-00805f9b34fb': [1, 80, 255, 180, 50], // power=on, brightness=80, r=255, g=180, b=50
    '00002a19-0000-1000-8000-00805f9b34fb': [85], // battery=85%
  };

  @override
  Future<bool> requestPermissions() async => true;

  @override
  Stream<IoTDevice> scan({Duration timeout = const Duration(seconds: 10)}) async* {
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
    final key = charUuid.toLowerCase();

    // Return written value if available
    final deviceWrites = _writtenValues[deviceId];
    if (deviceWrites != null && deviceWrites.containsKey(key)) {
      return deviceWrites[key]!;
    }

    // Return default
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
    final key = charUuid.toLowerCase();
    _writtenValues.putIfAbsent(deviceId, () => {});
    _writtenValues[deviceId]![key] = value;
  }

  @override
  Stream<List<int>> subscribeCharacteristic(
    String deviceId,
    String serviceUuid,
    String charUuid,
  ) {
    final controller = StreamController<List<int>>();

    // Emit periodic updates
    Timer.periodic(const Duration(seconds: 2), (timer) {
      if (!(_connected[deviceId] ?? false)) {
        timer.cancel();
        controller.close();
        return;
      }

      readCharacteristic(deviceId, serviceUuid, charUuid).then(
        (value) {
          if (!controller.isClosed) controller.add(value);
        },
      );
    });

    return controller.stream;
  }
}
