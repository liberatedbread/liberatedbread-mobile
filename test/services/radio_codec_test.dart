// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/models/channel_plan.dart';
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
  int? powerRaw,
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
  powerRaw: powerRaw,
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

    test('the radio\'s power index crosses in both directions', () {
      final hpLow = channelFromDto(_dto(1, power: 'low', powerRaw: 2));
      expect(hpLow.powerRaw, 2);
      expect(channelToDto(hpLow, slot: 1).powerRaw, 2);
      expect(channelFromDto(channelToDto(hpLow, slot: 1)), hpLow);
      // A channel made in the app has none to send.
      expect(channelToDto(channel, slot: 1).powerRaw, isNull);
      expect(channelFromDto(_dto(1)).powerRaw, isNull);
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

    test('a UV-82HP Low keeps its index when the channel above it is '
        'deleted from the plan', () async {
      if (!rustReady) return markTestSkipped('host Rust library unavailable');
      // A UV-82HP answers the UV-82 ident behind the two-level UV-5R
      // profile, whose Low is 1; the HP's own Low is 2 and its 1 is Med.
      // Slots M (1) and L (2) both read Low. Delete M from the plan and
      // write: L lands on M's record and must still go out as 2, not as
      // the record's 1 or a fresh 1 -- either is Med, raised with no user
      // action.
      int powerAt(Uint8List image, int slot) =>
          image[8 + slot * 16 + 14] & 0x03;
      const med = RadioChannel(
        name: 'M',
        rxFreqHz: 146520000,
        txFreqHz: 146520000,
        power: PowerLevel.low,
      );
      final low = med.copyWith(name: 'L');
      const encoder = CodeplugEncoder();
      final base = RadioCodeplug(
        modelId: uv5rProfile.id,
        image: await blankUv5rImage(),
        readAt: DateTime(2026, 9, 1),
      );
      final image = await encoder.encode(base, uv5rProfile, [med, low]);
      image[8 + 16 + 14] = (image[8 + 16 + 14] & ~0x03) | 2;
      expect([powerAt(image, 0), powerAt(image, 1)], [1, 2]);

      final read = await const CodeplugDecoder().decode(
        RadioCodeplug(
          modelId: uv5rProfile.id,
          image: image,
          readAt: DateTime(2026),
        ),
        uv5rProfile,
      );
      expect([for (final c in read.channels) c.powerRaw], [1, 2]);

      // Through the plan's own storage, then the delete.
      final stored = ChannelPlan(
        id: 'hp',
        name: 'HP',
        radioProfileId: uv5rProfile.id,
        channels: read.channels,
        createdAt: DateTime(2026),
        modifiedAt: DateTime(2026),
      );
      final reloaded = ChannelPlan.fromJson(
        jsonDecode(jsonEncode(stored.toJson())) as Map<String, dynamic>,
      )!;
      final deleted = reloaded.channels.sublist(1);
      expect(deleted.single.name, 'L');

      final written = await encoder.encode(
        RadioCodeplug(
          modelId: uv5rProfile.id,
          image: image,
          readAt: DateTime(2026),
        ),
        uv5rProfile,
        deleted,
      );
      expect(powerAt(written, 0), 2, reason: 'L, moved up a slot');

      // Set to High in the editor, it is written High.
      final raised = await encoder.encode(
        RadioCodeplug(
          modelId: uv5rProfile.id,
          image: image,
          readAt: DateTime(2026),
        ),
        uv5rProfile,
        [deleted.single.copyWith(power: PowerLevel.high)],
      );
      expect(powerAt(raised, 0), 0);
    });

    group('a power index the profile does not list', () {
      // A UV-82HP answers the UV-82 ident behind the two-level UV-5R
      // profile, whose Low is 1; the HP's own Low is 2 and its 1 is Med.
      int uv5rPowerAt(Uint8List image, int slot) =>
          image[8 + slot * 16 + 14] & 0x03;
      const low = RadioChannel(
        name: 'L',
        rxFreqHz: 146520000,
        txFreqHz: 146520000,
        power: PowerLevel.low,
      );
      const lowAt2 = RadioChannel(
        name: 'L',
        rxFreqHz: 146520000,
        txFreqHz: 146520000,
        power: PowerLevel.low,
        powerRaw: 2,
      );
      const encoder = CodeplugEncoder();

      /// A uv5r image whose slot 1 is [raw] at Low: 2 for an HP, 1 for a
      /// plain UV-5R.
      Future<RadioCodeplug> uv5rWithLowAt(int raw) async {
        final base = RadioCodeplug(
          modelId: uv5rProfile.id,
          image: await blankUv5rImage(),
          readAt: DateTime(2026, 9, 1),
        );
        final image = await encoder.encode(base, uv5rProfile, [
          low.copyWith(name: 'OLD'),
        ]);
        image[8 + 14] = (image[8 + 14] & ~0x03) | raw;
        return RadioCodeplug(
          modelId: uv5rProfile.id,
          image: image,
          readAt: DateTime(2026, 9, 1),
        );
      }

      test('is taken from the radio for a Low that carries none', () async {
        if (!rustReady) return markTestSkipped('host Rust library unavailable');
        // A plan stored before the index was carried, a Low made in the
        // app, and a High set back to Low in the editor all reach the codec
        // with no index. Encoded afresh they went out as 1: Med on the HP.
        // Fails on channelToDto's straight pass-through.
        final hp = await uv5rWithLowAt(2);
        final relevelled = lowAt2
            .copyWith(power: PowerLevel.high)
            .copyWith(power: PowerLevel.low);
        expect(relevelled.powerRaw, isNull);
        final written = await encoder.encode(hp, uv5rProfile, [
          low,
          relevelled,
          low.copyWith(power: PowerLevel.high),
        ]);
        expect(
          [for (var s = 0; s < 3; s++) uv5rPowerAt(written, s)],
          [2, 2, 0],
        );

        // A radio that shows no unlisted Low gets the profile's own 1.
        final plain = await encoder.encode(
          await uv5rWithLowAt(1),
          uv5rProfile,
          [low],
        );
        expect(uv5rPowerAt(plain, 0), 1);
      });

      test('read from one radio is not written to another', () async {
        if (!rustReady) return markTestSkipped('host Rust library unavailable');
        // An HP's Low (2) in a plan written to a plain UV-5R under the same
        // profile id, or to a Mini from the device screen's picker. Those
        // list only 0 and 1, and CHIRP reads 2 as High. Fails on the old
        // pass-through, which wrote the 2.
        const fromHp = lowAt2;
        final plain = await encoder.encode(
          await uv5rWithLowAt(1),
          uv5rProfile,
          [fromHp],
        );
        expect(uv5rPowerAt(plain, 0), 1);

        final mini = await encoder.encode(
          await _blank(uv5rMiniProfile),
          uv5rMiniProfile,
          [fromHp],
        );
        expect(mini[14] & 0x03, 1, reason: 'the Mini\'s Low');

        // Written back to an HP, which holds 2 at Low, it keeps the 2.
        final hp = await encoder.encode(await uv5rWithLowAt(2), uv5rProfile, [
          fromHp,
        ]);
        expect(uv5rPowerAt(hp, 0), 2);
      });
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
