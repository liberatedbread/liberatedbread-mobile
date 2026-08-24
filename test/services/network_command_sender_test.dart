// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// The extracted send pipeline, driven headlessly — the point of the
// extraction. The screen tests keep pinning the same behaviour through the
// widget; these pin the service's own contract: the signed session as a
// Roku's PRIMARY path with plain ECP as the fallback, the memoized
// unavailability behind that, and the errors a headless caller can now reach
// that a screen's load path used to make impossible.

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:liberated_bread_mobile/services/ecp2_control_service.dart';
import 'package:liberated_bread_mobile/services/http_control_service.dart';
import 'package:liberated_bread_mobile/services/kasa_control_service.dart';
import 'package:liberated_bread_mobile/services/mqtt_session.dart';
import 'package:liberated_bread_mobile/services/ws_control_service.dart';
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

  // The ecp2 capability as the resolver hands it over for a real Roku:
  // the spec's own block plus its declared 8060.
  const rokuCapabilities =
      NetworkCapabilitiesDto(signedSession: 'ecp2', defaultPort: 8060);

  NetworkCommandSender sender({
    MockClient? httpClient,
    Ecp2ControlService? ecp2,
    int? discoveredControlPort = 8060,
    List<String> ssdpTargets = const ['roku:ecp'],
    NetworkCapabilitiesDto? capabilities = rokuCapabilities,
    int? devicePort,
    MqttConnect? mqttConnect,
    Map<String, String> mqttCredentials = const {},
    WsConnect? wsConnect,
    String? wsCredential,
    void Function(String)? onWsCredential,
    SpecCodec? withCodec,
  }) =>
      NetworkCommandSender(
        mqttConnect: mqttConnect,
        mqttCredentials: mqttCredentials,
        wsConnect: wsConnect,
        wsCredential: wsCredential,
        onWsCredential: onWsCredential,
        host: '192.0.2.9',
        discoveredControlPort: discoveredControlPort,
        devicePort: devicePort,
        ssdpTargets: ssdpTargets,
        capabilities: capabilities,
        specYaml: 'yaml',
        codec: withCodec ?? codec,
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
    final s = sender(httpClient: MockClient((request) async {
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
      capabilities: rokuCapabilities,
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
      sender(
              discoveredControlPort: 7250,
              ssdpTargets: const [],
              capabilities: null)
          .controlPort,
      7250,
      reason: 'only a Roku is pinned',
    );
  });

  test('a refusal on a non-roku stays a refusal', () async {
    final s = sender(
      httpClient: MockClient((request) async => http.Response('denied', 403)),
      ssdpTargets: const ['urn:some:other:device'],
      capabilities: null,
    );
    await expectLater(
      s.sendAction(action('turn_off', 'press_power_off'), {}),
      throwsA(isA<ControlRefusedException>()),
    );
  });

  test('a failed session open is remembered, not retried per send', () async {
    var connects = 0;
    final s = sender(
      httpClient: MockClient((request) async => http.Response('denied', 403)),
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
    final s = sender(
        discoveredControlPort: null, ssdpTargets: const [], capabilities: null);
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

  // ── MQTT ──────────────────────────────────────────────────────────────────
  // A device whose control surface is its own broker: a Hisense set's remote.
  // The session is the device's, not the request's — a broker serving one
  // client at a time is held out by a client that reconnects per keypress.

  group('the mqtt transport', () {
    late _ScriptedBroker broker;
    late FakeSpecCodec mqttCodec;

    setUp(() {
      broker = _ScriptedBroker();
      mqttCodec = FakeSpecCodec()
        ..mqttRequest = const MqttRequestDto(
          topic: '/remoteapp/tv/remote_service/phone/actions/sendkey',
          payload: 'KEY_POWER',
        );
    });

    NetworkCommandSender mqttSender({
      Map<String, String> credentials = const {
        'client_id': 'phone',
        'username': 'hisenseservice',
        'password': 'multimqttservice',
      },
    }) =>
        sender(
          withCodec: mqttCodec,
          devicePort: 36669,
          mqttCredentials: credentials,
          mqttConnect: (host, port, timeout) async {
            scheduleMicrotask(() => broker.send([0x20, 0x02, 0x00, 0x00]));
            return broker;
          },
        );

    test('renders the command and publishes it', () async {
      final s = mqttSender();
      addTearDown(s.close);

      await s.sendAction(action('press', 'press_power', transport: 'mqtt'), {});

      expect(mqttCodec.mqttRenderCalls.single.commandName, 'press_power');
      expect(
        broker.written.last,
        await mqttCodec.mqttPublishPacket(
          topic: '/remoteapp/tv/remote_service/phone/actions/sendkey',
          payload: 'KEY_POWER',
        ),
      );
    });

    test('the stored credentials reach both the session and the renderer',
        () async {
      final s = mqttSender();
      addTearDown(s.close);

      await s.sendAction(action('press', 'press_power', transport: 'mqtt'), {});

      expect(mqttCodec.mqttConnectArgs?.clientId, 'phone');
      expect(mqttCodec.mqttConnectArgs?.username, 'hisenseservice');
      // The topic is addressed to the client id, so the renderer needs it too.
      expect(mqttCodec.mqttRenderCalls.single.values['client_id'], 'phone');
    });

    /// A value the caller set beats a stored credential of the same name:
    /// the caller is the one operating the control.
    test('a caller value wins over a stored credential of the same name',
        () async {
      final s = mqttSender();
      addTearDown(s.close);

      await s.sendAction(action('press', 'press_power', transport: 'mqtt'),
          {'client_id': 'other'});
      expect(mqttCodec.mqttRenderCalls.single.values['client_id'], 'other');
    });

    test('the session is opened once and reused across sends', () async {
      final s = mqttSender();
      addTearDown(s.close);

      await s.sendAction(action('press', 'press_power', transport: 'mqtt'), {});
      final afterFirst = broker.written.length;
      await s.sendAction(action('press', 'press_power', transport: 'mqtt'), {});

      // One more PUBLISH, no second CONNECT.
      expect(broker.written.length, afterFirst + 1);
      expect(broker.connects, 1);
    });

    /// Every topic is addressed to the client id, so an unpaired device has no
    /// useful session. Refused by name rather than connecting under a
    /// generated id, which would be silently unauthorised on a set that pairs.
    test('an unpaired device says so instead of improvising an identity',
        () async {
      final s = mqttSender(credentials: const {});
      addTearDown(s.close);

      await expectLater(
        s.sendAction(action('press', 'press_power', transport: 'mqtt'), {}),
        throwsA(isA<MqttConnectionException>()
            .having((e) => e.message, 'message', contains('paired'))),
      );
    });

    /// MQTT is an independent transport, so the screen deliberately does not
    /// serialize sends: two buttons pressed together arrive together. Without
    /// one shared connect in flight each would open a session, the second
    /// overwriting the first's handle so its socket never closes — and on a
    /// broker that serves one client at a time, the second CONNECT evicts the
    /// first.
    test('two sends racing open one session, not two', () async {
      final s = mqttSender();
      addTearDown(s.close);

      await Future.wait([
        s.sendAction(action('press', 'press_power', transport: 'mqtt'), {}),
        s.sendAction(action('press', 'press_up', transport: 'mqtt'), {}),
      ]);

      expect(broker.connects, 1, reason: 'one CONNECT, not one per press');
      // One CONNECT and two PUBLISHes.
      expect(broker.written.length, 3);
    });

    test('closing the sender disconnects the broker', () async {
      final s = mqttSender();
      await s.sendAction(action('press', 'press_power', transport: 'mqtt'), {});

      await s.close();
      // DISCONNECT, not a dropped socket: a broker that serves one local
      // client leaves the owner's own app locked out until it notices.
      expect(broker.written.last, await mqttCodec.mqttDisconnectPacket());
      expect(broker.closed, isTrue);
    });
  });

  // ── WebSocket ─────────────────────────────────────────────────────────────
  // A television's whole control surface is one socket, authorised once. The
  // session is the device's, not the request's: re-pairing per keypress would
  // raise the set's consent prompt every time.

  group('the websocket transport', () {
    late FakeSpecCodec wsCodec;
    late _ScriptedTv tv;

    const surface = WebSocketSurfaceDto(
      port: 8002,
      scheme: 'wss',
      path: '/api/v2/channels/samsung.remote.control?token={samsung_token}',
      headers: [],
      tlsSelfSigned: true,
      pairingMode: 'token_query',
      credentialName: 'samsung_token',
      issuedAt: 'data.token',
      channels: [
        WebSocketChannelDto(name: 'remote', isDefault: true, encoding: 'json'),
      ],
    );

    setUp(() {
      tv = _ScriptedTv();
      wsCodec = FakeSpecCodec()
        ..websocketSurfaceResult = surface
        ..websocketFrameFor = (command, id) => WebSocketFrameDto(
            channel: 'remote', text: '{"method":"$command","id":$id}');
    });

    NetworkCommandSender wsSender({
      String? credential = 'stored',
      void Function(String)? onIssued,
    }) =>
        sender(
          withCodec: wsCodec,
          wsCredential: credential,
          onWsCredential: onIssued,
          wsConnect: (url, headers) async {
            tv.urls.add(url);
            scheduleMicrotask(() => tv.send('{"data":{"token":"issued-1"}}'));
            return tv;
          },
        );

    test('renders the frame and writes it to the socket', () async {
      final s = wsSender();
      addTearDown(s.close);

      await s.sendAction(
          action('press', 'press_power', transport: 'websocket'), {});

      expect(wsCodec.websocketRenderCalls.single.commandName, 'press_power');
      expect(tv.written.single, contains('"method":"press_power"'));
    });

    test('the session is opened once and reused across sends', () async {
      final s = wsSender();
      addTearDown(s.close);

      await s
          .sendAction(action('press', 'press_up', transport: 'websocket'), {});
      await s.sendAction(
          action('press', 'press_down', transport: 'websocket'), {});

      expect(tv.urls, hasLength(1), reason: 'one socket, not one per press');
      expect(tv.written, hasLength(2));
    });

    /// Two buttons pressed together arrive together, and websocket is an
    /// independent transport — without one shared open each would pair
    /// separately, and a set that prompts would prompt twice.
    test('two sends racing open one session, not two', () async {
      final s = wsSender();
      addTearDown(s.close);

      await Future.wait([
        s.sendAction(action('press', 'press_up', transport: 'websocket'), {}),
        s.sendAction(action('press', 'press_down', transport: 'websocket'), {}),
      ]);

      expect(tv.urls, hasLength(1));
    });

    test('a newly issued credential is handed back to be stored', () async {
      final issued = <String>[];
      final s = wsSender(credential: null, onIssued: issued.add);
      addTearDown(s.close);

      await s.sendAction(
          action('press', 'press_power', transport: 'websocket'), {});
      expect(issued, ['issued-1']);
    });

    /// A pairing that reissued the same key is not news, and a store write per
    /// connect is a write per screen open.
    test('an unchanged credential is not reported again', () async {
      final issued = <String>[];
      final s = wsSender(credential: 'issued-1', onIssued: issued.add);
      addTearDown(s.close);

      await s.sendAction(
          action('press', 'press_power', transport: 'websocket'), {});
      expect(issued, isEmpty);
    });

    test('closing the sender closes the socket', () async {
      final s = wsSender();
      await s.sendAction(
          action('press', 'press_power', transport: 'websocket'), {});

      await s.close();
      expect(tv.closed, isTrue);
    });
  });
}

/// A scripted broker behind the sender's MQTT socket seam.
class _ScriptedBroker implements MqttSocket {
  final _out = StreamController<Uint8List>();
  final List<List<int>> written = [];
  var closed = false;
  var connects = 0;

  @override
  Stream<Uint8List> get incoming {
    connects++;
    return _out.stream;
  }

  @override
  void add(List<int> bytes) => written.add(List.of(bytes));

  @override
  Future<void> close() async {
    closed = true;
    if (!_out.isClosed) await _out.close();
  }

  void send(List<int> bytes) => _out.add(Uint8List.fromList(bytes));
}

/// A scripted television behind the sender's WebSocket seam.
class _ScriptedTv implements WsSocket {
  final _out = StreamController<dynamic>();
  final List<String> written = [];
  final List<String> urls = [];
  var closed = false;

  @override
  Stream<dynamic> get stream => _out.stream;

  @override
  void add(String frame) => written.add(frame);

  @override
  Future<void> close() async {
    closed = true;
    if (!_out.isClosed) unawaited(_out.close());
  }

  void send(String frame) => _out.add(frame);
}
