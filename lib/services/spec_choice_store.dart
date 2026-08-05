// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// Persists which device spec the user picked for a device when several specs
/// matched it equally well.
///
/// White-label hardware makes ambiguous matches a real state, not an error:
/// several brands ship the same platform (same GATT service UUIDs), each with
/// its own spec. When ranking cannot separate them the UI asks the user once,
/// and this store remembers the answer per device id so the next connection
/// goes straight to typed controls.
///
/// Values are spec identity keys (see `specKeyFor` in
/// device_spec_match_provider.dart), not file paths: a key survives spec-pack
/// refreshes and vendoring moves, and a stored key whose spec no longer
/// matches the device is simply ignored by the match provider rather than
/// misdirecting it.
class SpecChoiceStore {
  static const _key = 'spec_choices_v1';

  final SharedPreferences _prefs;

  SpecChoiceStore(this._prefs);

  /// Device id -> chosen spec key. Unreadable blobs or entries load as empty/
  /// skipped so one corrupt record can't take down spec matching at startup.
  Map<String, String> load() {
    final raw = _prefs.getString(_key);
    if (raw == null || raw.isEmpty) return const {};

    Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException {
      return const {};
    }
    if (decoded is! Map<String, dynamic>) return const {};

    return {
      for (final entry in decoded.entries)
        if (entry.key.isNotEmpty && entry.value is String)
          entry.key: entry.value as String,
    };
  }

  /// Record [specKey] as the user's choice for [deviceId], returning the new
  /// map.
  Future<Map<String, String>> save(String deviceId, String specKey) async {
    final choices = {...load(), deviceId: specKey};
    await _write(choices);
    return choices;
  }

  /// Forget the choice for [deviceId], returning the new map.
  Future<Map<String, String>> remove(String deviceId) async {
    final choices = {...load()}..remove(deviceId);
    await _write(choices);
    return choices;
  }

  Future<void> _write(Map<String, String> choices) =>
      _prefs.setString(_key, jsonEncode(choices));
}
