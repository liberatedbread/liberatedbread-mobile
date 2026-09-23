// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/core/error_text.dart';
import 'package:liberated_bread_mobile/models/radio_channel.dart';
import 'package:liberated_bread_mobile/models/radio_profile.dart';
import 'package:liberated_bread_mobile/services/mock_radio_programmer.dart';
import 'package:liberated_bread_mobile/services/radio_programmer.dart';

import '../fakes/fake_radio_programmer.dart';

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
            friendlyErrorText(failure, fallback: 'fallback'), failure.message);
      }
    });

    test('each says what to do next', () {
      expect(const RadioTimeoutException().message.toLowerCase(),
          contains('try again'));
      expect(const RadioUnsupportedException().message.toLowerCase(),
          contains('chirp'));
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
      const identity =
          RadioIdentity(profile: uv5rProfile, reported: 'BFB297 firmware');
      expect(identity.summary, 'The radio answered: BFB297 firmware.');
    });
  });

  group('MockRadioProgrammer', () {
    final programmer = MockRadioProgrammer(stepDelay: Duration.zero);

    test('answers an identify as the model it was asked about', () async {
      final identity =
          await programmer.identify(deviceId: 'mock', profile: uv5gMiniProfile);
      expect(identity.profile, uv5gMiniProfile);
      expect(identity.reported, isNull);
    });

    test('supports whatever this build can program', () {
      expect(programmer.supports(uv5rMiniProfile), isTrue);
      expect(programmer.supports(uv5rProfile), isTrue);
      expect(programmer.supports(uv5gProfile), isFalse);
    });

    test('walks the same stages the real driver does', () async {
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

    test('hands back an image of the right size', () async {
      RadioCodeplug? result;
      await programmer
          .readCodeplug(
            deviceId: 'mock',
            profile: uv5rMiniProfile,
            onResult: (codeplug) => result = codeplug,
          )
          .drain<void>();
      expect(result!.length, 0x8240);
    });

    test('remembers what was written to it', () async {
      final mock = MockRadioProgrammer(stepDelay: Duration.zero);
      final base = RadioCodeplug(
        modelId: 'uv-5r-mini',
        image: Uint8List(0x8240)..[7] = 0x42,
        readAt: DateTime.now(),
      );

      await mock.writeChannels(
        deviceId: 'mock',
        profile: uv5rMiniProfile,
        base: base,
        channels: const [
          RadioChannel(name: 'A', rxFreqHz: 146940000, txFreqHz: 146340000),
        ],
      ).drain<void>();

      expect(mock.writes, hasLength(1));
      expect(mock.image[7], 0x42);
    });

    test('restores an image byte for byte', () async {
      final mock = MockRadioProgrammer(stepDelay: Duration.zero);
      final backup = RadioCodeplug(
        modelId: 'uv-5r-mini',
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

      expect(mock.image, backup.image);
    });
  });

  group('FakeRadioProgrammer', () {
    test('identifies, reports, and records where it was aimed', () async {
      final fake = FakeRadioProgrammer()..reported = 'hello';
      final identity =
          await fake.identify(deviceId: 'radio-1', profile: uv5rMiniProfile);
      expect(identity.reported, 'hello');
      expect(fake.identifyCalls, 1);
      expect(fake.deviceIds, ['radio-1']);
    });

    test('an identify fails on command', () async {
      final fake = FakeRadioProgrammer(error: const RadioTimeoutException());
      await expectLater(
        fake.identify(deviceId: 'radio-1', profile: uv5rMiniProfile),
        throwsA(isA<RadioTimeoutException>()),
      );
    });

    test('records reads, writes and restores', () async {
      final fake = FakeRadioProgrammer();
      await fake
          .readCodeplug(
            deviceId: 'x',
            profile: uv5rMiniProfile,
            onResult: (_) {},
          )
          .drain<void>();
      expect(fake.readCalls, 1);

      await fake.writeChannels(
        deviceId: 'x',
        profile: uv5rMiniProfile,
        base: RadioCodeplug(
          modelId: 'uv-5r-mini',
          image: Uint8List(1),
          readAt: DateTime.now(),
        ),
        channels: const [],
      ).drain<void>();
      expect(fake.written, hasLength(1));
    });

    test('fails on command', () async {
      final fake = FakeRadioProgrammer(error: const RadioTimeoutException());
      await expectLater(
        fake
            .readCodeplug(
              deviceId: 'x',
              profile: uv5rMiniProfile,
              onResult: (_) {},
            )
            .drain<void>(),
        throwsA(isA<RadioTimeoutException>()),
      );
    });
  });
}
