// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/core/pairing_content.dart';
import 'package:liberated_bread_mobile/services/spec_codec.dart';

void main() {
  test('an open LAN API says plainly that nothing pairs', () {
    final c = PairingContent.of(
      const PairingDto(
        required_: false,
        securityMode: 'none',
        bonding: 'none',
        notes: 'Any host on the LAN can control it.',
      ),
    );
    expect(c.headline, 'No pairing needed.');
    expect(c.facts, [
      'Nothing to pair: any phone or client that can reach it is answered.',
    ]);
    expect(c.technicalNotes, ['Any host on the LAN can control it.']);
    expect(c.hasPairingMode, isFalse);
    expect(c.hasUnpair, isFalse);
    expect(c.hasContent, isTrue);
  });

  test('a bonding passkey device names its code, window and limits', () {
    final c = PairingContent.of(
      const PairingDto(
        required_: true,
        confidence: 'low',
        securityMode: 'passkey_entry',
        bonding: 'required',
        pin: PairingPinDto(
          source: 'fixed_default',
          value: ' 000000 ',
          length: 6,
          notes: 'Every unit ships with it.',
        ),
        exclusivity: PairingExclusivityDto(
          singleConnection: true,
          singleBond: true,
          recovery: '  Forget it on the old phone.  ',
        ),
        enterPairingMode: PairingModeDto(
          required_: true,
          windowSeconds: 30,
          advertisedName: 'LOCK-PAIR',
          indicator: 'Blue LED blinks.',
          procedures: [
            FactoryResetProcedureDto(
              name: 'Press five times',
              pressCount: 5,
              verified: false,
              steps: [],
            ),
          ],
        ),
        unpair: UnpairDto(
          supported: false,
          requiresFactoryReset: true,
          clears: 'Every bond.',
          procedures: [],
        ),
      ),
    );
    expect(c.headline, 'Pair it before it will answer.');
    expect(c.facts, [
      'Pairing asks for a passkey.',
      startsWith('It remembers the phone it pairs with.'),
      'Pairing code: 000000',
      'Only one phone or app can be connected to it at a time.',
      'It pairs with only one phone at a time.',
      startsWith('Not yet confirmed'),
    ]);
    expect(c.pinNotes, 'Every unit ships with it.');
    expect(c.recovery, 'Forget it on the old phone.');
    expect(c.pairingModeFacts, [
      'Put it in pairing mode first.',
      'It stays pairable for 30 seconds, so start the connect promptly.',
      'While pairable it shows up as “LOCK-PAIR”.',
      'Confirmed by: Blue LED blinks.',
    ]);
    expect(c.pairingModeProcedures.single.name, 'Press five times');
    expect(c.unpairFacts, [
      'Making it forget a paired phone takes a factory reset.',
      'Unpairing clears: Every bond.',
    ]);
    expect(
      procedureMeta(c.pairingModeProcedures.single),
      'Press 5 times · Not yet confirmed on real hardware',
    );
  });

  test('a per-unit code says where to find it, never a value', () {
    String? pinLine(String source) => PairingContent.of(
      PairingDto(pin: PairingPinDto(source: source, length: 6)),
    ).facts.singleOrNull;
    expect(
      pinLine('device_screen'),
      'The 6-character code appears on the device’s screen while pairing.',
    );
    expect(
      pinLine('printed_label'),
      'The 6-character code is printed on a label on the device.',
    );
    expect(pinLine('unknown'), 'Pairing uses a 6-character code.');
  });

  test('unknown answers and unheard-of modes say nothing', () {
    final c = PairingContent.of(
      const PairingDto(securityMode: 'unknown', bonding: 'unknown'),
    );
    expect(c.headline, isNull);
    expect(c.facts, isEmpty);
    expect(c.hasContent, isFalse);
    expect(
      PairingContent.of(const PairingDto(securityMode: 'quantum')).facts,
      isEmpty,
    );
  });

  test('a cue the procedure already gives is not repeated', () {
    final c = PairingContent.of(
      const PairingDto(
        enterPairingMode: PairingModeDto(
          indicator: 'LED blinks.',
          procedures: [
            FactoryResetProcedureDto(
              name: 'Hold',
              indicator: ' LED blinks. ',
              steps: [],
            ),
          ],
        ),
      ),
    );
    expect(c.pairingModeFacts, isEmpty);
  });

  test('a long window reads in minutes', () {
    final c = PairingContent.of(
      const PairingDto(
        enterPairingMode: PairingModeDto(windowSeconds: 180, procedures: []),
      ),
    );
    expect(
      c.pairingModeFacts.single,
      startsWith('It stays pairable for 3 minutes'),
    );
  });

  test('a reset procedure meta line is hold time only when it has one', () {
    expect(
      procedureMeta(
        const FactoryResetProcedureDto(name: 'x', holdSeconds: 15, steps: []),
      ),
      'Hold 15 s',
    );
    expect(
      procedureMeta(const FactoryResetProcedureDto(name: 'x', steps: [])),
      isNull,
    );
  });
}
