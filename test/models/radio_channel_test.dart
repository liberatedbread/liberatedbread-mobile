// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/models/radio_channel.dart';

void main() {
  group('ToneSetting', () {
    test('none carries no tone data', () {
      expect(ToneSetting.none.isNone, isTrue);
      expect(ToneSetting.none.label, '');
    });

    test('labels a CTCSS tone the way a radio displays it', () {
      expect(const ToneSetting.ctcss(1000).label, '100.0');
      expect(const ToneSetting.ctcss(1072).label, '107.2');
      expect(const ToneSetting.ctcss(670).label, '67.0');
    });

    test('labels a DCS code with its polarity', () {
      expect(const ToneSetting.dcs(23).label, 'D023N');
      expect(const ToneSetting.dcs(754, inverted: true).label, 'D754I');
    });

    test('round-trips through JSON', () {
      const settings = [
        ToneSetting.none,
        ToneSetting.ctcss(1072),
        ToneSetting.dcs(131),
        ToneSetting.dcs(131, inverted: true),
      ];
      for (final tone in settings) {
        expect(ToneSetting.fromJson(tone.toJson()), tone, reason: '$tone');
      }
    });

    test('degrades to no tone rather than throwing', () {
      expect(ToneSetting.fromJson(null), ToneSetting.none);
      expect(ToneSetting.fromJson('100.0'), ToneSetting.none);
      expect(
        ToneSetting.fromJson(const {'mode': 'telepathy'}),
        ToneSetting.none,
      );
      // A CTCSS mode with no usable tone value is no tone, not a tone of zero.
      expect(ToneSetting.fromJson(const {'mode': 'ctcss'}), ToneSetting.none);
      expect(
        ToneSetting.fromJson(const {'mode': 'ctcss', 'ctcss': 0}),
        ToneSetting.none,
      );
      expect(
        ToneSetting.fromJson(const {'mode': 'dcs', 'dcs': -1}),
        ToneSetting.none,
      );
    });

    test('has value equality', () {
      expect(const ToneSetting.ctcss(1000), const ToneSetting.ctcss(1000));
      expect(
        const ToneSetting.ctcss(1000).hashCode,
        const ToneSetting.ctcss(1000).hashCode,
      );
      expect(
        const ToneSetting.dcs(23),
        isNot(const ToneSetting.dcs(23, inverted: true)),
      );
    });
  });

  group('tone tables', () {
    test('the CTCSS table is the standard 50, sorted, with no duplicates', () {
      expect(ctcssTonesTenthHz.length, 50);
      expect(ctcssTonesTenthHz.toSet().length, 50);
      final sorted = [...ctcssTonesTenthHz]..sort();
      expect(ctcssTonesTenthHz, sorted);
      expect(ctcssTonesTenthHz.first, 670);
      expect(ctcssTonesTenthHz.last, 2541);
      // 100.0 Hz is the tone half the repeaters in North America use; if it
      // is missing from the table the picker cannot express them.
      expect(ctcssTonesTenthHz, contains(1000));
    });

    test('the DCS table is sorted and unique', () {
      expect(dcsCodes.toSet().length, dcsCodes.length);
      final sorted = [...dcsCodes]..sort();
      expect(dcsCodes, sorted);
      expect(dcsCodes.first, 23);
      expect(dcsCodes, contains(754));
    });
  });

  group('RadioChannel', () {
    const repeater = RadioChannel(
      name: 'W1AW',
      rxFreqHz: 146940000,
      txFreqHz: 146340000,
      txTone: ToneSetting.ctcss(1000),
      comment: 'Newington',
    );

    test('computes its own offset', () {
      expect(repeater.offsetHz, -600000);
      expect(repeater.isSimplex, isFalse);
      const simplex = RadioChannel(
        name: 'Calling',
        rxFreqHz: 146520000,
        txFreqHz: 146520000,
      );
      expect(simplex.offsetHz, 0);
      expect(simplex.isSimplex, isTrue);
    });

    test('receiveOnly cannot key anywhere but its own frequency', () {
      const weather = RadioChannel.receiveOnly(name: 'WX1', freqHz: 162550000);
      expect(weather.rxOnly, isTrue);
      expect(weather.txFreqHz, weather.rxFreqHz);
      expect(weather.txTone.isNone, isTrue);
    });

    test('round-trips through JSON', () {
      const channels = [
        repeater,
        RadioChannel.receiveOnly(name: 'WX1', freqHz: 162550000),
        RadioChannel(
          name: 'GMRS 16',
          rxFreqHz: 462575000,
          txFreqHz: 467575000,
          txTone: ToneSetting.dcs(23, inverted: true),
          rxTone: ToneSetting.ctcss(1072),
          mode: ChannelMode.nfm,
          power: PowerLevel.low,
        ),
      ];
      for (final channel in channels) {
        final json = jsonDecode(jsonEncode(channel.toJson()));
        expect(
          RadioChannel.fromJson(json as Map<String, dynamic>),
          channel,
          reason: '$channel',
        );
      }
    });

    test('keeps frequencies exact through the round trip', () {
      // The reason these are ints: 107.2 MHz is not representable as a double,
      // and a plan whose channels stop comparing equal to themselves cannot be
      // de-duplicated or diffed against what is on the radio.
      const channel = RadioChannel(
        name: 'Exact',
        rxFreqHz: 145170000,
        txFreqHz: 144570000,
      );
      final decoded = RadioChannel.fromJson(
        jsonDecode(jsonEncode(channel.toJson())) as Map<String, dynamic>,
      );
      expect(decoded!.rxFreqHz, 145170000);
      expect(decoded.txFreqHz, 144570000);
    });

    test('rejects a record with no usable receive frequency', () {
      expect(RadioChannel.fromJson(const {'name': 'x'}), isNull);
      expect(RadioChannel.fromJson(const {'name': 'x', 'rx': 0}), isNull);
      expect(
        RadioChannel.fromJson(const {'name': 'x', 'rx': '146.94'}),
        isNull,
      );
      expect(RadioChannel.fromJson(const {'rx': 146940000}), isNull);
    });

    test('a missing transmit frequency reads as simplex, not as junk', () {
      final channel = RadioChannel.fromJson(const {
        'name': 'S',
        'rx': 146520000,
      });
      expect(channel, isNotNull);
      expect(channel!.txFreqHz, 146520000);
      expect(channel.isSimplex, isTrue);
    });

    test('unknown enum values fall back rather than dropping the channel', () {
      final channel = RadioChannel.fromJson(const {
        'name': 'Future',
        'rx': 146520000,
        'mode': 'c4fm',
        'power': 'turbo',
      });
      expect(channel, isNotNull);
      expect(channel!.mode, ChannelMode.fm);
      expect(channel.power, PowerLevel.high);
    });

    test('copyWith replaces only what it is given', () {
      final renamed = repeater.copyWith(name: 'W1AW/R');
      expect(renamed.name, 'W1AW/R');
      expect(renamed.rxFreqHz, repeater.rxFreqHz);
      expect(renamed.txTone, repeater.txTone);
    });

    test('has value equality over every field', () {
      expect(repeater.copyWith(), repeater);
      expect(repeater.copyWith().hashCode, repeater.hashCode);
      expect(repeater.copyWith(name: 'other'), isNot(repeater));
      expect(repeater.copyWith(txTone: ToneSetting.none), isNot(repeater));
      expect(repeater.copyWith(power: PowerLevel.low), isNot(repeater));
    });
  });

  group('enum wire names', () {
    test('survive a round trip', () {
      for (final mode in ToneMode.values) {
        expect(ToneMode.fromWire(mode.wireName), mode);
      }
      for (final mode in ChannelMode.values) {
        expect(ChannelMode.fromWire(mode.wireName), mode);
      }
      for (final level in PowerLevel.values) {
        expect(PowerLevel.fromWire(level.wireName), level);
      }
    });

    test('return null for anything else', () {
      expect(ToneMode.fromWire('nope'), isNull);
      expect(ChannelMode.fromWire(7), isNull);
      expect(PowerLevel.fromWire(null), isNull);
    });

    test('ChannelMode uses CHIRP spelling in CSV', () {
      expect(ChannelMode.fm.chirpName, 'FM');
      expect(ChannelMode.nfm.chirpName, 'NFM');
    });
  });
}
