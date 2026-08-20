// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// The extracted send pipeline, driven headlessly — the point of the
// extraction. The screen tests keep pinning the same behaviour through the
// widget; these pin the service's own contract: the signed session as a
// Roku's PRIMARY path with plain ECP as the fallback, the memoized
// unavailability behind that, and the errors a headless caller can now reach
// that a screen's load path used to make impossible.

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:liberated_bread_mobile/services/ecp2_control_service.dart';
import 'package:liberated_bread_mobile/services/http_control_service.dart';
import 'package:liberated_bread_mobile/services/kasa_control_service.dart';
import 'package:liberated_bread_mobile/services/network_command_sender.dart';
import 'package:liberated_bread_mobile/services/rabbit_air_control_service.dart';
import 'package:liberated_bread_mobile/services/soap_control_service.dart';
import 'package:liberated_bread_mobile/services/spec_codec.dart';

import '../fakes/fake_ecp2_socket.dart';
import '../fakes/fake_spec_codec.dart';

NetworkActionDto action(String role, String command,
        {String transport = 'http'}) =>
    NetworkActionDto(
      role: role,
      commandName: command,
      transport: transport,
      userParams: const [],
      readBack: const [],
      credentials: const [],
      instanceParams: const [],
    );

void main() {
  final codec = FakeSpecCodec();

  NetworkCommandSender sender({
    MockClient? httpClient,
    Ecp2ControlService? ecp2,
    int? discoveredControlPort = 8060,
    List<String> ssdpTargets = const ['roku:ecp'],
  }) =>
      NetworkCommandSender(
        host: '192.0.2.9',
        discoveredControlPort: discoveredControlPort,
        devicePort: null,
        ssdpTargets: ssdpTargets,
        specYaml: 'yaml',
        codec: codec,
        http: HttpControlClient(
            httpClient: httpClient ??
                MockClient((request) async => http.Response('', 200))),
        soap: SoapControlClient(
            httpClient: MockClient((request) async =>
                fail('no SOAP exchange belongs in this test'))),
        kasa: KasaControlClient(codec),
        rabbitAir: RabbitAirControlClient(codec),
        ecp2: ecp2 ??
            Ecp2ControlService(
                connector: (host, port) async =>
                    throw const Ecp2Exception('no ECP2 in this test')),
      );

  test('an http action renders through the codec and posts the result',
      () async {
    final received = <http.Request>[];
    final s = sender(
        httpClient: MockClient((request) async {
      received.add(request);
      return http.Response('', 200);
    }));
    await s.sendAction(action('turn_off', 'press_power_off'), {});
    expect(received.single.url.path, '/fake/press_power_off');
  });

  test('a roku is driven over the signed session, opened once and reused',
      () async {
    final socket = AutoEcp2Socket();
    var connects = 0;
    // Render real ECP keypress paths — the session translates the path to
    // its ECP2 verb, and a path it does not know falls back to plain.
    final ecpCodec = FakeSpecCodec()
      ..networkHttpRequest = (name, values) => HttpRequestDto(
            method: 'POST',
            path: name == 'press_power_off'
                ? '/keypress/PowerOff'
                : '/keypress/PowerOn',
            body: '',
          );
    final s = NetworkCommandSender(
      host: '192.0.2.9',
      discoveredControlPort: 8060,
      devicePort: null,
      ssdpTargets: const ['roku:ecp'],
      specYaml: 'yaml',
      codec: ecpCodec,
      http: HttpControlClient(httpClient: MockClient((request) async {
        fail('a Roku must not take the plain path when the session is up');
      })),
      soap: SoapControlClient(
          httpClient: MockClient((request) async =>
              fail('no SOAP exchange belongs in this test'))),
      kasa: KasaControlClient(ecpCodec),
      rabbitAir: RabbitAirControlClient(ecpCodec),
      ecp2: Ecp2ControlService(connector: (host, port) async {
        connects++;
        socket.begin();
        return socket;
      }),
    );
    await s.sendAction(action('turn_off', 'press_power_off'), {});
    await s.sendAction(action('turn_on', 'press_power_on'), {});
    expect(connects, 1, reason: 'the session is opened once and reused');
    await s.close();
  });

  test('a roku pins control to 8060 whatever LOCATION advertised', () {
    expect(sender(discoveredControlPort: 7250).controlPort, 8060);
    expect(
      sender(discoveredControlPort: 7250, ssdpTargets: const []).controlPort,
      7250,
      reason: 'only a Roku is pinned',
    );
  });

  test('a refusal on a non-roku stays a refusal', () async {
    final s = sender(
      httpClient:
          MockClient((request) async => http.Response('denied', 403)),
      ssdpTargets: const ['urn:some:other:device'],
    );
    await expectLater(
      s.sendAction(action('turn_off', 'press_power_off'), {}),
      throwsA(isA<ControlRefusedException>()),
    );
  });

  test('a failed session open is remembered, not retried per send', () async {
    var connects = 0;
    final s = sender(
      httpClient:
          MockClient((request) async => http.Response('denied', 403)),
      ecp2: Ecp2ControlService(connector: (host, port) async {
        connects++;
        throw const Ecp2Exception('TV asleep');
      }),
    );
    for (var i = 0; i < 2; i++) {
      await expectLater(
        s.sendAction(action('turn_off', 'press_power_off'), {}),
        throwsA(isA<ControlRefusedException>()),
      );
    }
    expect(connects, 1, reason: 'unavailability is memoized');
  });

  test('a device that advertised no control port fails the http send visibly',
      () async {
    final s = sender(discoveredControlPort: null, ssdpTargets: const []);
    await expectLater(
      s.sendAction(action('turn_off', 'press_power_off'), {}),
      throwsA(isA<SoapTransportException>()),
    );
  });

  test('a soap action without a fetched description fails visibly', () async {
    final s = sender();
    await expectLater(
      s.sendAction(action('turn_off', 'crockpot_off', transport: 'soap'), {}),
      throwsA(isA<SoapTransportException>()),
    );
  });

  test('transport independence matches the soap-serialization rule', () {
    expect(
        NetworkCommandSender.isIndependentTransport(
            action('press', 'x', transport: 'http')),
        isTrue);
    expect(
        NetworkCommandSender.isIndependentTransport(
            action('press', 'x', transport: 'tcp-json')),
        isTrue);
    expect(
        NetworkCommandSender.isIndependentTransport(
            action('press', 'x', transport: 'udp')),
        isTrue);
    expect(
        NetworkCommandSender.isIndependentTransport(
            action('press', 'x', transport: 'soap')),
        isFalse);
  });

  test('close is safe on a sender that never opened a session', () async {
    await sender().close();
  });
}
