// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// The curated-layout resolver: spec `key` beats the historical name table,
// nothing resolves twice, and what no slot claims stays renderable.

import 'dart:io';

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

  /// Every semantic key the catalogue can emit reaches a curated layout.
  ///
  /// The two vocabularies are written down in two repositories: upstream's
  /// `ENTITY_KEY_VOCABULARY` (pytest-owned, in `scripts/test_device_specs.py`)
  /// says what a spec may emit, and this app's layouts say what it can place.
  /// Nothing bound them, and four tokens had already drifted apart — `exit`,
  /// `menu`, `info` and `keyboard` were in the vocabulary with no slot in the
  /// remote and no row in the fallback table, so eight TV specs' keyed Exit
  /// landed in the wrap at the foot beside the colour keys.
  ///
  /// Nothing is DROPPED by that — leftovers always render, which is the
  /// design — so the drift has no symptom a test could otherwise catch. This
  /// is the catalogue-vs-code guard in the shape `ios_bonjour_catalogue_test`
  /// established: read the vocabulary out of the vendored subtree, and fail
  /// when this side does not know a token.
  ///
  /// A token may be exempted, but only by name and with a reason. That is the
  /// difference between deciding not to place a key and forgetting it exists.
  test('every upstream entity key has a layout slot or a stated exemption', () {
    // Upstream owns the vocabulary in its pytest, as a Python set literal.
    final source = File(
      '${Directory.current.path}/vendor/protocol-specs/scripts/'
      'test_device_specs.py',
    );
    expect(
      source.existsSync(),
      isTrue,
      reason: '${source.path} is the vendored home of ENTITY_KEY_VOCABULARY. '
          'If upstream moved it, this test must follow rather than quietly '
          'stop checking.',
    );
    final block = RegExp(
      r'ENTITY_KEY_VOCABULARY\s*=\s*frozenset\(\s*\{(.*?)\}\s*\)',
      dotAll: true,
    ).firstMatch(source.readAsStringSync());
    expect(
      block,
      isNotNull,
      reason: 'ENTITY_KEY_VOCABULARY is no longer a frozenset literal in '
          '${source.path}; this test cannot read it and is silently passing.',
    );
    final upstream = RegExp('"([a-z0-9_]+)"')
        .allMatches(block!.group(1)!)
        .map((m) => m.group(1)!)
        .toSet();
    expect(upstream.length, greaterThan(20),
        reason: 'read ${upstream.length} tokens, which is not a vocabulary — '
            'the pattern above has stopped matching');

    // Placed by a layout, or claimed by a surface that does not go through
    // the index at all — each named, so removing one is a decision.
    const exempt = <String, String>{
      'keyboard': 'the text-entry field is found by its `text` platform, not '
          'by key: it is a TextField beside the remote, not a key in it.',
    };

    final unplaced = [
      for (final key in upstream)
        if (!EntityKeyIndex.knowsKey(key) && !exempt.containsKey(key)) key,
    ]..sort();
    expect(
      unplaced,
      isEmpty,
      reason: 'These keys are in upstream\'s vocabulary and no layout here '
          'places them: $unplaced. A spec that emits one gets a control in '
          'the leftover wrap rather than where a hand would look. Give each '
          'a slot, or add it to `exempt` above with the reason.',
    );
  });
}
