// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/core/error_text.dart';
import 'package:liberated_bread_mobile/models/radio_band_limits.dart';
import 'package:liberated_bread_mobile/models/radio_channel.dart';
import 'package:liberated_bread_mobile/models/radio_profile.dart';
import 'package:liberated_bread_mobile/services/mock_radio_programmer.dart';
import 'package:liberated_bread_mobile/services/radio_codec.dart';
import 'package:liberated_bread_mobile/services/radio_programmer.dart';

import '../helpers/host_rust_lib.dart';

void main() {
  group('the failures a session can have', () {
    const failures = <UserFacingException>[
      RadioProtocolException(),
      RadioTimeoutException(),
      RadioUnsupportedException(),
    ];

    test('are all written for a person to read', () {
      for (final failure in failures) {
        expect(failure.message, isNotEmpty);
        expect(failure.toString(), failure.message);
        expect(
          friendlyErrorText(failure, fallback: 'fallback'),
          failure.message,
        );
      }
    });

    test('each says what to do next', () {
      expect(
        const RadioTimeoutException().message.toLowerCase(),
        contains('try again'),
      );
      expect(
        const RadioUnsupportedException().message.toLowerCase(),
        contains('chirp'),
      );
    });

    test('can carry a more specific message', () {
      expect(const RadioProtocolException('specific').message, 'specific');
    });
  });

  test('a codeplug knows its own size', () {
    final codeplug = RadioCodeplug(
      modelId: 'uv-5r-mini',
      image: Uint8List(0x8240),
      readAt: DateTime.utc(2026, 8),
    );
    expect(codeplug.length, 0x8240);
    expect(codeplug.modelId, 'uv-5r-mini');
  });

  test('a progress event carries a stage and something to show', () {
    const event = RadioProgressEvent(
      stage: RadioProgressStage.reading,
      message: 'Reading…',
      progress: 0.5,
    );
    expect(event.stage, RadioProgressStage.reading);
    expect(event.progress, 0.5);
    expect(event.message, isNotEmpty);
  });

  group('RadioIdentity', () {
    test('claims only the family when the radio reported nothing', () {
      const identity = RadioIdentity(profile: uv5rMiniProfile);
      expect(identity.summary, contains('confirms the family'));
      expect(identity.summary, contains(uv5rMiniProfile.displayName));
    });

    test('repeats what the radio said when it said something', () {
      const identity = RadioIdentity(
        profile: uv5rProfile,
        reported: 'BFB297 firmware',
      );
      expect(identity.summary, 'The radio answered: BFB297 firmware.');
    });
  });

  group('MockRadioProgrammer', () {
    test('answers an identify as the model it was asked about', () async {
      final programmer = MockRadioProgrammer(
        stepDelay: Duration.zero,
        encoder: _StubEncoder(),
      );
      final identity = await programmer.identify(
        deviceId: 'mock',
        profile: uv5gMiniProfile,
      );
      expect(identity.profile, uv5gMiniProfile);
      expect(identity.reported, isNull);
    });

    test('supports whatever this build can program', () {
      final programmer = MockRadioProgrammer(
        stepDelay: Duration.zero,
        encoder: _StubEncoder(),
      );
      expect(programmer.supports(uv5rMiniProfile), isTrue);
      expect(programmer.supports(uv5rProfile), isTrue);
      expect(programmer.supports(uv5gProfile), isFalse);
    });

    test('walks the same stages the real driver does', () async {
      final programmer = MockRadioProgrammer(
        stepDelay: Duration.zero,
        encoder: _StubEncoder(),
      );
      final events = await programmer
          .readCodeplug(
            deviceId: 'mock',
            profile: uv5rMiniProfile,
            onResult: (_) {},
          )
          .toList();

      expect(events.first.stage, RadioProgressStage.connecting);
      expect(events.map((e) => e.stage), contains(RadioProgressStage.reading));
      expect(events.last.stage, RadioProgressStage.done);
      expect(events.last.progress, 1);
    });

    test('a first read hands back the blank image the encoder makes', () async {
      final encoder = _StubEncoder();
      final mock = MockRadioProgrammer(
        stepDelay: Duration.zero,
        encoder: encoder,
      );
      final first = await mock.readWhole(
        deviceId: 'mock',
        profile: uv5rMiniProfile,
      );
      expect(first.modelId, uv5rMiniProfile.id);
      expect(first.length, _StubEncoder.blankLen);
      expect(first.image.every((b) => b == 0xFF), isTrue);
      expect(encoder.blanksMade, [uv5rMiniProfile.id]);

      // The seed is made once and kept: a second read is the same radio,
      // and a copy -- what a caller does to its read stays with the caller.
      first.image[0] = 0x00;
      final second = await mock.readWhole(
        deviceId: 'mock',
        profile: uv5rMiniProfile,
      );
      expect(second.image[0], 0xFF);
      expect(encoder.blanksMade, [uv5rMiniProfile.id]);
    });

    test('hands the channels it is asked to write to the encoder, '
        'and holds the result', () async {
      final encoder = _StubEncoder();
      final mock = MockRadioProgrammer(
        stepDelay: Duration.zero,
        encoder: encoder,
      );
      final base = RadioCodeplug(
        modelId: uv5rMiniProfile.id,
        image: Uint8List(_StubEncoder.blankLen)..[7] = 0x42,
        readAt: DateTime.now(),
      );
      const channels = [
        RadioChannel(name: 'A', rxFreqHz: 146940000, txFreqHz: 146340000),
        RadioChannel(name: 'B', rxFreqHz: 146520000, txFreqHz: 146520000),
      ];

      final events = await mock
          .writeChannels(
            deviceId: 'mock',
            profile: uv5rMiniProfile,
            base: base,
            channels: channels,
          )
          .toList();

      expect(events.last.stage, RadioProgressStage.done);
      expect(encoder.encoded.single.profile, uv5rMiniProfile);
      expect(encoder.encoded.single.channels, channels);
      final read = await mock.readWhole(
        deviceId: 'mock',
        profile: uv5rMiniProfile,
      );
      expect(read.image[0], channels.length, reason: 'the encoded image');
      expect(read.image[7], 0x42, reason: 'built on the base');
    });

    test('a plan the encoder refuses leaves the radio untouched', () async {
      final mock = MockRadioProgrammer(
        stepDelay: Duration.zero,
        encoder: _StubEncoder(refuse: true),
      );
      final before = await mock.readWhole(
        deviceId: 'mock',
        profile: uv5rMiniProfile,
      );
      final events = <RadioProgressEvent>[];
      await expectLater(
        mock
            .writeChannels(
              deviceId: 'mock',
              profile: uv5rMiniProfile,
              base: before,
              channels: const [
                RadioChannel(
                  name: 'A',
                  rxFreqHz: 146520000,
                  txFreqHz: 146520000,
                ),
              ],
            )
            .forEach(events.add),
        throwsA(isA<StateError>()),
      );
      expect(
        events.map((e) => e.stage),
        isNot(contains(RadioProgressStage.writing)),
        reason: 'the real drivers encode before they connect',
      );
      final after = await mock.readWhole(
        deviceId: 'mock',
        profile: uv5rMiniProfile,
      );
      expect(after.image, before.image);
    });

    test('holds one image per model', () async {
      // Demo mode reaches the same mock for every radio in the catalogue,
      // and the codecs refuse an image of another model's length.
      final encoder = _StubEncoder();
      final mock = MockRadioProgrammer(
        stepDelay: Duration.zero,
        encoder: encoder,
      );
      final mini = await mock.readWhole(
        deviceId: 'mock',
        profile: uv5rMiniProfile,
      );
      await mock
          .writeChannels(
            deviceId: 'mock',
            profile: uv5rMiniProfile,
            base: mini,
            channels: const [
              RadioChannel(name: 'A', rxFreqHz: 146520000, txFreqHz: 146520000),
            ],
          )
          .drain<void>();

      final cable = await mock.readWhole(
        deviceId: 'mock',
        profile: uv5rProfile,
      );
      expect(cable.image.every((b) => b == 0xFF), isTrue);
      expect(encoder.blanksMade, [uv5rMiniProfile.id, uv5rProfile.id]);
      expect(
        (await mock.readWhole(
          deviceId: 'mock',
          profile: uv5rMiniProfile,
        )).image[0],
        1,
        reason: 'the Mini still holds its write',
      );
    });

    test('holds transmit limits, and keeps what is written to them', () async {
      final mock = MockRadioProgrammer(
        stepDelay: Duration.zero,
        encoder: _StubEncoder(),
      );
      final base = RadioCodeplug(
        modelId: uv5rProfile.id,
        image: Uint8List(0x10),
        readAt: DateTime.now(),
      );
      final before = await mock.bandLimitsIn(base, uv5rProfile);
      expect(before.label, 'VHF 136–174 MHz and UHF 400–520 MHz');

      final widened = RadioBandLimits.widenedFor(uv5rProfile)!;
      final events = await mock
          .writeBandLimits(
            deviceId: 'mock',
            profile: uv5rProfile,
            base: base,
            limits: widened,
          )
          .toList();
      expect(events.map((e) => e.stage), contains(RadioProgressStage.writing));
      expect(events.last.stage, RadioProgressStage.done);
      expect(await mock.bandLimitsIn(base, uv5rProfile), widened);
    });

    test('restores an image byte for byte', () async {
      final mock = MockRadioProgrammer(
        stepDelay: Duration.zero,
        encoder: _StubEncoder(),
      );
      final backup = RadioCodeplug(
        modelId: uv5rMiniProfile.id,
        image: Uint8List.fromList(List<int>.generate(0x8240, (i) => i & 0xFF)),
        readAt: DateTime.now(),
      );

      await mock
          .restoreCodeplug(
            deviceId: 'mock',
            profile: uv5rMiniProfile,
            codeplug: backup,
          )
          .drain<void>();

      final read = await mock.readWhole(
        deviceId: 'mock',
        profile: uv5rMiniProfile,
      );
      expect(read.image, backup.image);
    });

    group('with the native codec', () {
      late bool rustReady;

      setUpAll(() async {
        rustReady = await initHostRustLib();
      });

      // The claim demo mode makes: "Write complete", then a read that shows
      // what was written. One Bluetooth model and one cable model, since
      // each has its own codec and its own image size.
      for (final profile in [uv5rMiniProfile, uv5rProfile]) {
        test('${profile.id}: a write followed by a read returns '
            'the written channels', () async {
          if (!rustReady) {
            return markTestSkipped('host Rust library unavailable');
          }
          final mock = MockRadioProgrammer(stepDelay: Duration.zero);
          const decoder = CodeplugDecoder();
          Future<List<RadioChannel>> onRadio() async => (await decoder.decode(
            await mock.readWhole(deviceId: 'mock', profile: profile),
            profile,
          )).channels;

          expect(await onRadio(), isEmpty, reason: 'a fresh radio is empty');

          const plan = [
            RadioChannel(
              name: 'W1AW',
              rxFreqHz: 146940000,
              txFreqHz: 146340000,
              txTone: ToneSetting.ctcss(1000),
            ),
            RadioChannel(
              name: 'CALL',
              rxFreqHz: 146520000,
              txFreqHz: 146520000,
              skip: true,
            ),
          ];
          await mock
              .writeChannels(
                deviceId: 'mock',
                profile: profile,
                base: await mock.readWhole(deviceId: 'mock', profile: profile),
                channels: plan,
              )
              .drain<void>();

          final written = await onRadio();
          expect([for (final c in written) c.name], ['W1AW', 'CALL']);
          expect(written[0].txFreqHz, 146340000);
          expect(written[0].txTone, const ToneSetting.ctcss(1000));
          expect(written[1].skip, isTrue);

          // A second write replaces the set: the old channels are gone,
          // not left behind in later slots.
          await mock
              .writeChannels(
                deviceId: 'mock',
                profile: profile,
                base: await mock.readWhole(deviceId: 'mock', profile: profile),
                channels: const [
                  RadioChannel(
                    name: 'ONLY',
                    rxFreqHz: 446000000,
                    txFreqHz: 446000000,
                  ),
                ],
              )
              .drain<void>();
          expect([for (final c in await onRadio()) c.name], ['ONLY']);
        });
      }
    });
  });
}

/// An encoder that never touches the native library, for the tests of the
/// mock's own bookkeeping: what it records is the channels it was handed.
class _StubEncoder extends CodeplugEncoder {
  static const int blankLen = 0x8240;

  final bool refuse;
  final List<String> blanksMade = [];
  final List<({RadioProfile profile, List<RadioChannel> channels})> encoded =
      [];

  _StubEncoder({this.refuse = false});

  @override
  Future<Uint8List> encode(
    RadioCodeplug base,
    RadioProfile profile,
    List<RadioChannel> channels,
  ) async {
    if (refuse) throw StateError('does not fit');
    encoded.add((profile: profile, channels: channels));
    // Byte 0 says how many channels landed; the rest is the base, which is
    // the contract the real codecs keep.
    return Uint8List.fromList(base.image)..[0] = channels.length;
  }

  @override
  Future<Uint8List> blankImage(RadioProfile profile) async {
    blanksMade.add(profile.id);
    return Uint8List(blankLen)..fillRange(0, blankLen, 0xFF);
  }
}
