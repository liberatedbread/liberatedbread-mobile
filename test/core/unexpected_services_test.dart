// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/core/unexpected_services.dart';

void main() {
  group('unexpectedGattServices', () {
    test('reports a vendor service the spec does not declare', () {
      expect(
        unexpectedGattServices(
          declared: ['0000fff0-0000-1000-8000-00805f9b34fb'],
          discovered: [
            '0000FFF0-0000-1000-8000-00805F9B34FB',
            '0000fe59-0000-1000-8000-00805f9b34fb',
          ],
        ),
        ['fe59'],
      );
    });

    test('never reports GAP, GATT or Device Information', () {
      expect(
        unexpectedGattServices(
          declared: const [],
          discovered: [
            '00001800-0000-1000-8000-00805f9b34fb',
            '1801',
            '0000180A-0000-1000-8000-00805f9b34fb',
          ],
        ),
        isEmpty,
      );
    });

    test('compares short and long spellings as one service', () {
      expect(
        unexpectedGattServices(
          declared: ['fff0'],
          discovered: ['0000fff0-0000-1000-8000-00805f9b34fb'],
        ),
        isEmpty,
      );
    });

    test('is sorted and de-duplicated', () {
      const vendor = 'a1b2c3d4-0000-1000-8000-1234567890ab';
      expect(
        unexpectedGattServices(
          declared: const [],
          discovered: [vendor, 'fe59', vendor.toUpperCase(), 'fe59'],
        ),
        [vendor, 'fe59'],
      );
    });
  });

  group('unexpectedMdnsTypes', () {
    test('folds .local and the trailing dot, and drops generic types', () {
      expect(
        unexpectedMdnsTypes(
          declared: ['_hue._tcp'],
          announced: [
            '_hue._tcp.local.',
            '_http._tcp.local',
            '_matter._tcp.local',
          ],
        ),
        ['_matter._tcp'],
      );
    });
  });

  group('unexpectedSsdpTargets', () {
    test('drops rootdevice and per-unit uuid targets', () {
      expect(
        unexpectedSsdpTargets(
          declared: ['urn:Belkin:device:controllee:1'],
          answered: [
            'upnp:rootdevice',
            'uuid:Socket-1_0-221517K0101769',
            'urn:belkin:device:controllee:1',
            'urn:Belkin:service:insight:1',
          ],
        ),
        ['urn:belkin:service:insight:1'],
      );
    });
  });
}
