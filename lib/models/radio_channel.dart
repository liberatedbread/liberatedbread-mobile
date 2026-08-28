// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// One memory channel, in the form every radio in the catalogue can express.

/// How a channel squelches: not at all, on an analogue sub-audible tone
/// (CTCSS), or on a digital code (DCS/DCG).
enum ToneMode {
  none,
  ctcss,
  dcs;

  String get wireName => name;

  static ToneMode? fromWire(Object? value) {
    for (final mode in ToneMode.values) {
      if (mode.wireName == value) return mode;
    }
    return null;
  }
}

/// Channel bandwidth. Wide (25 kHz) or narrow (12.5 kHz) — the only two any
/// radio here offers, and the only two CHIRP's generic CSV can name.
enum ChannelMode {
  fm,
  nfm;

  String get wireName => name;

  /// The token CHIRP's generic CSV uses in its `Mode` column.
  String get chirpName => this == ChannelMode.nfm ? 'NFM' : 'FM';

  static ChannelMode? fromWire(Object? value) {
    for (final mode in ChannelMode.values) {
      if (mode.wireName == value) return mode;
    }
    return null;
  }
}

/// Transmit power. Deliberately two levels: the mid setting exists on some of
/// these radios and not others, and a plan that survives being retargeted at a
/// different model is worth more than one that carries a level half the
/// catalogue would have to round anyway.
enum PowerLevel {
  high,
  low;

  String get wireName => name;

  static PowerLevel? fromWire(Object? value) {
    for (final level in PowerLevel.values) {
      if (level.wireName == value) return level;
    }
    return null;
  }
}

/// The 50 standard CTCSS tones, in tenths of a Hz.
///
/// Tenths of a Hz as an int rather than a double for the reason every
/// frequency in this file is an int: 107.2 is not representable in binary
/// floating point, so a channel that round-tripped through JSON could stop
/// comparing equal to the one the user picked from this very list.
const List<int> ctcssTonesTenthHz = [
  670, 693, 719, 744, 770, 797, 825, 854, 885, 915, //
  948, 974, 1000, 1035, 1072, 1109, 1148, 1188, 1230, 1273,
  1318, 1365, 1413, 1462, 1514, 1567, 1598, 1622, 1655, 1679,
  1713, 1738, 1773, 1799, 1835, 1862, 1899, 1928, 1966, 1995,
  2035, 2065, 2107, 2181, 2257, 2291, 2336, 2418, 2503, 2541,
];

/// The 104 standard DCS codes, written the way they are spoken and printed —
/// as octal-looking three-digit numbers.
const List<int> dcsCodes = [
  23, 25, 26, 31, 32, 36, 43, 47, 51, 53, 54, 65, 71, 72, 73, 74, //
  114, 115, 116, 122, 125, 131, 132, 134, 143, 145, 152, 155, 156,
  162, 165, 172, 174, 205, 212, 223, 225, 226, 243, 244, 245, 246,
  251, 252, 255, 261, 263, 265, 266, 271, 274, 306, 311, 315, 325,
  331, 332, 343, 346, 351, 356, 364, 365, 371, 411, 412, 413, 423,
  431, 432, 445, 446, 452, 454, 455, 462, 464, 465, 466, 503, 506,
  516, 523, 526, 532, 546, 565, 606, 612, 624, 627, 631, 632, 654,
  662, 664, 703, 712, 723, 731, 732, 734, 743, 754,
];

/// The squelch setting for one direction of one channel.
class ToneSetting {
  final ToneMode mode;

  /// CTCSS tone in tenths of a Hz; 0 unless [mode] is [ToneMode.ctcss].
  final int ctcssTenthHz;

  /// DCS code; 0 unless [mode] is [ToneMode.dcs].
  final int dcsCode;

  /// DCS polarity. Inverted codes are written `D023N` vs `D023I` on radios and
  /// `NN`/`NR`/`RN`/`RR` in CHIRP's `DtcsPolarity` column.
  final bool dcsInverted;

  const ToneSetting._({
    required this.mode,
    this.ctcssTenthHz = 0,
    this.dcsCode = 0,
    this.dcsInverted = false,
  });

  static const ToneSetting none = ToneSetting._(mode: ToneMode.none);

  const ToneSetting.ctcss(int tenthHz)
      : this._(mode: ToneMode.ctcss, ctcssTenthHz: tenthHz);

  const ToneSetting.dcs(int code, {bool inverted = false})
      : this._(mode: ToneMode.dcs, dcsCode: code, dcsInverted: inverted);

  bool get isNone => mode == ToneMode.none;

  /// How the tone reads on a radio's own display: `100.0`, `D023N`, or empty.
  String get label => switch (mode) {
        ToneMode.none => '',
        ToneMode.ctcss => (ctcssTenthHz / 10).toStringAsFixed(1),
        ToneMode.dcs =>
          'D${dcsCode.toString().padLeft(3, '0')}${dcsInverted ? 'I' : 'N'}',
      };

  Map<String, dynamic> toJson() => {
        'mode': mode.wireName,
        if (mode == ToneMode.ctcss) 'ctcss': ctcssTenthHz,
        if (mode == ToneMode.dcs) 'dcs': dcsCode,
        if (mode == ToneMode.dcs && dcsInverted) 'inverted': true,
      };

  /// Never null: a tone that cannot be read is no tone, which is the setting
  /// that cannot key anything unexpected. A channel is still usable without
  /// its tone; dropping the whole channel over one unreadable field would lose
  /// more than it protects.
  static ToneSetting fromJson(Object? value) {
    if (value is! Map<String, dynamic>) return none;
    final mode = ToneMode.fromWire(value['mode']);
    switch (mode) {
      case ToneMode.ctcss:
        final tone = value['ctcss'];
        if (tone is! int || tone <= 0) return none;
        return ToneSetting.ctcss(tone);
      case ToneMode.dcs:
        final code = value['dcs'];
        if (code is! int || code <= 0) return none;
        return ToneSetting.dcs(code, inverted: value['inverted'] == true);
      case ToneMode.none:
      case null:
        return none;
    }
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ToneSetting &&
          mode == other.mode &&
          ctcssTenthHz == other.ctcssTenthHz &&
          dcsCode == other.dcsCode &&
          dcsInverted == other.dcsInverted;

  @override
  int get hashCode => Object.hash(mode, ctcssTenthHz, dcsCode, dcsInverted);

  @override
  String toString() => isNone ? 'ToneSetting.none' : 'ToneSetting($label)';
}

/// A single memory channel.
///
/// Frequencies are integer Hz throughout. A repeater output of 146.94 MHz is
/// 146940000 — exact, comparable, and dedupe-able. Held as a double it is
/// 146.94000000000001 on one path and 146.93999999999998 on another, and two
/// listings of the same repeater stop matching.
class RadioChannel {
  final String name;
  final int rxFreqHz;
  final int txFreqHz;

  /// Receive-only. Set for weather stations, and for anything outside the
  /// radio's transmit range — the radio is told `duplex=off` so a stray PTT
  /// cannot key it.
  final bool rxOnly;

  /// Tone sent while transmitting (a repeater's access tone).
  final ToneSetting txTone;

  /// Tone required to open the squelch on receive. Usually none: tone squelch
  /// silences the channel when the repeater is not sending the tone, which
  /// costs you every simplex station on the same frequency.
  final ToneSetting rxTone;

  final ChannelMode mode;
  final PowerLevel power;
  final String comment;

  const RadioChannel({
    required this.name,
    required this.rxFreqHz,
    required this.txFreqHz,
    this.rxOnly = false,
    this.txTone = ToneSetting.none,
    this.rxTone = ToneSetting.none,
    this.mode = ChannelMode.fm,
    this.power = PowerLevel.high,
    this.comment = '',
  });

  /// A receive-only channel: transmit frequency mirrors receive so that a
  /// radio which ignores the rx-only flag still cannot transmit somewhere
  /// unexpected — the worst it can do is key on the frequency it is listening
  /// to, which is what a simplex channel does anyway.
  const RadioChannel.receiveOnly({
    required this.name,
    required int freqHz,
    this.rxTone = ToneSetting.none,
    this.mode = ChannelMode.fm,
    this.power = PowerLevel.low,
    this.comment = '',
  })  : rxFreqHz = freqHz,
        txFreqHz = freqHz,
        rxOnly = true,
        txTone = ToneSetting.none;

  /// Repeater shift in Hz: positive for an input above the output, negative
  /// below, zero for simplex.
  int get offsetHz => txFreqHz - rxFreqHz;

  bool get isSimplex => txFreqHz == rxFreqHz;

  RadioChannel copyWith({
    String? name,
    int? rxFreqHz,
    int? txFreqHz,
    bool? rxOnly,
    ToneSetting? txTone,
    ToneSetting? rxTone,
    ChannelMode? mode,
    PowerLevel? power,
    String? comment,
  }) =>
      RadioChannel(
        name: name ?? this.name,
        rxFreqHz: rxFreqHz ?? this.rxFreqHz,
        txFreqHz: txFreqHz ?? this.txFreqHz,
        rxOnly: rxOnly ?? this.rxOnly,
        txTone: txTone ?? this.txTone,
        rxTone: rxTone ?? this.rxTone,
        mode: mode ?? this.mode,
        power: power ?? this.power,
        comment: comment ?? this.comment,
      );

  Map<String, dynamic> toJson() => {
        'name': name,
        'rx': rxFreqHz,
        'tx': txFreqHz,
        if (rxOnly) 'rxOnly': true,
        if (!txTone.isNone) 'txTone': txTone.toJson(),
        if (!rxTone.isNone) 'rxTone': rxTone.toJson(),
        'mode': mode.wireName,
        'power': power.wireName,
        if (comment.isNotEmpty) 'comment': comment,
      };

  /// Returns null for a record that cannot be read, so one corrupt channel
  /// costs its own slot and not the rest of the plan.
  static RadioChannel? fromJson(Map<String, dynamic> json) {
    final name = json['name'];
    final rx = json['rx'];
    final tx = json['tx'];
    if (name is! String || rx is! int || rx <= 0) return null;
    return RadioChannel(
      name: name,
      rxFreqHz: rx,
      // A missing transmit frequency means simplex rather than a dropped
      // record: that is what a listing with no offset describes.
      txFreqHz: tx is int && tx > 0 ? tx : rx,
      rxOnly: json['rxOnly'] == true,
      txTone: ToneSetting.fromJson(json['txTone']),
      rxTone: ToneSetting.fromJson(json['rxTone']),
      mode: ChannelMode.fromWire(json['mode']) ?? ChannelMode.fm,
      power: PowerLevel.fromWire(json['power']) ?? PowerLevel.high,
      comment: json['comment'] is String ? json['comment'] as String : '',
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is RadioChannel &&
          name == other.name &&
          rxFreqHz == other.rxFreqHz &&
          txFreqHz == other.txFreqHz &&
          rxOnly == other.rxOnly &&
          txTone == other.txTone &&
          rxTone == other.rxTone &&
          mode == other.mode &&
          power == other.power &&
          comment == other.comment;

  @override
  int get hashCode => Object.hash(
        name,
        rxFreqHz,
        txFreqHz,
        rxOnly,
        txTone,
        rxTone,
        mode,
        power,
        comment,
      );

  @override
  String toString() => 'RadioChannel($name, rx=$rxFreqHz, tx=$txFreqHz)';
}
