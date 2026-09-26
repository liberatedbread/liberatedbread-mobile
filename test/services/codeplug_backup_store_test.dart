// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/services/codeplug_backup_store.dart';
import 'package:liberated_bread_mobile/services/radio_programmer.dart';

RadioCodeplug _codeplug({
  String modelId = 'uv-5r-mini',
  int fill = 0x42,
  DateTime? readAt,
}) => RadioCodeplug(
  modelId: modelId,
  image: Uint8List.fromList(List<int>.filled(0x100, fill)),
  readAt: readAt ?? DateTime.utc(2026, 8, 28, 12),
);

void main() {
  late Directory temp;
  late CodeplugBackupStore store;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('codeplug_backup_test');
    store = CodeplugBackupStore(dirResolver: () async => temp);
  });

  tearDown(() async {
    if (await temp.exists()) await temp.delete(recursive: true);
  });

  test('nothing backed up yet is an empty list, not an error', () async {
    expect(await store.list(), isEmpty);
  });

  test('saves an image and reads it back byte for byte', () async {
    final original = _codeplug();
    final backup = await store.save(original);

    expect(await backup.file.exists(), isTrue);

    final loaded = await store.load(backup);
    expect(loaded.image, original.image);
    expect(loaded.modelId, 'uv-5r-mini');
  });

  test('names the file after the radio and when it was read', () async {
    final backup = await store.save(_codeplug());
    expect(backup.displayName, startsWith('uv-5r-mini_'));
    expect(backup.displayName, endsWith('.bin'));
    // A colon in a filename is fine on one platform and not on another.
    expect(backup.displayName, isNot(contains(':')));
  });

  test('the read time comes from the name, not the file\'s mtime', () async {
    // A copy, a restore from a phone backup or a sync all rewrite an mtime.
    // A backup list ordered by mtime would then be ordered by nothing.
    final backup = await store.save(
      _codeplug(readAt: DateTime.utc(2020, 5, 6)),
    );
    expect(backup.takenAt.toUtc(), DateTime.utc(2020, 5, 6));
    expect(
      (await store.list()).single.takenAt.toUtc(),
      DateTime.utc(2020, 5, 6),
    );
  });

  test('the read time comes from the name, not the file\'s mtime', () async {
    // A copy, a restore from a phone backup or a sync all rewrite an mtime.
    // A backup list ordered by mtime would then be ordered by nothing.
    final backup = await store.save(
      _codeplug(readAt: DateTime.utc(2020, 5, 6)),
    );
    expect(backup.takenAt.toUtc(), DateTime.utc(2020, 5, 6));
    expect(
      (await store.list()).single.takenAt.toUtc(),
      DateTime.utc(2020, 5, 6),
    );
  });

  test('lists newest first', () async {
    await store.save(_codeplug(readAt: DateTime.utc(2026, 1)));
    await store.save(_codeplug(readAt: DateTime.utc(2026, 8)));
    await store.save(_codeplug(readAt: DateTime.utc(2026, 4)));

    final all = await store.list();
    expect(all, hasLength(3));
    for (var i = 1; i < all.length; i++) {
      expect(
        all[i - 1].takenAt.isAfter(all[i].takenAt) ||
            all[i - 1].takenAt == all[i].takenAt,
        isTrue,
      );
    }
  });

  test('keeps a bounded number per radio', () async {
    // A backup from four months and two firmware updates ago is not the one
    // anybody restores, and each is 33 kB.
    for (var i = 0; i < CodeplugBackupStore.keepPerModel + 5; i++) {
      await store.save(_codeplug(readAt: DateTime.utc(2026, 1, 1 + i)));
    }
    final all = await store.list();
    expect(all, hasLength(CodeplugBackupStore.keepPerModel));
    // The survivors are the newest.
    expect(all.first.takenAt.day, greaterThan(all.last.takenAt.day));
  });

  test('does not prune another radio\'s backups', () async {
    await store.save(_codeplug(modelId: 'uv-32', readAt: DateTime.utc(2025)));
    for (var i = 0; i < CodeplugBackupStore.keepPerModel + 3; i++) {
      await store.save(_codeplug(readAt: DateTime.utc(2026, 1, 1 + i)));
    }
    final all = await store.list();
    expect(all.where((b) => b.modelId == 'uv-32'), hasLength(1));
  });

  test('deletes one', () async {
    final backup = await store.save(_codeplug());
    await store.delete(backup);
    expect(await store.list(), isEmpty);
    // Deleting twice is not an error.
    await store.delete(backup);
  });

  test('an unreadable directory is no backups rather than a crash', () async {
    final broken = CodeplugBackupStore(
      dirResolver: () async => throw const FileSystemException('nope'),
    );
    expect(await broken.list(), isEmpty);
  });

  test('a model id with path characters cannot escape the directory', () async {
    final backup = await store.save(_codeplug(modelId: '../../etc/passwd'));
    expect(backup.file.parent.path, endsWith('radio_backups'));
    expect(backup.displayName, isNot(contains('/')));
  });

  test('ignores files that are not backups', () async {
    await store.save(_codeplug());
    await File('${temp.path}/radio_backups/notes.txt').writeAsString('hello');
    expect(await store.list(), hasLength(1));
  });
}
