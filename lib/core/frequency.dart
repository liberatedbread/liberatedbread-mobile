// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// Reading and writing frequencies without ever going through a double.

/// Parse a megahertz string — "462.625", "146.94", "446" — into exact Hz.
///
/// Done digit by digit rather than through `double.parse` because that is
/// where the precision this app is built around would leak away:
/// `double.parse('462.625') * 1e6` is 462624999.99999994, and `.toInt()`
/// turns that into 462624999 Hz. One hertz low is invisible on a screen,
/// survives a JSON round trip, and quietly stops the same repeater from two
/// directories de-duplicating against itself.
///
/// Returns null for anything that is not a frequency, including the empty
/// strings and placeholder text these APIs use for "unknown".
int? parseMegahertzToHz(String? value) {
  final text = value?.trim();
  if (text == null || text.isEmpty) return null;

  final match = RegExp(r'^([+-]?)(\d*)(?:\.(\d*))?$').firstMatch(text);
  if (match == null) return null;

  final sign = match.group(1) == '-' ? -1 : 1;
  final whole = match.group(2) ?? '';
  final fraction = match.group(3) ?? '';
  if (whole.isEmpty && fraction.isEmpty) return null;

  // Six digits of fraction is one hertz. Longer inputs are truncated rather
  // than rounded: sub-hertz precision in a repeater listing is noise, and
  // rounding it up could push a channel over a band edge.
  final padded = fraction.padRight(6, '0').substring(0, 6);
  final megahertz = whole.isEmpty ? 0 : int.tryParse(whole);
  final hertz = int.tryParse(padded);
  if (megahertz == null || hertz == null) return null;
  return sign * (megahertz * 1000000 + hertz);
}

/// Format Hz as the megahertz string a radio operator reads.
///
/// Trailing zeros beyond [minDecimals] are dropped, so 146940000 reads as
/// "146.940" rather than "146.940000", and 446000000 as "446.000".
String formatHzAsMegahertz(int hz, {int minDecimals = 3}) {
  final negative = hz < 0;
  final magnitude = hz.abs();
  final whole = magnitude ~/ 1000000;
  var fraction = (magnitude % 1000000).toString().padLeft(6, '0');

  while (fraction.length > minDecimals && fraction.endsWith('0')) {
    fraction = fraction.substring(0, fraction.length - 1);
  }
  final sign = negative ? '-' : '';
  return fraction.isEmpty ? '$sign$whole' : '$sign$whole.$fraction';
}
