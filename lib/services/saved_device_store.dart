// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'package:shared_preferences/shared_preferences.dart';

import 'prefs_json_list.dart';

/// A device the user has paired with and wants to keep.
///
/// Deliberately a snapshot rather than a live [IoTDevice]: the point of a saved
/// device is that it survives the scan that discovered it, so it stores only
/// what's still meaningful when the device is out of range.
class SavedDevice {
  final String id;
  final String name;
  final DateTime lastSeen;

  /// The matched spec's `device.category` wire string ("light", "sensor", …),
  /// recorded once a spec match resolves during a connection. Kept as the raw
  /// string rather than a parsed enum for the same reason the Rust core does:
  /// a spec pack newer than this build may use categories the enum has not
  /// heard of yet, and they must survive a save/load round trip.
  final String? category;

  /// Identity key of the matched spec (`specKeyFor` in
  /// device_spec_match_provider.dart), so group operations can find the spec
  /// for a device that is currently out of range. Null until a match has been
  /// recorded — including every record saved before these fields existed.
  final String? specKey;

  const SavedDevice({
    required this.id,
    required this.name,
    required this.lastSeen,
    this.category,
    this.specKey,
  });

  /// Only the fields the merge path ([SavedDevicesNotifier.touch]) actually
  /// refreshes. Deliberately NOT category/specKey: `??`-merging can never
  /// clear a field, which is exactly why `recordMatch` replaces the whole
  /// record instead — dead parameters here would invite that trap back.
  SavedDevice copyWith({String? name, DateTime? lastSeen}) => SavedDevice(
        id: id,
        name: name ?? this.name,
        lastSeen: lastSeen ?? this.lastSeen,
        category: category,
        specKey: specKey,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'lastSeen': lastSeen.toIso8601String(),
        if (category != null) 'category': category,
        if (specKey != null) 'specKey': specKey,
      };

  /// Returns null for records that can't be read, so one corrupt entry can't
  /// take the whole saved-device list down with it.
  static SavedDevice? fromJson(Map<String, dynamic> json) {
    final id = json['id'];
    final name = json['name'];
    final lastSeen = json['lastSeen'];
    final category = json['category'];
    final specKey = json['specKey'];
    if (id is! String || id.isEmpty || name is! String) return null;
    final parsed = lastSeen is String ? DateTime.tryParse(lastSeen) : null;
    return SavedDevice(
      id: id,
      name: name,
      lastSeen: parsed ?? DateTime.fromMillisecondsSinceEpoch(0),
      category: category is String && category.isNotEmpty ? category : null,
      specKey: specKey is String && specKey.isNotEmpty ? specKey : null,
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
  List<SavedDevice> load() =>
      loadPrefsJsonList(_prefs, _key, SavedDevice.fromJson)
        ..sort((a, b) => b.lastSeen.compareTo(a.lastSeen));

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
      savePrefsJsonList(_prefs, _key, devices, (d) => d.toJson());
}
