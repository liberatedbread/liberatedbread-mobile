// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// What each supported radio can do — the table the suggestion engine filters
// against and the programmer dispatches on.
//
// EVERY NUMBER IN THE CATALOGUE BELOW IS A CLAIM ABOUT HARDWARE, and the ones
// that have not been read off a radio say so in a comment. Where a value is
// uncertain the conservative direction is chosen deliberately: too small a
// channel capacity refuses a channel the radio would have taken, which the
// user sees and can report. Too large a one silently overruns the codeplug.

import 'radio_target.dart';

/// An inclusive frequency span, in Hz.
class FreqRange {
  final int lowHz;
  final int highHz;

  const FreqRange(this.lowHz, this.highHz);

  bool contains(int hz) => hz >= lowHz && hz <= highHz;

  Map<String, dynamic> toJson() => {'low': lowHz, 'high': highHz};

  static FreqRange? fromJson(Object? value) {
    if (value is! Map<String, dynamic>) return null;
    final low = value['low'];
    final high = value['high'];
    if (low is! int || high is! int || low <= 0 || high < low) return null;
    return FreqRange(low, high);
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is FreqRange && lowHz == other.lowHz && highHz == other.highHz;

  @override
  int get hashCode => Object.hash(lowHz, highHz);

  @override
  String toString() => '${lowHz / 1000000}-${highHz / 1000000} MHz';
}

/// Whether any [FreqRange] in [ranges] covers [hz].
bool rangesContain(List<FreqRange> ranges, int hz) {
  for (final range in ranges) {
    if (range.contains(hz)) return true;
  }
  return false;
}

/// Which programming protocol a radio speaks.
///
/// Informational for the profiles this build cannot drive: only
/// [ProgrammingFamily.bleUv17Pro] has a transport here. The others are
/// recorded because the plan/export half of the app serves them today and the
/// USB slice will need exactly this dispatch.
enum ProgrammingFamily {
  /// 9600 baud serial, 7-byte binary ident, `S`/`X` 0x40-byte blocks.
  serialUv5r,

  /// 115200 baud serial, 16-char ASCII ident magic, `F`/`M`/`SEND!` preamble.
  serialUv17Pro,

  /// The UV-17Pro protocol tunnelled over an HM-10-style GATT UART, with
  /// writes re-blocked to 0x80 bytes.
  bleUv17Pro;

  String get wireName => name;

  static ProgrammingFamily? fromWire(Object? value) {
    for (final family in ProgrammingFamily.values) {
      if (family.wireName == value) return family;
    }
    return null;
  }
}

/// How well this build can actually talk to a radio.
enum ProgrammerSupport {
  /// No transport in this build. Plans and CSV export still work.
  none,

  /// A driver exists and the protocol has been confirmed on this model.
  verified,

  /// A driver exists and the model is same-family, but nobody has run it
  /// against this radio. The UI says so before the first write.
  unverified;

  String get wireName => name;
}

/// How a radio's transmit limits can be widened, where they can.
enum TxUnlockMechanism {
  /// The factory band limits are fields in the codeplug; writing wider ones
  /// widens the radio. This is what CHIRP, RT Systems and the vendor CPS all
  /// expose.
  codeplugBandLimit,

  /// A GMRS-locked radio whose lock is a codeplug flag rather than a separate
  /// band-limit field.
  gmrsUnlock,

  /// No documented software path. A keypad or hardware modification is out of
  /// scope for this app, and saying so is better than pretending.
  unsupported;

  String get wireName => name;
}

/// A radio's transmit-range unlock capability.
///
/// Configuring a wider transmit range is legal; transmitting outside your own
/// authorization is not. The app models the capability here, ships it off by
/// default, and gates enabling it behind an explicit operator acknowledgement.
class TxUnlock {
  final bool supported;

  /// The ranges the radio can reach once unlocked. Empty when unsupported.
  final List<FreqRange> expandedTxRanges;

  final TxUnlockMechanism mechanism;

  /// Whether the band-limit field layout has been confirmed on this model, as
  /// opposed to inferred from a same-family radio. An unverified unlock is
  /// still offered — with the uncertainty said out loud — because the write
  /// path reads the existing limits back before and after, and always keeps a
  /// full codeplug backup.
  final bool verified;

  final String notes;

  const TxUnlock({
    required this.supported,
    required this.mechanism,
    this.expandedTxRanges = const [],
    this.verified = false,
    this.notes = '',
  });

  static const TxUnlock unsupported = TxUnlock(
    supported: false,
    mechanism: TxUnlockMechanism.unsupported,
    notes:
        'No documented software path on this model. Widening its transmit '
        'range would need a hardware or keypad modification, which this app '
        'does not do.',
  );

  Map<String, dynamic> toJson() => {
    'supported': supported,
    'mechanism': mechanism.wireName,
    'ranges': [for (final range in expandedTxRanges) range.toJson()],
    'verified': verified,
    if (notes.isNotEmpty) 'notes': notes,
  };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is TxUnlock &&
          supported == other.supported &&
          mechanism == other.mechanism &&
          verified == other.verified &&
          notes == other.notes &&
          _listEquals(expandedTxRanges, other.expandedTxRanges);

  @override
  int get hashCode => Object.hash(
    supported,
    mechanism,
    verified,
    notes,
    Object.hashAll(expandedTxRanges),
  );
}

bool _listEquals<T>(List<T> a, List<T> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// One supported radio.
class RadioProfile {
  final String id;
  final String displayName;

  /// What the receiver can tune. A suggestion outside this is dropped: there
  /// is no point offering someone a channel their radio cannot hear.
  final List<FreqRange> rxRanges;

  /// What the transmitter reaches as it left the factory.
  final List<FreqRange> factoryTxRanges;

  /// A GMRS radio: fixed channel plan, tx limited to the GMRS allocation.
  final bool gmrsLocked;

  final int channelCapacity;

  /// Longest channel name the radio's display and codeplug will hold.
  final int nameLength;

  final bool supportsCtcss;
  final bool supportsDcs;
  final ProgrammingFamily programmingFamily;
  final ProgrammerSupport programmerSupport;
  final TxUnlock txUnlock;

  const RadioProfile({
    required this.id,
    required this.displayName,
    required this.rxRanges,
    required this.factoryTxRanges,
    required this.channelCapacity,
    required this.nameLength,
    required this.programmingFamily,
    this.gmrsLocked = false,
    this.supportsCtcss = true,
    this.supportsDcs = true,
    this.programmerSupport = ProgrammerSupport.none,
    this.txUnlock = TxUnlock.unsupported,
  });

  /// Whether this build can read and write this radio directly.
  bool get isProgrammable => programmerSupport != ProgrammerSupport.none;

  /// Whether this build can program this radio over [transport].
  ///
  /// Follows from the protocol family: the UV-17Pro protocol runs over the
  /// radio's own Bluetooth on the models that have it, and both serial
  /// families over a cable.
  bool programsOver(RadioTransport transport) =>
      isProgrammable &&
      switch (transport) {
        RadioTransport.ble => programmingFamily == ProgrammingFamily.bleUv17Pro,
        RadioTransport.usb =>
          programmingFamily == ProgrammingFamily.serialUv5r ||
              programmingFamily == ProgrammingFamily.serialUv17Pro,
      };

  /// The link this build programs this radio over, or null when it cannot.
  /// Each family speaks over exactly one.
  RadioTransport? get programmingTransport {
    for (final transport in RadioTransport.values) {
      if (programsOver(transport)) return transport;
    }
    return null;
  }

  /// The transmit ranges in force for a suggestion run.
  ///
  /// [unlockEnabled] only widens anything when the profile actually supports
  /// an unlock — a flag left on while a different radio is selected must not
  /// silently grant that radio a range it does not have.
  List<FreqRange> effectiveTxRanges({required bool unlockEnabled}) {
    if (!unlockEnabled || !txUnlock.supported) return factoryTxRanges;
    return [...factoryTxRanges, ...txUnlock.expandedTxRanges];
  }

  bool canReceive(int hz) => rangesContain(rxRanges, hz);

  bool canTransmit(int hz, {required bool unlockEnabled}) =>
      rangesContain(effectiveTxRanges(unlockEnabled: unlockEnabled), hz);

  /// Whether [hz] is only transmittable because the unlock is on — the
  /// condition the UI badges.
  bool needsUnlockToTransmit(int hz) =>
      !rangesContain(factoryTxRanges, hz) &&
      txUnlock.supported &&
      rangesContain(txUnlock.expandedTxRanges, hz);

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is RadioProfile && id == other.id;

  @override
  int get hashCode => id.hashCode;

  @override
  String toString() => 'RadioProfile($id)';
}

// ---------------------------------------------------------------------------
// The catalogue.
// ---------------------------------------------------------------------------

/// Broadcast FM, which every one of these radios receives and none transmits.
const _fmBroadcast = FreqRange(65000000, 108000000);

/// The classic Baofeng dual-band coverage.
const _vhfRx = FreqRange(136000000, 174000000);
const _uhfRx = FreqRange(400000000, 520000000);

/// The GMRS allocation: 462.5500-462.7250 (channels + repeater outputs) and
/// the 467 MHz repeater inputs. Modelled as two spans rather than 30 discrete
/// channels because the filter's question is "can it transmit here".
const _gmrsLow = FreqRange(462550000, 462725000);
const _gmrsHigh = FreqRange(467550000, 467725000);

/// The soft band limits an unlocked UV-5R-family radio accepts.
///
/// These are the spans that family's settings-memory band-limit fields can
/// express, not a promise the PA is happy across them — a widened radio
/// transmits poorly at the edges.
///
/// THE UV-17Pro FAMILY HAS NO SUCH FIELD. The band-limit pair (a lower, an
/// upper and an enable flag, per band) exists in the *older* UV-5R serial
/// codeplug and is what a software MARS/CAP modification edits. The newer
/// family — the Minis, the UV-32, the UV-17R Plus — does not expose one, so
/// those profiles say the unlock is unsupported rather than offering a switch
/// that could not do anything. This was the assumption the plan got wrong,
/// and it is the wrong way round from convenient: the radios this build can
/// program over Bluetooth are exactly the ones with no unlock.
const _uv5rExpandedVhf = FreqRange(130000000, 179995000);
const _uv5rExpandedUhf = FreqRange(400000000, 520000000);

/// Why the UV-17Pro family's profiles carry no unlock.
const _noBandLimitField =
    'This radio stores no adjustable band limits. Its transmit range is set '
    'in firmware, so no programming software — this app, CHIRP or the '
    'manufacturer\'s own — can widen it.';

/// UV-5R family: UV-5R itself, and the variants that program identically.
const RadioProfile uv5rProfile = RadioProfile(
  id: 'uv5r',
  displayName: 'Baofeng UV-5R (and UV-82, GT-5R)',
  rxRanges: [_fmBroadcast, _vhfRx, _uhfRx],
  factoryTxRanges: [
    FreqRange(144000000, 148000000),
    FreqRange(420000000, 450000000),
  ],
  channelCapacity: 128,
  // CHIRP's uv5r driver writes 7-character names. Verify on hardware.
  nameLength: 7,
  programmingFamily: ProgrammingFamily.serialUv5r,
  // A cable driver exists; nothing in it has been run against a radio.
  programmerSupport: ProgrammerSupport.unverified,
  txUnlock: TxUnlock(
    supported: true,
    mechanism: TxUnlockMechanism.codeplugBandLimit,
    expandedTxRanges: [_uv5rExpandedVhf, _uv5rExpandedUhf],
    notes:
        'The factory transmit limits are fields in the radio\'s own '
        'settings memory. Widening them is what a MARS/CAP modification does '
        'in software.',
  ),
);

const RadioProfile bfF8hpProfile = RadioProfile(
  id: 'bf-f8hp',
  displayName: 'BaoFeng BF-F8HP',
  rxRanges: [_fmBroadcast, _vhfRx, _uhfRx],
  factoryTxRanges: [
    FreqRange(144000000, 148000000),
    FreqRange(420000000, 450000000),
  ],
  channelCapacity: 128,
  nameLength: 7,
  programmingFamily: ProgrammingFamily.serialUv5r,
  programmerSupport: ProgrammerSupport.unverified,
  txUnlock: TxUnlock(
    supported: true,
    mechanism: TxUnlockMechanism.codeplugBandLimit,
    expandedTxRanges: [_uv5rExpandedVhf, _uv5rExpandedUhf],
    notes: 'Same settings-memory band limits as the UV-5R it is built from.',
  ),
);

/// AR-152: programs as a BF-F8HP (CHIRP issue #9755).
const RadioProfile ar152Profile = RadioProfile(
  id: 'ar-152',
  displayName: 'Baofeng AR-152',
  rxRanges: [_fmBroadcast, _vhfRx, _uhfRx],
  factoryTxRanges: [
    FreqRange(144000000, 148000000),
    FreqRange(420000000, 450000000),
  ],
  channelCapacity: 128,
  nameLength: 7,
  programmingFamily: ProgrammingFamily.serialUv5r,
  programmerSupport: ProgrammerSupport.unverified,
  txUnlock: TxUnlock(
    supported: true,
    mechanism: TxUnlockMechanism.codeplugBandLimit,
    expandedTxRanges: [_uv5rExpandedVhf, _uv5rExpandedUhf],
    notes:
        'Programs as a BF-F8HP; the band-limit fields sit in the same '
        'place. Not confirmed on an AR-152 itself.',
  ),
);

/// UV-5G: a GMRS radio built on the UV-5R.
///
/// Not programmable here. It answers an ident of its own, and the driver the
/// UV-5R layout comes from deliberately refuses that ident: whatever its
/// memory looks like, it is not a UV-5R's, and nothing here should write one
/// as if it were. Plans and CHIRP export still work.
const RadioProfile uv5gProfile = RadioProfile(
  id: 'uv-5g',
  displayName: 'Baofeng UV-5G (GMRS)',
  rxRanges: [_fmBroadcast, _vhfRx, _uhfRx],
  factoryTxRanges: [_gmrsLow, _gmrsHigh],
  gmrsLocked: true,
  channelCapacity: 128,
  nameLength: 7,
  programmingFamily: ProgrammingFamily.serialUv5r,
  txUnlock: TxUnlock(
    supported: false,
    mechanism: TxUnlockMechanism.unsupported,
    notes:
        'This app does not know how this radio stores its GMRS '
        'restriction: its memory is not laid out like a UV-5R\'s, so the '
        'UV-5R\'s band-limit fields say nothing about it.',
  ),
);

/// UV-5R Mini: UV-17Pro protocol, and the first radio this app programs over
/// its own Bluetooth, with no cable and no dongle.
const RadioProfile uv5rMiniProfile = RadioProfile(
  id: 'uv-5r-mini',
  displayName: 'Baofeng UV-5R Mini',
  rxRanges: [_fmBroadcast, _vhfRx, _uhfRx],
  factoryTxRanges: [
    FreqRange(144000000, 148000000),
    FreqRange(420000000, 450000000),
  ],
  channelCapacity: 999,
  nameLength: 12,
  programmingFamily: ProgrammingFamily.bleUv17Pro,
  programmerSupport: ProgrammerSupport.verified,
  txUnlock: TxUnlock(
    supported: false,
    mechanism: TxUnlockMechanism.unsupported,
    notes: _noBandLimitField,
  ),
);

/// Mini 5 / UV-5G Mini: the GMRS Mini. Same tunnel, same protocol.
const RadioProfile uv5gMiniProfile = RadioProfile(
  id: 'uv-5g-mini',
  displayName: 'Baofeng Mini 5 / UV-5G Mini (GMRS)',
  rxRanges: [_fmBroadcast, _vhfRx, _uhfRx],
  factoryTxRanges: [_gmrsLow, _gmrsHigh],
  gmrsLocked: true,
  channelCapacity: 999,
  nameLength: 12,
  programmingFamily: ProgrammingFamily.bleUv17Pro,
  programmerSupport: ProgrammerSupport.verified,
  txUnlock: TxUnlock(
    supported: false,
    mechanism: TxUnlockMechanism.unsupported,
    notes: _noBandLimitField,
  ),
);

/// UV-32: same family by every public account, but nobody has posted a
/// capture. The driver will run; the app says it is unconfirmed first.
const RadioProfile uv32Profile = RadioProfile(
  id: 'uv-32',
  displayName: 'Baofeng UV-32',
  rxRanges: [_fmBroadcast, _vhfRx, _uhfRx],
  factoryTxRanges: [
    FreqRange(144000000, 148000000),
    FreqRange(420000000, 450000000),
  ],
  channelCapacity: 999,
  nameLength: 12,
  programmingFamily: ProgrammingFamily.bleUv17Pro,
  programmerSupport: ProgrammerSupport.unverified,
  txUnlock: TxUnlock(
    supported: false,
    mechanism: TxUnlockMechanism.unsupported,
    notes: _noBandLimitField,
  ),
);

/// UV-17R Plus: UV-17Pro serial family. No transport in this build.
const RadioProfile uv17rPlusProfile = RadioProfile(
  id: 'uv-17r-plus',
  displayName: 'Baofeng UV-17R Plus',
  rxRanges: [_fmBroadcast, _vhfRx, _uhfRx],
  factoryTxRanges: [
    FreqRange(144000000, 148000000),
    FreqRange(420000000, 450000000),
  ],
  channelCapacity: 1000,
  nameLength: 12,
  programmingFamily: ProgrammingFamily.serialUv17Pro,
  txUnlock: TxUnlock(
    supported: false,
    mechanism: TxUnlockMechanism.unsupported,
    notes: _noBandLimitField,
  ),
);

/// Every radio the app knows, in the order the picker shows them.
const List<RadioProfile> radioProfiles = [
  uv5rProfile,
  bfF8hpProfile,
  uv5rMiniProfile,
  uv5gMiniProfile,
  uv32Profile,
  uv17rPlusProfile,
  uv5gProfile,
  ar152Profile,
];

/// The profile with [id], or null if this build has never heard of it — which
/// happens when a stored selection outlives the build that wrote it.
RadioProfile? radioProfileById(String? id) {
  if (id == null) return null;
  for (final profile in radioProfiles) {
    if (profile.id == id) return profile;
  }
  return null;
}

/// What the app selects until the user chooses: the radio it can actually
/// program.
const RadioProfile defaultRadioProfile = uv5rMiniProfile;

/// Every radio this build can program over [transport], in catalogue order.
List<RadioProfile> profilesProgrammableOver(RadioTransport transport) => [
  for (final profile in radioProfiles)
    if (profile.programsOver(transport)) profile,
];
