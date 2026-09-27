// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// The Linux router's own window onto bluetoothd, beside the one
// flutter_blue_plus_linux keeps: one long-lived BlueZClient, connected on
// first use. Its object cache follows bluetoothd's signals, so every answer
// here is a local read rather than a round trip over the bus. Two questions
// only BlueZ can answer:
//
// - A device's LE ADDRESS TYPE. The direct path's L2CAP connect needs it, an
//   advertisement is the only place it is stated, and no flutter_blue_plus
//   message carries it.
//
// - Which devices BlueZ ALREADY KNEW are advertising now. flutter_blue_plus_
//   linux builds scan results from one signal alone — a device appearing in
//   BlueZ's object tree (InterfacesAdded) — and bluetoothd keeps every device
//   that was ever connected through it (Device1.Connect makes a device
//   non-temporary), plus every paired one. So from the moment a device has
//   been used once, it never appears in a scan again: not later in the same
//   run, and not in any later run, because the tree is replayed at startup
//   before anyone is listening. That includes every direct-ATT device, whose
//   first contact went through BlueZ. bluetoothd does publish what it hears
//   from a known device during discovery, as property changes on its Device1
//   (RSSI first of all), and [BluezView.sightings] turns those back into
//   the scan results the backend never sends.

import 'dart:async';

import 'package:bluez/bluez.dart';
import 'package:flutter_blue_plus_platform_interface/flutter_blue_plus_platform_interface.dart';

import '../../core/log.dart';

/// See the file comment.
class BluezView {
  final BlueZClient Function() _newClient;
  BlueZClient? _client;
  Future<BlueZClient>? _connecting;

  /// [client] builds the BlueZ client — injectable so a test can point it at
  /// a private bus; the default is the system bus bluetoothd serves.
  BluezView({BlueZClient Function()? client})
    : _newClient = client ?? BlueZClient.new;

  /// The Device1 properties an advertisement updates. A change to any of
  /// them on a device that is not connected means bluetoothd just heard it.
  static const Set<String> advertised = {
    'RSSI',
    'ManufacturerData',
    'ServiceData',
    'TxPower',
    'UUIDs',
  };

  Future<BlueZClient> _connected() => _connecting ??= () async {
    final client = _newClient();
    try {
      await client.connect();
    } catch (_) {
      // Try the bus again next time rather than caching a dead client.
      _connecting = null;
      unawaited(client.close().catchError((Object _) {}));
      rethrow;
    }
    return _client = client;
  }();

  /// Connect to bluetoothd now rather than on first use. Never throws: a
  /// failure is retried at the next use.
  Future<void> warmUp() async {
    try {
      await _connected();
    } catch (e) {
      Log.ble.debug('bluetoothd not reachable yet', error: e);
    }
  }

  /// Whether [address] is an LE random address, by bluetoothd's record of
  /// it. A device bluetoothd does not know, or any trouble asking, reads as
  /// public — the common case for the products the direct path serves.
  Future<bool> isRandom(String address) async {
    try {
      final client = await _connected();
      final wanted = address.toUpperCase();
      for (final device in client.devices) {
        if (device.address.toUpperCase() == wanted) {
          return device.addressType == BlueZAddressType.random;
        }
      }
      Log.ble.debug(
        '$address is unknown to bluetoothd; assuming a public address',
      );
    } catch (e) {
      Log.ble.debug(
        'could not ask bluetoothd for the address type of $address; '
        'assuming public',
        error: e,
      );
    }
    return false;
  }

  /// Every advertisement bluetoothd reports hearing from a device it already
  /// has, as the scan result flutter_blue_plus_linux would have built for a
  /// new one. Listen only while scanning (the router does); a device that is
  /// connected is not advertising, and its property changes are skipped.
  ///
  /// Never errors: without bluetoothd there are simply no sightings, and a
  /// scan works exactly as it did before.
  Stream<BmScanAdvertisement> sightings() => Stream.multi((controller) {
    final watched = <String, StreamSubscription<List<String>>>{};
    StreamSubscription<BlueZDevice>? added;
    StreamSubscription<BlueZDevice>? removed;
    var cancelled = false;

    void watch(BlueZDevice device) {
      final key = device.address.toUpperCase();
      unawaited(watched.remove(key)?.cancel());
      try {
        watched[key] = device.propertiesChanged.listen((changed) {
          if (!changed.any(advertised.contains)) return;
          if (device.connected) return;
          controller.add(advertisementOf(device));
        });
      } catch (e) {
        // package:bluez throws (a String) for an object that lost its
        // Device1 interface; such a device has nothing to report.
        Log.ble.debug('not watching ${device.address}', error: e);
      }
    }

    unawaited(() async {
      try {
        final client = await _connected();
        if (cancelled) return;
        client.devices.forEach(watch);
        // Devices new to BlueZ are reported by flutter_blue_plus_linux
        // itself when they appear; watching them too only adds what the
        // backend never re-sends — their later advertisements.
        added = client.deviceAdded.listen(watch);
        removed = client.deviceRemoved.listen(
          (device) =>
              unawaited(watched.remove(device.address.toUpperCase())?.cancel()),
        );
      } catch (e) {
        Log.ble.debug('no known-device sightings from bluetoothd', error: e);
      }
    }());

    controller.onCancel = () async {
      cancelled = true;
      await added?.cancel();
      await removed?.cancel();
      await Future.wait(watched.values.map((s) => s.cancel()));
      watched.clear();
    };
  });

  /// [device] as a scan result, field for field as flutter_blue_plus_linux
  /// builds one from a device it has just seen appear.
  static BmScanAdvertisement advertisementOf(BlueZDevice device) =>
      BmScanAdvertisement(
        remoteId: DeviceIdentifier(device.address),
        platformName: device.name,
        advName: null,
        connectable: true,
        txPowerLevel: device.txPower,
        appearance: device.appearance,
        manufacturerData: device.manufacturerData.map(
          (id, value) => MapEntry(id.id, value),
        ),
        serviceData: device.serviceData.map(
          (uuid, value) => MapEntry(Guid.fromBytes(uuid.value), value),
        ),
        serviceUuids: [
          for (final uuid in device.uuids) Guid.fromBytes(uuid.value),
        ],
        rssi: device.rssi,
      );

  Future<void> close() async {
    final client = _client;
    _connecting = null;
    _client = null;
    await client?.close();
  }
}
