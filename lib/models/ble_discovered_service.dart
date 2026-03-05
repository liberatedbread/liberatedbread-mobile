// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0

/// A discovered BLE GATT service (our own model, decoupled from flutter_blue_plus).
class BleDiscoveredService {
  final String uuid;
  final List<BleDiscoveredCharacteristic> characteristics;

  const BleDiscoveredService({
    required this.uuid,
    required this.characteristics,
  });
}

/// A discovered BLE GATT characteristic.
class BleDiscoveredCharacteristic {
  final String uuid;
  final bool canRead;
  final bool canWrite;
  final bool canNotify;

  const BleDiscoveredCharacteristic({
    required this.uuid,
    required this.canRead,
    required this.canWrite,
    required this.canNotify,
  });
}
