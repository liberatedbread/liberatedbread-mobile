// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// The transmit limits a radio stores for itself, where it stores any.

import 'package:flutter/foundation.dart';

import 'radio_profile.dart';

/// One band's transmit limits, as the radio holds them: whole megahertz, and
/// whether it may transmit in the band at all.
///
/// Whether the radio counts the upper megahertz as allowed — 174 meaning up
/// to 174.995, or only up to 174.000 — is one of the things only a real
/// radio can say, and nothing here assumes either.
@immutable
class BandLimit {
  final bool txEnabled;
  final int lowerMhz;
  final int upperMhz;

  const BandLimit({
    required this.txEnabled,
    required this.lowerMhz,
    required this.upperMhz,
  });

  /// `136–174 MHz`, or `136–174 MHz, transmit off`.
  String get label =>
      '$lowerMhz–$upperMhz MHz${txEnabled ? '' : ', transmit off'}';

  Map<String, dynamic> toJson() => {
        'tx': txEnabled,
        'lower': lowerMhz,
        'upper': upperMhz,
      };

  static BandLimit? fromJson(Object? json) {
    if (json is! Map<String, dynamic>) return null;
    final tx = json['tx'];
    final lower = json['lower'];
    final upper = json['upper'];
    if (tx is! bool || lower is! int || upper is! int) return null;
    return BandLimit(txEnabled: tx, lowerMhz: lower, upperMhz: upper);
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is BandLimit &&
          txEnabled == other.txEnabled &&
          lowerMhz == other.lowerMhz &&
          upperMhz == other.upperMhz;

  @override
  int get hashCode => Object.hash(txEnabled, lowerMhz, upperMhz);

  @override
  String toString() => 'BandLimit($label)';
}

/// Both bands' stored transmit limits.
///
/// Only the older serial family has these (see `_uv5rExpandedVhf` in
/// radio_profile.dart for which radios, and why the newer family has none).
@immutable
class RadioBandLimits {
  final BandLimit vhf;
  final BandLimit uhf;

  const RadioBandLimits({required this.vhf, required this.uhf});

  /// The limits [profile]'s unlock widens a radio to, or null for a profile
  /// with no unlock.
  ///
  /// Taken from the profile's expanded ranges, so the radio is widened to
  /// exactly what the suggestions and the acknowledgement say it will be —
  /// rounded down to the whole megahertz the fields hold.
  static RadioBandLimits? widenedFor(RadioProfile profile) {
    final unlock = profile.txUnlock;
    if (!unlock.supported) return null;
    BandLimit? band(bool Function(FreqRange range) inBand) {
      final range = unlock.expandedTxRanges.where(inBand).firstOrNull;
      if (range == null) return null;
      return BandLimit(
        txEnabled: true,
        lowerMhz: range.lowHz ~/ 1000000,
        upperMhz: range.highHz ~/ 1000000,
      );
    }

    final vhf = band((r) => r.lowHz < 300000000);
    final uhf = band((r) => r.lowHz >= 300000000);
    if (vhf == null || uhf == null) return null;
    return RadioBandLimits(vhf: vhf, uhf: uhf);
  }

  /// `VHF 136–174 MHz and UHF 400–520 MHz`.
  String get label => 'VHF ${vhf.label} and UHF ${uhf.label}';

  Map<String, dynamic> toJson() => {'vhf': vhf.toJson(), 'uhf': uhf.toJson()};

  /// Null for anything that is not a pair of readable limits.
  static RadioBandLimits? fromJson(Object? json) {
    if (json is! Map<String, dynamic>) return null;
    final vhf = BandLimit.fromJson(json['vhf']);
    final uhf = BandLimit.fromJson(json['uhf']);
    if (vhf == null || uhf == null) return null;
    return RadioBandLimits(vhf: vhf, uhf: uhf);
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is RadioBandLimits && vhf == other.vhf && uhf == other.uhf;

  @override
  int get hashCode => Object.hash(vhf, uhf);

  @override
  String toString() => 'RadioBandLimits($label)';
}

/// The limits a radio had before this app first widened one of its model.
///
/// Recorded per model rather than per radio because a cable radio cannot be
/// told apart from another of its model — the ident names the model and the
/// firmware, never the unit. Radios of one model leave the factory with the
/// same limits, so this is almost always the right thing to put back; and
/// putting it back always shows the values first, so it is never a
/// surprise when it is not.
@immutable
class OriginalBandLimits {
  final RadioBandLimits limits;

  /// When the radio they were read from was read.
  final DateTime readAt;

  const OriginalBandLimits({required this.limits, required this.readAt});

  Map<String, dynamic> toJson() => {
        ...limits.toJson(),
        'readAt': readAt.toUtc().toIso8601String(),
      };

  static OriginalBandLimits? fromJson(Object? json) {
    if (json is! Map<String, dynamic>) return null;
    final limits = RadioBandLimits.fromJson(json);
    final readAt = DateTime.tryParse(json['readAt'] as String? ?? '');
    if (limits == null || readAt == null) return null;
    return OriginalBandLimits(limits: limits, readAt: readAt);
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is OriginalBandLimits &&
          limits == other.limits &&
          readAt == other.readAt;

  @override
  int get hashCode => Object.hash(limits, readAt);
}
