// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import '../models/iot_device.dart';

class DeviceManager {
  final Map<String, IoTDevice> _devices = {};

  /// Consecutive completed scans each known device has missed. BLE
  /// advertising is lossy, so one missed scan window keeps the device (its
  /// entry would otherwise flicker out and back); a device that misses
  /// [maxConsecutiveMisses] full windows in a row has stopped advertising —
  /// powered off or gone — and listing it any longer offers the user a tap
  /// that can only end in a connect timeout.
  final Map<String, int> _misses = {};
  final Set<String> _seenThisScan = {};

  /// How many completed scans in a row a device may miss before it is
  /// dropped as a ghost.
  static const int maxConsecutiveMisses = 2;

  List<IoTDevice> get devices {
    final list = _devices.values.toList();
    list.sort((a, b) => b.rssi.compareTo(a.rssi));
    return list;
  }

  int get count => _devices.length;

  void addOrUpdate(IoTDevice device) {
    _devices[device.id] = device;
    _seenThisScan.add(device.id);
    _misses.remove(device.id);
  }

  IoTDevice? getById(String id) => _devices[id];
  void remove(String id) {
    _devices.remove(id);
    _misses.remove(id);
  }

  void clear() {
    _devices.clear();
    _misses.clear();
    _seenThisScan.clear();
  }

  /// Mark the start of a scan window: what is (re)discovered from here on
  /// counts toward the next [completeScan] reckoning.
  void beginScan() => _seenThisScan.clear();

  /// Settle a COMPLETED scan window: devices seen keep their entry with a
  /// clean slate, devices missed accrue a strike, and a device striking out
  /// [maxConsecutiveMisses] times is dropped. Only call for scans that ran
  /// their course — an aborted or failed scan says nothing about who is
  /// still advertising.
  void completeScan() {
    final ghosts = <String>[];
    for (final id in _devices.keys) {
      if (_seenThisScan.contains(id)) continue;
      final missed = (_misses[id] ?? 0) + 1;
      if (missed >= maxConsecutiveMisses) {
        ghosts.add(id);
      } else {
        _misses[id] = missed;
      }
    }
    for (final id in ghosts) {
      _devices.remove(id);
      _misses.remove(id);
    }
    _seenThisScan.clear();
  }
}
