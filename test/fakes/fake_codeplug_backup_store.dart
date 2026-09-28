// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:io';

import 'package:liberated_bread_mobile/services/codeplug_backup_store.dart';
import 'package:liberated_bread_mobile/services/radio_programmer.dart';

/// A backup store that keeps everything in memory.
///
/// `testWidgets` runs its body inside a fake-async zone where real file I/O
/// never completes -- a disk write in a screen test is not a slow test, it is
/// a hang. The store's own suite covers the filesystem; what a screen test is
/// for is whether the backup happens, and when.
///
/// Each backup gets a stable id at insertion, carried in its file name the way
/// the real store's file path identifies it: an index into a list that grows
/// would point at a different backup after the next save.
class FakeCodeplugBackupStore implements CodeplugBackupStore {
  final List<RadioCodeplug> saved = [];
  final Map<int, RadioCodeplug> _byId = {};
  final List<int> _order = [];
  int _nextId = 0;

  /// When true, a save prunes each model the way the real store's _prune
  /// does: past [CodeplugBackupStore.keepPerModel] newest, every backup but
  /// the very oldest goes. A fake that dropped the oldest first pinned a
  /// restore the real store can never face, and left untested the one it
  /// can (the second-oldest, deleted by the pre-restore save).
  ///
  /// It does not copy the real store's skipping of an image identical to
  /// the newest backup: a screen test's saves are told apart by count.
  final bool prunes;

  /// [existing] are backups already on "disk" before the test starts, oldest
  /// first.
  FakeCodeplugBackupStore({
    List<RadioCodeplug> existing = const [],
    this.prunes = false,
  }) {
    for (final codeplug in existing) {
      _add(codeplug);
    }
  }

  int _add(RadioCodeplug codeplug) {
    final id = _nextId++;
    _byId[id] = codeplug;
    _order.add(id);
    return id;
  }

  CodeplugBackup _entry(int id) {
    final codeplug = _byId[id]!;
    return CodeplugBackup(
      file: File('/in-memory/${codeplug.modelId}_$id.bin'),
      modelId: codeplug.modelId,
      takenAt: codeplug.readAt,
    );
  }

  @override
  Future<CodeplugBackup> save(RadioCodeplug codeplug) async {
    saved.add(codeplug);
    final entry = _entry(_add(codeplug));
    if (prunes) {
      const keep = CodeplugBackupStore.keepPerModel;
      // Oldest first.
      final ofModel = [
        for (final id in _order)
          if (_byId[id]!.modelId == codeplug.modelId) id,
      ];
      if (ofModel.length > keep + 1) {
        for (final id in ofModel.sublist(1, ofModel.length - keep)) {
          _byId.remove(id);
          _order.remove(id);
        }
      }
    }
    return entry;
  }

  /// Newest first, as the real store lists them.
  @override
  Future<List<CodeplugBackup>> list() async => [
    for (final id in _order.reversed) _entry(id),
  ];

  @override
  Future<RadioCodeplug> load(CodeplugBackup backup) async {
    final id = int.parse(
      RegExp(r'_(\d+)\.bin$').firstMatch(backup.file.path)!.group(1)!,
    );
    final codeplug = _byId[id];
    if (codeplug == null) {
      throw FileSystemException('backup pruned', backup.file.path);
    }
    return codeplug;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
