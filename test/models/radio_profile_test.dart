// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/models/radio_profile.dart';
import 'package:liberated_bread_mobile/models/radio_target.dart';

void main() {
  group('FreqRange', () {
    test('is inclusive at both ends', () {
      const range = FreqRange(144000000, 148000000);
      expect(range.contains(144000000), isTrue);
      expect(range.contains(148000000), isTrue);
      expect(range.contains(146520000), isTrue);
      expect(range.contains(143999999), isFalse);
      expect(range.contains(148000001), isFalse);
    });

    test('rangesContain scans the whole list', () {
      const ranges = [
        FreqRange(144000000, 148000000),
        FreqRange(420000000, 450000000),
      ];
      expect(rangesContain(ranges, 446000000), isTrue);
      expect(rangesContain(ranges, 146520000), isTrue);
      expect(rangesContain(ranges, 162550000), isFalse);
      expect(rangesContain(const [], 146520000), isFalse);
    });
  });

  group('the catalogue', () {
    test('has unique ids', () {
      final ids = [for (final p in radioProfiles) p.id];
      expect(ids.toSet().length, ids.length);
    });

    test('every profile is coherent', () {
      for (final profile in radioProfiles) {
        expect(profile.displayName, isNotEmpty, reason: profile.id);
        expect(profile.rxRanges, isNotEmpty, reason: profile.id);
        expect(profile.factoryTxRanges, isNotEmpty, reason: profile.id);
        expect(profile.channelCapacity, greaterThan(0), reason: profile.id);
        expect(profile.nameLength, greaterThan(0), reason: profile.id);
        // Anything the radio can transmit on, it can also hear. A profile
        // that violates this would offer channels the suggestion engine then
        // drops for being un-receivable, which reads as a missing repeater.
        for (final tx in profile.factoryTxRanges) {
          expect(
            rangesContain(profile.rxRanges, tx.lowHz),
            isTrue,
            reason:
                '${profile.id} transmits at ${tx.lowHz} but cannot '
                'receive there',
          );
          expect(
            rangesContain(profile.rxRanges, tx.highHz),
            isTrue,
            reason:
                '${profile.id} transmits at ${tx.highHz} but cannot '
                'receive there',
          );
        }
      }
    });

    test('an unsupported unlock offers no expanded ranges', () {
      for (final profile in radioProfiles) {
        if (profile.txUnlock.supported) continue;
        expect(profile.txUnlock.expandedTxRanges, isEmpty, reason: profile.id);
      }
      expect(TxUnlock.unsupported.supported, isFalse);
      expect(TxUnlock.unsupported.mechanism, TxUnlockMechanism.unsupported);
      expect(TxUnlock.unsupported.notes, isNotEmpty);
    });

    test('a supported unlock says what it does and where it goes', () {
      for (final profile in radioProfiles) {
        if (!profile.txUnlock.supported) continue;
        expect(
          profile.txUnlock.expandedTxRanges,
          isNotEmpty,
          reason: profile.id,
        );
        expect(
          profile.txUnlock.mechanism,
          isNot(TxUnlockMechanism.unsupported),
          reason: profile.id,
        );
        expect(profile.txUnlock.notes, isNotEmpty, reason: profile.id);
      }
    });

    test('every radio claiming a programmer has a driver for its family', () {
      for (final profile in radioProfiles) {
        if (!profile.isProgrammable) continue;
        final expected = switch (profile.programmingFamily) {
          ProgrammingFamily.bleUv17Pro => RadioTransport.ble,
          ProgrammingFamily.serialUv5r => RadioTransport.usb,
          // No cable driver speaks the UV-17Pro protocol in this build.
          ProgrammingFamily.serialUv17Pro => null,
        };
        expect(
          profile.programmingTransport,
          expected,
          reason:
              '${profile.id} claims programmer support, but this build '
              'has no transport for its family',
        );
        expect(expected, isNotNull, reason: profile.id);
      }
    });

    test('the default profile is one this build can actually program', () {
      expect(radioProfiles, contains(defaultRadioProfile));
      expect(defaultRadioProfile.isProgrammable, isTrue);
    });

    test('the UV-17Pro family holds far more channels than the UV-5R', () {
      // 999 twelve-character names, not 128 seven-character ones. Getting
      // this wrong caps a plan at an eighth of the radio and truncates every
      // name.
      expect(uv5rMiniProfile.channelCapacity, 999);
      expect(uv5rMiniProfile.nameLength, 12);
      expect(uv5rProfile.channelCapacity, 128);
      expect(uv5rProfile.nameLength, 7);
    });

    test('lookup by id finds every profile and nothing else', () {
      for (final profile in radioProfiles) {
        expect(radioProfileById(profile.id), profile);
      }
      expect(radioProfileById('nokia-3310'), isNull);
      expect(radioProfileById(null), isNull);
      expect(radioProfileById(''), isNull);
    });

    test('GMRS radios transmit only in the GMRS allocation', () {
      for (final profile in radioProfiles) {
        if (!profile.gmrsLocked) continue;
        for (final range in profile.factoryTxRanges) {
          expect(
            range.lowHz,
            greaterThanOrEqualTo(462000000),
            reason: profile.id,
          );
          expect(
            range.highHz,
            lessThanOrEqualTo(468000000),
            reason: profile.id,
          );
        }
      }
    });
  });

  group('effective transmit ranges', () {
    test('are the factory ranges with the unlock off', () {
      expect(
        uv5rMiniProfile.effectiveTxRanges(unlockEnabled: false),
        uv5rMiniProfile.factoryTxRanges,
      );
    });

    test('widen with the unlock on', () {
      final widened = uv5rProfile.effectiveTxRanges(unlockEnabled: true);
      expect(widened.length, greaterThan(uv5rProfile.factoryTxRanges.length));
      expect(uv5rProfile.canTransmit(140000000, unlockEnabled: false), isFalse);
      expect(uv5rProfile.canTransmit(140000000, unlockEnabled: true), isTrue);
    });

    test('every radio with an unlock is one this build can write it to', () {
      // Until the cable driver this was the other way round: the unlock was
      // modelled for radios this build could not write to, and the radios it
      // could write to had nothing to unlock. The band-limit fields live in
      // the UV-5R serial codeplug, which the cable now reaches; the
      // Bluetooth family still has none.
      for (final profile in radioProfiles) {
        if (!profile.txUnlock.supported) continue;
        expect(
          profile.programsOver(RadioTransport.usb),
          isTrue,
          reason: '${profile.id} offers an unlock no driver could write',
        );
      }
      for (final profile in profilesProgrammableOver(RadioTransport.ble)) {
        expect(
          profile.txUnlock.supported,
          isFalse,
          reason: '${profile.id} claims an unlock its family does not have',
        );
      }
      expect(uv5rProfile.txUnlock.supported, isTrue);
    });

    test('do not widen for a radio that cannot unlock, flag or no flag', () {
      // The setting is stored per profile, but a stale "on" must never grant
      // a range to a radio that has no software path to it.
      const locked = RadioProfile(
        id: 'test-locked',
        displayName: 'Test',
        rxRanges: [FreqRange(136000000, 174000000)],
        factoryTxRanges: [FreqRange(144000000, 148000000)],
        channelCapacity: 16,
        nameLength: 6,
        programmingFamily: ProgrammingFamily.serialUv5r,
      );
      expect(
        locked.effectiveTxRanges(unlockEnabled: true),
        locked.factoryTxRanges,
      );
      expect(locked.canTransmit(140000000, unlockEnabled: true), isFalse);
      expect(locked.needsUnlockToTransmit(140000000), isFalse);
    });

    test('needsUnlockToTransmit marks exactly the widened band', () {
      // Inside the factory range: no badge.
      expect(uv5rProfile.needsUnlockToTransmit(146520000), isFalse);
      // Inside the expanded range only: badge.
      expect(uv5rProfile.needsUnlockToTransmit(140000000), isTrue);
      // Outside both: not a badge, just unreachable.
      expect(uv5rProfile.needsUnlockToTransmit(900000000), isFalse);
      // And never for a radio whose family has no band-limit field at all.
      expect(uv5rMiniProfile.needsUnlockToTransmit(140000000), isFalse);
    });

    test('a GMRS radio can hear far more than it can transmit on', () {
      expect(uv5gMiniProfile.canReceive(146520000), isTrue);
      expect(
        uv5gMiniProfile.canTransmit(146520000, unlockEnabled: false),
        isFalse,
      );
      expect(
        uv5gMiniProfile.canTransmit(462600000, unlockEnabled: false),
        isTrue,
      );
    });
  });

  test('profile identity is the id', () {
    expect(uv5rMiniProfile, radioProfileById('uv-5r-mini'));
    expect(uv5rMiniProfile.hashCode, radioProfileById('uv-5r-mini').hashCode);
    expect(uv5rMiniProfile, isNot(uv32Profile));
  });

  group('programsOver', () {
    test('the Bluetooth radios program over Bluetooth and only Bluetooth', () {
      for (final profile in [uv5rMiniProfile, uv5gMiniProfile, uv32Profile]) {
        expect(
          profile.programsOver(RadioTransport.ble),
          isTrue,
          reason: profile.id,
        );
        expect(
          profile.programsOver(RadioTransport.usb),
          isFalse,
          reason: profile.id,
        );
      }
    });

    test('the UV-5R family programs over a cable and only a cable', () {
      for (final profile in [uv5rProfile, bfF8hpProfile, ar152Profile]) {
        expect(
          profile.programsOver(RadioTransport.usb),
          isTrue,
          reason: profile.id,
        );
        expect(
          profile.programsOver(RadioTransport.ble),
          isFalse,
          reason: profile.id,
        );
        expect(
          profile.programmingTransport,
          RadioTransport.usb,
          reason: profile.id,
        );
        expect(
          profile.programmerSupport,
          ProgrammerSupport.unverified,
          reason: 'nothing in the cable driver has met a radio yet',
        );
      }
      expect(uv5rMiniProfile.programmingTransport, RadioTransport.ble);
    });

    test('a radio this build has no driver for programs over nothing', () {
      // The UV-5G's memory is not a UV-5R's; the UV-17R Plus's cable path is
      // not built.
      for (final profile in [uv5gProfile, uv17rPlusProfile]) {
        expect(profile.programmingTransport, isNull, reason: profile.id);
        expect(profile.isProgrammable, isFalse, reason: profile.id);
        for (final transport in RadioTransport.values) {
          expect(
            profile.programsOver(transport),
            isFalse,
            reason: '${profile.id} over ${transport.name}',
          );
        }
      }
    });

    test('the UV-5G claims no unlock this app cannot perform', () {
      // It once described a "GMRS flag in the codeplug" — for a radio whose
      // memory nothing here knows the layout of.
      expect(uv5gProfile.txUnlock.supported, isFalse);
      expect(uv5gProfile.txUnlock.notes, contains('does not know'));
    });

    test('profilesProgrammableOver agrees with programsOver, in order', () {
      for (final transport in RadioTransport.values) {
        expect(profilesProgrammableOver(transport), [
          for (final profile in radioProfiles)
            if (profile.programsOver(transport)) profile,
        ]);
      }
      expect(profilesProgrammableOver(RadioTransport.ble), isNotEmpty);
    });
  });
}
