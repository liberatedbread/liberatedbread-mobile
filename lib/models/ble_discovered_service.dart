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

  /// True when the characteristic is writable in *either* mode. Kept as the
  /// convenience flag used by the UI to decide whether to offer write controls.
  final bool canWrite;

  /// True when the characteristic supports write-with-response (GATT `write`).
  final bool canWriteWithResponse;

  /// True when the characteristic supports write-without-response
  /// (GATT `writeWithoutResponse`). Many real control characteristics are
  /// write-without-response ONLY, so this mode must be preserved rather than
  /// collapsed into [canWrite].
  final bool canWriteWithoutResponse;

  final bool canNotify;

  const BleDiscoveredCharacteristic({
    required this.uuid,
    required this.canRead,
    required this.canWrite,
    this.canWriteWithResponse = false,
    this.canWriteWithoutResponse = false,
    required this.canNotify,
  });
}
