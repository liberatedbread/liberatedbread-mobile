// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:bluez/bluez.dart';

import '../core/error_text.dart';
import '../core/log.dart';
import 'direct_att/bluez_view.dart';
import 'linux_spp_transport.dart';

abstract interface class ClassicSppService {
  Future<void> pair(String address);

  Future<Uint8List> request(
    String address,
    List<int> payload, {
    Duration timeout,
  });

  factory ClassicSppService.system() {
    if (!Platform.isLinux) return const _UnsupportedClassicSppService();
    final view = BluezView();
    return BluezClassicSppService((address) async {
      final device = await view.device(address);
      return device == null ? null : _BluezDevice(device);
    });
  }
}

class ClassicSppException implements UserFacingException {
  @override
  final String message;

  const ClassicSppException(this.message);

  @override
  String toString() => message;
}

class _UnsupportedClassicSppService implements ClassicSppService {
  const _UnsupportedClassicSppService();

  @override
  Future<void> pair(String address) => throw const ClassicSppException(
    'This printer uses Bluetooth Classic SPP, which this platform cannot '
    'open from the app. Pair it in system settings or use its network '
    'connection instead.',
  );

  @override
  Future<Uint8List> request(
    String address,
    List<int> payload, {
    Duration timeout = const Duration(seconds: 12),
  }) async {
    await pair(address);
    throw StateError('unsupported SPP request did not throw');
  }
}

abstract interface class ClassicBluetoothAdapter {
  bool get pairable;
  Future<void> setPairable(bool value);
}

abstract interface class ClassicBluetoothDevice {
  bool get paired;
  ClassicBluetoothAdapter get adapter;
  Future<void> pair();
  Future<void> cancelPairing();
}

typedef ClassicDeviceLoader =
    Future<ClassicBluetoothDevice?> Function(String address);

class _BluezAdapter implements ClassicBluetoothAdapter {
  final BlueZAdapter inner;

  const _BluezAdapter(this.inner);

  @override
  bool get pairable => inner.pairable;

  @override
  Future<void> setPairable(bool value) => inner.setPairable(value);
}

class _BluezDevice implements ClassicBluetoothDevice {
  final BlueZDevice inner;

  const _BluezDevice(this.inner);

  @override
  bool get paired => inner.paired;

  @override
  ClassicBluetoothAdapter get adapter => _BluezAdapter(inner.adapter);

  @override
  Future<void> pair() => inner.pair();

  @override
  Future<void> cancelPairing() => inner.cancelPairing();
}

typedef SppProbe =
    Future<Uint8List> Function(
      String address,
      List<int> payload,
      Duration timeout,
    );

class BluezClassicSppService implements ClassicSppService {
  final ClassicDeviceLoader _loadDevice;
  final SppProbe _probe;
  final Duration pairingTimeout;

  BluezClassicSppService(
    this._loadDevice, {
    this._probe = linuxSppProbe,
    this.pairingTimeout = const Duration(seconds: 90),
  });

  @override
  Future<void> pair(String address) async {
    final device = await _device(address);
    if (device.paired) return;
    final adapter = device.adapter;
    final wasPairable = adapter.pairable;
    try {
      if (!wasPairable) await adapter.setPairable(true);
      await device.pair().timeout(pairingTimeout);
    } on TimeoutException {
      await device.cancelPairing().catchError((Object _) {});
      Log.ble.warning('Classic pairing timed out for $address');
      throw const ClassicSppException(
        'Pairing timed out. Press the printer’s Bluetooth button and try '
        'again.',
      );
    } on Object catch (e) {
      Log.ble.warning('Classic pairing failed for $address', error: e);
      throw const ClassicSppException(
        'The system could not pair with the printer. Press its Bluetooth '
        'button, watch for a pairing request, and try again.',
      );
    } finally {
      if (!wasPairable) {
        await adapter.setPairable(false).catchError((Object e) {
          Log.ble.warning(
            'could not restore the adapter pairable flag',
            error: e,
          );
        });
      }
    }
    final confirmed = await _device(address);
    if (!confirmed.paired) {
      throw const ClassicSppException(
        'The system did not save a Bluetooth bond for the printer. Try '
        'pairing again.',
      );
    }
  }

  Future<ClassicBluetoothDevice> _device(String address) async {
    final device = await _loadDevice(address);
    if (device == null) {
      throw const ClassicSppException(
        'The printer is no longer visible to Bluetooth. Turn its Bluetooth '
        'on and scan again.',
      );
    }
    return device;
  }

  @override
  Future<Uint8List> request(
    String address,
    List<int> payload, {
    Duration timeout = const Duration(seconds: 12),
  }) async {
    try {
      return await _probe(address, payload, timeout);
    } on ClassicSppException {
      rethrow;
    } on Object catch (e) {
      Log.ble.warning('SPP request failed for $address', error: e);
      throw const ClassicSppException(
        'The printer is paired, but its SPP status request failed. Turn '
        'Bluetooth off and on at the printer, then try again.',
      );
    }
  }
}
