// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/core/group_actions.dart';
import 'package:liberated_bread_mobile/core/stop_signal.dart';
import 'package:liberated_bread_mobile/models/ble_discovered_service.dart';
import 'package:liberated_bread_mobile/services/group_runner.dart';
import 'package:liberated_bread_mobile/services/spec_codec.dart';

import '../fakes/fake_ble_service.dart';
import '../fakes/fake_spec_codec.dart';

const _svc = '0000fff0-0000-1000-8000-00805f9b34fb';
const _cmdChar = '0000fff1-0000-1000-8000-00805f9b34fb';

DeviceSpecDto _bulbSpec() => DeviceSpecDto(
      deviceName: 'Bulb',
      manufacturer: 'Acme',
      manufacturerStatus: 'abandoned',
      protocol: 'ble',
      localNamePrefixes: const [],
      serviceUuids: const [_svc],
      companyIds: Uint16List(0),
      macPrefixes: const [],
      ssdpSearchTargets: const [],
      services: const [],
      entities: const [
        EntityDto(
          name: 'Bulb',
          platform: 'light',
          canNotify: false,
          hasFormat: false,
          onWhenNonzero: false,
          actions: [
            EntityActionDto(
              role: 'turn_off',
              serviceUuid: _svc,
              characteristicUuid: _cmdChar,
              commandName: 'power_off',
              userParams: [],
            ),
          ],
        ),
      ],
    );

/// A spec whose only verb is turn_on — the xkglow shape, used to prove the
/// pre-connect skip.
DeviceSpecDto _onOnlySpec() => DeviceSpecDto(
      deviceName: 'OnOnly',
      manufacturer: 'Acme',
      manufacturerStatus: 'abandoned',
      protocol: 'ble',
      localNamePrefixes: const [],
      serviceUuids: const [_svc],
      companyIds: Uint16List(0),
      macPrefixes: const [],
      ssdpSearchTargets: const [],
      services: const [],
      entities: const [
        EntityDto(
          name: 'LEDs',
          platform: 'light',
          canNotify: false,
          hasFormat: false,
          onWhenNonzero: false,
          actions: [
            EntityActionDto(
              role: 'turn_on',
              serviceUuid: _svc,
              characteristicUuid: _cmdChar,
              commandName: 'on',
              userParams: [],
            ),
          ],
        ),
      ],
    );

const _controlService = BleDiscoveredService(
  uuid: _svc,
  characteristics: [
    BleDiscoveredCharacteristic(
      uuid: _cmdChar,
      canRead: false,
      canWrite: true,
      canNotify: false,
    ),
  ],
);

const _batteryService = BleDiscoveredService(
  uuid: batteryServiceUuid,
  characteristics: [
    BleDiscoveredCharacteristic(
      uuid: batteryLevelCharUuid,
      canRead: true,
      canWrite: false,
      canNotify: false,
    ),
  ],
);

GroupMember _member(String id, {DeviceSpecDto? spec, String? yaml}) =>
    GroupMember(id: id, name: id, spec: spec, specYaml: yaml);

/// Per-device failures, which the base fake's single mutable error field
/// cannot express.
class _PerDeviceFakeBle extends FakeBleService {
  final Set<String> connectFails;
  final Set<String> writeFails;

  _PerDeviceFakeBle({
    this.connectFails = const {},
    this.writeFails = const {},
    super.servicesToReturn,
  });

  @override
  Future<void> connect(String deviceId) async {
    if (connectFails.contains(deviceId)) {
      events.add('connect-failed:$deviceId');
      throw Exception('connect refused');
    }
    return super.connect(deviceId);
  }

  @override
  Future<void> writeCharacteristic(
    String deviceId,
    String serviceUuid,
    String charUuid,
    List<int> value,
  ) async {
    if (writeFails.contains(deviceId)) throw Exception('write refused');
    return super.writeCharacteristic(deviceId, serviceUuid, charUuid, value);
  }
}

void main() {
  test('runs members strictly one at a time, stopping the scan first',
      () async {
    final ble = FakeBleService(servicesToReturn: const [_controlService]);
    final codec = FakeSpecCodec(encoded: Uint8List.fromList([0x00]));
    final runner = GroupRunner(ble: ble, codec: codec);

    final events = await runner
        .run(
          GroupOp.turnOff,
          [
            _member('A', spec: _bulbSpec(), yaml: 'y'),
            _member('B', spec: _bulbSpec(), yaml: 'y')
          ],
          stop: StopSignal(),
        )
        .toList();

    expect(ble.stopScanCount, 1);
    // One device fully finishes (including disconnect) before the next starts.
    expect(
        ble.events, ['connect:A', 'disconnect:A', 'connect:B', 'disconnect:B']);
    final byDevice = {
      for (final e in events)
        if (e.status == GroupDeviceStatus.ok) e.deviceId: e,
    };
    expect(byDevice.keys, {'A', 'B'});
    expect(byDevice['A']!.detail, '1 command sent');
    expect(ble.writes, hasLength(2));
    expect(codec.encodeCalls, hasLength(2));
    expect(codec.encodeCalls.first.commandName, 'power_off');
    expect(codec.encodeCalls.first.params, isEmpty);
  });

  test('a member whose spec lacks the op is skipped without connecting',
      () async {
    final ble = FakeBleService(servicesToReturn: const [_controlService]);
    final runner = GroupRunner(ble: ble, codec: FakeSpecCodec());

    final events = await runner
        .run(
          GroupOp.turnOff,
          [_member('A', spec: _onOnlySpec(), yaml: 'y')],
          stop: StopSignal(),
        )
        .toList();

    expect(events.single.status, GroupDeviceStatus.skipped);
    expect(events.single.detail, "Not supported by this device's spec");
    expect(ble.events, isEmpty); // never connected
  });

  test('a connect failure fails that member and the run continues', () async {
    final ble = _PerDeviceFakeBle(
      connectFails: {'A'},
      servicesToReturn: const [_controlService],
    );
    final runner = GroupRunner(
        ble: ble, codec: FakeSpecCodec(encoded: Uint8List.fromList([0x00])));

    final events = await runner
        .run(
          GroupOp.turnOff,
          [
            _member('A', spec: _bulbSpec(), yaml: 'y'),
            _member('B', spec: _bulbSpec(), yaml: 'y')
          ],
          stop: StopSignal(),
        )
        .toList();

    final a = events.lastWhere((e) => e.deviceId == 'A');
    final b = events.lastWhere((e) => e.deviceId == 'B');
    expect(a.status, GroupDeviceStatus.failed);
    expect(b.status, GroupDeviceStatus.ok);
    // B still ran normally after A's failure.
    expect(ble.events, contains('connect:B'));
  });

  test('a write failure still disconnects the device', () async {
    final ble = _PerDeviceFakeBle(
      writeFails: {'A'},
      servicesToReturn: const [_controlService],
    );
    final runner = GroupRunner(
        ble: ble, codec: FakeSpecCodec(encoded: Uint8List.fromList([0x00])));

    final events = await runner
        .run(
          GroupOp.turnOff,
          [_member('A', spec: _bulbSpec(), yaml: 'y')],
          stop: StopSignal(),
        )
        .toList();

    expect(events.last.status, GroupDeviceStatus.failed);
    expect(ble.events, ['connect:A', 'disconnect:A']);
  });

  test('a stop signal skips every member not yet started', () async {
    final ble = FakeBleService(servicesToReturn: const [_controlService]);
    final codec = FakeSpecCodec(encoded: Uint8List.fromList([0x00]));
    final runner = GroupRunner(ble: ble, codec: codec);
    final stop = StopSignal();

    final events = <GroupRunEvent>[];
    await for (final event in runner.run(
      GroupOp.turnOff,
      [
        _member('A', spec: _bulbSpec(), yaml: 'y'),
        _member('B', spec: _bulbSpec(), yaml: 'y')
      ],
      stop: stop,
    )) {
      events.add(event);
      // Cancel as soon as A lands; B must not get radio time.
      if (event.deviceId == 'A' && event.status == GroupDeviceStatus.ok) {
        stop.stop();
      }
    }

    final b = events.lastWhere((e) => e.deviceId == 'B');
    expect(b.status, GroupDeviceStatus.skipped);
    expect(b.detail, 'Cancelled');
    expect(ble.events, isNot(contains('connect:B')));
  });

  test(
      'a spec that promises the op but a unit without the characteristic '
      'is skipped as not found', () async {
    // Discovery returns no services at all: the family spec's variant gap.
    final ble = FakeBleService(servicesToReturn: const []);
    final runner = GroupRunner(
        ble: ble, codec: FakeSpecCodec(encoded: Uint8List.fromList([0x00])));

    final events = await runner
        .run(
          GroupOp.turnOff,
          [_member('A', spec: _bulbSpec(), yaml: 'y')],
          stop: StopSignal(),
        )
        .toList();

    expect(events.last.status, GroupDeviceStatus.skipped);
    expect(events.last.detail, 'Not found on this device');
    expect(ble.events, ['connect:A', 'disconnect:A']);
  });

  test('battery reads work with no spec at all through the SIG service',
      () async {
    final ble = FakeBleService(
      servicesToReturn: const [_batteryService],
      readValues: {
        batteryLevelCharUuid.toLowerCase(): const [87]
      },
    );
    final codec = FakeSpecCodec(decoded: const [
      DecodedValueDto(
        name: 'battery_percent',
        valueType: 'uint8',
        display: '87',
        uintValue: 87,
      ),
    ]);
    final runner = GroupRunner(ble: ble, codec: codec);

    final events = await runner
        .run(
          GroupOp.readBattery,
          [_member('A')],
          stop: StopSignal(),
        )
        .toList();

    final done = events.last;
    expect(done.status, GroupDeviceStatus.ok);
    expect(done.readings.single.label, 'Battery');
    expect(done.readings.single.value, '87 %');
  });

  test('a member with no battery surface is skipped, not failed', () async {
    final ble = FakeBleService(servicesToReturn: const [_controlService]);
    final runner = GroupRunner(ble: ble, codec: FakeSpecCodec());

    final events = await runner
        .run(
          GroupOp.readBattery,
          [_member('A')],
          stop: StopSignal(),
        )
        .toList();

    expect(events.last.status, GroupDeviceStatus.skipped);
    expect(events.last.detail, 'No battery reading on this device');
  });

  test('a read error on the only reading fails the member after disconnect',
      () async {
    final ble = FakeBleService(
      servicesToReturn: const [_batteryService],
      readError: Exception('read refused'),
    );
    final runner = GroupRunner(ble: ble, codec: FakeSpecCodec());

    final events = await runner
        .run(
          GroupOp.readBattery,
          [_member('A')],
          stop: StopSignal(),
        )
        .toList();

    expect(events.last.status, GroupDeviceStatus.failed);
    expect(ble.events, ['connect:A', 'disconnect:A']);
  });

  test('a member without a stored spec resolves one after discovery', () async {
    final ble = FakeBleService(servicesToReturn: const [_controlService]);
    final codec = FakeSpecCodec(encoded: Uint8List.fromList([0x00]));
    var resolverCalls = 0;
    final runner = GroupRunner(
      ble: ble,
      codec: codec,
      resolveSpec: (member, services) async {
        resolverCalls++;
        expect(services, const [_controlService]);
        return (spec: _bulbSpec(), yaml: 'resolved-yaml');
      },
    );

    final events = await runner
        .run(
          GroupOp.turnOff,
          [_member('A')],
          stop: StopSignal(),
        )
        .toList();

    expect(resolverCalls, 1);
    expect(events.last.status, GroupDeviceStatus.ok);
    expect(ble.writes, hasLength(1));
  });

  test('sensor snapshot without a spec is skipped', () async {
    final ble = FakeBleService(servicesToReturn: const [_controlService]);
    final runner = GroupRunner(ble: ble, codec: FakeSpecCodec());

    final events = await runner
        .run(
          GroupOp.readSensors,
          [_member('A')],
          stop: StopSignal(),
        )
        .toList();

    expect(events.last.status, GroupDeviceStatus.skipped);
    expect(events.last.detail, 'No spec matched this device');
  });

  test('cancelling the stream mid-run still disconnects the device', () async {
    final ble = FakeBleService(servicesToReturn: const [_controlService]);
    final codec = FakeSpecCodec(encoded: Uint8List.fromList([0x00]));
    final runner = GroupRunner(ble: ble, codec: codec);

    final sub = runner
        .run(
          GroupOp.turnOff,
          [_member('A', spec: _bulbSpec(), yaml: 'y')],
          stop: StopSignal(),
        )
        .listen(null);
    // Give the generator a beat to connect, then cancel the listener the way
    // a disposed screen would.
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
    await sub.cancel();

    expect(ble.events, contains('connect:A'));
    expect(ble.events, contains('disconnect:A'));
  });
}
