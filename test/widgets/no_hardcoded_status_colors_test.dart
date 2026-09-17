// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// F-055: status text in these files used Colors.red/grey/green literals.
// Colors.grey (#9E9E9E) and Colors.green (#4CAF50) sit at ~2.7:1 and ~2.8:1
// on the light surface — under WCAG AA's 4.5:1 for small text — and none of
// the three adapt to dark mode. The widget suites check the rendered colours
// against the scheme; this keeps the literals from creeping back in.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

const _files = [
  'lib/screens/ha_settings_screen.dart',
  'lib/screens/spec_pack_settings_screen.dart',
  'lib/widgets/decoded_value_widget.dart',
  'lib/widgets/raw_characteristic_widget.dart',
  'lib/widgets/typed_command_widget.dart',
  'lib/widgets/treadmill_control_card.dart',
];

void main() {
  test('status text uses ColorScheme roles, not Colors.red/grey/green', () {
    final literal = RegExp(r'Colors\.(red|grey|green)\b');
    for (final path in _files) {
      final source = File(path).readAsStringSync();
      final hit = literal.firstMatch(source);
      expect(hit, isNull, reason: '$path still hard-codes ${hit?.group(0)}');
    }
  });
}
