// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// The MPID session layer against a scripted Lumalou. The crypto is Rust's and
// is pinned there against the spec's vectors; here a stand-in codec whose
// "frames" are readable (7e, seq, body...) lets the tests check what the
// layer does with them: the handshake's order and pacing, the frame counter,
// what it refuses, and what happens when the unit answers garbage or nothing.
// The last group runs the real codec over FFI against the spec's own vectors.
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/core/group_actions.dart';
import 'package:liberated_bread_mobile/core/stop_signal.dart';
import 'package:liberated_bread_mobile/models/ble_discovered_service.dart';
import 'package:liberated_bread_mobile/services/ble_service.dart';
import 'package:liberated_bread_mobile/services/group_runner.dart';
import 'package:liberated_bread_mobile/services/mattel_mpid_ble_service.dart';
import 'package:liberated_bread_mobile/services/real_spec_codec.dart';
import 'package:liberated_bread_mobile/src/rust/api/mpid_api.dart' as rust;

import '../helpers/host_rust_lib.dart';

const _svc = '4cea0001-c678-4202-b5d3-712dbb5e5b14';
const _tx = '4cea0002-c678-4202-b5d3-712dbb5e5b14';
const _rx = '4cea0003-c678-4202-b5d3-712dbb5e5b14';
const _token = '4cea0004-c678-4202-b5d3-712dbb5e5b14';
const _session = '4cea0005-c678-4202-b5d3-712dbb5e5b14';
const _dfu = '00001530-1212-efde-1523-785feabcd123';

const _enableRx = [0x01, 0x50, 0x01];
const _requestState = [0x01, 0x10, 0xFE, 0x01, 0x53, 0x52];

/// GLOBAL_STATE from the spec's `rx_seq9_plaintext`.
const _globalState = [
  0x01, 0x50, 0xFE, 0x0E, 0x02, 0x01, 0x10, 0x34, 0x51, 0x64, //
  0x00, 0x10, 0x02, 0x13, 0x10, 0x10, 0x45, 0x10, 0x48,
];

/// A CURRENT_DATE tick, which the unit streams once ENABLE_RX is in.
const _clockTick = [0x01, 0x50, 0xFE, 0x05, 0x13, 0x23, 0x59, 0x00, 0x03, 0x17];

rust.MpidChannelsDto _channels() => rust.MpidChannelsDto(
  serviceUuid: _svc,
  txUuid: _tx,
  rxUuid: _rx,
  tokenUuid: _token,
  sessionUuid: _session,
  dfuServiceUuid: _dfu,
  afterSessionWriteMs: 400,
  afterEnableRxMs: 300,
  betweenCommandsMs: 150,
  enableRx: Uint8List.fromList(_enableRx),
  requestGlobalState: Uint8List.fromList(_requestState),
);

/// Frames anyone can read: `7e seq body...`. A token that is not 192 bytes is
/// refused, as Rust refuses it; a body opening 01 10 fe 02 34 (the pairing
/// message the spec says never to send) is refused, as Rust's allow list
/// refuses it.
class _ReadableCodec implements MpidCodec {
  int sessions = 0;

  @override
  rust.MpidChannelsDto channels() => _channels();

  @override
  Future<rust.MpidSessionDto> startSession(List<int> token) async {
    if (token.length != 192) throw StateError('not a token');
    sessions++;
    return rust.MpidSessionDto(
      key: Uint8List.fromList([sessions]),
      appNonce: Uint8List(4),
      deviceSalt: Uint8List(4),
      sessionWrite: Uint8List.fromList([0xA0 + sessions]),
    );
  }

  @override
  Uint8List seal(rust.MpidSessionDto session, int seq, List<int> body) {
    if (body.length > 4 && body[4] == 0x34) throw StateError('undeclared');
    return Uint8List.fromList([0x7E, seq, ...body]);
  }

  @override
  Uint8List open(rust.MpidSessionDto session, List<int> frame) {
    if (frame.length < 2 || frame[0] != 0x7E) throw StateError('not a frame');
    return Uint8List.fromList(frame.sublist(2));
  }
}

enum _Answers { properly, garbage, nothing }

/// A Lumalou on the other end of the link, as far as the layer can see one.
class _Lumalou implements BleService {
  _Answers answers = _Answers.properly;
  List<int> token = List.filled(192, 7);

  _Lumalou();

  final writes = <(String service, String char, List<int> value)>[];
  final _notify = StreamController<List<int>>.broadcast();
  final _state = StreamController<BleConnectionState>.broadcast();
  int _deviceSeq = 100;

  /// Bodies the unit has received, unwrapped from the readable frames.
  List<List<int>> get bodies => [
    for (final (_, char, value) in writes)
      if (char == _tx) value.sublist(2),
  ];

  List<int> get frameNumbers => [
    for (final (_, char, value) in writes)
      if (char == _tx) value[1],
  ];

  void notify(List<int> body) => _notify.add([0x7E, _deviceSeq++, ...body]);

  void drop() => _state.add(BleConnectionState.disconnected);

  @override
  Future<List<int>> readCharacteristic(
    String deviceId,
    String serviceUuid,
    String charUuid,
  ) async {
    if (charUuid != _token) throw StateError('unexpected read $charUuid');
    if (answers == _Answers.nothing) return Completer<List<int>>().future;
    return token;
  }

  @override
  Future<void> writeCharacteristic(
    String deviceId,
    String serviceUuid,
    String charUuid,
    List<int> value,
  ) async {
    writes.add((serviceUuid, charUuid, List.of(value)));
    if (charUuid != _tx) return;
    final body = value.sublist(2);
    switch (answers) {
      case _Answers.properly:
        if (_listEquals(body, _enableRx)) {
          scheduleMicrotask(() => notify(_clockTick));
        } else if (_listEquals(body, _requestState)) {
          scheduleMicrotask(() => notify(_globalState));
        }
      case _Answers.garbage:
        scheduleMicrotask(() => _notify.add([0x00, 0x01, 0x02, 0x03]));
      case _Answers.nothing:
        break;
    }
  }

  @override
  Stream<List<int>> subscribeCharacteristic(
    String deviceId,
    String serviceUuid,
    String charUuid,
  ) {
    expect(charUuid, _rx);
    return _notify.stream;
  }

  @override
  Stream<BleConnectionState> connectionState(String deviceId) => _state.stream;

  @override
  Future<List<BleDiscoveredService>> discoverServices(String deviceId) async =>
      const [
        BleDiscoveredService(uuid: _svc, characteristics: []),
        BleDiscoveredService(uuid: _dfu, characteristics: []),
      ];

  @override
  Future<void> connect(String deviceId) async {}

  @override
  Future<void> disconnect(String deviceId) async {}

  @override
  Future<void> stopScan() async {}

  @override
  Future<int> mtu(String deviceId) async => 247;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

bool _listEquals(List<int> a, List<int> b) =>
    a.length == b.length &&
    Iterable<int>.generate(a.length).every((i) => a[i] == b[i]);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _Lumalou unit;
  late _ReadableCodec codec;
  late List<Duration> slept;

  MattelMpidBleService layer({Duration confirm = const Duration(seconds: 1)}) =>
      MattelMpidBleService(
        unit,
        codec: codec,
        ioTimeout: const Duration(seconds: 1),
        confirmTimeout: confirm,
        sleep: (d) async => slept.add(d),
        now: () => DateTime(2026),
      );

  setUp(() {
    unit = _Lumalou();
    codec = _ReadableCodec();
    slept = [];
  });

  test('the first write opens the session in the spec\'s order', () async {
    final ble = layer();
    await ble.writeCharacteristic('d', _svc, _tx, [
      0x01,
      0x10,
      0xFE,
      0x02,
      0x3C,
      0x09,
      0x37,
    ]);

    expect(unit.writes.first.$2, _session);
    expect(unit.writes.first.$3, [0xA1]);
    expect(unit.bodies, [
      _enableRx,
      _requestState,
      [0x01, 0x10, 0xFE, 0x02, 0x3C, 0x09, 0x37],
    ]);
    expect(unit.frameNumbers, [1, 2, 3]);
    // 400 ms after the session write, 300 after ENABLE_RX, then the gap
    // between commands.
    expect(slept.take(2), [
      const Duration(milliseconds: 400),
      const Duration(milliseconds: 300),
    ]);
    expect(slept.skip(2), everyElement(const Duration(milliseconds: 150)));
    expect(ble.hasSession('d'), isTrue);
  });

  test('later writes reuse the session and keep counting', () async {
    final ble = layer();
    await ble.writeCharacteristic('d', _svc, _tx, [
      0x01,
      0x10,
      0xFE,
      0x01,
      0x3E,
      0x3F,
    ]);
    await ble.writeCharacteristic('d', _svc, _tx, [
      0x01,
      0x10,
      0xFE,
      0x01,
      0x38,
      0x39,
    ]);
    expect(codec.sessions, 1);
    expect(unit.frameNumbers, [1, 2, 3, 4]);
    expect(unit.writes.where((w) => w.$2 == _session), hasLength(1));
  });

  test('a subscriber hears decrypted bodies, state first', () async {
    final ble = layer();
    final heard = <List<int>>[];
    final sub = ble.subscribeCharacteristic('d', _svc, _rx).listen(heard.add);
    await pumpEventQueue();
    expect(ble.hasSession('d'), isTrue);
    expect(heard, containsAll([equals(_clockTick), equals(_globalState)]));

    // A card mounting later gets the last state without asking again.
    final late = <List<int>>[];
    final sub2 = ble.subscribeCharacteristic('d', _svc, _rx).listen(late.add);
    await pumpEventQueue();
    expect(late.first, _globalState);
    expect(
      ble.recentNotifications('d', _svc, _rx),
      contains(equals(_globalState)),
    );
    await sub.cancel();
    await sub2.cancel();
  });

  test('a unit that answers garbage does not get a session', () async {
    unit.answers = _Answers.garbage;
    final ble = layer();
    await expectLater(
      ble.writeCharacteristic('d', _svc, _tx, _requestState),
      throwsA(isA<MpidSessionException>()),
    );
    expect(ble.hasSession('d'), isFalse);
    // Nothing past the state request: the command itself never went out.
    expect(unit.bodies, [_enableRx, _requestState]);
  });

  test('a unit that answers nothing fails the open, and says so', () async {
    unit.answers = _Answers.nothing;
    final ble = layer();
    await expectLater(
      ble.writeCharacteristic('d', _svc, _tx, _requestState),
      throwsA(isA<MpidSessionException>()),
    );
    expect(ble.hasSession('d'), isFalse);
    expect(unit.writes, isEmpty);
  });

  test(
    'a token that is not one is refused before anything is written',
    () async {
      unit.token = [1, 2, 3];
      final ble = layer();
      await expectLater(
        ble.writeCharacteristic('d', _svc, _tx, _requestState),
        throwsA(
          isA<MpidSessionException>().having(
            (e) => e.message,
            'message',
            contains('factory token'),
          ),
        ),
      );
      expect(unit.writes, isEmpty);
    },
  );

  test('a body the codec refuses is not sent', () async {
    final ble = layer();
    await ble.writeCharacteristic('d', _svc, _tx, _requestState);
    final before = unit.writes.length;
    await expectLater(
      ble.writeCharacteristic('d', _svc, _tx, [
        0x01,
        0x10,
        0xFE,
        0x02,
        0x34,
        0x00,
        0x36,
      ]),
      throwsA(isA<MpidSessionException>()),
    );
    expect(unit.writes, hasLength(before));
  });

  test(
    'the DFU service, the token and the session write are never written',
    () async {
      final ble = layer();
      await ble.discoverServices('d');
      for (final (service, char) in [
        (_dfu, '00001531-1212-efde-1523-785feabcd123'),
        (_dfu, '00001532-1212-efde-1523-785feabcd123'),
        (_svc, _session),
        (_svc, _token),
      ]) {
        await expectLater(
          ble.writeCharacteristic('d', service, char, [0x01]),
          throwsA(isA<MpidSessionException>()),
          reason: '$service $char',
        );
      }
      expect(unit.writes, isEmpty);
    },
  );

  test(
    'a dropped link forgets the session; the next write agrees a new one',
    () async {
      final ble = layer();
      await ble.writeCharacteristic('d', _svc, _tx, _requestState);
      unit.drop();
      await pumpEventQueue();
      expect(ble.hasSession('d'), isFalse);
      await ble.writeCharacteristic('d', _svc, _tx, _requestState);
      expect(codec.sessions, 2);
      expect(unit.writes.where((w) => w.$2 == _session).map((w) => w.$3), [
        [0xA1],
        [0xA2],
      ]);
      // The counter starts again at 1 for the new session.
      expect(unit.frameNumbers.skip(3).first, 1);
    },
  );

  test('other services pass straight through', () async {
    final ble = layer();
    await ble.writeCharacteristic(
      'd',
      '0000fff0-0000-1000-8000-00805f9b34fb',
      '0000fff1-0000-1000-8000-00805f9b34fb',
      [1, 2, 3],
    );
    expect(unit.writes.single.$3, [1, 2, 3]);
    expect(codec.sessions, 0);
  });

  group('with the real Rust codec', () {
    late bool rustReady;
    late String yaml;

    setUpAll(() async {
      rustReady = await initHostRustLib();
      yaml = await rootBundle.loadString(
        'vendor/protocol-specs/device-specs/devices/fisher-price-lumalou.yaml',
      );
    });

    test('the spec\'s receive vector opens across the FFI', () {
      if (!rustReady) return markTestSkipped('Rust lib not loaded');
      const codec = RustMpidCodec();
      expect(codec.channels().txUuid, _tx);
      expect(
        codec.channels().serviceUuid,
        MattelMpidBleService.mpidServiceUuid,
      );
      expect(
        codec.channels().dfuServiceUuid,
        MattelMpidBleService.dfuServiceUuid,
      );
      final session = rust.MpidSessionDto(
        key: Uint8List.fromList(List.generate(16, (i) => i)),
        appNonce: Uint8List.fromList([0xA1, 0xA2, 0xA3, 0xA4]),
        deviceSalt: Uint8List.fromList([0xB1, 0xB2, 0xB3, 0xB4]),
        sessionWrite: Uint8List(0),
      );
      final frame = _hex(
        '7e00000009001403bf980718dc58e7163ac5d6be2ce1b042be802fed',
      );
      expect(codec.open(session, frame), _globalState);
      expect(
        codec.seal(session, 1, _enableRx),
        _hex('7e00000001000422f9b2b8ef'),
      );
      expect(() => codec.open(session, [0x7E, 0, 0]), throwsA(anything));
      // SEND_PAIRING_COMPLETE stays unsendable.
      expect(
        () =>
            codec.seal(session, 2, [0x01, 0x10, 0xFE, 0x02, 0x34, 0x00, 0x36]),
        throwsA(anything),
      );
    });

    test('a garbage token is refused across the FFI', () async {
      if (!rustReady) return markTestSkipped('Rust lib not loaded');
      await expectLater(
        const RustMpidCodec().startSession(List.filled(192, 0)),
        throwsA(anything),
      );
    });

    test(
      'group pride mode puts the night light on its rainbow preset',
      () async {
        if (!rustReady) return markTestSkipped('Rust lib not loaded');
        final specCodec = RealSpecCodec();
        final spec = await specCodec.loadDeviceSpec(yaml);
        expect(supportedGroupOps(spec), contains(GroupOp.prideMode));

        const services = [
          BleDiscoveredService(
            uuid: _svc,
            characteristics: [
              BleDiscoveredCharacteristic(
                uuid: _tx,
                canRead: false,
                canWrite: true,
                canNotify: false,
              ),
            ],
          ),
        ];
        final writes = resolvePrideColorWrites(
          spec: spec,
          services: services,
          color: (r: 255, g: 0, b: 0),
        );
        // One write: the rainbow preset. "On" is the same command with warm
        // white, and would only flash first.
        expect(writes, hasLength(1));
        expect(writes.single.commandName, 'set_light_color');
        expect(writes.single.params, {'color': 9.0});

        final ble = MattelMpidBleService(
          _DiscoveringLumalou(services),
          codec: codec,
          ioTimeout: const Duration(seconds: 1),
          confirmTimeout: const Duration(seconds: 1),
          sleep: (d) async {},
        );
        final runner = GroupRunner(ble: ble, codec: specCodec);
        final events = await runner.run(GroupOp.prideMode, [
          GroupMember(
            id: 'cloud',
            name: '0123456789',
            spec: spec,
            specYaml: yaml,
          ),
        ], stop: StopSignal()).toList();
        expect(
          events.last.status,
          GroupDeviceStatus.ok,
          reason: '${events.last.detail}',
        );
        final unit = (ble.inner as _DiscoveringLumalou);
        expect(unit.bodies.last, [0x01, 0x10, 0xFE, 0x02, 0x3C, 0x09, 0x37]);
        expect(unit.bodies.take(2), [_enableRx, _requestState]);
      },
    );
  });
}

class _DiscoveringLumalou extends _Lumalou {
  final List<BleDiscoveredService> services;

  _DiscoveringLumalou(this.services);

  @override
  Future<List<BleDiscoveredService>> discoverServices(String deviceId) async =>
      services;
}

List<int> _hex(String text) => [
  for (var i = 0; i < text.length; i += 2)
    int.parse(text.substring(i, i + 2), radix: 16),
];
