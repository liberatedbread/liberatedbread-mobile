// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'package:flutter/foundation.dart';

import '../core/constants.dart';
import '../core/hex.dart';

class IoTDevice {
  final String id;
  final String name;
  final int rssi;
  final bool isConnectable;
  final DateTime discoveredAt;

  /// When this device was last heard advertising.
  ///
  /// Distinct from [discoveredAt], which is pinned to the FIRST sighting: the
  /// scan keeps devices listed across the whole session, so without a separate
  /// last-heard stamp a row that stopped advertising ten minutes ago looks
  /// exactly like one broadcasting right now. Every sighting refreshes it —
  /// see `ScanResultCoalescer`, which re-emits a device on a heartbeat even
  /// when nothing about the advertisement changed, precisely so this stays
  /// honest. Defaults to [discoveredAt]: a device only just seen was, by
  /// definition, last seen then.
  final DateTime lastSeen;

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
    DateTime? lastSeen,
    this.serviceUuids = const [],
    this.companyIds = const [],
  }) : lastSeen = lastSeen ?? discoveredAt;

  bool get isNearby => rssi > AppConstants.nearbyRssiThreshold;

  /// How long ago this device was last heard from, as of [now].
  Duration ageAt(DateTime now) => now.difference(lastSeen);
  String get displayName => name.isNotEmpty ? name : 'Unknown ($id)';

  /// The device's hardware address, when [id] is one — see
  /// [macAddressOrNull] for the discriminator and why it is shared.
  String? get macAddress => macAddressOrNull(id);

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is IoTDevice && id == other.id;

  @override
  int get hashCode => id.hashCode;

  /// Whether two sightings say the same thing about *what* the device is.
  ///
  /// Deliberately excludes rssi, [discoveredAt] and [lastSeen]: signal strength
  /// and freshness change on every advertisement, and re-running spec matching
  /// on each of those would be pure waste. Identity is what matching actually
  /// reads.
  bool hasSameIdentity(IoTDevice other) =>
      other.id == id &&
      other.name == name &&
      listEquals(other.serviceUuids, serviceUuids) &&
      listEquals(other.companyIds, companyIds);
}
