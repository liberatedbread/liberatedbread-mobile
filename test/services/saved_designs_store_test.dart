// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/services/saved_designs_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  late SharedPreferences prefs;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
  });

  test('an animation round-trips its frame pixels so replay can re-upload',
      () async {
    final store = SavedDesignsStore(prefs);
    final design = SavedDesign(
      name: 'anim',
      cid: 100,
      kind: 'animation',
      contentHash: 'h',
      savedAt: DateTime(2026, 1, 2),
      frameCids: const [100, 101],
      frameSlots: const [1, 2],
      frames: [
        Uint8List.fromList(const [1, 2, 3, 4, 5, 6]),
        Uint8List.fromList(const [7, 8, 9, 10, 11, 12]),
      ],
      width: 2,
      height: 1,
      frameMs: 200,
    );
    await store.save('AA:BB', design);

    final loaded = store.load('AA:BB').single;
    expect(loaded.frames.map((f) => f.toList()), [
      [1, 2, 3, 4, 5, 6],
      [7, 8, 9, 10, 11, 12],
    ]);
    expect((loaded.width, loaded.height, loaded.frameMs), (2, 1, 200));
    expect(loaded.frameCids, const [100, 101]);
    expect(loaded.frameSlots, const [1, 2]);
  });

  test('a record with no pixels loads with empty frames (legacy fallback)',
      () async {
    final store = SavedDesignsStore(prefs);
    await store.save(
      'AA:BB',
      SavedDesign(
        name: 'old',
        cid: 5,
        kind: 'animation',
        contentHash: 'h',
        savedAt: DateTime(2026),
        frameCids: const [5, 6],
        frameSlots: const [0, 1],
      ),
    );
    final loaded = store.load('AA:BB').single;
    expect(loaded.frames, isEmpty);
    expect(loaded.width, 0);
    expect(loaded.frameCids, const [5, 6]);
  });
}
