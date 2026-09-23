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

  /// When set, a save prunes each model to its newest [keepPerModel], as
  /// [CodeplugBackupStore.keepPerModel] makes the real store do.
  final int? keepPerModel;

  /// [existing] are backups already on "disk" before the test starts, oldest
  /// first.
  FakeCodeplugBackupStore({
    List<RadioCodeplug> existing = const [],
    this.keepPerModel,
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
      length: codeplug.length,
    );
  }

  @override
  Future<CodeplugBackup> save(RadioCodeplug codeplug) async {
    saved.add(codeplug);
    final entry = _entry(_add(codeplug));
    final keep = keepPerModel;
    if (keep != null) {
      final ofModel = [
        for (final id in _order)
          if (_byId[id]!.modelId == codeplug.modelId) id,
      ];
      for (final id in ofModel.take(ofModel.length - keep)) {
        _byId.remove(id);
        _order.remove(id);
      }
    }
    return entry;
  }

  /// Newest first, as the real store lists them.
  @override
  Future<List<CodeplugBackup>> list() async =>
      [for (final id in _order.reversed) _entry(id)];

  @override
  Future<RadioCodeplug> load(CodeplugBackup backup) async {
    final id = int.parse(
        RegExp(r'_(\d+)\.bin$').firstMatch(backup.file.path)!.group(1)!);
    final codeplug = _byId[id];
    if (codeplug == null) {
      throw FileSystemException('backup pruned', backup.file.path);
    }
    return codeplug;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
