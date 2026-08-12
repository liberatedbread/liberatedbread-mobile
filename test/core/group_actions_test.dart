// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/core/group_actions.dart';
import 'package:liberated_bread_mobile/models/ble_discovered_service.dart';
import 'package:liberated_bread_mobile/services/spec_codec.dart';

// -- DTO builders (find_device_test idiom: hand-built, no codec needed) ------

const _svc = '0000fff0-0000-1000-8000-00805f9b34fb';
const _cmdChar = '0000fff1-0000-1000-8000-00805f9b34fb';
const _stateChar = '0000fff2-0000-1000-8000-00805f9b34fb';

EntityActionDto _action(
  String role, {
  String? commandName = 'cmd',
  String serviceUuid = _svc,
  String charUuid = _cmdChar,
  List<String> userParams = const [],
  double? min,
  double? max,
}) =>
    EntityActionDto(
      role: role,
      serviceUuid: serviceUuid,
      characteristicUuid: charUuid,
      commandName: commandName,
      userParams: userParams,
      min: min,
      max: max,
    );

EntityDto _entity(
  String name, {
  String? platform,
  String? deviceClass,
  String? stateCharacteristic,
  bool hasFormat = false,
  List<EntityActionDto> actions = const [],
  String? valueField,
  double? valueScale,
  double? precision,
  String? unit,
}) =>
    EntityDto(
      name: name,
      platform: platform,
      deviceClass: deviceClass,
      stateCharacteristic: stateCharacteristic,
      canNotify: false,
      hasFormat: hasFormat,
      valueField: valueField,
      valueScale: valueScale,
      precision: precision,
      unit: unit,
      onWhenNonzero: false,
      actions: actions,
    );

DeviceSpecDto _spec({
  List<EntityDto> entities = const [],
  List<ServiceDto> services = const [],
}) =>
    DeviceSpecDto(
      deviceName: 'Test Device',
      manufacturer: 'Test Co',
      manufacturerStatus: 'abandoned',
      protocol: 'ble',
      localNamePrefixes: const [],
      serviceUuids: const [_svc],
      companyIds: Uint16List(0),
      macPrefixes: const [],
      ssdpSearchTargets: const [],
      services: services,
      entities: entities,
    );

BleDiscoveredService _discovered({
  String serviceUuid = _svc,
  String charUuid = _cmdChar,
  bool canWrite = true,
  bool canRead = false,
}) =>
    BleDiscoveredService(
      uuid: serviceUuid,
      characteristics: [
        BleDiscoveredCharacteristic(
          uuid: charUuid,
          canRead: canRead,
          canWrite: canWrite,
          canNotify: false,
        ),
      ],
    );

DecodedValueDto _decoded(
  String name, {
  int? uintValue,
  double? scale,
  String? unit,
  String? valueLabel,
}) =>
    DecodedValueDto(
      name: name,
      valueType: 'uint8',
      display: '$uintValue',
      uintValue: uintValue,
      scale: scale,
      unit: unit,
      valueLabel: valueLabel,
    );

void main() {
  group('supportedGroupOps', () {
    test('light action roles map onto the command ops', () {
      final spec = _spec(entities: [
        _entity('Bulb', platform: 'light', actions: [
          _action('turn_on'),
          _action('turn_off'),
          _action('set_brightness'),
        ]),
      ]);
      expect(supportedGroupOps(spec),
          {GroupOp.turnOn, GroupOp.turnOff, GroupOp.setBrightness});
    });

    test('an action without a command name does not count', () {
      final spec = _spec(entities: [
        _entity('Bulb', platform: 'light', actions: [
          _action('turn_on', commandName: null),
        ]),
      ]);
      expect(supportedGroupOps(spec), isEmpty);
    });

    test('roles on non light/switch platforms are not group commands', () {
      // A climate set_value must never ride along into "turn all on".
      final spec = _spec(entities: [
        _entity('Heat', platform: 'climate', actions: [_action('turn_on')]),
      ]);
      expect(supportedGroupOps(spec), isEmpty);
    });

    test('a readable battery entity offers the battery op', () {
      final spec = _spec(entities: [
        _entity('Battery',
            platform: 'sensor',
            deviceClass: 'battery',
            stateCharacteristic: _stateChar,
            hasFormat: true),
      ]);
      expect(supportedGroupOps(spec), {GroupOp.readBattery});
    });

    test(
        'a declared SIG battery service offers the battery op without a '
        'format block', () {
      final spec = _spec(services: const [
        ServiceDto(uuid: batteryServiceUuid, name: 'Battery', characteristics: [
          CharacteristicDto(
            uuid: batteryLevelCharUuid,
            name: 'Battery Level',
            canRead: true,
            canWrite: false,
            canNotify: false,
            commands: [],
            formatFields: [],
          ),
        ]),
      ]);
      expect(supportedGroupOps(spec), {GroupOp.readBattery});
    });

    test('sensor entities offer the snapshot op; batteries do not double up',
        () {
      final spec = _spec(entities: [
        _entity('Temperature',
            platform: 'sensor',
            stateCharacteristic: _stateChar,
            hasFormat: true),
        _entity('Battery',
            platform: 'sensor',
            deviceClass: 'battery',
            stateCharacteristic: _stateChar,
            hasFormat: true),
      ]);
      expect(
          supportedGroupOps(spec), {GroupOp.readSensors, GroupOp.readBattery});
    });
  });

  group('resolveGroupWrites', () {
    final onOffSpec = _spec(entities: [
      _entity('Bulb', platform: 'light', actions: [
        _action('turn_on'),
        _action('turn_off', commandName: 'power_off'),
      ]),
    ]);

    test('resolves a write when the pair is discovered and writable', () {
      final writes = resolveGroupWrites(
        op: GroupOp.turnOff,
        spec: onOffSpec,
        services: [_discovered()],
      );
      final write = writes.single;
      expect(write.commandName, 'power_off');
      expect(write.serviceUuid, _svc);
      expect(write.charUuid, _cmdChar);
      expect(write.params, isEmpty);
    });

    test('an undiscovered characteristic resolves nothing', () {
      final writes = resolveGroupWrites(
        op: GroupOp.turnOff,
        spec: onOffSpec,
        services: [
          _discovered(charUuid: '0000aaaa-0000-1000-8000-00805f9b34fb')
        ],
      );
      expect(writes, isEmpty);
    });

    test('a discovered but unwritable characteristic resolves nothing', () {
      final writes = resolveGroupWrites(
        op: GroupOp.turnOff,
        spec: onOffSpec,
        services: [_discovered(canWrite: false)],
      );
      expect(writes, isEmpty);
    });

    test('the same characteristic under a different service does not count',
        () {
      // Vendor channels reuse char UUIDs; the pair must match, not the char.
      final writes = resolveGroupWrites(
        op: GroupOp.turnOff,
        spec: onOffSpec,
        services: [
          _discovered(serviceUuid: '0000eee0-0000-1000-8000-00805f9b34fb'),
        ],
      );
      expect(writes, isEmpty);
    });

    test('switch on/off sends no parameters', () {
      final spec = _spec(entities: [
        _entity('Plug', platform: 'switch', actions: [_action('turn_on')]),
      ]);
      final writes = resolveGroupWrites(
        op: GroupOp.turnOn,
        spec: spec,
        services: [_discovered()],
      );
      expect(writes.single.params, isEmpty);
    });

    test('a light turn_on that carries color parameters gets full-on white',
        () {
      final spec = _spec(entities: [
        _entity('LEDs', platform: 'light', actions: [
          _action('turn_on',
              commandName: 'set_rgb_color',
              userParams: const ['red', 'green', 'blue']),
        ]),
      ]);
      final writes = resolveGroupWrites(
        op: GroupOp.turnOn,
        spec: spec,
        services: [_discovered()],
      );
      expect(
          writes.single.params, {'red': 255.0, 'green': 255.0, 'blue': 255.0});
    });

    test('brightness maps percent onto the declared device range', () {
      expect(
        brightnessDeviceValue(_action('set_brightness', min: 0, max: 100), 50),
        50.0,
      );
      expect(
        brightnessDeviceValue(_action('set_brightness', min: 1, max: 255), 50),
        128.0,
      );
      // No declared bounds: the light card's 0..255 assumption.
      expect(brightnessDeviceValue(_action('set_brightness'), 50), 128.0);
      expect(
        brightnessDeviceValue(_action('set_brightness', min: 5, max: 100), 0),
        5.0,
      );
      expect(
        brightnessDeviceValue(_action('set_brightness', min: 5, max: 100), 100),
        100.0,
      );
      // Out-of-range percents clamp instead of extrapolating.
      expect(
        brightnessDeviceValue(_action('set_brightness', min: 0, max: 100), 140),
        100.0,
      );
    });

    test('brightness fills the named slider parameter and zeroes the rest', () {
      final spec = _spec(entities: [
        _entity('Strip', platform: 'light', actions: [
          _action('set_brightness',
              userParams: const ['brightness', 'mystery'], min: 0, max: 100),
        ]),
      ]);
      final writes = resolveGroupWrites(
        op: GroupOp.setBrightness,
        spec: spec,
        services: [_discovered()],
        brightnessPercent: 40,
      );
      expect(writes.single.params, {'brightness': 40.0, 'mystery': 0.0});
    });

    test("'level' is honoured as the slider parameter name", () {
      final spec = _spec(entities: [
        _entity('Strip', platform: 'light', actions: [
          _action('set_brightness',
              userParams: const ['level'], min: 0, max: 200),
        ]),
      ]);
      final writes = resolveGroupWrites(
        op: GroupOp.setBrightness,
        spec: spec,
        services: [_discovered()],
        brightnessPercent: 50,
      );
      expect(writes.single.params, {'level': 100.0});
    });
  });

  group('resolveBatteryReads', () {
    final specBattery = _spec(entities: [
      _entity('Battery',
          platform: 'sensor',
          deviceClass: 'battery',
          stateCharacteristic: _stateChar,
          hasFormat: true,
          valueField: 'battery'),
    ]);

    test('the spec battery entity wins over the SIG service', () {
      final reads = resolveBatteryReads(
        spec: specBattery,
        services: [
          _discovered(charUuid: _stateChar, canRead: true, canWrite: false),
          _discovered(
              serviceUuid: batteryServiceUuid,
              charUuid: batteryLevelCharUuid,
              canRead: true,
              canWrite: false),
        ],
      );
      final read = reads.single;
      expect(read.specBased, isTrue);
      expect(read.charUuid, _stateChar);
      expect(read.entity, isNotNull);
    });

    test('falls back to SIG when the spec battery char was not discovered', () {
      final reads = resolveBatteryReads(
        spec: specBattery,
        services: [
          _discovered(
              serviceUuid: batteryServiceUuid,
              charUuid: batteryLevelCharUuid,
              canRead: true,
              canWrite: false),
        ],
      );
      final read = reads.single;
      expect(read.specBased, isFalse);
      expect(read.label, 'Battery');
    });

    test('SIG path works with no spec at all', () {
      final reads = resolveBatteryReads(
        spec: null,
        services: [
          _discovered(
              serviceUuid: batteryServiceUuid,
              charUuid: batteryLevelCharUuid,
              canRead: true,
              canWrite: false),
        ],
      );
      expect(reads.single.specBased, isFalse);
    });

    test('2a19 under a vendor service is not the battery profile', () {
      final reads = resolveBatteryReads(
        spec: null,
        services: [
          _discovered(
              serviceUuid: _svc,
              charUuid: batteryLevelCharUuid,
              canRead: true,
              canWrite: false),
        ],
      );
      expect(reads, isEmpty);
    });

    test('an unreadable battery level resolves nothing', () {
      final reads = resolveBatteryReads(
        spec: null,
        services: [
          _discovered(
              serviceUuid: batteryServiceUuid,
              charUuid: batteryLevelCharUuid,
              canRead: false,
              canWrite: false),
        ],
      );
      expect(reads, isEmpty);
    });

    test('variant entities binding the same characteristic read it once', () {
      final spec = _spec(entities: [
        for (final variant in ['Gen 1', 'Gen 2'])
          _entity('Battery ($variant)',
              platform: 'sensor',
              deviceClass: 'battery',
              stateCharacteristic: _stateChar,
              hasFormat: true),
      ]);
      final reads = resolveBatteryReads(
        spec: spec,
        services: [
          _discovered(charUuid: _stateChar, canRead: true, canWrite: false),
        ],
      );
      expect(reads, hasLength(1));
    });
  });

  group('read service binding', () {
    test('reads bind to the service the spec declares, not discovery order',
        () {
      // The device also exposes the same characteristic UUID under a vendor
      // service that discovery happens to list first. Reading THAT one and
      // decoding it with this entity's format would report garbage as a
      // healthy value — the spec says which service it meant.
      final spec = _spec(
        entities: [
          _entity('Battery',
              platform: 'sensor',
              deviceClass: 'battery',
              stateCharacteristic: batteryLevelCharUuid,
              hasFormat: true),
        ],
        services: const [
          ServiceDto(
            uuid: batteryServiceUuid,
            name: 'Battery',
            characteristics: [
              CharacteristicDto(
                uuid: batteryLevelCharUuid,
                name: 'Level',
                canRead: true,
                canWrite: false,
                canNotify: false,
                commands: [],
                formatFields: [],
              ),
            ],
          ),
        ],
      );
      final reads = resolveBatteryReads(spec: spec, services: [
        _discovered(
            serviceUuid: _svc,
            charUuid: batteryLevelCharUuid,
            canRead: true,
            canWrite: false),
        _discovered(
            serviceUuid: batteryServiceUuid,
            charUuid: batteryLevelCharUuid,
            canRead: true,
            canWrite: false),
      ]);
      expect(reads.single.serviceUuid, batteryServiceUuid);
    });

    test(
        'a characteristic the spec declares under no service keeps the '
        'discovery-order fallback', () {
      final spec = _spec(entities: [
        _entity('Temperature',
            platform: 'sensor',
            stateCharacteristic: _stateChar,
            hasFormat: true),
      ]);
      final reads = resolveSensorReads(spec: spec, services: [
        _discovered(charUuid: _stateChar, canRead: true, canWrite: false),
      ]);
      expect(reads.single.serviceUuid, _svc);
    });
  });

  group('resolveSensorReads', () {
    test('caps the snapshot and dedupes variant bindings by name', () {
      final spec = _spec(entities: [
        for (var i = 0; i < 10; i++)
          _entity('Reading $i',
              platform: 'sensor',
              stateCharacteristic: _stateChar,
              hasFormat: true),
        _entity('Reading 0', // variant duplicate of the first
            platform: 'sensor',
            stateCharacteristic: _stateChar,
            hasFormat: true),
      ]);
      final reads = resolveSensorReads(
        spec: spec,
        services: [
          _discovered(charUuid: _stateChar, canRead: true, canWrite: false),
        ],
        cap: 4,
      );
      expect(reads, hasLength(4));
      expect([for (final r in reads) r.label],
          ['Reading 0', 'Reading 1', 'Reading 2', 'Reading 3']);
    });

    test('battery entities are excluded — they have their own op', () {
      final spec = _spec(entities: [
        _entity('Battery',
            platform: 'sensor',
            deviceClass: 'battery',
            stateCharacteristic: _stateChar,
            hasFormat: true),
      ]);
      expect(
        resolveSensorReads(spec: spec, services: [
          _discovered(charUuid: _stateChar, canRead: true, canWrite: false),
        ]),
        isEmpty,
      );
    });

    test('a notify-only characteristic is skipped — group reads are one-shot',
        () {
      final spec = _spec(entities: [
        _entity('Temperature',
            platform: 'sensor',
            stateCharacteristic: _stateChar,
            hasFormat: true),
      ]);
      expect(
        resolveSensorReads(spec: spec, services: [
          _discovered(charUuid: _stateChar, canRead: false, canWrite: false),
        ]),
        isEmpty,
      );
    });
  });

  group('groupReadingDisplay', () {
    test('SIG battery renders the pinned field with its SIG unit', () {
      const read = GroupRead(
        serviceUuid: batteryServiceUuid,
        charUuid: batteryLevelCharUuid,
        specBased: false,
        label: 'Battery',
      );
      expect(
        groupReadingDisplay(read, [_decoded('battery_percent', uintValue: 87)]),
        '87 %',
      );
    });

    test('spec reads follow the entity value field, scale and unit', () {
      final read = GroupRead(
        serviceUuid: _svc,
        charUuid: _stateChar,
        specBased: true,
        entity: _entity('Temperature',
            platform: 'sensor',
            stateCharacteristic: _stateChar,
            hasFormat: true,
            valueField: 'temperature',
            unit: '°C'),
        label: 'Temperature',
      );
      final display = groupReadingDisplay(read, [
        _decoded('flags', uintValue: 1),
        _decoded('temperature', uintValue: 235, scale: 0.1),
      ]);
      expect(display, '23.5 °C');
    });

    test('a code-table label wins over the number', () {
      final read = GroupRead(
        serviceUuid: _svc,
        charUuid: _stateChar,
        specBased: true,
        entity: _entity('State',
            platform: 'sensor',
            stateCharacteristic: _stateChar,
            hasFormat: true),
        label: 'State',
      );
      expect(
        groupReadingDisplay(
            read, [_decoded('state', uintValue: 5, valueLabel: 'heating')]),
        'heating',
      );
    });

    test('a value field the decode did not produce renders nothing', () {
      final read = GroupRead(
        serviceUuid: _svc,
        charUuid: _stateChar,
        specBased: true,
        entity: _entity('Ghost',
            platform: 'sensor',
            stateCharacteristic: _stateChar,
            hasFormat: true,
            valueField: 'missing'),
        label: 'Ghost',
      );
      expect(
          groupReadingDisplay(read, [_decoded('other', uintValue: 1)]), isNull);
      expect(groupReadingDisplay(read, const []), isNull);
    });
  });
}
