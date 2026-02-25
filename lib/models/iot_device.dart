// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import '../core/constants.dart';

class IoTDevice {
  final String id;
  final String name;
  final int rssi;
  final bool isConnectable;
  final DateTime discoveredAt;

  const IoTDevice({
    required this.id,
    required this.name,
    required this.rssi,
    required this.isConnectable,
    required this.discoveredAt,
  });

  bool get isNearby => rssi > AppConstants.nearbyRssiThreshold;
  String get displayName => name.isNotEmpty ? name : 'Unknown ($id)';

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is IoTDevice && id == other.id;

  @override
  int get hashCode => id.hashCode;
}
