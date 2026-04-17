// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import '../core/hex.dart';

class DeviceCharacteristic {
  final String uuid;
  final String? name;
  final List<int> value;
  final bool canRead;
  final bool canWrite;
  final bool canNotify;

  const DeviceCharacteristic({
    required this.uuid,
    this.name,
    this.value = const [],
    this.canRead = false,
    this.canWrite = false,
    this.canNotify = false,
  });

  String get hexValue {
    if (value.isEmpty) return '(empty)';
    return bytesToHex(value);
  }

  String? get stringValue {
    if (value.isEmpty) return null;
    try {
      final s = String.fromCharCodes(value);
      final isPrintable = s.runes.every(
        (r) => (r >= 0x20 && r < 0x7F) || r == 0x0A || r == 0x0D,
      );
      if (isPrintable) return s;
    } catch (_) {}
    return null;
  }
}
