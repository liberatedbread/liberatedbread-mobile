// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/models/iot_device.dart';

void main() {
  group('IoTDevice', () {
    test('isNearby returns true when RSSI is strong', () {
      final device = IoTDevice(
        id: 'AA:BB:CC:DD:EE:FF',
        name: 'Test',
        rssi: -50,
        isConnectable: true,
        discoveredAt: DateTime.now(),
      );
      expect(device.isNearby, isTrue);
    });

    test('isNearby returns false when RSSI is weak', () {
      final device = IoTDevice(
        id: 'AA:BB:CC:DD:EE:FF',
        name: 'Test',
        rssi: -90,
        isConnectable: true,
        discoveredAt: DateTime.now(),
      );
      expect(device.isNearby, isFalse);
    });

    test('displayName falls back to ID when name is empty', () {
      final device = IoTDevice(
        id: 'AA:BB:CC:DD:EE:FF',
        name: '',
        rssi: -50,
        isConnectable: true,
        discoveredAt: DateTime.now(),
      );
      expect(device.displayName, equals('Unknown (AA:BB:CC:DD:EE:FF)'));
    });

    test('equality is based on id', () {
      final now = DateTime.now();
      final d1 = IoTDevice(
        id: 'AA:BB:CC:DD:EE:FF',
        name: 'A',
        rssi: -50,
        isConnectable: true,
        discoveredAt: now,
      );
      final d2 = IoTDevice(
        id: 'AA:BB:CC:DD:EE:FF',
        name: 'B',
        rssi: -80,
        isConnectable: false,
        discoveredAt: now,
      );
      expect(d1, equals(d2));
    });

    group('macAddress', () {
      IoTDevice withId(String id) => IoTDevice(
        id: id,
        name: 'Test',
        rssi: -50,
        isConnectable: true,
        discoveredAt: DateTime.now(),
      );

      test('an Android/Linux device id is the hardware address', () {
        expect(withId('C4:7C:8D:11:22:33').macAddress, 'C4:7C:8D:11:22:33');
      });

      test('a CoreBluetooth uuid is not an address', () {
        // Apple platforms substitute a per-host UUID, which carries no OUI.
        // Reading its hex as an address would invent a vendor out of nothing.
        expect(
          withId('C47C8DAB-1234-5678-9ABC-DEF012345678').macAddress,
          isNull,
        );
      });

      test('a malformed id is not an address', () {
        expect(withId('not:an:address:at:all:x').macAddress, isNull);
        expect(withId('C4:7C:8D:11:22').macAddress, isNull);
      });
    });

    group('hasSameIdentity', () {
      IoTDevice device({
        int rssi = -50,
        String name = 'Test',
        List<String> serviceUuids = const [],
        List<int> companyIds = const [],
        Map<int, List<int>> manufacturerData = const {},
      }) => IoTDevice(
        id: 'AA:BB:CC:DD:EE:FF',
        name: name,
        rssi: rssi,
        isConnectable: true,
        discoveredAt: DateTime.now(),
        serviceUuids: serviceUuids,
        companyIds: companyIds,
        manufacturerData: manufacturerData,
      );

      test('ignores signal strength', () {
        // Otherwise every advertisement would look like a different device to
        // the matcher, and the cache would never hit.
        expect(device(rssi: -50).hasSameIdentity(device(rssi: -90)), isTrue);
      });

      test('a changed name is a changed identity', () {
        expect(device(name: 'A').hasSameIdentity(device(name: 'B')), isFalse);
      });

      test('compares advertisement contents by value', () {
        expect(
          device(serviceUuids: ['fff0']).hasSameIdentity(
            device(serviceUuids: List<String>.of(const ['fff0'])),
          ),
          isTrue,
        );
        expect(
          device(
            companyIds: const [961],
          ).hasSameIdentity(device(companyIds: const [89])),
          isFalse,
        );
      });

      // R-080: the payload bytes are what a pixel panel advertises its real
      // width and height in, so a sighting that changes them is not the same
      // identity even though the company id is unchanged.
      test('changed manufacturer payload bytes are a changed identity', () {
        expect(
          device(
            companyIds: const [961],
            manufacturerData: const {
              961: [16, 16],
            },
          ).hasSameIdentity(
            device(
              companyIds: const [961],
              manufacturerData: const {
                961: [32, 8],
              },
            ),
          ),
          isFalse,
        );
      });

      test('equal manufacturer payloads compare by value, not by map', () {
        expect(
          device(
            manufacturerData: {
              961: List<int>.of(const [16, 16]),
            },
          ).hasSameIdentity(
            device(
              manufacturerData: {
                961: List<int>.of(const [16, 16]),
              },
            ),
          ),
          isTrue,
        );
      });

      test('a payload appearing where there was none is a change', () {
        expect(
          device().hasSameIdentity(
            device(
              manufacturerData: const {
                961: [1],
              },
            ),
          ),
          isFalse,
        );
      });

      test('the same bytes under a different company id is a change', () {
        expect(
          device(
            manufacturerData: const {
              961: [1],
            },
          ).hasSameIdentity(
            device(
              manufacturerData: const {
                89: [1],
              },
            ),
          ),
          isFalse,
        );
      });
    });

    test('different ids are not equal', () {
      final now = DateTime.now();
      final d1 = IoTDevice(
        id: '11:22:33:44:55:66',
        name: 'A',
        rssi: -50,
        isConnectable: true,
        discoveredAt: now,
      );
      final d2 = IoTDevice(
        id: 'AA:BB:CC:DD:EE:FF',
        name: 'A',
        rssi: -50,
        isConnectable: true,
        discoveredAt: now,
      );
      expect(d1, isNot(equals(d2)));
    });
  });
}
