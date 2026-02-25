// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import '../models/iot_device.dart';

class DeviceManager {
  final Map<String, IoTDevice> _devices = {};

  List<IoTDevice> get devices {
    final list = _devices.values.toList();
    list.sort((a, b) => b.rssi.compareTo(a.rssi));
    return list;
  }

  int get count => _devices.length;
  void addOrUpdate(IoTDevice device) => _devices[device.id] = device;
  IoTDevice? getById(String id) => _devices[id];
  void remove(String id) => _devices.remove(id);
  void clear() => _devices.clear();
}
