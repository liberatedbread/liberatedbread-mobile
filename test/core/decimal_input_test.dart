// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:ui' show Locale;

import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/core/decimal_input.dart';
import 'package:liberated_bread_mobile/core/frequency.dart';

const _de = Locale('de', 'DE');
const _us = Locale('en', 'US');

void main() {
  group('normalizeDecimalInput', () {
    test('reads a single decimal comma as the point', () {
      // What an iOS decimal pad in a de/fr/es/it/pt/nl locale types: it has
      // a comma key and no period.
      expect(normalizeDecimalInput('146,940', locale: _de), '146.940');
      expect(normalizeDecimalInput('-72,6734', locale: _de), '-72.6734');
      expect(normalizeDecimalInput(',5', locale: _de), '.5');
      expect(normalizeDecimalInput('146,', locale: _de), '146.');
      expect(
        parseMegahertzToHz(normalizeDecimalInput('146,940', locale: _de)),
        146940000,
      );
      expect(
        double.tryParse(normalizeDecimalInput('41,7658', locale: _de)),
        41.7658,
      );
    });

    test('trims, and leaves a period alone', () {
      expect(normalizeDecimalInput(' 146,94 ', locale: _de), '146.94');
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
        for (final locale in [_de, _us]) {
          expect(
            normalizeDecimalInput(typed, locale: locale),
            typed,
            reason: '$typed in $locale',
          );
        }
      }
      expect(parseMegahertzToHz(normalizeDecimalInput('1,234.5')), isNull);
      expect(double.tryParse(normalizeDecimalInput('1,2,3')), isNull);
    });

    // Before the fix any single comma was a decimal point, so fifteen
    // hundred typed in a period locale became one and a half.
    test(
      'a thousands-shaped comma in a decimal-period locale is not a point',
      () {
        for (final typed in ['1,500', '12,000', '-1,000', '146,940']) {
          expect(normalizeDecimalInput(typed, locale: _us), typed);
          expect(
            double.tryParse(normalizeDecimalInput(typed, locale: _us)),
            isNull,
          );
        }
        expect(
          parseMegahertzToHz(normalizeDecimalInput('146,940', locale: _de)),
          146940000,
        );
        // Region exceptions, on the one shape the locale decides.
        expect(
          normalizeDecimalInput('1,500', locale: const Locale('de', 'CH')),
          '1,500',
        );
        expect(
          normalizeDecimalInput('1,500', locale: const Locale('es', 'MX')),
          '1,500',
        );
        expect(
          normalizeDecimalInput('1,500', locale: const Locale('pt', 'BR')),
          '1.500',
        );
        expect(
          normalizeDecimalInput('1,500', locale: const Locale('en', 'ZA')),
          '1.500',
        );
      },
    );

    test('any other single comma is a decimal point in every locale', () {
      // "0,25" or "146,9400" cannot be a grouped integer, so nothing is
      // ambiguous and the comma typed on a European keyboard still works on
      // an English-language phone.
      for (final locale in [_us, _de, const Locale('de', 'CH')]) {
        expect(normalizeDecimalInput('-0,25', locale: locale), '-0.25');
        expect(normalizeDecimalInput('1,5', locale: locale), '1.5');
        expect(normalizeDecimalInput('146,9400', locale: locale), '146.9400');
        expect(normalizeDecimalInput('1234,5', locale: locale), '1234.5');
      }
    });
  });
}
