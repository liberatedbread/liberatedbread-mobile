// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/core/hex.dart';

void main() {
  group('bytesToHex', () {
    test('empty list returns empty string', () {
      expect(bytesToHex(const []), '');
    });

    test('single byte is zero-padded', () {
      expect(bytesToHex(const [0]), '00');
      expect(bytesToHex(const [0x0a]), '0a');
    });

    test('multiple bytes are space-separated lowercase', () {
      expect(bytesToHex(const [0x01, 0xaa, 0xff]), '01 aa ff');
    });
  });

  group('tryParseHex', () {
    test('empty string parses to empty list', () {
      expect(tryParseHex(''), const <int>[]);
      expect(tryParseHex('   '), const <int>[]);
    });

    test('parses contiguous hex', () {
      expect(tryParseHex('01aaff'), const [0x01, 0xaa, 0xff]);
    });

    test('tolerates spaces, colons, dashes and 0x prefixes', () {
      expect(tryParseHex('01 aa ff'), const [0x01, 0xaa, 0xff]);
      expect(tryParseHex('01:AA:FF'), const [0x01, 0xaa, 0xff]);
      expect(tryParseHex('0x01, 0xAA'), const [0x01, 0xaa]);
      expect(tryParseHex('01-aa'), const [0x01, 0xaa]);
    });

    test('rejects odd-length input', () {
      expect(tryParseHex('abc'), isNull);
    });

    test('rejects non-hex characters', () {
      expect(tryParseHex('zz'), isNull);
      expect(tryParseHex('01gg'), isNull);
    });
  });

  group('normalizeUuid', () {
    test('folds a SIG-base UUID to its short form, lowercased', () {
      expect(normalizeUuid('0000FFF0-0000-1000-8000-00805F9B34FB'), 'fff0');
      expect(normalizeUuid('0000180f-0000-1000-8000-00805f9b34fb'), '180f');
    });

    test('leaves a genuinely 128-bit UUID alone but lowercases it', () {
      expect(normalizeUuid('6E400001-B5A3-F393-E0A9-E50E24DCCA9D'),
          '6e400001-b5a3-f393-e0a9-e50e24dcca9d');
    });

    test('both spellings of one attribute compare equal', () {
      // This is the whole point: device specs write the 128-bit form while
      // flutter_blue_plus reports the short form, and the two name the same
      // characteristic.
      expect(normalizeUuid('00002a06-0000-1000-8000-00805f9b34fb'),
          normalizeUuid('2a06'));
      expect(normalizeUuid('2A06'), normalizeUuid('2a06'));
    });

    test('strips leading zeros from a bare short form', () {
      expect(normalizeUuid('000000f0-0000-1000-8000-00805f9b34fb'), 'f0');
      expect(normalizeUuid('00f0'), 'f0');
      expect(normalizeUuid('0000'), '0');
    });

    test('is idempotent', () {
      for (final u in [
        '0000180f-0000-1000-8000-00805f9b34fb',
        '180f',
        '6e400001-b5a3-f393-e0a9-e50e24dcca9d',
      ]) {
        expect(normalizeUuid(normalizeUuid(u)), normalizeUuid(u));
      }
    });

    // Normalization must never reject input: it is used on values that come
    // from user-editable device specs, where a typo should degrade to "no
    // match" rather than crashing the panel that renders the device.
    test('passes through anything that is not a short-form UUID', () {
      expect(normalizeUuid(''), '');
      expect(normalizeUuid('NotAUuid'), 'notauuid');
      expect(normalizeUuid('zzzz'), 'zzzz');
    });
  });

  group('asciiPreview', () {
    test('renders printable bytes as text', () {
      expect(asciiPreview([0x4f, 0x4b]), 'OK');
      expect(asciiPreview('v1.2.3'.codeUnits), 'v1.2.3');
    });

    test('null for binary, so hex stays the honest rendering', () {
      expect(asciiPreview([0x01, 0x80, 0xff]), isNull);
      expect(asciiPreview([0x00]), isNull);
    });

    test('null for empty', () {
      expect(asciiPreview(const []), isNull);
    });

    test('allows CR and LF but not other control bytes', () {
      expect(asciiPreview('a\r\nb'.codeUnits), 'a\r\nb');
      expect(asciiPreview([0x61, 0x07]), isNull);
    });
  });
}
