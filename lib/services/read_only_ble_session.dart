// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:async';

import '../core/error_text.dart';
import '../core/hex.dart';
import '../core/log.dart';
import 'ble_service.dart';
import 'ble_write_plan_runner.dart';

/// A read-only BLE device could not be read.
class ReadOnlyBleException implements UserFacingException {
  @override
  final String message;

  const ReadOnlyBleException(this.message);

  @override
  String toString() => message;
}

/// The GATT half of a read-only handler: connect, confirm the service, hold
/// one subscription, write what Rust built, and let go.
///
/// It has no idea what a frame means, and no way to invent one. The clients
/// using it pass it bytes from the handler's own encoders, which build reads
/// only.
class ReadOnlyBleSession {
  final BleService ble;
  final String deviceId;
  final String serviceUuid;
  final String writeUuid;
  final String notifyUuid;

  StreamSubscription<List<int>>? _subscription;
  bool _connected = false;
  bool _closed = false;

  ReadOnlyBleSession({
    required this.ble,
    required this.deviceId,
    required this.serviceUuid,
    required this.writeUuid,
    required this.notifyUuid,
  });

  bool get isClosed => _closed;

  /// Connect, confirm the service, and subscribe. [missingService] is what to
  /// tell the user when the device does not carry it.
  Future<void> open({
    required void Function(List<int> bytes) onBytes,
    required void Function(Object error) onError,
    required String missingService,
  }) async {
    await ble.connect(deviceId);
    _connected = true;
    if (_closed) return;
    final services = await ble.discoverServices(deviceId);
    final wanted = normalizeUuid(serviceUuid);
    if (!services.any((s) => normalizeUuid(s.uuid) == wanted)) {
      throw ReadOnlyBleException(missingService);
    }
    if (_closed) return;
    final notifications = ble.subscribeCharacteristic(
      deviceId,
      serviceUuid,
      notifyUuid,
    );
    _subscription = notifications.listen(onBytes, onError: onError);
    if (notifications case final BleReadyNotificationStream ready) {
      await ready.ready;
    }
  }

  /// Write one frame, split to the link's MTU where it does not fit.
  Future<void> write(List<int> frame) async {
    if (_closed) return;
    final payload = writePayloadForMtu(await ble.mtu(deviceId));
    final packets = [
      for (var offset = 0; offset < frame.length; offset += payload)
        frame.sublist(
          offset,
          offset + payload < frame.length ? offset + payload : frame.length,
        ),
    ];
    if (ble case BlePacketWriter writer) {
      await writer.writeCharacteristicPackets(
        deviceId,
        serviceUuid,
        writeUuid,
        packets,
      );
      return;
    }
    for (final packet in packets) {
      await ble.writeCharacteristic(deviceId, serviceUuid, writeUuid, packet);
    }
  }

  Future<void> close() async {
    _closed = true;
    await _subscription?.cancel();
    _subscription = null;
    if (!_connected) return;
    _connected = false;
    try {
      await ble.disconnect(deviceId);
    } on Object catch (e) {
      Log.ble.debug('read-only session disconnect failed', error: e);
    }
  }
}
