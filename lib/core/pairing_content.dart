// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import '../services/spec_codec.dart'
    show FactoryResetProcedureDto, PairingDto, PairingPinDto;
import 'setup_content.dart';

/// A spec's `device.pairing` block as plain sentences, in reading order.
///
/// The ONE reading of the block, shared by the setup screen and its printout
/// so the two cannot word the same fact differently. Every catalogue spec
/// carries the block — on Bluetooth "nothing pairs" is the usual answer, on
/// Wi-Fi it says how a client gets authorised — so the negative answers are
/// content too: "No pairing needed" is what stops someone hunting for a
/// pairing button that does not exist.
class PairingContent {
  /// The answer to "do I have to pair it?", when the spec gives one.
  final String? headline;

  /// Short facts under the headline: how pairing is authenticated, whether
  /// the device remembers a phone, the code, one-client-at-a-time limits.
  final List<String> facts;

  /// The PIN's own notes ("six hexadecimal characters"), kept beside the
  /// code line rather than buried in the technical notes.
  final String? pinNotes;

  /// What to do when another phone or app is holding the device.
  final String? recovery;

  /// Facts about the pairing-mode window: whether it is needed, how long it
  /// stays open, the name it advertises, how to tell it worked.
  final List<String> pairingModeFacts;
  final List<FactoryResetProcedureDto> pairingModeProcedures;

  /// Facts about forgetting a paired client.
  final List<String> unpairFacts;
  final List<FactoryResetProcedureDto> unpairProcedures;

  /// The catalogue's longer prose — written for implementers as much as for
  /// owners, so the screen tucks it away.
  final List<String> technicalNotes;

  const PairingContent._({
    required this.headline,
    required this.facts,
    required this.pinNotes,
    required this.recovery,
    required this.pairingModeFacts,
    required this.pairingModeProcedures,
    required this.unpairFacts,
    required this.unpairProcedures,
    required this.technicalNotes,
  });

  factory PairingContent.of(PairingDto p) {
    String? text(String? s) => hasSetupText(s) ? s!.trim() : null;

    final mode = p.enterPairingMode;
    final unpair = p.unpair;
    final exclusivity = p.exclusivity;

    final facts = <String>[
      ?_securityFact(p.securityMode),
      ?_bondingFact(p.bonding),
      if (p.pin case final pin?) ?_pinFact(pin),
      if (exclusivity?.singleConnection == true)
        'Only one phone or app can be connected to it at a time.',
      if (exclusivity?.singleBond == true)
        'It pairs with only one phone at a time.',
      if (p.confidence == 'low')
        'Not yet confirmed: the catalogue infers this rather than having '
            'tested it.',
    ];

    final modeFacts = <String>[
      if (mode != null) ...[
        if (mode.required_ == true) 'Put it in pairing mode first.',
        if (mode.windowSeconds case final s? when s > 0)
          'It stays pairable for ${_seconds(s)}, so start the connect '
              'promptly.',
        if (text(mode.advertisedName) case final name?)
          'While pairable it shows up as “$name”.',
        // Specs often repeat the cue on the procedure that produces it; the
        // procedure prints its own, so say it once.
        if (text(mode.indicator) case final indicator?
            when !mode.procedures.any((p) => p.indicator?.trim() == indicator))
          'Confirmed by: $indicator',
        ?text(mode.notes),
      ],
    ];

    final unpairFacts = <String>[
      if (unpair != null) ...[
        if (unpair.requiresFactoryReset == true)
          'Making it forget a paired phone takes a factory reset.'
        else if (unpair.supported == false)
          'It cannot be told to forget a paired phone.',
        if (text(unpair.clears) case final clears?) 'Unpairing clears: $clears',
        ?text(unpair.notes),
      ],
    ];

    return PairingContent._(
      headline: switch (p.required_) {
        true => 'Pair it before it will answer.',
        false => 'No pairing needed.',
        null => null,
      },
      facts: facts,
      pinNotes: text(p.pin?.notes),
      recovery: text(exclusivity?.recovery),
      pairingModeFacts: modeFacts,
      pairingModeProcedures: mode?.procedures ?? const [],
      unpairFacts: unpairFacts,
      unpairProcedures: unpair?.procedures ?? const [],
      technicalNotes: [?text(exclusivity?.notes), ?text(p.notes)],
    );
  }

  /// Whether there is anything to show. A block whose every answer is
  /// `unknown` reads as nothing, and gets no section.
  bool get hasContent =>
      headline != null ||
      facts.isNotEmpty ||
      pinNotes != null ||
      recovery != null ||
      hasPairingMode ||
      hasUnpair ||
      technicalNotes.isNotEmpty;

  bool get hasPairingMode =>
      pairingModeFacts.isNotEmpty || pairingModeProcedures.isNotEmpty;

  bool get hasUnpair => unpairFacts.isNotEmpty || unpairProcedures.isNotEmpty;

  static String _seconds(int s) => s % 60 == 0 && s >= 120
      ? '${s ~/ 60} minutes'
      : '$s second${s == 1 ? '' : 's'}';

  /// How the pairing is authenticated, in an owner's words. `unknown` and a
  /// mode this build has never heard of say nothing rather than guess.
  static String? _securityFact(String? mode) => switch (mode) {
    'none' =>
      'Nothing to pair: any phone or client that can reach it is '
          'answered.',
    'just_works' => 'Pairs automatically, with no code to enter.',
    'passkey_entry' => 'Pairing asks for a passkey.',
    'numeric_comparison' =>
      'Pairing shows a number to confirm matches on both sides.',
    'out_of_band' =>
      'Pairing exchanges its key another way, such as NFC or a QR code.',
    'legacy_pin' => 'Pairing asks for a PIN.',
    'network_join' =>
      'It joins a hub’s network rather than pairing with a phone; remove it '
          'from one hub before adding it to another.',
    'app_layer' =>
      'Access is granted by a code or key exchange inside the app’s '
          'protocol, not by Bluetooth or Wi-Fi pairing.',
    _ => null,
  };

  static String? _bondingFact(String? bonding) => switch (bonding) {
    'required' =>
      'It remembers the phone it pairs with. If that phone forgets it, clear '
          'the pairing on the device too, or it will refuse to reconnect.',
    'optional' => 'It can remember a phone that pairs with it.',
    _ => null,
  };

  static String? _pinFact(PairingPinDto pin) {
    final length = pin.length == null ? '' : '${pin.length}-character ';
    final value = (pin.value ?? '').trim();
    // A value is only ever a product-wide default: the schema forbids a
    // per-unit secret, so printing it here hands out nothing private.
    if (value.isNotEmpty) return 'Pairing code: $value';
    return switch (pin.source) {
      'fixed_default' =>
        'The ${length}code is the same for every unit of this product.',
      'printed_label' =>
        'The ${length}code is printed on a label on the '
            'device.',
      'device_screen' =>
        'The ${length}code appears on the device’s screen '
            'while pairing.',
      'vendor_app' => 'The ${length}code comes from the vendor’s app.',
      'derived' => 'The ${length}code is worked out from the device itself.',
      'user_chosen' => 'The ${length}code is one you set.',
      _ when length.isNotEmpty => 'Pairing uses a ${length}code.',
      _ => null,
    };
  }
}

/// The meta line under a hardware procedure's name: how long to hold, how
/// many presses, and whether anyone has run it on real hardware.
String? procedureMeta(FactoryResetProcedureDto p) {
  final parts = [
    if (p.holdSeconds case final s? when s > 0) 'Hold $s s',
    if (p.pressCount case final n? when n > 1) 'Press $n times',
    if (p.verified == false) 'Not yet confirmed on real hardware',
  ];
  return parts.isEmpty ? null : parts.join(' · ');
}
