// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// Keeping a copy of what was on the radio before.

import 'dart:io';
import 'dart:typed_data';

import '../core/log.dart';
import 'radio_programmer.dart';
import 'spec_pack_service.dart' show CacheDirResolver;

/// A stored copy of a radio's memory.
class CodeplugBackup {
  final File file;
  final String modelId;
  final DateTime takenAt;
  final int length;

  const CodeplugBackup({
    required this.file,
    required this.modelId,
    required this.takenAt,
    required this.length,
  });

  String get displayName => file.uri.pathSegments.last;
}

/// Saves and lists codeplug backups under the app documents directory.
///
/// Every write to a radio is preceded by one. That is not a safety gate
/// bolted onto the feature -- it is the same download-then-upload discipline
/// every programming tool uses, and it is the only thing that makes an
/// unverified protocol a recoverable risk rather than a permanent one.
class CodeplugBackupStore {
  static const String _dirName = 'radio_backups';

  /// Keep this many per radio. Old ones are pruned oldest-first: a backup
  /// from four months and two firmware updates ago is not the one anybody
  /// restores, and the images are 33 kB each.
  static const int keepPerModel = 10;

  final CacheDirResolver _resolveDir;

  CodeplugBackupStore({required CacheDirResolver dirResolver})
      : _resolveDir = dirResolver;

  Future<Directory> _root() async {
    final base = await _resolveDir();
    return Directory('${base.path}/$_dirName');
  }

  /// Save [codeplug], returning the file it landed in.
  Future<CodeplugBackup> save(RadioCodeplug codeplug) async {
    final dir = await _root();
    await dir.create(recursive: true);

    // `<model>_<epoch millis>.bin`. The timestamp goes in the name rather
    // than being read back off the filesystem later, because a file's mtime
    // is not when the radio was read -- a copy, a restore from a phone
    // backup, or a sync all rewrite it, and a backup list ordered by mtime
    // would then be ordered by nothing in particular. The underscore is the
    // separator because model ids contain dashes and do not contain
    // underscores.
    final safeModel = codeplug.modelId.replaceAll(RegExp(r'[^A-Za-z0-9-]'), '');
    final stamp = codeplug.readAt.toUtc().millisecondsSinceEpoch;
    final file = File('${dir.path}/${safeModel}_$stamp.bin');
    await file.writeAsBytes(codeplug.image, flush: true);

    await _prune(safeModel);
    return CodeplugBackup(
      file: file,
      modelId: codeplug.modelId,
      takenAt: codeplug.readAt,
      length: codeplug.length,
    );
  }

  /// Every backup, newest first. Never throws: no backups is a normal state
  /// and an unreadable directory should not take a screen down.
  Future<List<CodeplugBackup>> list() async {
    try {
      final dir = await _root();
      if (!await dir.exists()) return const [];

      final backups = <CodeplugBackup>[];
      await for (final entry in dir.list()) {
        if (entry is! File || !entry.path.endsWith('.bin')) continue;
        final parsed = _parseName(entry.uri.pathSegments.last);
        if (parsed == null) continue;
        final stat = await entry.stat();
        backups.add(CodeplugBackup(
          file: entry,
          modelId: parsed.modelId,
          takenAt: parsed.takenAt,
          length: stat.size,
        ));
      }
      backups.sort((a, b) => b.takenAt.compareTo(a.takenAt));
      return backups;
    } catch (error) {
      Log.radio.warning('listing codeplug backups failed', error: error);
      return const [];
    }
  }

  /// Read one back, ready to write to a radio.
  Future<RadioCodeplug> load(CodeplugBackup backup) async {
    final bytes = await backup.file.readAsBytes();
    return RadioCodeplug(
      modelId: backup.modelId,
      image: Uint8List.fromList(bytes),
      readAt: backup.takenAt,
    );
  }

  Future<void> delete(CodeplugBackup backup) async {
    try {
      if (await backup.file.exists()) await backup.file.delete();
    } catch (error) {
      Log.radio.warning('deleting a codeplug backup failed', error: error);
    }
  }

  /// Read the model and the read-time back out of a filename.
  ///
  /// Returns null for anything this store did not write, so a stray file in
  /// the directory is skipped rather than listed as a backup of nothing.
  static ({String modelId, DateTime takenAt})? _parseName(String name) {
    if (!name.endsWith('.bin')) return null;
    final stem = name.substring(0, name.length - 4);
    final split = stem.lastIndexOf('_');
    if (split <= 0) return null;
    final millis = int.tryParse(stem.substring(split + 1));
    if (millis == null) return null;
    return (
      modelId: stem.substring(0, split),
      takenAt: DateTime.fromMillisecondsSinceEpoch(millis, isUtc: true),
    );
  }

  /// Drop the oldest backups for one model past [keepPerModel].
  Future<void> _prune(String modelPrefix) async {
    try {
      final all = await list();
      final mine = [
        for (final backup in all)
          if (backup.modelId == modelPrefix) backup,
      ];
      for (final backup in mine.skip(keepPerModel)) {
        await delete(backup);
      }
    } catch (error) {
      Log.radio.debug('pruning codeplug backups failed', error: error);
    }
  }
}
