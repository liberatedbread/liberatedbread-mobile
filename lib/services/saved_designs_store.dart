// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:convert';
import 'dart:typed_data';

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

  /// For an `animation`: the stored frame cids, in play order. The animation
  /// plays as a looping playlist of these (each a single-frame microapp), so
  /// replay re-sets that playlist rather than playing one cid. Empty/absent for
  /// a single-item picture or text.
  final List<int> frameCids;

  /// For an `animation`: each frame's device-assigned slot (parallel to
  /// [frameCids]), captured from the effect list at save time. The playlist
  /// addresses items by slot, so replay reuses these rather than re-reading the
  /// list. Empty/absent for a picture or text.
  final List<int> frameSlots;

  /// For an `animation`: the RGB888 pixels of each frame (row-major,
  /// `width*height*3` bytes), so replay can RE-UPLOAD the design. The device is
  /// wiped of a design's frames whenever a later save scopes a new loop, so
  /// addressing old cids alone would replay nothing — keeping the pixels lets
  /// replay store them afresh. Empty/absent for designs saved before this field
  /// existed (they fall back to cid-only replay).
  final List<Uint8List> frames;

  /// Canvas geometry + cadence for [frames], needed to re-encode them on replay.
  final int width;
  final int height;
  final int frameMs;

  const SavedDesign({
    required this.name,
    required this.cid,
    required this.kind,
    required this.contentHash,
    required this.savedAt,
    this.frameCids = const [],
    this.frameSlots = const [],
    this.frames = const [],
    this.width = 0,
    this.height = 0,
    this.frameMs = 0,
  });

  Map<String, dynamic> toJson() => {
        'name': name,
        'cid': cid,
        'kind': kind,
        'contentHash': contentHash,
        'savedAt': savedAt.toIso8601String(),
        if (frameCids.isNotEmpty) 'frameCids': frameCids,
        if (frameSlots.isNotEmpty) 'frameSlots': frameSlots,
        if (frames.isNotEmpty) ...{
          'frames': [for (final f in frames) base64Encode(f)],
          'width': width,
          'height': height,
          'frameMs': frameMs,
        },
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
    final rawFrames = json['frameCids'];
    final frameCids = rawFrames is List
        ? rawFrames.whereType<int>().toList(growable: false)
        : const <int>[];
    final rawSlots = json['frameSlots'];
    final frameSlots = rawSlots is List
        ? rawSlots.whereType<int>().toList(growable: false)
        : const <int>[];
    final rawPixels = json['frames'];
    final frames = <Uint8List>[];
    if (rawPixels is List) {
      for (final f in rawPixels) {
        if (f is String) {
          try {
            frames.add(base64Decode(f));
          } on FormatException {
            // A corrupt frame drops re-upload for this design; cid-replay stays.
            frames.clear();
            break;
          }
        }
      }
    }
    return SavedDesign(
      name: name,
      cid: cid,
      kind: kind,
      contentHash: hash,
      savedAt: parsed ?? DateTime.fromMillisecondsSinceEpoch(0),
      frameCids: frameCids,
      frameSlots: frameSlots,
      frames: frames,
      width: json['width'] is int ? json['width'] as int : 0,
      height: json['height'] is int ? json['height'] as int : 0,
      frameMs: json['frameMs'] is int ? json['frameMs'] as int : 0,
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

  /// Forget every design recorded for [deviceId] — the app's side of a
  /// "clear the device's stored designs" action (the caller sends the device
  /// the deletes).
  Future<void> clear(String deviceId) async {
    await _prefs.remove('$_keyPrefix$deviceId');
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
