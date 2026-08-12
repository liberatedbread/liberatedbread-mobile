// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0

/// Format bytes as space-separated lowercase hex (e.g. `[0x01, 0xaa] -> '01 aa'`).
String bytesToHex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ');

/// The Bluetooth SIG base UUID suffix. A 128-bit UUID ending in this is an
/// alias for a 16-/32-bit assigned number, and the two forms name the same
/// attribute.
const _btBaseUuidSuffix = '-0000-1000-8000-00805f9b34fb';

/// Canonicalize a BLE UUID for comparison: lowercased, and SIG-base UUIDs
/// folded to their short form with leading zeros stripped.
///
///   `0000180F-0000-1000-8000-00805F9B34FB` → `180f`
///   `180f`                                 → `180f`
///   `6e400001-b5a3-f393-e0a9-e50e24dcca9d` → unchanged (not SIG-base)
///
/// Folding — not just lowercasing — is required because the two sides of
/// every UUID comparison in this app speak different dialects. Device specs
/// always write the full 128-bit form, while flutter_blue_plus reports the
/// *shortest* representation (`Guid.toString()` returns `str`, which slices
/// SIG-base UUIDs down to 4 hex digits), so a plain lowercase comparison of
/// `0000180f-...` against `180f` fails on every real peripheral exposing a
/// standard service. This mirrors `normalize_uuid` in
/// `rust/src/protocol/profiles/mod.rs`, so the Dart and Rust sides agree on
/// when two UUIDs are the same attribute.
String normalizeUuid(String uuid) {
  final lower = uuid.toLowerCase();
  if (lower.endsWith(_btBaseUuidSuffix)) {
    final prefix = lower.substring(0, lower.length - _btBaseUuidSuffix.length);
    return _stripLeadingZeros(prefix);
  }
  // A bare short form may still carry leading zeros ("0180f"); fold those too
  // so both spellings of the same assigned number compare equal.
  if (lower.length <= 8 && !lower.contains('-')) {
    return _stripLeadingZeros(lower);
  }
  return lower;
}

/// Drop leading zeros, keeping at least one digit ("0000" → "0").
String _stripLeadingZeros(String value) {
  var i = 0;
  while (i < value.length - 1 && value.codeUnitAt(i) == 0x30) {
    i++;
  }
  return value.substring(i);
}

/// [id] when it is a hardware address, null when it is not one.
///
/// Android, Linux and Windows put the MAC in the platform device id; Apple
/// platforms substitute a per-host CoreBluetooth UUID, which carries no OUI
/// and must not be read as an address. Six colon-separated hex octets is the
/// discriminator — a UUID has five hyphen-separated groups instead. One
/// implementation, shared by `IoTDevice.macAddress` and the saved-device
/// paths, so the two can never classify the same id differently.
String? macAddressOrNull(String id) {
  final octets = id.split(':');
  if (octets.length != 6) return null;
  final isMac = octets.every((octet) =>
      octet.length == 2 &&
      octet.codeUnits.every((c) =>
          (c >= 0x30 && c <= 0x39) || // 0-9
          (c >= 0x41 && c <= 0x46) || // A-F
          (c >= 0x61 && c <= 0x66))); // a-f
  return isMac ? id : null;
}

final RegExp _macSeparators = RegExp('[:-]');
final RegExp _upperHex = RegExp(r'^[0-9A-F]+$');

/// Strip a MAC's `:`/`-` separators and uppercase it, or return null when what
/// remains is not pure hex.
///
/// Deliberately does NOT enforce a length: an address is 12 digits, a Hue
/// `bridgeid` is an EUI-64's 16, and each caller owns that rule. What is shared
/// is the tolerant-input step, so the registry lookup and the TXT-record parser
/// cannot drift on what counts as a MAC. The regexes are top-level so per-call
/// sites on the scan path do not recompile them per device per rebuild.
String? normalizeMacHex(String raw) {
  final hex = raw.replaceAll(_macSeparators, '').toUpperCase();
  return _upperHex.hasMatch(hex) ? hex : null;
}

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
