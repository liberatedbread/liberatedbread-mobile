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

    // Separators split bytes BEFORE digits are paired. The old parser
    // stripped them first, so '0x1, 0x2' became the single byte 0x12 and
    // '1 2 3 4' became [0x12, 0x34] -- different bytes on the wire than the
    // user typed into the raw write console.
    test('a separator never glues single-digit bytes together', () {
      expect(tryParseHex('0x1, 0x2'), isNull);
      expect(tryParseHex('1 2 3 4'), isNull);
      expect(tryParseHex('0x1,0x2,0x3,0x4'), isNull);
      expect(tryParseHex('a 0b c'), isNull);
    });

    test('0x is a prefix only at the start of a token', () {
      expect(tryParseHex('a0x1'), isNull);
    });

    test('a token may hold several whole bytes', () {
      expect(tryParseHex('0x01AA 02'), const [0x01, 0xaa, 0x02]);
      expect(tryParseHex('0102 03'), const [0x01, 0x02, 0x03]);
      expect(tryParseHex('0102 3'), isNull);
    });
  });

  group('isHexInputPlausible', () {
    // The keyboard filter must never refuse something the parser accepts.
    test('passes every input tryParseHex accepts', () {
      for (final input in [
        '',
        '01aaff',
        '01 aa ff',
        '01:AA:FF',
        '0x01, 0xAA',
        '0X01',
        '01-aa',
        '01\taa\n02',
        '01 ,:- aa',
      ]) {
        expect(tryParseHex(input), isNotNull, reason: input);
        expect(isHexInputPlausible(input), isTrue, reason: input);
      }
    });

    test('passes a half-typed value the parser would still reject', () {
      expect(isHexInputPlausible('0x1'), isTrue);
    });

    test('refuses characters the parser can never accept', () {
      expect(isHexInputPlausible('01 02 // comment'), isFalse);
      expect(isHexInputPlausible('zz'), isFalse);
      expect(isHexInputPlausible('01;02'), isFalse);
    });
  });

  group('normalizeUuid', () {
    test('folds a SIG-base UUID to its short form, lowercased', () {
      expect(normalizeUuid('0000FFF0-0000-1000-8000-00805F9B34FB'), 'fff0');
      expect(normalizeUuid('0000180f-0000-1000-8000-00805f9b34fb'), '180f');
    });

    test('leaves a genuinely 128-bit UUID alone but lowercases it', () {
      expect(
        normalizeUuid('6E400001-B5A3-F393-E0A9-E50E24DCCA9D'),
        '6e400001-b5a3-f393-e0a9-e50e24dcca9d',
      );
    });

    test('both spellings of one attribute compare equal', () {
      // This is the whole point: device specs write the 128-bit form while
      // flutter_blue_plus reports the short form, and the two name the same
      // characteristic.
      expect(
        normalizeUuid('00002a06-0000-1000-8000-00805f9b34fb'),
        normalizeUuid('2a06'),
      );
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
