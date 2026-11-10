// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// Where a Wi-Fi LOY SPACE panel's actions and pictures go: a `popled_json`
// action to the panel's UDP client and nowhere else, the group ops its light
// supports, and pride mode as an upload to a fake panel on loopback. The fake
// codec's framing here is a toy; the real bytes are pinned in
// rust/src/protocol/popled_udp.rs and popled_udp_control_service_test.dart.
// None of this has met a Wi-Fi panel.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:liberated_bread_mobile/core/group_actions.dart';
import 'package:liberated_bread_mobile/core/pride_flags.dart';
import 'package:liberated_bread_mobile/core/stop_signal.dart';
import 'package:liberated_bread_mobile/services/ecp2_control_service.dart';
import 'package:liberated_bread_mobile/services/group_runner.dart';
import 'package:liberated_bread_mobile/services/http_control_service.dart';
import 'package:liberated_bread_mobile/services/kasa_control_service.dart';
import 'package:liberated_bread_mobile/services/limitlessled_control_service.dart';
import 'package:liberated_bread_mobile/services/network_command_sender.dart';
import 'package:liberated_bread_mobile/services/popled_udp_control_service.dart';
import 'package:liberated_bread_mobile/services/rabbit_air_control_service.dart';
import 'package:liberated_bread_mobile/services/saved_network_device_store.dart';
import 'package:liberated_bread_mobile/services/soap_control_service.dart';
import 'package:liberated_bread_mobile/services/spec_codec.dart';

import '../fakes/fake_spec_codec.dart';

class _RecordingPanel extends PopledUdpClient {
  _RecordingPanel(super.codec);
  final sent = <({String host, int port, List<int> body})>[];

  @override
  Future<PopledUdpReplyDto> send(String host, int port, List<int> body) async {
    sent.add((host: host, port: port, body: body));
    return const PopledUdpReplyDto(
      seq: 1,
      ackStatus: 0,
      answer: false,
      fields: {},
    );
  }
}

class _NoBridge extends LimitlessledControlClient {
  @override
  Future<void> send(
    String host,
    int port,
    List<LimitlessledFrameDto> frames,
  ) async => fail('a panel action must not reach the LimitlessLED socket');
}

NetworkActionDto _action(String role, {List<String> params = const []}) =>
    NetworkActionDto(
      role: role,
      commandName: role,
      transport: kPopledTransport,
      userParams: params,
      readBack: const [],
      credentials: const [],
      instanceParams: const [],
      min: params.isEmpty ? null : 1,
      max: params.isEmpty ? null : 15,
    );

/// The surface the Rust resolver gives led-space.yaml's light
/// (rust/tests/lan_handlers.rs pins it): write-only, three actions.
final _panelLight = NetworkEntityDto(
  name: 'LED Screen',
  platform: 'light',
  stateCommand: '',
  transport: kPopledTransport,
  isInstanced: false,
  options: const [],
  actions: [
    _action('turn_on'),
    _action('turn_off'),
    _action('set_brightness', params: ['brightness']),
  ],
);

NetworkCapabilitiesDto _caps({int? port}) => NetworkCapabilitiesDto(
  defaultPort: port ?? 9090,
  tlsSelfSigned: false,
  advertisedPortUnreliable: false,
  protocolHandler: kPopledTransport,
  mqttClientIdGenerated: false,
);

NetworkCommandSender _sender(
  FakeSpecCodec codec, {
  required String host,
  NetworkCapabilitiesDto? capabilities,
  PopledUdpClient? popled,
}) => NetworkCommandSender(
  host: host,
  discoveredControlPort: null,
  devicePort: null,
  ssdpTargets: const [],
  capabilities: capabilities,
  specYaml: 'yaml',
  codec: codec,
  http: HttpControlClient(
    httpClient: MockClient((request) async => fail('no HTTP here')),
  ),
  soap: SoapControlClient(
    httpClient: MockClient((request) async => fail('no SOAP here')),
  ),
  kasa: KasaControlClient(
    codec,
    exchange: (host, port, request, timeout) async =>
        fail('Kasa\'s cipher must not reach a panel'),
  ),
  rabbitAir: RabbitAirControlClient(codec),
  ecp2: Ecp2ControlService(
    connector: (host, port) async =>
        throw const Ecp2Exception('no ECP2 in this test'),
  ),
  limitlessled: _NoBridge(),
  popled: popled,
);

void main() {
  group('routing', () {
    test('a panel action is rendered and sent to its UDP port', () async {
      final codec = FakeSpecCodec();
      final panel = _RecordingPanel(codec);
      await _sender(codec, host: '192.168.4.1', popled: panel).sendAction(
        _action('set_brightness', params: ['brightness']),
        {'brightness': '9'},
      );

      final call = codec.renderNetworkPopledCommandCalls.single;
      expect(call.commandName, 'set_brightness');
      expect(call.values, {'brightness': '9'});
      expect(panel.sent.single.host, '192.168.4.1');
      expect(panel.sent.single.port, 9090, reason: 'the spec\'s port');
    });

    test('the spec\'s declared port is where frames go', () async {
      final codec = FakeSpecCodec();
      final panel = _RecordingPanel(codec);
      await _sender(
        codec,
        host: '192.168.4.1',
        capabilities: _caps(port: 19090),
        popled: panel,
      ).sendAction(_action('turn_off'), {});
      expect(panel.sent.single.port, 19090);
    });

    test('a panel send waits on nothing else', () {
      expect(
        NetworkCommandSender.isIndependentTransport(_action('turn_on')),
        isTrue,
      );
    });
  });

  group('group ops', () {
    test('the panel\'s light joins on, off and brightness', () {
      expect(kGroupSendableTransports, contains(kPopledTransport));
      expect(supportedNetworkGroupOps([_panelLight]), {
        GroupOp.turnOn,
        GroupOp.turnOff,
        GroupOp.setBrightness,
      });
    });

    test('pride is a picture, offered by the panel, not its light', () {
      final member = _member(port: 9090);
      expect(member.ops, contains(GroupOp.prideMode));
      final plain = NetworkGroupMember(
        memberId: 'net:x',
        name: 'x',
        record: member.record,
        specYaml: 'yaml',
        entities: [_panelLight],
      );
      expect(plain.ops, isNot(contains(GroupOp.prideMode)));
    });
  });

  group('pride mode', () {
    test('uploads every flag as one animation, acknowledged', () async {
      final codec = FakeSpecCodec();
      final panel = await _ToyPanel.start(answerSize: (32, 16));
      addTearDown(panel.close);

      final events = await _runner(codec).run(GroupOp.prideMode, [
        _member(port: panel.port),
      ], stop: StopSignal()).toList();

      expect(
        events.last.status,
        GroupDeviceStatus.ok,
        reason: '${events.last.detail}',
      );
      expect(events.last.detail, 'Alternating ${prideFlags.length} flags');
      final upload = codec.popledUploadCalls.single;
      expect(upload.frames, prideFlags.length);
      expect((upload.width, upload.height), (32, 16), reason: 'its own size');
      expect(upload.delayMs, GroupRunner.prideFlagSeconds * 1000);
      // The size query, then every body, one sequence throughout.
      expect(panel.heard.first.skip(2).toList(), [
        0xC1, 0x03, 0x0A, 0x00, 0x1B, 0x00, //
      ]);
      expect(panel.heard, hasLength(1 + prideFlags.length + 2));
      expect(
        panel.heard.map((d) => d[0] | d[1] << 8),
        List.generate(panel.heard.length, (i) => i + 1),
      );
    });

    test('a panel that does not answer fails its row', () async {
      final codec = FakeSpecCodec();
      final panel = await _ToyPanel.start(silent: true);
      addTearDown(panel.close);

      final events =
          await _runner(
            codec,
            ackTimeout: const Duration(milliseconds: 100),
          ).run(GroupOp.prideMode, [
            _member(port: panel.port),
          ], stop: StopSignal()).toList();

      expect(events.last.status, GroupDeviceStatus.failed);
      expect(events.last.detail, contains('did not answer'));
    });
  });
}

NetworkGroupMember _member({required int port}) => NetworkGroupMember(
  memberId: 'net:panel',
  name: 'Backpack screen',
  category: 'display',
  record: SavedNetworkDevice(
    id: 'panel',
    name: 'Backpack screen',
    lastSeen: DateTime(2026, 1, 1),
    host: '127.0.0.1',
    ssdpTargets: const [],
  ),
  specYaml: 'yaml',
  capabilities: _caps(port: port),
  entities: [_panelLight],
);

NetworkGroupRunner _runner(
  FakeSpecCodec codec, {
  Duration ackTimeout = const Duration(milliseconds: 500),
}) => NetworkGroupRunner(
  codec: codec,
  soap: SoapControlClient(
    httpClient: MockClient((request) async => fail('no SOAP here')),
  ),
  senderFor: ({required device, required specYaml, capabilities}) => _sender(
    codec,
    host: device.host,
    capabilities: capabilities,
    popled: PopledUdpClient(codec, ackTimeout: ackTimeout, attempts: 2),
  ),
);

/// A loopback panel speaking the fake codec's toy framing: `[seq lo, seq hi,
/// ...body]` in, `[seq lo, seq hi, 0x82, 0]` or a size answer out.
class _ToyPanel {
  final RawDatagramSocket socket;
  final heard = <List<int>>[];

  _ToyPanel._(this.socket, (int, int)? answerSize, bool silent) {
    socket.listen((event) {
      if (event != RawSocketEvent.read) return;
      final d = socket.receive();
      if (d == null) return;
      heard.add(d.data);
      if (silent) return;
      final isQuery = d.data.length > 3 && d.data[3] == 0x03;
      final reply = isQuery && answerSize != null
          ? [d.data[0], d.data[1], 0x83, answerSize.$1, answerSize.$2]
          : [d.data[0], d.data[1], 0x82, 0];
      socket.send(reply, d.address, d.port);
    });
  }

  static Future<_ToyPanel> start({
    (int, int)? answerSize,
    bool silent = false,
  }) async => _ToyPanel._(
    await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0),
    answerSize,
    silent,
  );

  int get port => socket.port;
  void close() => socket.close();
}
