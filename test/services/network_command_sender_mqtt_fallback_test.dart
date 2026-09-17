// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// The reading half of the two-spellings rule, on the transport with no 404.
//
// A spec that covers a firmware change carries both spellings of a reading's
// location (`state_topic` / `state_topic_fallback`). Over HTTP the device says
// which is real by answering 404 to the other; a subscription gets no such
// answer — a topic the firmware never publishes on looks exactly like a quiet
// device — so the sender listens on both and hands what arrives back under the
// spelling the caller asked for.

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:http/http.dart' as http;
import 'package:liberated_bread_mobile/services/ecp2_control_service.dart';
import 'package:liberated_bread_mobile/services/http_control_service.dart';
import 'package:liberated_bread_mobile/services/kasa_control_service.dart';
import 'package:liberated_bread_mobile/services/mqtt_session.dart';
import 'package:liberated_bread_mobile/services/network_command_sender.dart';
import 'package:liberated_bread_mobile/services/rabbit_air_control_service.dart';
import 'package:liberated_bread_mobile/services/soap_control_service.dart';
import 'package:liberated_bread_mobile/services/spec_codec.dart';

import '../fakes/fake_spec_codec.dart';

/// A broker on the other end of the socket seam: records what was written,
/// pushes what the test scripts.
class _Broker implements MqttSocket {
  final _out = StreamController<Uint8List>();
  final List<List<int>> written = [];

  @override
  Stream<Uint8List> get incoming => _out.stream;

  @override
  void add(List<int> bytes) => written.add(List.of(bytes));

  @override
  Future<void> close() async {
    if (!_out.isClosed) await _out.close();
  }

  void send(List<int> bytes) => _out.add(Uint8List.fromList(bytes));
}

void main() {
  late _Broker broker;

  setUp(() => broker = _Broker());

  NetworkCommandSender senderWith(FakeSpecCodec codec) => NetworkCommandSender(
    host: '192.0.2.9',
    discoveredControlPort: null,
    devicePort: 1883,
    ssdpTargets: const [],
    capabilities: const NetworkCapabilitiesDto(
      defaultPort: 1883,
      tlsSelfSigned: false,
      advertisedPortUnreliable: false,
      mqttClientIdGenerated: true,
    ),
    specYaml: 'yaml',
    codec: codec,
    mqttConnect: (host, port, timeout) async {
      scheduleMicrotask(() => broker.send([0x20, 0x02, 0x00, 0x00]));
      return broker;
    },
    http: HttpControlClient(
      httpClient: MockClient((_) async => http.Response('', 200)),
    ),
    soap: SoapControlClient(
      httpClient: MockClient(
        (_) async => fail('no SOAP exchange belongs in this test'),
      ),
    ),
    kasa: KasaControlClient(codec),
    rabbitAir: RabbitAirControlClient(codec),
    ecp2: Ecp2ControlService(
      connector: (host, port) async =>
          throw const Ecp2Exception('no ECP2 in this test'),
    ),
  )..useCredentials(() async => const {'username': 'u', 'password': 'p'});

  /// The topics a SUBSCRIBE packet the session wrote was for. The fake codec
  /// builds real MQTT bytes, so this reads them back the way a broker would.
  List<String> subscribedTopics() => [
    for (final packet in broker.written)
      if (packet.isNotEmpty && packet.first == 0x82)
        // [0x82][remaining length][packet id ×2][topic length ×2][topic][qos]
        String.fromCharCodes(
          packet.sublist(6, 6 + ((packet[4] << 8) | packet[5])),
        ),
  ];

  test(
    'a declared fallback topic is subscribed alongside the primary',
    () async {
      final codec = FakeSpecCodec(
        stateTopicFallbacks: const [
          StateTopicFallbackDto(topic: '/cover/Door', fallback: '/cover/door'),
        ],
      );
      final sender = senderWith(codec);
      addTearDown(sender.close);

      await sender.subscribeMqttState(null, ['/cover/Door']);

      expect(subscribedTopics(), ['/cover/Door', '/cover/door']);
    },
  );

  test('a reading pushed on the fallback arrives under the primary', () async {
    // The caller subscribed to a READING, not to a string: it looks messages
    // up by the topic it declared, so a message that came in on the older
    // firmware's spelling has to reach it under the newer one.
    final codec = FakeSpecCodec(
      stateTopicFallbacks: const [
        StateTopicFallbackDto(topic: '/cover/Door', fallback: '/cover/door'),
      ],
    );
    final sender = senderWith(codec);
    addTearDown(sender.close);

    final stream = await sender.subscribeMqttState(null, ['/cover/Door']);
    final seen = <MqttMessage>[];
    final sub = stream.listen(seen.add);
    addTearDown(sub.cancel);

    broker.send(
      await codec.mqttPublishPacket(
        topic: '/cover/door',
        payload: '{"state":"OPEN"}',
      ),
    );
    await pumpEventQueue();

    expect(seen.single.topic, '/cover/Door');
    expect(seen.single.payload, '{"state":"OPEN"}');
  });

  test('a message on the primary is passed through untouched', () async {
    final codec = FakeSpecCodec(
      stateTopicFallbacks: const [
        StateTopicFallbackDto(topic: '/cover/Door', fallback: '/cover/door'),
      ],
    );
    final sender = senderWith(codec);
    addTearDown(sender.close);

    final stream = await sender.subscribeMqttState(null, ['/cover/Door']);
    final seen = <MqttMessage>[];
    final sub = stream.listen(seen.add);
    addTearDown(sub.cancel);

    broker.send(
      await codec.mqttPublishPacket(topic: '/cover/Door', payload: 'shut'),
    );
    await pumpEventQueue();

    expect(seen.single.topic, '/cover/Door');
  });

  test(
    'a spec with no fallbacks subscribes to exactly what it was asked for',
    () async {
      final sender = senderWith(FakeSpecCodec());
      addTearDown(sender.close);

      await sender.subscribeMqttState(null, ['delta', 'status']);

      expect(subscribedTopics(), ['delta', 'status']);
    },
  );

  test('a fallback for a topic nobody asked about is not subscribed', () async {
    final codec = FakeSpecCodec(
      stateTopicFallbacks: const [
        StateTopicFallbackDto(topic: '/light/Light', fallback: '/light/light'),
      ],
    );
    final sender = senderWith(codec);
    addTearDown(sender.close);

    await sender.subscribeMqttState(null, ['/cover/Door']);

    expect(subscribedTopics(), ['/cover/Door']);
  });
}
