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
import '../helpers/uv5r_image.dart';

rust.ToneDto _tone(
  String mode, {
  int ctcss = 0,
  int dcs = 0,
  bool inv = false,
}) => rust.ToneDto(
  mode: mode,
  ctcssTenthHz: ctcss,
  dcsCode: dcs,
  dcsInverted: inv,
);

rust.RadioChannelDto _dto(
  int slot, {
  String name = 'CH',
  rust.ToneDto? tx,
  rust.ToneDto? rx,
  bool narrow = false,
  String power = 'high',
  bool skip = false,
}) => rust.RadioChannelDto(
  slot: slot,
  name: '$name$slot',
  rxFreqHz: 146520000,
  txFreqHz: 146520000,
  rxOnly: false,
  txTone: tx ?? _tone('none'),
  rxTone: rx ?? _tone('none'),
  narrow: narrow,
  power: power,
  skip: skip,
);

/// [profile]'s image as an unwritten radio holds it, sized the way the
/// codec checks: from the model table for the newer family, from the one
/// fixed length for the older.
Future<RadioCodeplug> _blank(RadioProfile profile) async {
  final image = await const CodeplugEncoder().blankImage(profile);
  return RadioCodeplug(
    modelId: profile.id,
    image: image,
    readAt: DateTime(2026, 9, 1),
  );
}

/// The channels a native encode of [channels] then decode hands back.
Future<DecodedChannels> _nativeRoundTrip(
  RadioProfile profile,
  List<RadioChannel> channels,
) async {
  const encoder = CodeplugEncoder();
  final image = await encoder.encode(await _blank(profile), profile, channels);
  return const CodeplugDecoder().decode(
    RadioCodeplug(modelId: profile.id, image: image, readAt: DateTime(2026)),
    profile,
  );
}

void main() {
  // One init for the whole file: RustLib.init refuses to run twice in an
  // isolate, so a second group with its own setUpAll would read the
  // library as unavailable and skip every native test it holds.
  late bool rustReady;

  setUpAll(() async {
    rustReady = await initHostRustLib();
  });

  group('channel conversion', () {
    const channel = RadioChannel(
      name: 'W1AW',
      rxFreqHz: 146940000,
      txFreqHz: 146340000,
      txTone: ToneSetting.ctcss(1000),
      rxTone: ToneSetting.dcs(23, inverted: true),
      mode: ChannelMode.nfm,
      power: PowerLevel.low,
      skip: true,
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
      expect(back.skip, isTrue);
      expect(back, channel);
    });

    test('medium power crosses the boundary as medium', () {
      // A low-power flag could not say medium: a UV-32's Medium channel read
      // as low, and the encoder then took the level from whatever record
      // sat in the slot the channel was written to.
      final medium = channel.copyWith(power: PowerLevel.medium);
      expect(channelToDto(medium, slot: 1).power, 'medium');
      expect(channelFromDto(_dto(1, power: 'medium')).power, PowerLevel.medium);
      expect(channelFromDto(_dto(1, power: 'low')).power, PowerLevel.low);
      expect(channelFromDto(_dto(1)).power, PowerLevel.high);
      expect(channelFromDto(_dto(1, power: '?')).power, PowerLevel.high);
    });

    test('a scan-skipped memory stays skipped in both directions', () {
      // The codecs write the record's skip bit from the DTO on every write,
      // so a flag lost on either crossing puts the memory back in the scan
      // list the next time its plan is written.
      expect(channelToDto(channel, slot: 1).skip, isTrue);
      expect(
        channelToDto(channel.copyWith(skip: false), slot: 1).skip,
        isFalse,
      );
      expect(channelFromDto(_dto(1, skip: true)).skip, isTrue);
      expect(channelFromDto(_dto(1)).skip, isFalse);
    });

    test('the family\'s 645 code is representable', () {
      // 645 is not one of the standard 104, but the codec indexes it and a
      // radio can hold it; reading it as "no tone" would drop it on the
      // next write.
      final read = channelFromDto(
        _dto(
          1,
          tx: _tone('dcs', dcs: 645),
          rx: _tone('dcs', dcs: 645, inv: true),
        ),
      );
      expect(read.txTone, const ToneSetting.dcs(645));
      expect(read.rxTone, const ToneSetting.dcs(645, inverted: true));
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

    test(
      'a tone the app cannot represent reads as none, keeping the channel',
      () {
        final odd = channelFromDto(
          _dto(1, tx: _tone('ctcss', ctcss: 1234), rx: _tone('dcs', dcs: 999)),
        );
        expect(odd.rxFreqHz, 146520000, reason: 'the channel survives');
        expect(odd.txTone, ToneSetting.none);
        expect(odd.rxTone, ToneSetting.none);
      },
    );

    test('an unknown tone mode reads as none', () {
      expect(
        channelFromDto(_dto(1, tx: _tone('bogus'))).txTone,
        ToneSetting.none,
      );
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
    expect(
      dto.layout,
      isEmpty,
      reason: 'the codec works the layout out from the image again',
    );
    expect(dto.vhf.lowerMhz, 136);
    expect(dto.uhf.txEnabled, isFalse);
    expect(bandLimitsFromDto(dto), limits);
  });

  group('CodeplugDecoder', () {
    test(
      'decodes what the codec encoded, through the native library',
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
      },
    );

    test('a cable radio decodes through its own codec', () async {
      if (!rustReady) return markTestSkipped('host Rust library unavailable');
      final image = await rust.uv5REncodeChannels(
        image: await blankUv5rImage(),
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

    // The pure-Dart round trip above cannot catch either of these: the DTO
    // conversion validates nothing on the way out, so only an encode and
    // decode through the real codec shows what a radio would hand back.
    for (final profile in [uv5rMiniProfile, uv5rProfile]) {
      test('${profile.id}: a skip and a DCS 645 survive the codec', () async {
        if (!rustReady) return markTestSkipped('host Rust library unavailable');
        const channels = [
          RadioChannel(name: 'SCAN', rxFreqHz: 146520000, txFreqHz: 146520000),
          RadioChannel(
            name: 'SKIP',
            rxFreqHz: 146940000,
            txFreqHz: 146340000,
            txTone: ToneSetting.dcs(645),
            rxTone: ToneSetting.dcs(645, inverted: true),
            skip: true,
          ),
        ];
        final decoded = await _nativeRoundTrip(profile, channels);
        expect([for (final c in decoded.channels) c.name], ['SCAN', 'SKIP']);
        expect(decoded.channels[0].skip, isFalse);
        expect(decoded.channels[1].skip, isTrue);
        expect(decoded.channels[1].txTone, const ToneSetting.dcs(645));
        expect(
          decoded.channels[1].rxTone,
          const ToneSetting.dcs(645, inverted: true),
        );
      });
    }
  });

  group('CodeplugEncoder', () {
    const channels = [
      RadioChannel(name: 'ONE', rxFreqHz: 146520000, txFreqHz: 146520000),
      RadioChannel(
        name: 'TWO',
        rxFreqHz: 446000000,
        txFreqHz: 446000000,
        txTone: ToneSetting.ctcss(885),
        mode: ChannelMode.nfm,
        power: PowerLevel.low,
      ),
    ];

    test('encodes for a Bluetooth radio what its driver sends', () async {
      if (!rustReady) return markTestSkipped('host Rust library unavailable');
      final base = await _blank(uv5rMiniProfile);
      final encoded = await const CodeplugEncoder().encode(
        base,
        uv5rMiniProfile,
        channels,
      );
      // Byte for byte the call BaofengBleProgrammer.writeChannels makes.
      final driver = await rust.radioEncodeChannels(
        image: base.image,
        channels: [
          for (var i = 0; i < channels.length; i++)
            channelToDto(channels[i], slot: i + 1),
        ],
        modelId: uv5rMiniProfile.id,
      );
      expect(encoded, driver);
      expect(encoded, isNot(base.image), reason: 'something was written');
    });

    test('encodes for a cable radio what its driver sends', () async {
      if (!rustReady) return markTestSkipped('host Rust library unavailable');
      final base = RadioCodeplug(
        modelId: uv5rProfile.id,
        image: await blankUv5rImage(),
        readAt: DateTime(2026, 9, 1),
      );
      final encoded = await const CodeplugEncoder().encode(
        base,
        uv5rProfile,
        channels,
      );
      // Byte for byte the call SerialRadioProgrammer.writeChannels makes.
      final driver = await rust.uv5REncodeChannels(
        image: base.image,
        channels: [
          for (var i = 0; i < channels.length; i++)
            channelToDto(channels[i], slot: i + 1),
        ],
        modelId: uv5rProfile.id,
      );
      expect(encoded, driver);
      expect(
        await rust.uv5RFirmware(image: encoded),
        await rust.uv5RFirmware(image: base.image),
        reason: 'what the app does not model survives from the base',
      );
    });

    test('refuses more channels than the radio has slots', () async {
      if (!rustReady) return markTestSkipped('host Rust library unavailable');
      final tooMany = [
        for (var i = 0; i <= uv5rProfile.channelCapacity; i++)
          RadioChannel(name: 'C$i', rxFreqHz: 146520000, txFreqHz: 146520000),
      ];
      await expectLater(
        const CodeplugEncoder().encode(
          await _blank(uv5rProfile),
          uv5rProfile,
          tooMany,
        ),
        throwsA(predicate((e) => '$e'.contains('do not fit'))),
      );
    });

    test('a UV-32 channel moved by a delete keeps its own power', () async {
      if (!rustReady) return markTestSkipped('host Rust library unavailable');
      // Slots High, Medium, Low; delete the first and write. The level used
      // to follow the slot, so the Low channel went out Medium (5 W) and the
      // Medium one went out Low.
      const high = RadioChannel(
        name: 'H',
        rxFreqHz: 146520000,
        txFreqHz: 146520000,
      );
      final medium = high.copyWith(name: 'M', power: PowerLevel.medium);
      final low = high.copyWith(name: 'L', power: PowerLevel.low);
      const encoder = CodeplugEncoder();
      final full = await encoder.encode(
        await _blank(uv32Profile),
        uv32Profile,
        [high, medium, low],
      );
      final moved = await encoder.encode(
        RadioCodeplug(modelId: 'uv-32', image: full, readAt: DateTime(2026)),
        uv32Profile,
        [medium, low],
      );
      // Byte 14's low two bits: CHIRP UV32.POWER_LEVELS is High, Low, Medium.
      expect(moved[14] & 0x03, 2, reason: 'Medium, now in slot 1');
      expect(moved[32 + 14] & 0x03, 1, reason: 'Low, now in slot 2');
      final read = await const CodeplugDecoder().decode(
        RadioCodeplug(modelId: 'uv-32', image: moved, readAt: DateTime(2026)),
        uv32Profile,
      );
      expect(
        [for (final c in read.channels) c.power],
        [PowerLevel.medium, PowerLevel.low],
      );
    });

    test('a radio without medium is written low for it', () async {
      if (!rustReady) return markTestSkipped('host Rust library unavailable');
      const medium = RadioChannel(
        name: 'M',
        rxFreqHz: 146520000,
        txFreqHz: 146520000,
        power: PowerLevel.medium,
      );
      final read = await _nativeRoundTrip(uv5rMiniProfile, [medium]);
      expect(read.channels.single.power, PowerLevel.low);
    });

    for (final profile in [uv5rMiniProfile, uv32Profile, uv5rProfile]) {
      test('${profile.id}: a blank image is the model\'s length, all 0xFF, '
          'and decodes to nothing', () async {
        if (!rustReady) return markTestSkipped('host Rust library unavailable');
        final blank = await _blank(profile);
        final expectedLen = switch (profile.programmingFamily) {
          ProgrammingFamily.serialUv5r => await rust.uv5RImageLen(),
          _ =>
            (await rust.radioModels())
                .firstWhere((m) => m.id == profile.id)
                .imageLen,
        };
        expect(blank.length, expectedLen);
        expect(blank.image.every((b) => b == 0xFF), isTrue);
        final decoded = await const CodeplugDecoder().decode(blank, profile);
        expect(decoded.channels, isEmpty);
        expect(decoded.hadGaps, isFalse);
      });
    }
  });
}
