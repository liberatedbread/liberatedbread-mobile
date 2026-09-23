// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'package:shared_preferences/shared_preferences.dart';

import '../models/radio_target.dart';
import 'prefs_json_list.dart';

/// A radio the user has talked to and wants to keep.
///
/// Its own record rather than a [SavedDevice] with a radio category, for two
/// reasons. Reopening one goes somewhere different: a saved device reopens
/// the GATT explorer and a saved network device its spec controls, while a
/// radio reopens the radio screen, over Bluetooth or a cable. And the
/// category vocabulary is owned upstream by the device-spec schema, which has
/// no "radio" — radios are not spec-matched at all.
class SavedRadio {
  final RadioTransport transport;
  final String id;
  final String name;

  /// The radio model last used with this radio, which the device screen
  /// opens on. Null until one has been chosen: the radio cannot be asked.
  final String? radioProfileId;

  final DateTime lastSeen;

  const SavedRadio({
    required this.transport,
    required this.id,
    required this.name,
    required this.lastSeen,
    this.radioProfileId,
  });

  RadioTarget get target =>
      RadioTarget(transport: transport, id: id, name: name);

  Map<String, dynamic> toJson() => {
        'transport': transport.wireName,
        'id': id,
        'name': name,
        'lastSeen': lastSeen.toIso8601String(),
        if (radioProfileId != null) 'radioProfileId': radioProfileId,
      };

  /// Returns null for records that can't be read, so one corrupt entry can't
  /// take the whole list down with it.
  static SavedRadio? fromJson(Map<String, dynamic> json) {
    final transport = RadioTransport.fromWire(json['transport']);
    final id = json['id'];
    final name = json['name'];
    final lastSeen = json['lastSeen'];
    final profileId = json['radioProfileId'];
    if (transport == null || id is! String || id.isEmpty || name is! String) {
      return null;
    }
    final parsed = lastSeen is String ? DateTime.tryParse(lastSeen) : null;
    return SavedRadio(
      transport: transport,
      id: id,
      name: name,
      lastSeen: parsed ?? DateTime.fromMillisecondsSinceEpoch(0),
      radioProfileId:
          profileId is String && profileId.isNotEmpty ? profileId : null,
    );
  }

  /// Same identity as [RadioTarget]: the transport and the id together. The
  /// same string could name a Bluetooth device and a port, and those would
  /// not be the same radio.
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SavedRadio && transport == other.transport && id == other.id;

  @override
  int get hashCode => Object.hash(transport, id);
}

/// Persists the radios the user has connected to, most recently seen first.
///
/// One JSON array under one key, like the other saved-device stores: the
/// list is a handful of radios.
class SavedRadioStore {
  static const _key = 'saved_radios_v1';

  final SharedPreferences _prefs;

  SavedRadioStore(this._prefs);

  List<SavedRadio> load() =>
      loadPrefsJsonList(_prefs, _key, SavedRadio.fromJson)
        ..sort((a, b) => b.lastSeen.compareTo(a.lastSeen));

  /// Insert or replace [radio], keeping the list newest-first.
  Future<List<SavedRadio>> save(SavedRadio radio) async {
    final radios = load().where((r) => r != radio).toList()..insert(0, radio);
    await _write(radios);
    return radios;
  }

  Future<List<SavedRadio>> remove(RadioTarget target) async {
    final radios = load()
        .where((r) => r.transport != target.transport || r.id != target.id)
        .toList();
    await _write(radios);
    return radios;
  }

  Future<void> _write(List<SavedRadio> radios) =>
      savePrefsJsonList(_prefs, _key, radios, (r) => r.toJson());
}
