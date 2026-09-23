// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/models/radio_band_limits.dart';
import 'package:liberated_bread_mobile/models/radio_channel.dart';
import 'package:liberated_bread_mobile/models/radio_profile.dart';
import 'package:liberated_bread_mobile/services/radio_codec.dart';
import 'package:liberated_bread_mobile/services/radio_programmer.dart';
import 'package:liberated_bread_mobile/src/rust/api/radio_api.dart' as rust;

import '../helpers/host_rust_lib.dart';

rust.ToneDto _tone(String mode,
        {int ctcss = 0, int dcs = 0, bool inv = false}) =>
    rust.ToneDto(
        mode: mode, ctcssTenthHz: ctcss, dcsCode: dcs, dcsInverted: inv);

rust.RadioChannelDto _dto(int slot,
        {String name = 'CH',
        rust.ToneDto? tx,
        rust.ToneDto? rx,
        bool narrow = false,
        bool lowPower = false}) =>
    rust.RadioChannelDto(
      slot: slot,
      name: '$name$slot',
      rxFreqHz: 146520000,
      txFreqHz: 146520000,
      rxOnly: false,
      txTone: tx ?? _tone('none'),
      rxTone: rx ?? _tone('none'),
      narrow: narrow,
      lowPower: lowPower,
      skip: false,
    );

void main() {
  group('channel conversion', () {
    const channel = RadioChannel(
      name: 'W1AW',
      rxFreqHz: 146940000,
      txFreqHz: 146340000,
      txTone: ToneSetting.ctcss(1000),
      rxTone: ToneSetting.dcs(23, inverted: true),
      mode: ChannelMode.nfm,
      power: PowerLevel.low,
    );

    test('round-trips every field the codec carries', () {
      final back = channelFromDto(channelToDto(channel, slot: 4));
      expect(back.name, channel.name);
      expect(back.rxFreqHz, channel.rxFreqHz);
      expect(back.txFreqHz, channel.txFreqHz);
      expect(back.txTone, channel.txTone);
      expect(back.rxTone, channel.rxTone);
      expect(back.mode, ChannelMode.nfm);
      expect(back.power, PowerLevel.low);
    });

    test('places the channel in the slot it is given', () {
      expect(channelToDto(channel, slot: 7).slot, 7);
    });

    test('a receive-only channel stays receive-only', () {
      const listen = RadioChannel(
        name: 'NOAA1',
        rxFreqHz: 162550000,
        txFreqHz: 162550000,
        rxOnly: true,
      );
      expect(channelFromDto(channelToDto(listen, slot: 1)).rxOnly, isTrue);
    });

    test('a tone the app cannot represent reads as none, keeping the channel',
        () {
      final odd = channelFromDto(
          _dto(1, tx: _tone('ctcss', ctcss: 1234), rx: _tone('dcs', dcs: 999)));
      expect(odd.rxFreqHz, 146520000, reason: 'the channel survives');
      expect(odd.txTone, ToneSetting.none);
      expect(odd.rxTone, ToneSetting.none);
    });

    test('an unknown tone mode reads as none', () {
      expect(
          channelFromDto(_dto(1, tx: _tone('bogus'))).txTone, ToneSetting.none);
    });
  });

  group('decodedFromDtos', () {
    test('orders by slot', () {
      final decoded = decodedFromDtos([_dto(3), _dto(1), _dto(2)]);
      expect([for (final c in decoded.channels) c.name], ['CH1', 'CH2', 'CH3']);
      expect(decoded.hadGaps, isFalse);
    });

    test('notices empty slots between channels', () {
      final decoded = decodedFromDtos([_dto(1), _dto(2), _dto(7)]);
      expect(decoded.channels, hasLength(3));
      expect(decoded.hadGaps, isTrue);
    });

    test('a first channel past slot 1 is a gap too', () {
      expect(decodedFromDtos([_dto(2)]).hadGaps, isTrue);
    });

    test('an empty radio is empty, with nothing to report', () {
      final decoded = decodedFromDtos(const []);
      expect(decoded.channels, isEmpty);
      expect(decoded.hadGaps, isFalse);
    });
  });

  test('band limits cross to the codec and back unchanged', () {
    const limits = RadioBandLimits(
      vhf: BandLimit(txEnabled: true, lowerMhz: 136, upperMhz: 174),
      uhf: BandLimit(txEnabled: false, lowerMhz: 400, upperMhz: 520),
    );
    final dto = bandLimitsToDto(limits);
    expect(dto.layout, isEmpty,
        reason: 'the codec works the layout out from the image again');
    expect(dto.vhf.lowerMhz, 136);
    expect(dto.uhf.txEnabled, isFalse);
    expect(bandLimitsFromDto(dto), limits);
  });

  group('CodeplugDecoder', () {
    late bool rustReady;

    setUpAll(() async {
      rustReady = await initHostRustLib();
    });

    test('decodes what the codec encoded, through the native library',
        () async {
      if (!rustReady) return markTestSkipped('host Rust library unavailable');
      const channels = [
        RadioChannel(name: 'ONE', rxFreqHz: 146520000, txFreqHz: 146520000),
        RadioChannel(
          name: 'TWO',
          rxFreqHz: 446000000,
          txFreqHz: 446000000,
          txTone: ToneSetting.ctcss(885),
        ),
      ];
      final image = await rust.radioEncodeChannels(
        image: Uint8List(0x8240),
        channels: [
          for (var i = 0; i < channels.length; i++)
            channelToDto(channels[i], slot: i + 1),
        ],
        modelId: uv5rMiniProfile.id,
      );

      final decoded = await const CodeplugDecoder().decode(
        RadioCodeplug(
          modelId: uv5rMiniProfile.id,
          image: image,
          readAt: DateTime(2026, 9, 1),
        ),
        uv5rMiniProfile,
      );

      expect([for (final c in decoded.channels) c.name], ['ONE', 'TWO']);
      expect(decoded.channels[1].txTone, const ToneSetting.ctcss(885));
      expect(decoded.hadGaps, isFalse);
    });

    test('a cable radio decodes through its own codec', () async {
      if (!rustReady) return markTestSkipped('host Rust library unavailable');
      // A blank UV-5R image: ident, empty slots and names, a firmware string.
      final blank = Uint8List(await rust.uv5RImageLen());
      blank.setRange(0, 8, [0xAA, 0x30, 0x76, 0x04, 0x00, 0x05, 0x20, 0xDD]);
      blank.fillRange(8, 8 + 0x800, 0xFF);
      blank.fillRange(8 + 0x1000, 8 + 0x1800, 0xFF);
      blank.fillRange(8 + 0x1830, 8 + 0x1830 + 14, 0xFF);
      blank.setRange(8 + 0x1830, 8 + 0x1836, 'BFB297'.codeUnits);
      final image = await rust.uv5REncodeChannels(
        image: blank,
        channels: [
          channelToDto(
            const RadioChannel(
              name: 'W1AW',
              rxFreqHz: 146940000,
              txFreqHz: 146340000,
              txTone: ToneSetting.ctcss(1000),
            ),
            slot: 1,
          ),
        ],
        modelId: uv5rProfile.id,
      );

      final decoded = await const CodeplugDecoder().decode(
        RadioCodeplug(
          modelId: uv5rProfile.id,
          image: image,
          readAt: DateTime(2026, 9, 1),
        ),
        uv5rProfile,
      );

      expect(decoded.channels.single.name, 'W1AW');
      expect(decoded.channels.single.txFreqHz, 146340000);
      expect(decoded.channels.single.txTone, const ToneSetting.ctcss(1000));
    });
  });
}
