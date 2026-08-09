// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'package:flutter/foundation.dart';

import '../core/constants.dart';

class IoTDevice {
  final String id;
  final String name;
  final int rssi;
  final bool isConnectable;
  final DateTime discoveredAt;

  /// Service UUIDs carried in the advertisement. NOT the GATT services
  /// discovered after connecting — advertisements are 31 bytes, so this is
  /// usually a subset and often empty.
  final List<String> serviceUuids;

  /// Bluetooth SIG company IDs from the advertisement's manufacturer-specific
  /// data. Often the only pre-connect signal a sensor gives off: plenty of
  /// devices broadcast their readings under a company ID and advertise neither
  /// a useful name nor a service UUID.
  final List<int> companyIds;

  const IoTDevice({
    required this.id,
    required this.name,
    required this.rssi,
    required this.isConnectable,
    required this.discoveredAt,
    this.serviceUuids = const [],
    this.companyIds = const [],
  });

  bool get isNearby => rssi > AppConstants.nearbyRssiThreshold;
  String get displayName => name.isNotEmpty ? name : 'Unknown ($id)';

  /// The device's hardware address, when [id] is one.
  ///
  /// Android, Linux and Windows put the MAC in the platform device id; Apple
  /// platforms substitute a per-host CoreBluetooth UUID, which carries no OUI
  /// and must not be read as an address. Six colon-separated octets is the
  /// discriminator — a UUID has five hyphen-separated groups instead.
  String? get macAddress {
    final octets = id.split(':');
    if (octets.length != 6) return null;
    final isMac = octets.every((octet) =>
        octet.length == 2 &&
        octet.codeUnits.every((c) =>
            (c >= 0x30 && c <= 0x39) || // 0-9
            (c >= 0x41 && c <= 0x46) || // A-F
            (c >= 0x61 && c <= 0x66))); // a-f
    return isMac ? id : null;
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is IoTDevice && id == other.id;

  @override
  int get hashCode => id.hashCode;

  /// Whether two sightings say the same thing about *what* the device is.
  ///
  /// Deliberately excludes rssi and [discoveredAt]: signal strength changes on
  /// every advertisement, and re-running spec matching on each of those would
  /// be pure waste. Identity is what matching actually reads.
  bool hasSameIdentity(IoTDevice other) =>
      other.id == id &&
      other.name == name &&
      listEquals(other.serviceUuids, serviceUuids) &&
      listEquals(other.companyIds, companyIds);
}
