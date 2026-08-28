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
  const rokuCapabilities = NetworkCapabilitiesDto(
    signedSession: 'ecp2',
    defaultPort: 8060,
    tlsSelfSigned: false,
    // As roku-ecp.yaml declares: a Roku serves its control paths only on 8060
    // whatever its SSDP LOCATION carried.
    advertisedPortUnreliable: true,
  );

  NetworkCommandSender sender({
    MockClient? httpClient,
    Ecp2ControlService? ecp2,
    int? discoveredControlPort = 8060,
    List<String> ssdpTargets = const ['roku:ecp'],
    NetworkCapabilitiesDto? capabilities = rokuCapabilities,
    int? devicePort,
    MqttConnect? mqttConnect,
    Map<String, String> storedCredentials = const {},
    WsConnect? wsConnect,
    String? wsCredential,
    void Function(String)? onWsCredential,
    void Function(String, String)? onCredentialIssued,
    SpecCodec? withCodec,
  }) =>
      NetworkCommandSender(
        mqttConnect: mqttConnect,
        wsConnect: wsConnect,
        wsCredential: wsCredential,
        onWsCredential: onWsCredential,
        onCredentialIssued: onCredentialIssued,
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
      )..useCredentials(() async => storedCredentials);

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

  test('a spec that says its announcement lies is pinned to the declared port',
      () {
    // A Roku advertised 7250 in the field and serves control only on 8060.
    expect(sender(discoveredControlPort: 7250).controlPort, 8060);

    // The Envoy is the same fact without the Roku: its mDNS answer still says
    // 80 while firmware 8.x serves the API only over 443 and refuses 80
    // outright. Expressing this as "is this a Roku" is what left the one
    // HTTPS device in the catalogue connecting to a closed port.
    expect(
      sender(
        discoveredControlPort: 80,
        ssdpTargets: const [],
        capabilities: const NetworkCapabilitiesDto(
          defaultPort: 443,
          defaultScheme: 'https',
          advertisedPortUnreliable: true,
          tlsSelfSigned: true,
          tlsVerification: 'trust_on_first_use',
        ),
      ).controlPort,
      443,
    );

    // And a device whose announcement is trustworthy — the normal case — is
    // still reached where it said it is.
    expect(
      sender(
              discoveredControlPort: 7250,
              ssdpTargets: const [],
              capabilities: null)
          .controlPort,
      7250,
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

  test('the spec\'s port is the fallback when discovery carried none',
      () async {
    // 67 specs declare `identification.default_port`, and it was read for
    // nothing but the Roku pin. A device added by hand, or found by a
    // transport that carries an address and no port, failed every send with
    // "did not advertise a control port" while its own spec said which port to
    // use. Discovery still wins where it has an answer — the assertion below —
    // because a device that told us where it is knows better than a default.
    Uri? sent;
    final s = sender(
      httpClient: MockClient((request) async {
        sent = request.url;
        return http.Response('', 200);
      }),
      discoveredControlPort: null,
      ssdpTargets: const [],
      capabilities: const NetworkCapabilitiesDto(
          defaultPort: 8081,
          tlsSelfSigned: false,
          advertisedPortUnreliable: false),
    );
    await s.sendAction(action('turn_off', 'press_power_off'), {});
    expect(sent?.port, 8081);
  });

  test('a discovered port still beats the spec on a non-roku', () {
    expect(
      sender(
        discoveredControlPort: 7250,
        ssdpTargets: const [],
        capabilities: const NetworkCapabilitiesDto(
            defaultPort: 80,
            tlsSelfSigned: false,
            advertisedPortUnreliable: false),
      ).controlPort,
      7250,
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

  // ── Credentials ───────────────────────────────────────────────────────────
  // A `credential:` parameter is a value the client was given, not one the
  // user picks and not one the device answers. These went to the MQTT render
  // and nowhere else, so the same parameter on any of the four other
  // transports silently had nothing to fill it.

  test('stored credentials reach every transport, not just mqtt', () async {
    final s = sender(storedCredentials: const {'username': 'nUP9k2sQ'});
    addTearDown(s.close);

    await s.sendAction(action('turn_off', 'press_power_off'), {});

    // `.last`, not `.single`: the fake codec is shared across this file's
    // tests and records every render.
    expect(codec.renderNetworkHttpCommandCalls.last.values,
        containsPair('username', 'nUP9k2sQ'));
  });

  test('the caller wins over the store for the same name', () async {
    // A read-back value the send just fetched is more current than anything a
    // store holds, and a value the user typed into a control is the point of
    // the control.
    final s = sender(storedCredentials: const {'level': 'stored'});
    addTearDown(s.close);

    await s.sendAction(
        action('set_brightness', 'set_level'), const {'level': 'picked'});

    expect(codec.renderNetworkHttpCommandCalls.last.values,
        containsPair('level', 'picked'));
  });

  test('a credential entered after the sender was built is used', () async {
    // The reason this is a reader and not a map: a person types the serial off
    // their printer's touchscreen, and the very next press has to use it. A
    // map captured at construction would fail on a value the app is holding.
    final held = <String, String>{};
    final s = sender(storedCredentials: held);
    addTearDown(s.close);

    await s.sendAction(action('turn_off', 'press_power_off'), {});
    expect(codec.renderNetworkHttpCommandCalls.last.values,
        isNot(contains('serial')));

    held['serial'] = '01P00A123456789';
    await s.sendAction(action('turn_off', 'press_power_off'), {});
    expect(codec.renderNetworkHttpCommandCalls.last.values,
        containsPair('serial', '01P00A123456789'));
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
          storedCredentials: credentials,
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

    test('subscribing to state topics rides the one session', () async {
      final s = mqttSender();
      addTearDown(s.close);

      const topic = '/remoteapp/mobile/broadcast/ui_service/state';
      final stream = await s.subscribeMqttState(
          action('press', 'press_power', transport: 'mqtt'), const [topic]);

      // The SUBSCRIBE reached the broker on the SAME session a send would
      // use — one connection, one client identity for state and commands.
      expect(broker.connects, 1);
      expect(
        broker.written.last,
        await mqttCodec.mqttSubscribePacket(topic: topic, packetId: 1),
      );
      await s.sendAction(action('press', 'press_power', transport: 'mqtt'), {});
      expect(broker.connects, 1, reason: 'the send reuses the session');
      expect(stream, isA<Stream<MqttMessage>>());
    });

    /// A readings-only device — entities with state topics, zero MQTT
    /// commands — has no action to carry the credential mapping. The
    /// subscription must still work: the login falls back to stored
    /// credentials under the literal names. Requiring an action here is what
    /// left exactly these devices permanently silent.
    test('a device with no MQTT actions can still subscribe to state',
        () async {
      final s = mqttSender();
      addTearDown(s.close);

      const topic = '438/NN2-EU-ABC1234D/status/current';
      await s.subscribeMqttState(null, const [topic]);

      expect(broker.connects, 1);
      expect(mqttCodec.mqttConnectArgs?.clientId, 'phone');
      expect(mqttCodec.mqttConnectArgs?.username, 'hisenseservice');
      expect(
        broker.written.last,
        await mqttCodec.mqttSubscribePacket(topic: topic, packetId: 1),
      );
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
      void Function(String, String)? onNamedIssue,
      Map<String, String> storedCredentials = const {},
    }) =>
        sender(
          withCodec: wsCodec,
          wsCredential: credential,
          onWsCredential: onIssued,
          onCredentialIssued: onNamedIssue,
          storedCredentials: storedCredentials,
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

    test("a stored credential is read from the store by the spec's name",
        () async {
      // No constructor value: the production factory passes none, and the
      // token a past pairing issued lives in the ONE store map under the
      // spec's credential_name. Before this lookup existed, a stored token
      // was unreachable and every screen open re-raised the Allow prompt.
      final s = wsSender(
        credential: null,
        storedCredentials: const {'samsung_token': 'from-store'},
      );
      addTearDown(s.close);

      await s.sendAction(
          action('press', 'press_power', transport: 'websocket'), {});
      expect(tv.urls.single, contains('token=from-store'));
    });

    test("an issued credential is reported under the spec's name", () async {
      // The (name, value) pair is what a store can file: the bare-value
      // callback alone left the factory nothing to save it AS.
      final named = <(String, String)>[];
      final s = wsSender(
        credential: null,
        onNamedIssue: (name, value) => named.add((name, value)),
      );
      addTearDown(s.close);

      await s.sendAction(
          action('press', 'press_power', transport: 'websocket'), {});
      expect(named, [('samsung_token', 'issued-1')]);
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
  Duration? pings;
  @override
  set pingInterval(Duration? interval) => pings = interval;

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
