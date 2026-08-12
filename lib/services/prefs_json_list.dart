// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// Read a JSON-array-under-one-key preferences blob defensively: an absent
/// key, an unreadable blob, a non-list payload, a non-object entry, or an
/// entry [decode] rejects (returns null for) each costs only itself — never
/// the rest of the list, and never startup.
///
/// [SavedDeviceStore] and [DeviceGroupStore] share this policy through one
/// implementation on purpose: how much data one corrupt write may take down
/// is a decision, and two hand-copied loaders would eventually answer it
/// differently.
List<T> loadPrefsJsonList<T>(
  SharedPreferences prefs,
  String key,
  T? Function(Map<String, dynamic> json) decode,
) {
  final raw = prefs.getString(key);
  if (raw == null || raw.isEmpty) return [];

  List<dynamic> decoded;
  try {
    final value = jsonDecode(raw);
    if (value is! List) return [];
    decoded = value;
  } on FormatException {
    // Unreadable blob: treat as empty rather than throwing on startup.
    return [];
  }

  final items = <T>[];
  for (final entry in decoded) {
    if (entry is! Map<String, dynamic>) continue;
    final item = decode(entry);
    if (item != null) items.add(item);
  }
  return items;
}

/// Write [items] back as the JSON array [loadPrefsJsonList] reads.
Future<void> savePrefsJsonList<T>(
  SharedPreferences prefs,
  String key,
  List<T> items,
  Map<String, dynamic> Function(T item) encode,
) =>
    prefs.setString(key, jsonEncode([for (final item in items) encode(item)]));
