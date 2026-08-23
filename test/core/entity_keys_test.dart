// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// The curated-layout resolver: spec `key` beats the historical name table,
// nothing resolves twice, and what no slot claims stays renderable.

import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/core/entity_keys.dart';

typedef _E = ({String? key, String name});

EntityKeyIndex<_E> _index(List<_E> entities) => EntityKeyIndex<_E>(
      entities,
      keyOf: (e) => e.key,
      nameOf: (e) => e.name,
    );

void main() {
  test('the spec key wins over the display-name table', () {
    // A keyed entity with a misleading name, and a name-only claimant: the
    // key resolves first whatever either is called.
    final index = _index(const [
      (key: null, name: 'OK'),
      (key: 'ok', name: 'Bestätigen'),
    ]);
    expect(index.take('ok')?.name, 'Bestätigen');
    // The name-table claimant is still there for nothing else to take: it
    // lands in leftovers, never dropped.
    expect(index.leftovers.map((e) => e.name), ['OK']);
  });

  test('an un-keyed spec resolves through the historical names', () {
    final index = _index(const [
      (key: null, name: 'Power On'),
      (key: null, name: 'Fart Mode'),
    ]);
    expect(index.take('power_on')?.name, 'Power On');
    expect(index.take('power_off'), isNull);
    expect(index.leftovers.map((e) => e.name), ['Fart Mode']);
  });

  test('a keyed entity never fallback-matches a different slot by name', () {
    // The spec SAID what this entity is (volume_up); its display name
    // happening to be 'Mute' is not evidence for the mute slot.
    final index = _index(const [(key: 'volume_up', name: 'Mute')]);
    expect(index.take('mute'), isNull);
    expect(index.take('volume_up')?.name, 'Mute');
  });

  test('a resolved entity is consumed exactly once', () {
    final index = _index(const [(key: 'stop', name: 'Stop')]);
    expect(index.take('stop'), isNotNull);
    expect(index.take('stop'), isNull);
    expect(index.leftovers, isEmpty);
  });

  test('takeAll keeps slot order and skips empty slots', () {
    final index = _index(const [
      (key: null, name: 'Volume Down'),
      (key: null, name: 'Volume Up'),
    ]);
    final row = index.takeAll(const ['volume_up', 'mute', 'volume_down']);
    expect(row.map((e) => e.name), ['Volume Up', 'Volume Down']);
  });
}
