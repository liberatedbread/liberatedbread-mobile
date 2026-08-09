// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/models/iot_device.dart';
import 'package:liberated_bread_mobile/providers/device_description_provider.dart';
import 'package:liberated_bread_mobile/services/number_registry.dart';

String _table(Map<String, String> rows) {
  final keys = rows.keys.toList()..sort();
  return keys.map((k) => '$k\t${rows[k]}\n').join();
}

final _registry = NumberRegistry(
  addressBlocks: [
    RegistryTable.parse(_table({'C47C8D6': 'HHCC Plant Technology'}),
        keyWidth: 7),
    RegistryTable.parse(
        _table({'A4CF12': 'Espressif Inc.', 'B894D9': 'Texas Instruments'}),
        keyWidth: 6),
  ],
  companyIds:
      RegistryTable.parse(_table({'00961': 'Ember Technologies'}), keyWidth: 5),
  serviceUuids: RegistryTable.parse(
      _table({'180f': 'Battery Service', '181a': 'Environmental Sensing'}),
      keyWidth: 4),
);

IoTDevice _device({
  String id = 'A4:CF:12:11:22:33',
  String name = '',
  List<String> serviceUuids = const [],
  List<int> companyIds = const [],
}) =>
    IoTDevice(
      id: id,
      name: name,
      rssi: -50,
      isConnectable: true,
      discoveredAt: DateTime(2026),
      serviceUuids: serviceUuids,
      companyIds: companyIds,
    );

void main() {
  group('describeDevice', () {
    test('names the maker of a device that advertises nothing at all', () {
      // The case the scan list handled worst: no name, no services, no
      // manufacturer data. The address block is the only thing left.
      final d = describeDevice(_device(), _registry);
      expect(d.addressVendor, 'Espressif Inc.');
      expect(d.maker, 'Espressif Inc.');
      expect(d.summary, 'Espressif Inc.');
    });

    test('names standard services when capabilities are advertised', () {
      final d = describeDevice(
        _device(serviceUuids: const [
          '0000180f-0000-1000-8000-00805f9b34fb',
          '0000181a-0000-1000-8000-00805f9b34fb',
        ]),
        _registry,
      );
      expect(d.standardServices, ['Battery Service', 'Environmental Sensing']);
      expect(d.vendorServiceCount, 0);
      expect(
          d.summary, 'Espressif Inc. · Battery Service, Environmental Sensing');
    });

    test('counts vendor services rather than printing raw UUIDs', () {
      final d = describeDevice(
        _device(serviceUuids: const [
          'fc543622-236c-4c94-8fa9-944a3e5353fa',
          'fc543621-236c-4c94-8fa9-944a3e5353fa',
        ]),
        _registry,
      );
      expect(d.standardServices, isEmpty);
      expect(d.vendorServiceCount, 2);
      expect(d.summary, 'Espressif Inc. · 2 custom services');
    });

    test('a single custom service is singular', () {
      final d = describeDevice(
        _device(serviceUuids: const ['fc543622-236c-4c94-8fa9-944a3e5353fa']),
        _registry,
      );
      expect(d.summary, 'Espressif Inc. · 1 custom service');
    });

    test('the advertised company id outranks the address block', () {
      // A Texas Instruments block under an Ember company ID is an Ember mug,
      // not a TI product: the firmware author picked the company ID, whoever
      // assembled the radio picked the address.
      final d = describeDevice(
        _device(id: 'B8:94:D9:11:22:33', companyIds: const [961]),
        _registry,
      );
      expect(d.addressVendor, 'Texas Instruments');
      expect(d.maker, 'Ember Technologies');
    });

    test('unknown company ids and unassigned blocks contribute nothing', () {
      final d = describeDevice(
        _device(id: '02:00:00:11:22:33', companyIds: const [4242]),
        _registry,
      );
      expect(d.isEmpty, isTrue);
      expect(d.summary, isNull);
    });

    test('duplicate services and companies are reported once', () {
      final d = describeDevice(
        _device(
          serviceUuids: const ['180f', '0000180f-0000-1000-8000-00805f9b34fb'],
          companyIds: const [961, 961],
        ),
        _registry,
      );
      expect(d.standardServices, ['Battery Service']);
      expect(d.companies, ['Ember Technologies']);
    });

    test('resolves through the longest matching address block', () {
      final d = describeDevice(_device(id: 'C4:7C:8D:6A:1B:2C'), _registry);
      expect(d.addressVendor, 'HHCC Plant Technology');
    });
  });

  group('deviceTitle', () {
    test('an advertised name always wins', () {
      final device = _device(name: 'Kitchen Bulb');
      expect(
        deviceTitle(device, describeDevice(device, _registry)),
        'Kitchen Bulb',
      );
    });

    test('a nameless device is titled by its maker', () {
      final device = _device();
      expect(
        deviceTitle(device, describeDevice(device, _registry)),
        'Espressif Inc.',
      );
    });

    test('a nameless device from nobody known falls back to a plain label', () {
      final device = _device(id: '02:00:00:11:22:33');
      expect(
        deviceTitle(device, describeDevice(device, _registry)),
        'Unknown device',
      );
    });
  });

  group('deviceSubtitle', () {
    test('carries the address when the title came from the registry', () {
      // Two devices from the same maker would otherwise be indistinguishable.
      final device = _device();
      expect(
        deviceSubtitle(device, describeDevice(device, _registry)),
        'A4:CF:12:11:22:33',
      );
    });

    test('does not repeat the maker it already used as the title', () {
      final device = _device(serviceUuids: const ['180f']);
      expect(
        deviceSubtitle(device, describeDevice(device, _registry)),
        'A4:CF:12:11:22:33 · Battery Service',
      );
    });

    test('a named device gets the full summary, maker included', () {
      final device =
          _device(name: 'Kitchen Bulb', serviceUuids: const ['180f']);
      expect(
        deviceSubtitle(device, describeDevice(device, _registry)),
        'Espressif Inc. · Battery Service',
      );
    });

    test('a named device we know nothing about gets no subtitle', () {
      final device = _device(id: '02:00:00:11:22:33', name: 'Some Gadget');
      expect(deviceSubtitle(device, describeDevice(device, _registry)), isNull);
    });
  });
}
