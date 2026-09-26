// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/models/radio_channel.dart';
import 'package:liberated_bread_mobile/services/preset_channels.dart';

void main() {
  group('FRS/GMRS', () {
    test('is the full 22-channel plan', () {
      final channels = frsGmrsChannels();
      expect(channels, hasLength(22));
      expect(channels.first.name, 'GMRS 1');
      expect(channels.last.name, 'GMRS 22');
    });

    test('puts the channels on their regulated frequencies', () {
      final channels = frsGmrsChannels();
      // Spot-checks against 47 CFR 95.563/95.1763. Channel 1 is the first
      // 462 MHz interstitial, 8 the first 467 MHz low-power channel, and 15
      // the first 462 MHz main channel.
      expect(channels[0].rxFreqHz, 462562500);
      expect(channels[7].rxFreqHz, 467562500);
      expect(channels[14].rxFreqHz, 462550000);
      expect(channels[21].rxFreqHz, 462725000);
    });

    test('is simplex throughout', () {
      for (final channel in frsGmrsChannels()) {
        expect(channel.isSimplex, isTrue, reason: channel.name);
      }
    });

    test('marks 8-14 as the low-power channels', () {
      final channels = frsGmrsChannels();
      for (var i = 0; i < channels.length; i++) {
        final expected = (i >= 7 && i <= 13) ? PowerLevel.low : PowerLevel.high;
        expect(channels[i].power, expected, reason: channels[i].name);
      }
    });

    test('is narrowband, which is what hears both kinds of station', () {
      for (final channel in frsGmrsChannels()) {
        expect(channel.mode, ChannelMode.nfm, reason: channel.name);
      }
    });
  });

  group('GMRS repeater pairs', () {
    test('are the eight main channels with a 5 MHz input', () {
      final repeaters = gmrsRepeaterChannels();
      expect(repeaters, hasLength(8));
      for (final channel in repeaters) {
        expect(channel.offsetHz, 5000000, reason: channel.name);
        expect(channel.rxFreqHz, greaterThanOrEqualTo(462550000));
        expect(channel.rxFreqHz, lessThanOrEqualTo(462725000));
        expect(channel.txFreqHz, greaterThanOrEqualTo(467550000));
      }
      expect(repeaters.first.name, 'RPT 15');
      expect(repeaters.last.name, 'RPT 22');
    });

    test('say out loud that the tone is the user\'s to supply', () {
      // A repeater pair with no tone is the one preset that silently does
      // nothing on the air, so the comment has to carry the missing half.
      for (final channel in gmrsRepeaterChannels()) {
        expect(channel.txTone.isNone, isTrue);
        expect(channel.comment.toLowerCase(), contains('tone'));
      }
    });
  });

  group('MURS', () {
    test('is the five channels, narrow where the rules say narrow', () {
      final murs = mursChannels();
      expect(murs, hasLength(5));
      expect(murs[0].rxFreqHz, 151820000);
      expect(murs[1].rxFreqHz, 151880000);
      expect(murs[2].rxFreqHz, 151940000);
      expect(murs[3].rxFreqHz, 154570000);
      expect(murs[4].rxFreqHz, 154600000);
      expect(murs[0].mode, ChannelMode.nfm);
      expect(murs[3].mode, ChannelMode.fm);
      for (final channel in murs) {
        expect(channel.isSimplex, isTrue);
      }
    });
  });

  group('weather', () {
    test('is the seven NOAA channels, in radio numbering order', () {
      final weather = weatherChannels();
      expect(weather, hasLength(7));
      expect(weather[0].name, 'WX1');
      expect(weather[0].rxFreqHz, 162550000);
      expect(weather[1].rxFreqHz, 162400000);
      expect(weather[6].rxFreqHz, 162525000);
    });

    test('cannot transmit, by construction rather than by band limit', () {
      // Nothing may transmit on the NOAA allocation. That is not left to the
      // profile's transmit-range filter to notice: the channels are built
      // receive-only, with the transmit frequency pinned to the receive one.
      for (final channel in weatherChannels()) {
        expect(channel.rxOnly, isTrue, reason: channel.name);
        expect(channel.txFreqHz, channel.rxFreqHz, reason: channel.name);
        expect(channel.txTone.isNone, isTrue, reason: channel.name);
      }
    });

    test('all seven sit in the NOAA allocation', () {
      for (final channel in weatherChannels()) {
        expect(channel.rxFreqHz, greaterThanOrEqualTo(162400000));
        expect(channel.rxFreqHz, lessThanOrEqualTo(162550000));
      }
    });
  });

  group('calling channels', () {
    test('are the two national simplex calling frequencies', () {
      final calling = callingChannels();
      expect(calling, hasLength(2));
      expect(calling[0].rxFreqHz, 146520000);
      expect(calling[1].rxFreqHz, 446000000);
      for (final channel in calling) {
        expect(channel.isSimplex, isTrue);
      }
    });
  });

  group('the whole preset set', () {
    test('has no duplicate frequencies within a mode', () {
      // The 462 MHz main channels appear twice on purpose -- once simplex,
      // once as a repeater pair -- so the identity that must be unique is the
      // rx/tx pair, not the receive frequency.
      final seen = <String>{};
      for (final channel in allPresetChannels()) {
        final key = '${channel.rxFreqHz}/${channel.txFreqHz}';
        expect(
          seen.add(key),
          isTrue,
          reason: 'duplicate preset ${channel.name} at $key',
        );
      }
    });

    test('every channel has a name and a plausible frequency', () {
      for (final channel in allPresetChannels()) {
        expect(channel.name, isNotEmpty);
        expect(channel.rxFreqHz, greaterThan(100000000));
        expect(channel.rxFreqHz, lessThan(1000000000));
      }
    });

    test('is stable across calls', () {
      expect(allPresetChannels(), allPresetChannels());
    });

    test('needs no network, no location and no permission', () {
      // Not an assertion about behaviour so much as a statement of what this
      // tier is for: it is the answer when everything else has failed.
      expect(allPresetChannels(), isNotEmpty);
    });
  });
}
