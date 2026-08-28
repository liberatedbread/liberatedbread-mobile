// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/core/frequency.dart';

void main() {
  group('parseMegahertzToHz', () {
    test('parses the forms these directories actually send', () {
      expect(parseMegahertzToHz('462.625'), 462625000);
      expect(parseMegahertzToHz('146.94'), 146940000);
      expect(parseMegahertzToHz('446'), 446000000);
      expect(parseMegahertzToHz('446.'), 446000000);
      expect(parseMegahertzToHz('.5'), 500000);
      expect(parseMegahertzToHz(' 162.550 '), 162550000);
    });

    test('is exact where a double would not be', () {
      // This is the whole reason the function exists. Most frequencies
      // survive `double.parse(x) * 1e6`, which is what makes the ones that
      // do not so unpleasant: 512.05 comes back as 512049999.99999994 and
      // truncates to a hertz low. One hertz is invisible on a screen,
      // survives a JSON round trip, and quietly stops two listings of one
      // repeater from de-duplicating against each other.
      expect((double.parse('512.05') * 1e6).toInt(), 512049999);
      expect(parseMegahertzToHz('512.05'), 512050000);

      // A sweep of every 12.5 kHz step across both bands these radios cover.
      // 144 of them lose a hertz through a double; none may here.
      for (final band in [
        (low: 136000000, high: 174000000),
        (low: 400000000, high: 520000000),
      ]) {
        for (var hz = band.low; hz <= band.high; hz += 12500) {
          expect(parseMegahertzToHz(formatHzAsMegahertz(hz)), hz,
              reason: formatHzAsMegahertz(hz));
        }
      }
    });

    test('truncates beyond one hertz rather than rounding up', () {
      // Rounding up could push a channel over a band edge, which turns a
      // transmittable channel into a listen-only one for no reason.
      expect(parseMegahertzToHz('146.9400009'), 146940000);
      expect(parseMegahertzToHz('146.9400001'), 146940000);
    });

    test('handles a negative offset', () {
      expect(parseMegahertzToHz('-0.6'), -600000);
      expect(parseMegahertzToHz('+5'), 5000000);
    });

    test('returns null for the ways a field says "unknown"', () {
      for (final value in [
        null,
        '',
        '   ',
        'unknown',
        'n/a',
        '146.94 MHz',
        '1.2.3',
        '--',
      ]) {
        expect(parseMegahertzToHz(value), isNull, reason: '$value');
      }
    });
  });

  group('formatHzAsMegahertz', () {
    test('reads the way an operator writes it', () {
      expect(formatHzAsMegahertz(146940000), '146.940');
      expect(formatHzAsMegahertz(446000000), '446.000');
      expect(formatHzAsMegahertz(462562500), '462.5625');
      expect(formatHzAsMegahertz(162550000), '162.550');
    });

    test('keeps enough decimals to distinguish adjacent channels', () {
      // 462.5625 and 462.5875 are different channels; three decimals would
      // render both as 462.563/462.588 and a 12.5 kHz step would vanish.
      expect(formatHzAsMegahertz(462562500),
          isNot(formatHzAsMegahertz(462587500)));
    });

    test('round-trips through the parser', () {
      for (final hz in [
        146940000,
        146340000,
        462562500,
        467712500,
        151820000,
        162525000,
        446000000,
      ]) {
        expect(parseMegahertzToHz(formatHzAsMegahertz(hz)), hz, reason: '$hz');
      }
    });

    test('handles a negative offset', () {
      expect(formatHzAsMegahertz(-600000), '-0.600');
    });
  });
}
