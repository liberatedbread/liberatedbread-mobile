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
}
