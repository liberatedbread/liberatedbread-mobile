// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// Stable 64-bit FNV-1a over a design's encoded inputs, hex-encoded.
///
/// This is a CONTENT key, not a security hash: it exists so saving the same
/// design twice re-uses the device slot it already occupies instead of
/// filling the catalogue with byte-identical copies. The inputs are hashed
/// (pixels, geometry, playback settings) rather than the finished container,
/// because the container bakes the cid in — the one field a re-save must be
/// allowed to differ on.
String designContentHash(Iterable<int> bytes) {
  // Two decorrelated FNV-1a 32 lanes rather than one FNV-1a 64: the 64-bit
  // multiply wraps Dart's signed int into negatives, while (h ^ byte) * prime
  // here peaks at ~2^57 and stays exact.
  var h1 = 0x811c9dc5;
  var h2 = 0x811c9dc5 ^ 0x5bd1e995;
  for (final b in bytes) {
    final v = b & 0xff;
    h1 = ((h1 ^ v) * 0x01000193) & 0xFFFFFFFF;
    h2 = ((h2 ^ (v + 1)) * 0x01000193) & 0xFFFFFFFF;
  }
  return h1.toRadixString(16).padLeft(8, '0') +
      h2.toRadixString(16).padLeft(8, '0');
}

/// One design stored on a device: enough to re-trigger it (the cid), name it
/// in the UI, and recognise a byte-identical re-save (the content hash).
class SavedDesign {
  final String name;
  final int cid;

  /// `picture` / `text` / `animation` — mirrors the save dialog's kinds.
  final String kind;
  final String contentHash;
  final DateTime savedAt;

  const SavedDesign({
    required this.name,
    required this.cid,
    required this.kind,
    required this.contentHash,
    required this.savedAt,
  });

  Map<String, dynamic> toJson() => {
        'name': name,
        'cid': cid,
        'kind': kind,
        'contentHash': contentHash,
        'savedAt': savedAt.toIso8601String(),
      };

  /// Returns null for records that can't be read, so one corrupt entry can't
  /// take the whole list down with it.
  static SavedDesign? fromJson(Map<String, dynamic> json) {
    final name = json['name'];
    final cid = json['cid'];
    final kind = json['kind'];
    final hash = json['contentHash'];
    if (name is! String || cid is! int || kind is! String || hash is! String) {
      return null;
    }
    final savedAt = json['savedAt'];
    final parsed = savedAt is String ? DateTime.tryParse(savedAt) : null;
    return SavedDesign(
      name: name,
      cid: cid,
      kind: kind,
      contentHash: hash,
      savedAt: parsed ?? DateTime.fromMillisecondsSinceEpoch(0),
    );
  }
}

/// Persists, per device, the designs this app has stored on it — the replay
/// list under the LED editor.
///
/// The DEVICE is the source of truth for what it holds; this store is the
/// app's memory of what it put there (the device offers no practical way to
/// enumerate its catalogue with names from here). Keyed per device because a
/// cid stored on one curtain means nothing to another.
class SavedDesignsStore {
  static const _keyPrefix = 'saved_designs_v1:';

  final SharedPreferences _prefs;

  SavedDesignsStore(this._prefs);

  /// Designs saved on [deviceId], most recently saved first.
  List<SavedDesign> load(String deviceId) {
    final raw = _prefs.getString('$_keyPrefix$deviceId');
    if (raw == null || raw.isEmpty) return const [];

    List<dynamic> decoded;
    try {
      final value = jsonDecode(raw);
      if (value is! List) return const [];
      decoded = value;
    } on FormatException {
      return const [];
    }

    final designs = <SavedDesign>[];
    for (final entry in decoded) {
      if (entry is! Map<String, dynamic>) continue;
      final design = SavedDesign.fromJson(entry);
      if (design != null) designs.add(design);
    }
    designs.sort((a, b) => b.savedAt.compareTo(a.savedAt));
    return designs;
  }

  /// The prior save whose content matches [contentHash], if any — the entry a
  /// byte-identical re-save reuses the cid of.
  SavedDesign? findByContent(String deviceId, String contentHash) {
    for (final design in load(deviceId)) {
      if (design.contentHash == contentHash) return design;
    }
    return null;
  }

  /// Insert or update [design], newest-first. An entry with the same cid OR
  /// the same content is replaced — the same device slot under a new name is
  /// one entry, not two.
  Future<List<SavedDesign>> save(String deviceId, SavedDesign design) async {
    final designs = load(deviceId)
        .where(
            (d) => d.cid != design.cid && d.contentHash != design.contentHash)
        .toList()
      ..insert(0, design);
    await _prefs.setString('$_keyPrefix$deviceId',
        jsonEncode(designs.map((d) => d.toJson()).toList()));
    return designs;
  }
}
