// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// A user-named collection of saved devices ("Living Room", "Bike lights"),
/// acted on as one thing by the group operations.
///
/// Members are device ids into the saved-devices store, not embedded device
/// records: the saved record stays the single owner of name/category state,
/// and a member the user forgets is simply filtered out at display and run
/// time rather than living on here as a stale copy.
class DeviceGroup {
  final String id;
  final String name;
  final List<String> deviceIds;

  const DeviceGroup({
    required this.id,
    required this.name,
    required this.deviceIds,
  });

  DeviceGroup copyWith({String? name, List<String>? deviceIds}) => DeviceGroup(
        id: id,
        name: name ?? this.name,
        deviceIds: deviceIds ?? this.deviceIds,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'deviceIds': deviceIds,
      };

  /// Returns null for records that can't be read, so one corrupt entry can't
  /// take the whole group list down with it. Non-string member entries are
  /// dropped individually for the same reason.
  static DeviceGroup? fromJson(Map<String, dynamic> json) {
    final id = json['id'];
    final name = json['name'];
    final ids = json['deviceIds'];
    if (id is! String || id.isEmpty || name is! String || name.isEmpty) {
      return null;
    }
    if (ids is! List) return null;
    return DeviceGroup(
      id: id,
      name: name,
      deviceIds: [
        for (final entry in ids)
          if (entry is String && entry.isNotEmpty) entry,
      ],
    );
  }

  /// Identity equality, like [SavedDevice]: two snapshots of the same group
  /// are the same group.
  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is DeviceGroup && id == other.id;

  @override
  int get hashCode => id.hashCode;
}

/// Persists the user's device groups across launches. Same shape as
/// `SavedDeviceStore`: a JSON array under a single key with defensive
/// decoding, because the list is a handful of records at most.
///
/// Unlike saved devices, groups keep **creation order** rather than recency
/// order — a list that reshuffles every time a group is edited would move
/// buttons under the user's finger for no benefit.
class DeviceGroupStore {
  static const _key = 'device_groups_v1';

  final SharedPreferences _prefs;

  DeviceGroupStore(this._prefs);

  /// Groups in creation order.
  List<DeviceGroup> load() {
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

    final groups = <DeviceGroup>[];
    for (final entry in decoded) {
      if (entry is! Map<String, dynamic>) continue;
      final group = DeviceGroup.fromJson(entry);
      if (group != null) groups.add(group);
    }
    return groups;
  }

  /// Insert or update [group] (matched by id): updates keep their place in
  /// the list, new groups append at the end.
  Future<List<DeviceGroup>> save(DeviceGroup group) async {
    final groups = load().toList();
    final index = groups.indexWhere((g) => g.id == group.id);
    if (index >= 0) {
      groups[index] = group;
    } else {
      groups.add(group);
    }
    await _write(groups);
    return groups;
  }

  Future<List<DeviceGroup>> remove(String id) async {
    final groups = load().where((g) => g.id != id).toList();
    await _write(groups);
    return groups;
  }

  Future<void> _write(List<DeviceGroup> groups) => _prefs.setString(
      _key, jsonEncode(groups.map((g) => g.toJson()).toList()));
}
