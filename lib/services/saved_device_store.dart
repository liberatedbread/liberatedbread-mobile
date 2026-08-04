// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// A device the user has paired with and wants to keep.
///
/// Deliberately a snapshot rather than a live [IoTDevice]: the point of a saved
/// device is that it survives the scan that discovered it, so it stores only
/// what's still meaningful when the device is out of range.
class SavedDevice {
  final String id;
  final String name;
  final DateTime lastSeen;

  const SavedDevice({
    required this.id,
    required this.name,
    required this.lastSeen,
  });

  SavedDevice copyWith({String? name, DateTime? lastSeen}) => SavedDevice(
        id: id,
        name: name ?? this.name,
        lastSeen: lastSeen ?? this.lastSeen,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'lastSeen': lastSeen.toIso8601String(),
      };

  /// Returns null for records that can't be read, so one corrupt entry can't
  /// take the whole saved-device list down with it.
  static SavedDevice? fromJson(Map<String, dynamic> json) {
    final id = json['id'];
    final name = json['name'];
    final lastSeen = json['lastSeen'];
    if (id is! String || id.isEmpty || name is! String) return null;
    final parsed = lastSeen is String ? DateTime.tryParse(lastSeen) : null;
    return SavedDevice(
      id: id,
      name: name,
      lastSeen: parsed ?? DateTime.fromMillisecondsSinceEpoch(0),
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is SavedDevice && id == other.id;

  @override
  int get hashCode => id.hashCode;
}

/// Persists the user's paired devices across launches.
///
/// This is the gap the scan-only app had: discovered devices lived in an
/// in-memory map, so every relaunch started from an empty list. Records are
/// stored as a JSON array under a single key — the list is small (a handful of
/// devices), so per-key storage would buy nothing but complexity.
class SavedDeviceStore {
  static const _key = 'saved_devices_v1';

  final SharedPreferences _prefs;

  SavedDeviceStore(this._prefs);

  /// Saved devices, most recently seen first.
  List<SavedDevice> load() {
    final raw = _prefs.getString(_key);
    if (raw == null || raw.isEmpty) return const [];

    List<dynamic> decoded;
    try {
      final value = jsonDecode(raw);
      if (value is! List) return const [];
      decoded = value;
    } on FormatException {
      // Unreadable blob: treat as empty rather than throwing on startup.
      return const [];
    }

    final devices = <SavedDevice>[];
    for (final entry in decoded) {
      if (entry is! Map<String, dynamic>) continue;
      final device = SavedDevice.fromJson(entry);
      if (device != null) devices.add(device);
    }
    devices.sort((a, b) => b.lastSeen.compareTo(a.lastSeen));
    return devices;
  }

  /// Insert or update [device], keeping the list newest-first.
  Future<List<SavedDevice>> save(SavedDevice device) async {
    final devices = load().where((d) => d.id != device.id).toList()
      ..insert(0, device);
    await _write(devices);
    return devices;
  }

  Future<List<SavedDevice>> remove(String id) async {
    final devices = load().where((d) => d.id != id).toList();
    await _write(devices);
    return devices;
  }

  Future<void> _write(List<SavedDevice> devices) =>
      _prefs.setString(_key, jsonEncode(devices.map((d) => d.toJson()).toList()));
}
