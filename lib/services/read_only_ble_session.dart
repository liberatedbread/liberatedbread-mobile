// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:async';

import '../core/error_text.dart';
import '../core/hex.dart';
import '../core/log.dart';
import '../models/ble_discovered_service.dart';
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
  bool _connecting = false;
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

    /// Asked with the discovered services before anything is subscribed or
    /// written; a non-null answer ends the session with that message. How a
    /// handler refuses a model it can tell only once connected.
    Future<String?> Function(List<BleDiscoveredService> services)? vet,
  }) async {
    _connecting = true;
    try {
      await ble.connect(deviceId);
    } finally {
      _connecting = false;
    }
    if (_closed) {
      // Closed while the connect was pending, and the connect won the race. It
      // took a claim nobody else will release, and a peripheral left holding a
      // connection stops advertising.
      await _release();
      return;
    }
    _connected = true;
    final services = await ble.discoverServices(deviceId);
    final wanted = normalizeUuid(serviceUuid);
    if (!services.any((s) => normalizeUuid(s.uuid) == wanted)) {
      throw ReadOnlyBleException(missingService);
    }
    if (vet != null) {
      final refusal = await vet(services);
      if (refusal != null) throw ReadOnlyBleException(refusal);
    }
    if (_closed) return;
    final notifications = ble.subscribeCharacteristic(
      deviceId,
      serviceUuid,
      notifyUuid,
    );
    _subscription = notifications.listen(
      onBytes,
      onError: onError,
      // A link that drops closes the stream without an error. Left unheard,
      // the panel kept "reading" a device that had gone, holding its
      // connection claim until the user noticed.
      onDone: () {
        if (!_closed) {
          onError(const ReadOnlyBleException('The device disconnected.'));
        }
      },
    );
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
    if (_connecting) {
      // No claim yet, so disconnect here could release someone else's. Ask for
      // the pending connect to be dropped; if it lands anyway, open() releases
      // what it took.
      if (ble case BleConnectCanceller canceller) {
        try {
          await canceller.cancelConnect(deviceId);
        } on Object catch (e) {
          Log.ble.debug('read-only session cancel failed', error: e);
        }
      }
      return;
    }
    if (!_connected) return;
    _connected = false;
    await _release();
  }

  Future<void> _release() async {
    try {
      await ble.disconnect(deviceId);
    } on Object catch (e) {
      Log.ble.debug('read-only session disconnect failed', error: e);
    }
  }
}
