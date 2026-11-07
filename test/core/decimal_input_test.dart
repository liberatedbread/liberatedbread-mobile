// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/core/decimal_input.dart';
import 'package:liberated_bread_mobile/core/frequency.dart';

void main() {
  group('normalizeDecimalInput', () {
    test('reads a single decimal comma as the point', () {
      // What an iOS decimal pad in a de/fr/es/it/pt/nl locale types: it has
      // a comma key and no period.
      expect(normalizeDecimalInput('146,940'), '146.940');
      expect(normalizeDecimalInput('-72,6734'), '-72.6734');
      expect(normalizeDecimalInput(',5'), '.5');
      expect(normalizeDecimalInput('146,'), '146.');
      expect(parseMegahertzToHz(normalizeDecimalInput('146,940')), 146940000);
      expect(double.tryParse(normalizeDecimalInput('41,7658')), 41.7658);
    });

    test('trims, and leaves a period alone', () {
      expect(normalizeDecimalInput(' 146,94 '), '146.94');
      expect(normalizeDecimalInput('146.940'), '146.940');
      expect(normalizeDecimalInput('446'), '446');
      expect(normalizeDecimalInput(''), '');
      expect(normalizeDecimalInput('   '), '');
    });

    test('does not guess at anything but one comma', () {
      // A comma beside a period is a thousands separator, and more than one
      // comma is not a number: left as typed, so the parser refuses them as
      // it always did rather than reading a different number.
      for (final typed in ['1,234.5', '1.234,5', '1,2,3', '146,,940', 'abc']) {
        expect(normalizeDecimalInput(typed), typed, reason: typed);
      }
      expect(parseMegahertzToHz(normalizeDecimalInput('1,234.5')), isNull);
      expect(double.tryParse(normalizeDecimalInput('1,2,3')), isNull);
    });
  });
}
