// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0

/// Format bytes as space-separated lowercase hex (e.g. `[0x01, 0xaa] -> '01 aa'`).
String bytesToHex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ');

/// Lowercase a BLE UUID for case-insensitive comparison.
String normalizeUuid(String uuid) => uuid.toLowerCase();

/// Parse a user-entered hex string into bytes, or return null if it isn't
/// valid hex.
///
/// Tolerant of common formatting: surrounding/interior whitespace, `0x`
/// prefixes, and `:`/`-` separators (e.g. `01 aa`, `0x01,0xAA`, `01:aa`,
/// `01AA`). After separators are stripped the remaining digits must be an even
/// number of `[0-9a-fA-F]` characters. An empty string returns an empty list.
List<int>? tryParseHex(String input) {
  // Drop whitespace and byte separators, and any 0x/0X prefixes.
  final cleaned = input
      .replaceAll(RegExp(r'0[xX]'), '')
      .replaceAll(RegExp(r'[\s:,\-]'), '');
  if (cleaned.isEmpty) return const [];
  if (cleaned.length.isOdd) return null;
  if (!RegExp(r'^[0-9a-fA-F]+$').hasMatch(cleaned)) return null;
  final bytes = <int>[];
  for (var i = 0; i < cleaned.length; i += 2) {
    bytes.add(int.parse(cleaned.substring(i, i + 2), radix: 16));
  }
  return bytes;
}

/// [bytes] rendered as text when every byte is printable ASCII, else null.
///
/// Reverse-engineering a device is much easier when a characteristic holding
/// `4f 4b` also shows as `OK`. Only printable ASCII (plus CR/LF) qualifies —
/// anything else is binary and the hex view is the honest rendering.
String? asciiPreview(List<int> bytes) {
  if (bytes.isEmpty) return null;
  final text = String.fromCharCodes(bytes);
  final printable = text.runes.every(
    (r) => (r >= 0x20 && r < 0x7F) || r == 0x0A || r == 0x0D,
  );
  return printable ? text : null;
}
