// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'package:flutter_test/flutter_test.dart';
import 'package:opengreeniot_mobile/core/ha_url.dart';

void main() {
  group('classifyHaUrl', () {
    const cases = <String, HaUrlKind>{
      // Private/LAN addresses.
      'http://192.168.1.10:8123': HaUrlKind.privateLan,
      'http://10.0.0.5:8123': HaUrlKind.privateLan,
      'http://172.16.0.1:8123': HaUrlKind.privateLan,
      'http://172.31.255.255': HaUrlKind.privateLan,
      'http://169.254.1.1': HaUrlKind.privateLan,
      'http://127.0.0.1:8123': HaUrlKind.privateLan,
      'http://localhost:8123': HaUrlKind.privateLan,
      // Not private: outside 172.16/12.
      'http://172.32.0.1': HaUrlKind.publicHttp,
      // mDNS.
      'http://homeassistant.local:8123': HaUrlKind.mdnsLocal,
      // Tailscale.
      'https://ha.tail1234.ts.net': HaUrlKind.tailscale,
      'https://ha.TAIL1234.TS.NET': HaUrlKind.tailscale,
      'http://100.101.1.2:8123': HaUrlKind.tailscale,
      // CGNAT boundary checks.
      'http://100.63.0.1': HaUrlKind.publicHttp,
      'http://100.128.0.1': HaUrlKind.publicHttp,
      // Public.
      'https://ha.example.com': HaUrlKind.publicHttps,
      'http://ha.example.com': HaUrlKind.publicHttp,
      // Invalid.
      '': HaUrlKind.invalid,
      'not a url at all': HaUrlKind.invalid,
      'ftp://ha.example.com': HaUrlKind.invalid,
    };

    cases.forEach((input, expected) {
      test('"$input" -> $expected', () {
        expect(classifyHaUrl(input), expected);
      });
    });

    test('defaults to http scheme when missing', () {
      expect(classifyHaUrl('192.168.1.10:8123'), HaUrlKind.privateLan);
      expect(classifyHaUrl('ha.example.com'), HaUrlKind.publicHttp);
    });
  });

  group('normalizeHaBaseUrl', () {
    test('trims whitespace and trailing slashes', () {
      expect(normalizeHaBaseUrl('  http://ha.local:8123/  '),
          'http://ha.local:8123');
      expect(normalizeHaBaseUrl('http://ha.local:8123///'),
          'http://ha.local:8123');
    });

    test('adds http scheme when missing', () {
      expect(normalizeHaBaseUrl('ha.local:8123'), 'http://ha.local:8123');
    });

    test('keeps https scheme', () {
      expect(normalizeHaBaseUrl('https://ha.ts.net'), 'https://ha.ts.net');
    });

    test('empty stays empty', () {
      expect(normalizeHaBaseUrl('   '), '');
    });
  });

  group('isPrivateIpv4', () {
    test('rejects non-IP and out-of-range octets', () {
      expect(isPrivateIpv4('example.com'), isFalse);
      expect(isPrivateIpv4('192.168.1'), isFalse);
      expect(isPrivateIpv4('192.168.1.256'), isFalse);
    });
  });
}
