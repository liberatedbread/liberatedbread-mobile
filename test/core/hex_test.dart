// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'package:flutter_test/flutter_test.dart';
import 'package:opengreeniot_mobile/core/hex.dart';

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
    test('lowercases mixed case', () {
      expect(normalizeUuid('0000FFF0-0000-1000-8000-00805F9B34FB'),
          '0000fff0-0000-1000-8000-00805f9b34fb');
    });

    test('is idempotent', () {
      const u = '0000180f-0000-1000-8000-00805f9b34fb';
      expect(normalizeUuid(normalizeUuid(u)), u);
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
