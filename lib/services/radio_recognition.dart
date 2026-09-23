// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// Is this Bluetooth device a radio?

import 'package:flutter/foundation.dart';

import '../models/radio_profile.dart';
import 'baofeng_ble_programmer.dart' show baofengUartService;

/// Name fragments specific enough to call a device a radio in a general scan.
///
/// Every entry names the maker or a model line with Bluetooth programming.
/// Deliberately NOT "mini": some of these radios spell themselves that way,
/// and so do half the speakers and LED strips in any scan. Nor is the UART
/// service enough on its own — it is the generic HM-10 serial service, and a
/// score of catalogue devices advertise it too. A radio that shows neither is
/// still found by the programming screen's scan, which is looking for a radio
/// and so can afford [mightBeRadio]'s looser test; it is just not announced
/// as one in the Nearby list.
const List<String> radioNameTokens = [
  'baofeng',
  'uv-5r',
  'uv5r',
  'uv-5g',
  'uv5g',
  'uv-32',
  'uv32',
];

/// Whether [uuid] is the radios' UART service, in any spelling a scan can
/// report it in: the full 128-bit form, or the 16-bit short one.
bool isRadioUartService(String uuid) {
  final lower = uuid.toLowerCase();
  return lower == baofengUartService || lower == 'ffe0' || lower == '0000ffe0';
}

/// What an advertisement says about a radio — which is less than it seems.
@immutable
class RadioSighting {
  /// Whether the advertisement carried the UART service the programming
  /// protocol runs over. A named device without it is still shown — some
  /// adverts leave their services to the scan response — but it is the
  /// weaker sighting.
  final bool advertisesUart;

  /// The model the advertised name spells, when it spells exactly one.
  ///
  /// A default for the device screen's model picker, never a claim: these
  /// radios answer to one ident string between them and their names are not
  /// reliable, so nothing the app can observe tells a UV-5R Mini from a UV-32
  /// for certain.
  final RadioProfile? nameSuggests;

  const RadioSighting({required this.advertisesUart, this.nameSuggests});

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is RadioSighting &&
          advertisesUart == other.advertisesUart &&
          nameSuggests == other.nameSuggests;

  @override
  int get hashCode => Object.hash(advertisesUart, nameSuggests);
}

/// A radio, by the strict test the general device list uses — or null.
///
/// Requires a [radioNameTokens] match. The service strengthens a sighting
/// but cannot make one; see that list for why.
RadioSighting? recogniseRadio({
  required String name,
  required List<String> serviceUuids,
}) {
  final lower = name.toLowerCase();
  if (!radioNameTokens.any(lower.contains)) return null;
  return RadioSighting(
    advertisesUart: serviceUuids.any(isRadioUartService),
    nameSuggests: _profileNamed(lower),
  );
}

/// The looser test, for a scan that is already looking for a radio: the
/// UART service alone qualifies. Anything [recogniseRadio] accepts does too.
bool mightBeRadio({
  required String name,
  required List<String> serviceUuids,
}) =>
    serviceUuids.any(isRadioUartService) ||
    recogniseRadio(name: name, serviceUuids: serviceUuids) != null;

/// The one Bluetooth profile [lowerName] names, if it names exactly one. A
/// name carrying two models' tokens is ambiguous, and suggests nothing.
RadioProfile? _profileNamed(String lowerName) {
  final named = <RadioProfile>{
    if (lowerName.contains('uv-5g') || lowerName.contains('uv5g'))
      uv5gMiniProfile,
    if (lowerName.contains('uv-32') || lowerName.contains('uv32')) uv32Profile,
    if (lowerName.contains('uv-5r') || lowerName.contains('uv5r'))
      uv5rMiniProfile,
  };
  return named.length == 1 ? named.single : null;
}
