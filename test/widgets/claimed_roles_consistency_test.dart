// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// Each control card hand-maintains a `_claimedRoles` set beside the
// `_action('role')` getters it draws with, and the two drift silently: a
// role looked up but not claimed is drawn TWICE (once by the card, once by
// UnclaimedActions); one claimed but never looked up is drawn by NOBODY,
// which is the exact failure the sets' own comments promise to prevent.
// The sets are rightly private, so — like the Rust suite's
// dart_loader_does_not_hardcode_spec_filenames — this reads the SOURCE.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  const cards = <String, Set<String>>{
    // Roles a card claims WITHOUT a matching `_action('x')` lookup, each
    // with a reason. Empty today; add an entry only with a comment saying
    // why the claim is deliberate.
    'lib/widgets/network_light_card.dart': {},
    'lib/widgets/light_control_card.dart': {},
    'lib/widgets/switch_control_card.dart': {},
  };

  for (final entry in cards.entries) {
    test('${entry.key} claims exactly the roles it looks up', () {
      final source = File(entry.key).readAsStringSync();

      // Both quote styles, deliberately: the repo's style is single quotes,
      // but a double-quoted `_action("x")` is legal Dart the formatter
      // leaves alone — and a guard blind to it would wave a genuine drift
      // through green (both extraction sets missing the same role satisfies
      // the equality below vacuously).
      final lookedUp = RegExp(
        '_action\\([\'"]([a-z_0-9]+)[\'"]\\)',
      ).allMatches(source).map((m) => m.group(1)!).toSet();
      expect(
        lookedUp,
        isNotEmpty,
        reason: 'the card should look roles up via _action',
      );

      final setLiteral = RegExp(
        r'_claimedRoles = (?:<String>)?\{([^}]*)\}',
        dotAll: true,
      ).firstMatch(source);
      expect(
        setLiteral,
        isNotNull,
        reason: 'the card should declare _claimedRoles',
      );
      final claimed = RegExp(
        '[\'"]([a-z_0-9]+)[\'"]',
      ).allMatches(setLiteral!.group(1)!).map((m) => m.group(1)!).toSet();

      expect(
        claimed,
        lookedUp.union(entry.value),
        reason:
            'claimed-but-never-looked-up is drawn by nobody; '
            'looked-up-but-unclaimed is drawn twice via UnclaimedActions',
      );
    });
  }
}
