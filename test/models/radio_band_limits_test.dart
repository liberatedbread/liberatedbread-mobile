// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/models/radio_band_limits.dart';
import 'package:liberated_bread_mobile/models/radio_profile.dart';

const _stock = RadioBandLimits(
  vhf: BandLimit(txEnabled: true, lowerMhz: 136, upperMhz: 174),
  uhf: BandLimit(txEnabled: true, lowerMhz: 400, upperMhz: 520),
);

void main() {
  group('RadioBandLimits.widenedFor', () {
    test('widens a UV-5R to the ranges its unlock promises', () {
      final widened = RadioBandLimits.widenedFor(uv5rProfile)!;
      // The same spans the acknowledgement lists and suggestions use,
      // rounded down to whole megahertz.
      expect(widened.vhf,
          const BandLimit(txEnabled: true, lowerMhz: 130, upperMhz: 179));
      expect(widened.uhf,
          const BandLimit(txEnabled: true, lowerMhz: 400, upperMhz: 520));
    });

    test('every radio with an unlock widens to something', () {
      for (final profile in radioProfiles) {
        if (!profile.txUnlock.supported) continue;
        expect(RadioBandLimits.widenedFor(profile), isNotNull,
            reason: profile.id);
      }
    });

    test('a radio with no unlock has nothing to widen to', () {
      expect(RadioBandLimits.widenedFor(uv5rMiniProfile), isNull);
      expect(RadioBandLimits.widenedFor(uv5gProfile), isNull);
    });
  });

  test('reads the way a person says it', () {
    expect(_stock.label, 'VHF 136–174 MHz and UHF 400–520 MHz');
    const uhfOff = RadioBandLimits(
      vhf: BandLimit(txEnabled: true, lowerMhz: 136, upperMhz: 174),
      uhf: BandLimit(txEnabled: false, lowerMhz: 400, upperMhz: 520),
    );
    expect(uhfOff.label, contains('UHF 400–520 MHz, transmit off'));
  });

  test('limits survive a trip through JSON', () {
    final original =
        OriginalBandLimits(limits: _stock, readAt: DateTime.utc(2026, 9, 20));
    final back =
        OriginalBandLimits.fromJson(jsonDecode(jsonEncode(original.toJson())));
    expect(back, original);
  });

  test('anything unreadable reads as nothing, not as a guess', () {
    expect(RadioBandLimits.fromJson('136-174'), isNull);
    expect(
        RadioBandLimits.fromJson({
          'vhf': {'tx': true, 'lower': 136, 'upper': 174},
          'uhf': {'tx': 'yes', 'lower': 400, 'upper': 520},
        }),
        isNull);
    expect(OriginalBandLimits.fromJson({..._stock.toJson()}), isNull,
        reason: 'no read time');
    expect(
        OriginalBandLimits.fromJson(
            {..._stock.toJson(), 'readAt': 'last Tuesday'}),
        isNull);
  });

  test('two readings of the same limits are equal', () {
    expect(
      RadioBandLimits.fromJson(_stock.toJson()),
      _stock,
    );
    expect(_stock.hashCode, RadioBandLimits.fromJson(_stock.toJson()).hashCode);
    expect(_stock, isNot(RadioBandLimits.widenedFor(uv5rProfile)));
  });
}
