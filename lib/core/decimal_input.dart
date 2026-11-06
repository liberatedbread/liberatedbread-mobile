// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// Numbers as people type them.

/// [typed], trimmed, with a single decimal comma read as the decimal point.
///
/// For numbers a person typed, not for data: an iOS decimal pad in the
/// de, fr, es, it, pt and nl locales has a comma key and no period, so there
/// "146,940" is the only way to type a frequency and "41,7658" a latitude,
/// and parsers that take only a period refused both. Nothing else is
/// guessed at: a comma beside a period (a thousands separator) or more than
/// one comma is left as typed, for the parser to refuse as it always did
/// rather than to read as some other number.
///
/// Directory data does not come through here. A feed's "146,940" is not a
/// keyboard's, and `parseMegahertzToHz` reads such feeds directly.
String normalizeDecimalInput(String typed) {
  final text = typed.trim();
  final comma = text.indexOf(',');
  if (comma < 0 || text.contains('.') || text.lastIndexOf(',') != comma) {
    return text;
  }
  return text.replaceRange(comma, comma + 1, '.');
}
