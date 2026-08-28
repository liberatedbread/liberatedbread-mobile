// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/models/radio_profile.dart';

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

    test('round-trips through JSON and rejects nonsense', () {
      const range = FreqRange(144000000, 148000000);
      expect(FreqRange.fromJson(range.toJson()), range);
      expect(FreqRange.fromJson(null), isNull);
      expect(FreqRange.fromJson(const {'low': 0, 'high': 1}), isNull);
      // high below low is not a range, it is a typo.
      expect(FreqRange.fromJson(const {'low': 200, 'high': 100}), isNull);
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
          expect(rangesContain(profile.rxRanges, tx.lowHz), isTrue,
              reason: '${profile.id} transmits at ${tx.lowHz} but cannot '
                  'receive there');
          expect(rangesContain(profile.rxRanges, tx.highHz), isTrue,
              reason: '${profile.id} transmits at ${tx.highHz} but cannot '
                  'receive there');
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
        expect(profile.txUnlock.expandedTxRanges, isNotEmpty,
            reason: profile.id);
        expect(profile.txUnlock.mechanism, isNot(TxUnlockMechanism.unsupported),
            reason: profile.id);
        expect(profile.txUnlock.notes, isNotEmpty, reason: profile.id);
      }
    });

    test('only the BLE family claims a programmer in this build', () {
      for (final profile in radioProfiles) {
        if (!profile.isProgrammable) continue;
        expect(profile.programmingFamily, ProgrammingFamily.bleUv17Pro,
            reason: '${profile.id} claims programmer support, but this build '
                'has no transport for its family');
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
          expect(range.lowHz, greaterThanOrEqualTo(462000000),
              reason: profile.id);
          expect(range.highHz, lessThanOrEqualTo(468000000),
              reason: profile.id);
        }
      }
    });
  });

  group('effective transmit ranges', () {
    test('are the factory ranges with the unlock off', () {
      expect(uv5rMiniProfile.effectiveTxRanges(unlockEnabled: false),
          uv5rMiniProfile.factoryTxRanges);
    });

    test('widen with the unlock on', () {
      final widened = uv5rProfile.effectiveTxRanges(unlockEnabled: true);
      expect(widened.length, greaterThan(uv5rProfile.factoryTxRanges.length));
      expect(uv5rProfile.canTransmit(140000000, unlockEnabled: false), isFalse);
      expect(uv5rProfile.canTransmit(140000000, unlockEnabled: true), isTrue);
    });

    test('the radios this build can program are not the unlockable ones', () {
      // Awkward, and worth stating rather than discovering. The band-limit
      // fields live in the older UV-5R serial codeplug; the UV-17Pro family,
      // which is what the Bluetooth driver speaks, has none. So the unlock is
      // modelled for radios this build cannot yet write to, and the radios it
      // can write to have nothing to unlock.
      for (final profile in radioProfiles) {
        if (!profile.isProgrammable) continue;
        expect(profile.txUnlock.supported, isFalse,
            reason: '${profile.id} claims an unlock its family does not have');
      }
      expect(uv5rProfile.txUnlock.supported, isTrue);
      expect(uv5rProfile.isProgrammable, isFalse);
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
      expect(locked.effectiveTxRanges(unlockEnabled: true),
          locked.factoryTxRanges);
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
      expect(uv5gMiniProfile.canTransmit(146520000, unlockEnabled: false),
          isFalse);
      expect(
          uv5gMiniProfile.canTransmit(462600000, unlockEnabled: false), isTrue);
    });
  });

  test('profile identity is the id', () {
    expect(uv5rMiniProfile, radioProfileById('uv-5r-mini'));
    expect(uv5rMiniProfile.hashCode, radioProfileById('uv-5r-mini').hashCode);
    expect(uv5rMiniProfile, isNot(uv32Profile));
  });

  test('TxUnlock has value equality', () {
    const a = TxUnlock(
      supported: true,
      mechanism: TxUnlockMechanism.codeplugBandLimit,
      expandedTxRanges: [FreqRange(130000000, 179995000)],
    );
    const b = TxUnlock(
      supported: true,
      mechanism: TxUnlockMechanism.codeplugBandLimit,
      expandedTxRanges: [FreqRange(130000000, 179995000)],
    );
    expect(a, b);
    expect(a.hashCode, b.hashCode);
    expect(a, isNot(TxUnlock.unsupported));
    expect(a.toJson()['ranges'], hasLength(1));
  });
}
