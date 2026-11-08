// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/core/group_actions.dart';
import 'package:liberated_bread_mobile/core/pride_flags.dart';
import 'package:liberated_bread_mobile/core/stop_signal.dart';
import 'package:liberated_bread_mobile/models/ble_discovered_service.dart';
import 'package:liberated_bread_mobile/services/ble_service.dart';
import 'package:liberated_bread_mobile/services/group_runner.dart';
import 'package:liberated_bread_mobile/services/spec_codec.dart';

import '../fakes/fake_ble_service.dart';
import '../fakes/fake_spec_codec.dart';

const _svc = '0000fff0-0000-1000-8000-00805f9b34fb';
const _cmdChar = '0000fff1-0000-1000-8000-00805f9b34fb';

DeviceSpecDto _bulbSpec() => DeviceSpecDto(
  nameMatchers: const [],
  platformFallbackTypes: const [],
  txtMatchGroups: const [],
  hiddenEntityNames: const [],
  deviceName: 'Bulb',
  manufacturer: 'Acme',
  manufacturerStatus: 'abandoned',
  protocol: 'ble',
  localNamePrefixes: const [],
  localNames: const [],
  serviceUuids: const [_svc],
  companyIds: Uint16List(0),
  macPrefixes: const [],
  mdnsServiceTypes: const [],
  ssdpSearchTargets: const [],
  lanProtocols: const [],
  services: const [],
  entities: const [
    EntityDto(
      options: [],
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
      variants: [],
    ),
  ],
);

/// A spec whose only verb is turn_on — the xkglow shape, used to prove the
/// pre-connect skip.
DeviceSpecDto _onOnlySpec() => DeviceSpecDto(
  nameMatchers: const [],
  platformFallbackTypes: const [],
  txtMatchGroups: const [],
  hiddenEntityNames: const [],
  deviceName: 'OnOnly',
  manufacturer: 'Acme',
  manufacturerStatus: 'abandoned',
  protocol: 'ble',
  localNamePrefixes: const [],
  localNames: const [],
  serviceUuids: const [_svc],
  companyIds: Uint16List(0),
  macPrefixes: const [],
  mdnsServiceTypes: const [],
  ssdpSearchTargets: const [],
  lanProtocols: const [],
  services: const [],
  entities: const [
    EntityDto(
      options: [],
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
      variants: [],
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

class _FlakyConnectBle extends FakeBleService {
  final void Function() onConnect;

  _FlakyConnectBle({required this.onConnect})
    : super(servicesToReturn: const [_controlService]);

  @override
  Future<void> connect(String deviceId) async {
    onConnect();
    await super.connect(deviceId);
  }
}

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

/// Keeps RealBleService's claim books: a connect that resolves takes a
/// claim whether or not anyone is still waiting, and a release with no
/// claim is the platform disconnect that cancels whatever connect is
/// running. Connects wait on [gate].
class _ClaimBooksBle extends FakeBleService {
  _ClaimBooksBle({required this.gate, super.servicesToReturn});

  final Completer<void> gate;
  int claims = 0;
  int unclaimedReleases = 0;

  @override
  Future<void> connect(String deviceId) async {
    await gate.future;
    claims++;
    return super.connect(deviceId);
  }

  @override
  Future<void> disconnect(String deviceId) async {
    if (claims > 0) {
      claims--;
    } else {
      unclaimedReleases++;
    }
    return super.disconnect(deviceId);
  }
}

DeviceSpecDto _prideSpec({
  String? category,
  ImageUploadDto? imageUpload,
  List<EntityDto> entities = const [],
}) => DeviceSpecDto(
  nameMatchers: const [],
  platformFallbackTypes: const [],
  txtMatchGroups: const [],
  hiddenEntityNames: const [],
  deviceName: 'Panel',
  manufacturer: 'Acme',
  manufacturerStatus: 'active',
  protocol: 'ble',
  category: category,
  localNamePrefixes: const [],
  localNames: const [],
  serviceUuids: const [_svc],
  companyIds: Uint16List(0),
  macPrefixes: const [],
  mdnsServiceTypes: const [],
  ssdpSearchTargets: const [],
  lanProtocols: const [],
  services: const [],
  imageUpload: imageUpload,
  entities: entities,
);

ImageUploadDto _upload({
  bool encodable = true,
  bool animatedUpload = false,
  bool reported = false,
  int? maxWidth = 32,
  int? maxHeight = 16,
}) => ImageUploadDto(
  encodable: encodable,
  maxWidth: maxWidth,
  maxHeight: maxHeight,
  resolutionDeviceReported: reported,
  animation: false,
  animatedUpload: animatedUpload,
);

const _colorLight = EntityDto(
  options: [],
  name: 'Strip',
  platform: 'light',
  canNotify: false,
  hasFormat: false,
  onWhenNonzero: false,
  variants: [],
  actions: [
    EntityActionDto(
      role: 'turn_on',
      serviceUuid: _svc,
      characteristicUuid: _cmdChar,
      commandName: 'power_on',
      userParams: [],
    ),
    EntityActionDto(
      role: 'set_color',
      serviceUuid: _svc,
      characteristicUuid: _cmdChar,
      commandName: 'set_rgb',
      userParams: ['red', 'green', 'blue'],
    ),
  ],
);

void main() {
  group('pride mode', () {
    Future<List<GroupRunEvent>> run(
      GroupRunner runner,
      List<GroupMember> members, {
      int firstPosition = 0,
    }) => runner
        .run(
          GroupOp.prideMode,
          members,
          firstPosition: firstPosition,
          stop: StopSignal(),
        )
        .toList();

    test('panels get different flags, in member order', () async {
      final ble = FakeBleService(servicesToReturn: const [_controlService]);
      final codec = FakeSpecCodec();
      final spec = _prideSpec(category: 'display', imageUpload: _upload());
      final events = await run(GroupRunner(ble: ble, codec: codec), [
        _member('A', spec: spec, yaml: 'y'),
        _member('B', spec: spec, yaml: 'y'),
      ]);

      expect(codec.encodeImageCalls, hasLength(2));
      expect(
        codec.encodeImageCalls[0].rgb,
        renderPrideFlag(prideFlagAt(0), 32, 16),
      );
      expect(
        codec.encodeImageCalls[1].rgb,
        renderPrideFlag(prideFlagAt(1), 32, 16),
      );
      expect(
        events
            .where((e) => e.status == GroupDeviceStatus.ok)
            .map((e) => e.detail),
        ['${prideFlagAt(0).name} flag set', '${prideFlagAt(1).name} flag set'],
      );
      expect(ble.writes, hasLength(2), reason: 'each plan actually went out');
    });

    test('a panel that holds an animation cycles from its own flag', () async {
      final ble = FakeBleService(servicesToReturn: const [_controlService]);
      final codec = FakeSpecCodec();
      final spec = _prideSpec(
        category: 'display',
        imageUpload: _upload(animatedUpload: true),
      );
      final events = await run(GroupRunner(ble: ble, codec: codec), [
        _member('A', spec: spec, yaml: 'y'),
      ], firstPosition: 3);

      expect(codec.animationFrames, hasLength(prideFlags.length));
      expect(
        codec.animationFrames!.first,
        renderPrideFlag(prideFlagAt(3), 32, 16),
      );
      expect(
        codec.animationFrames![1],
        renderPrideFlag(prideFlagAt(4), 32, 16),
      );
      expect(codec.animationDelayMs, GroupRunner.prideFlagSeconds * 1000);
      expect(events.last.status, GroupDeviceStatus.ok);
      expect(events.last.detail, 'Alternating ${prideFlags.length} flags');
    });

    test('a string with a canvas gets the rainbow, not a flag', () async {
      final ble = FakeBleService(servicesToReturn: const [_controlService]);
      final codec = FakeSpecCodec();
      final spec = _prideSpec(category: 'light', imageUpload: _upload());
      final events = await run(GroupRunner(ble: ble, codec: codec), [
        _member('A', spec: spec, yaml: 'y'),
      ]);

      expect(codec.encodeImageCalls.single.rgb, renderRainbowGradient(32, 16));
      expect(events.last.detail, 'Rainbow set');
    });

    test('single-colour lights take the rainbow one colour each', () async {
      final ble = FakeBleService(servicesToReturn: const [_controlService]);
      final codec = FakeSpecCodec(encoded: Uint8List.fromList([0x01]));
      final spec = _prideSpec(category: 'light', entities: const [_colorLight]);
      final events = await run(GroupRunner(ble: ble, codec: codec), [
        _member('A', spec: spec, yaml: 'y'),
        _member('B', spec: spec, yaml: 'y'),
      ]);

      final colors = codec.encodeCalls
          .where((c) => c.commandName == 'set_rgb')
          .map((c) => c.params)
          .toList();
      Map<String, double> asParams(Rgb c) => {
        'red': c.r.toDouble(),
        'green': c.g.toDouble(),
        'blue': c.b.toDouble(),
      };
      expect(colors, [asParams(prideColorAt(0)), asParams(prideColorAt(1))]);
      expect(
        codec.encodeCalls.map((c) => c.commandName).take(2),
        ['power_on', 'set_rgb'],
        reason: 'on first, for a light whose colour does not wake it',
      );
      expect(events.last.detail, 'Rainbow colour set');
    });

    test('a printer never runs its roll out, nor a lock its bolt', () async {
      final ble = FakeBleService(servicesToReturn: const [_controlService]);
      final codec = FakeSpecCodec();
      final printer = _prideSpec(category: 'printer', imageUpload: _upload());
      final lock = _prideSpec(category: 'lock', entities: const [_colorLight]);
      expect(supportedGroupOps(printer), isNot(contains(GroupOp.prideMode)));
      expect(supportedGroupOps(lock), isNot(contains(GroupOp.prideMode)));

      final events = await run(GroupRunner(ble: ble, codec: codec), [
        _member('P', spec: printer, yaml: 'y'),
        _member('L', spec: lock, yaml: 'y'),
      ]);
      expect(
        events.every((e) => e.status == GroupDeviceStatus.skipped),
        isTrue,
      );
      expect(ble.writes, isEmpty);
      expect(ble.events, isEmpty, reason: 'ruled out before spending radio');
    });

    test('a one-colour panel cannot show a flag and says so', () async {
      final ble = FakeBleService(servicesToReturn: const [_controlService]);
      final codec = FakeSpecCodec();
      final spec = _prideSpec(
        category: 'display',
        imageUpload: const ImageUploadDto(
          encodable: true,
          format: '1bit-bitmap',
          maxWidth: 64,
          maxHeight: 16,
          resolutionDeviceReported: false,
          animation: false,
          animatedUpload: false,
        ),
      );
      expect(supportedGroupOps(spec), isNot(contains(GroupOp.prideMode)));
      final events = await run(GroupRunner(ble: ble, codec: codec), [
        _member('A', spec: spec, yaml: 'y'),
      ]);
      expect(events.single.status, GroupDeviceStatus.skipped);
      expect(codec.encodeImageCalls, isEmpty);
    });

    test('an upload this build cannot encode does not claim support', () {
      final spec = _prideSpec(
        category: 'display',
        imageUpload: _upload(encodable: false),
      );
      expect(supportedGroupOps(spec), isNot(contains(GroupOp.prideMode)));
    });

    test('a panel asked for its size is drawn at that size', () async {
      final ble = FakeBleService(servicesToReturn: const [_controlService]);
      final codec = FakeSpecCodec()
        ..panelProbeResult = PanelProbeDto(
          serviceUuid: _svc,
          writeCharacteristicUuid: _cmdChar,
          notifyCharacteristicUuid: _cmdChar,
          bytes: Uint8List.fromList([0x01]),
        )
        ..panelReplyResolution = const PanelResolutionDto(
          width: 96,
          height: 16,
        );
      final spec = _prideSpec(
        category: 'display',
        imageUpload: _upload(reported: true, maxWidth: null, maxHeight: null),
      );
      await run(
        GroupRunner(ble: ble, codec: codec, panelQueryListen: Duration.zero),
        [_member('A', spec: spec, yaml: 'y')],
      );
      expect(codec.encodeImageCalls.single.width, 96);
      expect(codec.encodeImageCalls.single.height, 16);
    });

    test(
      'a panel that will not say falls back to what was remembered',
      () async {
        final ble = FakeBleService(servicesToReturn: const [_controlService]);
        final codec = FakeSpecCodec();
        final spec = _prideSpec(
          category: 'light',
          imageUpload: _upload(reported: true, maxWidth: 255, maxHeight: 255),
        );
        await run(
          GroupRunner(
            ble: ble,
            codec: codec,
            rememberedSize: (_) => (width: 20, height: 20),
          ),
          [_member('A', spec: spec, yaml: 'y')],
        );
        expect(codec.encodeImageCalls.single.width, 20);
      },
    );

    test(
      'a failed upload is that member failing, and the run goes on',
      () async {
        final ble = FakeBleService(servicesToReturn: const [_controlService]);
        final codec = FakeSpecCodec(encodeImageError: StateError('no'));
        final spec = _prideSpec(category: 'display', imageUpload: _upload());
        final events = await run(GroupRunner(ble: ble, codec: codec), [
          _member('A', spec: spec, yaml: 'y'),
          _member('B', spec: spec, yaml: 'y'),
        ]);
        expect(
          events.where((e) => e.status == GroupDeviceStatus.failed),
          hasLength(2),
        );
        expect(ble.events, contains('disconnect:B'));
      },
    );
  });

  test('a transient connect failure is retried once', () async {
    var attempts = 0;
    final ble = _FlakyConnectBle(
      onConnect: () {
        if (++attempts == 1) throw Exception('link still closing');
      },
    );
    final codec = FakeSpecCodec(encoded: Uint8List.fromList([0x00]));
    final events =
        await GroupRunner(
          ble: ble,
          codec: codec,
          connectRetryPause: Duration.zero,
        ).run(GroupOp.turnOff, [
          _member('A', spec: _bulbSpec(), yaml: 'y'),
        ], stop: StopSignal()).toList();
    expect(attempts, 2);
    expect(events.last.status, GroupDeviceStatus.ok);
  });

  test('a connect failure that is an answer is not retried', () async {
    var attempts = 0;
    final ble = _FlakyConnectBle(
      onConnect: () {
        attempts++;
        throw const BlePermissionDeniedException('denied');
      },
    );
    final events =
        await GroupRunner(
          ble: ble,
          codec: FakeSpecCodec(),
          connectRetryPause: Duration.zero,
        ).run(GroupOp.turnOff, [
          _member('A', spec: _bulbSpec(), yaml: 'y'),
        ], stop: StopSignal()).toList();
    expect(attempts, 1);
    expect(events.last.status, GroupDeviceStatus.failed);
  });

  test('runs members strictly one at a time, stopping the scan first', () async {
    final ble = FakeBleService(servicesToReturn: const [_controlService]);
    final codec = FakeSpecCodec(encoded: Uint8List.fromList([0x00]));
    final runner = GroupRunner(ble: ble, codec: codec);

    final events = await runner.run(GroupOp.turnOff, [
      _member('A', spec: _bulbSpec(), yaml: 'y'),
      _member('B', spec: _bulbSpec(), yaml: 'y'),
    ], stop: StopSignal()).toList();

    expect(ble.stopScanCount, 1);
    // One device fully finishes (including disconnect) before the next starts.
    expect(ble.events, [
      'connect:A',
      'disconnect:A',
      'connect:B',
      'disconnect:B',
    ]);
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
    // The pair, not just the characteristic: the codec scopes its command
    // lookup to the named service.
    expect(codec.encodeCalls.first.serviceUuid, _svc);
  });

  test(
    'a member whose spec lacks the op is skipped without connecting',
    () async {
      final ble = FakeBleService(servicesToReturn: const [_controlService]);
      final runner = GroupRunner(ble: ble, codec: FakeSpecCodec());

      final events = await runner.run(GroupOp.turnOff, [
        _member('A', spec: _onOnlySpec(), yaml: 'y'),
      ], stop: StopSignal()).toList();

      expect(events.single.status, GroupDeviceStatus.skipped);
      expect(events.single.detail, "Not supported by this device's spec");
      expect(ble.events, isEmpty); // never connected
    },
  );

  test('a connect failure fails that member and the run continues', () async {
    final ble = _PerDeviceFakeBle(
      connectFails: {'A'},
      servicesToReturn: const [_controlService],
    );
    final runner = GroupRunner(
      ble: ble,
      codec: FakeSpecCodec(encoded: Uint8List.fromList([0x00])),
    );

    final events = await runner.run(GroupOp.turnOff, [
      _member('A', spec: _bulbSpec(), yaml: 'y'),
      _member('B', spec: _bulbSpec(), yaml: 'y'),
    ], stop: StopSignal()).toList();

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
      ble: ble,
      codec: FakeSpecCodec(encoded: Uint8List.fromList([0x00])),
    );

    final events = await runner.run(GroupOp.turnOff, [
      _member('A', spec: _bulbSpec(), yaml: 'y'),
    ], stop: StopSignal()).toList();

    expect(events.last.status, GroupDeviceStatus.failed);
    expect(ble.events, ['connect:A', 'disconnect:A']);
  });

  test('a stop signal skips every member not yet started', () async {
    final ble = FakeBleService(servicesToReturn: const [_controlService]);
    final codec = FakeSpecCodec(encoded: Uint8List.fromList([0x00]));
    final runner = GroupRunner(ble: ble, codec: codec);
    final stop = StopSignal();

    final events = <GroupRunEvent>[];
    await for (final event in runner.run(GroupOp.turnOff, [
      _member('A', spec: _bulbSpec(), yaml: 'y'),
      _member('B', spec: _bulbSpec(), yaml: 'y'),
    ], stop: stop)) {
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

  test('a spec that promises the op but a unit without the characteristic '
      'is skipped as not found', () async {
    // Discovery returns no services at all: the family spec's variant gap.
    final ble = FakeBleService(servicesToReturn: const []);
    final runner = GroupRunner(
      ble: ble,
      codec: FakeSpecCodec(encoded: Uint8List.fromList([0x00])),
    );

    final events = await runner.run(GroupOp.turnOff, [
      _member('A', spec: _bulbSpec(), yaml: 'y'),
    ], stop: StopSignal()).toList();

    expect(events.last.status, GroupDeviceStatus.skipped);
    expect(events.last.detail, 'Not found on this device');
    expect(ble.events, ['connect:A', 'disconnect:A']);
  });

  test(
    'battery reads work with no spec at all through the SIG service',
    () async {
      final ble = FakeBleService(
        servicesToReturn: const [_batteryService],
        readValues: {
          batteryLevelCharUuid.toLowerCase(): const [87],
        },
      );
      final codec = FakeSpecCodec(
        decoded: const [
          DecodedValueDto(
            name: 'battery_percent',
            valueType: 'uint8',
            display: '87',
            uintValue: 87,
            rawNumber: 87.0,
            decodedNumber: 87.0,
            decodedText: '87',
            decimals: 0,
          ),
        ],
      );
      final runner = GroupRunner(ble: ble, codec: codec);

      final events = await runner.run(GroupOp.readBattery, [
        _member('A'),
      ], stop: StopSignal()).toList();

      final done = events.last;
      expect(done.status, GroupDeviceStatus.ok);
      expect(done.readings.single.label, 'Battery');
      expect(done.readings.single.value, '87 %');
    },
  );

  test('a member with no battery surface is skipped, not failed', () async {
    final ble = FakeBleService(servicesToReturn: const [_controlService]);
    final runner = GroupRunner(ble: ble, codec: FakeSpecCodec());

    final events = await runner.run(GroupOp.readBattery, [
      _member('A'),
    ], stop: StopSignal()).toList();

    expect(events.last.status, GroupDeviceStatus.skipped);
    expect(events.last.detail, 'No battery reading on this device');
  });

  test(
    'a read error on the only reading fails the member after disconnect',
    () async {
      final ble = FakeBleService(
        servicesToReturn: const [_batteryService],
        readError: Exception('read refused'),
      );
      final runner = GroupRunner(ble: ble, codec: FakeSpecCodec());

      final events = await runner.run(GroupOp.readBattery, [
        _member('A'),
      ], stop: StopSignal()).toList();

      expect(events.last.status, GroupDeviceStatus.failed);
      expect(ble.events, ['connect:A', 'disconnect:A']);
    },
  );

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

    final events = await runner.run(GroupOp.turnOff, [
      _member('A'),
    ], stop: StopSignal()).toList();

    expect(resolverCalls, 1);
    expect(events.last.status, GroupDeviceStatus.ok);
    expect(ble.writes, hasLength(1));
  });

  test('sensor snapshot without a spec is skipped', () async {
    final ble = FakeBleService(servicesToReturn: const [_controlService]);
    final runner = GroupRunner(ble: ble, codec: FakeSpecCodec());

    final events = await runner.run(GroupOp.readSensors, [
      _member('A'),
    ], stop: StopSignal()).toList();

    expect(events.last.status, GroupDeviceStatus.skipped);
    expect(events.last.detail, 'No spec matched this device');
  });

  test('cancelling the stream mid-run still disconnects the device', () async {
    final ble = FakeBleService(servicesToReturn: const [_controlService]);
    final codec = FakeSpecCodec(encoded: Uint8List.fromList([0x00]));
    final runner = GroupRunner(ble: ble, codec: codec);

    final sub = runner
        .run(GroupOp.turnOff, [
          _member('A', spec: _bulbSpec(), yaml: 'y'),
        ], stop: StopSignal())
        .listen(null);
    // Give the generator a beat to connect, then cancel the listener the way
    // a disposed screen would.
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
    await sub.cancel();

    expect(ble.events, contains('connect:A'));
    expect(ble.events, contains('disconnect:A'));
  });

  test('a connect that lands after the timeout gives its claim back', () async {
    // Future.timeout stops the wait, not the connect. The late connect
    // took a claim nobody released, so the device stayed connected (and
    // stopped advertising) until the app died; and the run's finally sent
    // a release it had no claim for, which on the real service cancelled
    // whichever connect was running — another owner's included. Fails on
    // the old code: one unclaimed release, and one claim left behind.
    final gate = Completer<void>();
    final ble = _ClaimBooksBle(
      gate: gate,
      servicesToReturn: const [_controlService],
    );
    final runner = GroupRunner(
      ble: ble,
      codec: FakeSpecCodec(encoded: Uint8List.fromList([0x00])),
      connectTimeout: const Duration(milliseconds: 20),
    );

    final events = await runner.run(GroupOp.turnOff, [
      _member('A', spec: _bulbSpec(), yaml: 'y'),
    ], stop: StopSignal()).toList();

    expect(events.last.status, GroupDeviceStatus.failed);
    expect(ble.events, ['cancel:A'], reason: 'no release without a claim');

    gate.complete();
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);

    expect(ble.unclaimedReleases, 0);
    expect(ble.claims, 0);
    expect(ble.events, ['cancel:A', 'connect:A', 'disconnect:A']);
  });
}
