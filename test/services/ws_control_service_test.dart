// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// The spec-declared WebSocket session, driven from scripted sockets. The two
// televisions in the catalogue have genuinely different shapes and both are
// exercised here: a Samsung set issues its token in the first frame it sends,
// and an LG set takes a registration frame, answers after the viewer accepts,
// and keeps its remote buttons on a SECOND socket it hands out at runtime.

import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/core/constants.dart';
import 'package:liberated_bread_mobile/services/spec_codec.dart';
import 'package:liberated_bread_mobile/services/ws_control_service.dart';

import '../fakes/fake_spec_codec.dart';
import '../fakes/scripted_ws_socket.dart';

/// A codec whose websocket render waits for the test's say-so, so a test can
/// land a hang-up exactly inside send()'s render await.
class _GatedRenderCodec extends FakeSpecCodec {
  final gate = Completer<void>();

  @override
  Future<WebSocketFrameDto> renderNetworkWebsocketCommand({
    required String specYaml,
    required String commandName,
    required Map<String, String> values,
    required int requestId,
  }) async {
    await gate.future;
    return super.renderNetworkWebsocketCommand(
      specYaml: specYaml,
      commandName: commandName,
      values: values,
      requestId: requestId,
    );
  }
}

void main() {
  late FakeSpecCodec codec;

  setUp(() => codec = FakeSpecCodec());

  // ── Samsung: one socket, a token the TV issues unprompted ────────────────

  // The REAL vendored path shape, not an invented one: the spec spells
  // `{client_name}` and `{token}`, while naming its credential
  // `samsung_token`. The earlier fixture wrote `{samsung_token}` into the
  // path, so these tests passed against a fill rule the actual catalogue
  // never exercised — and the literal braces went to the TV.
  const samsungSurface = WebSocketSurfaceDto(
    port: 8002,
    scheme: 'wss',
    path:
        '/api/v2/channels/samsung.remote.control?name={client_name}&token={token}',
    fallbackPort: 8001,
    fallbackScheme: 'ws',
    fallbackPath: '/api/v2/channels/samsung.remote.control?name={client_name}',
    headers: [],
    tlsSelfSigned: true,
    tlsVerification: 'none',
    pairingMode: 'token_query',
    credentialName: 'samsung_token',
    issuedAt: 'data.token',
    promptNotes: 'Approve the connection on the TV.',
    channels: [
      WebSocketChannelDto(name: 'remote', isDefault: true, encoding: 'json'),
    ],
  );

  test('connection failures never quote the pairing token', () {
    // Samsung's token rides in the socket URL's query string, and the three
    // connection failures used to interpolate the whole URL into a
    // WsConnectionException — shown on screen and kept in the info log.
    expect(
      redactUrl('wss://tv.local:8002/api/v2/channels/samsung.remote.control'
          '?name=TGliZXJhdGVk&token=12345678'),
      'wss://tv.local:8002/api/v2/channels/samsung.remote.control?…',
    );
    expect(redactUrl('ws://tv.local:8001/api/v2'), 'ws://tv.local:8001/api/v2');
    expect(redactUrl('not a url ::'), isNot(contains('token')));
  });

  test('opens the declared address and stores the token the TV issues',
      () async {
    final tv = ScriptedWsSocket();
    final urls = <String>[];
    final session = WsSession(
      codec: codec,
      specYaml: 'yaml',
      host: '10.0.0.4',
      surface: samsungSurface,
      connect: (url, headers) async {
        urls.add(url);
        // The set speaks first: a good connection delivers the token.
        scheduleMicrotask(() => tv.send(jsonEncode({
              'event': 'ms.channel.connect',
              'data': {'token': '12345678'},
            })));
        return tv;
      },
    );
    addTearDown(session.dispose);

    await session.open();

    expect(urls.single, startsWith('wss://10.0.0.4:8002/api/v2/channels/'));
    // No placeholder survives to the wire: the pairing keys on the client
    // NAME in the URL, and a literal "{client_name}" is a client the viewer
    // never approved.
    expect(urls.single, isNot(contains('{')));
    // The name rides as standard base64 of the UTF-8 display name.
    expect(
      urls.single,
      contains('name=${base64.encode(utf8.encode(AppConstants.appName))}'),
    );
    // No token yet on a first connection: the pair is DROPPED, not sent
    // empty — some sets read `token=` as a key and refuse it.
    expect(urls.single, isNot(contains('token')));
    // And the issued one is now available for the caller to store.
    expect(session.credential, '12345678');
  });

  test('carries a stored token into the connect path', () async {
    final tv = ScriptedWsSocket();
    final urls = <String>[];
    final session = WsSession(
      codec: codec,
      specYaml: 'yaml',
      host: '10.0.0.4',
      surface: samsungSurface,
      credential: 'stored-token',
      connect: (url, headers) async {
        urls.add(url);
        scheduleMicrotask(() => tv.send(jsonEncode({
              'event': 'ms.channel.connect',
              'data': {'token': 'stored-token'},
            })));
        return tv;
      },
    );
    addTearDown(session.dispose);

    await session.open();
    expect(urls.single, endsWith('token=stored-token'));
  });

  /// Late firmware listens on the TLS port only and refuses the plain one;
  /// LG's clients are required to try both, and the refusal on the way is
  /// ordinary rather than an error worth showing.
  test('falls back to the second address when the first refuses', () async {
    final tv = ScriptedWsSocket();
    final urls = <String>[];
    final session = WsSession(
      codec: codec,
      specYaml: 'yaml',
      host: '10.0.0.4',
      surface: samsungSurface,
      connect: (url, headers) async {
        urls.add(url);
        if (urls.length == 1) {
          throw const WsConnectionException('refused');
        }
        scheduleMicrotask(() => tv.send(jsonEncode({
              'data': {'token': 't'}
            })));
        return tv;
      },
    );
    addTearDown(session.dispose);

    await session.open();
    expect(urls, hasLength(2));
    expect(urls[1], startsWith('ws://10.0.0.4:8001/'));
  });

  test('a device that never authorises says what the viewer must do', () async {
    final tv = ScriptedWsSocket();
    final session = WsSession(
      codec: codec,
      specYaml: 'yaml',
      host: '10.0.0.4',
      // Same surface, but nothing will answer.
      surface: samsungSurface,
      connect: (url, headers) async => tv,
    );
    addTearDown(session.dispose);

    // Not waited out in real time: the assertion is the message, and a 60s
    // pairing window is deliberate. Drive it by closing the socket instead,
    // which fails the wait immediately.
    final opening = session.open();
    scheduleMicrotask(tv.close);

    await expectLater(opening, throwsA(isA<Exception>()));
    expect(session.isConnected, isFalse);
  });

  // ── LG: a registration frame, and a second socket for buttons ────────────

  const lgSurface = WebSocketSurfaceDto(
    port: 3000,
    scheme: 'ws',
    path: '/',
    headers: [],
    tlsSelfSigned: true,
    tlsVerification: 'none',
    pairingMode: 'register_frame',
    credentialName: 'webos_client_key',
    issuedAt: 'payload.client-key',
    registerFrame:
        '{"id":"register_0","type":"register","payload":{"client-key":"{credential}","pairingType":"PROMPT"}}',
    promptNotes: 'Accept the pairing request on the TV.',
    channels: [
      WebSocketChannelDto(name: 'ssap', isDefault: true, encoding: 'json'),
      WebSocketChannelDto(
        name: 'pointer',
        isDefault: false,
        encoding: 'text',
        obtainedBy: 'get_pointer_socket',
        addressPath: 'payload.socketPath',
      ),
    ],
  );

  /// A first pairing has no key, and sending the field as an empty string is
  /// not the same message: some devices read that as a key and reject it.
  test('a first pairing sends the register frame without the key field',
      () async {
    final tv = ScriptedWsSocket();
    final session = WsSession(
      codec: codec,
      specYaml: 'yaml',
      host: '10.0.0.5',
      surface: lgSurface,
      connect: (url, headers) async {
        scheduleMicrotask(() => tv.send(jsonEncode({
              'type': 'registered',
              'payload': {'client-key': 'abc123'},
            })));
        return tv;
      },
    );
    addTearDown(session.dispose);

    await session.open();

    final sent = jsonDecode(tv.written.single) as Map<String, dynamic>;
    final payload = sent['payload'] as Map<String, dynamic>;
    expect(payload.containsKey('client-key'), isFalse);
    expect(payload['pairingType'], 'PROMPT');
    expect(session.credential, 'abc123');
  });

  test('a repeat pairing sends the stored key', () async {
    final tv = ScriptedWsSocket();
    final session = WsSession(
      codec: codec,
      specYaml: 'yaml',
      host: '10.0.0.5',
      surface: lgSurface,
      credential: 'abc123',
      connect: (url, headers) async {
        scheduleMicrotask(() => tv.send(jsonEncode({
              'type': 'registered',
              'payload': {'client-key': 'abc123'},
            })));
        return tv;
      },
    );
    addTearDown(session.dispose);

    await session.open();
    final sent = jsonDecode(tv.written.single) as Map<String, dynamic>;
    expect((sent['payload'] as Map)['client-key'], 'abc123');
  });

  /// The point of the two-channel design: a button does NOT go to the socket
  /// the JSON requests go to. It goes to one the TV names at runtime, and
  /// sending it on the main socket would be silently ignored.
  test('a button opens the runtime socket the TV names, once', () async {
    final main = ScriptedWsSocket();
    final pointer = ScriptedWsSocket();
    final urls = <String>[];

    codec.websocketFrameFor = (command, id) => switch (command) {
          'get_pointer_socket' => WebSocketFrameDto(
              channel: 'ssap',
              text: jsonEncode({
                'id': id,
                'type': 'request',
                'uri':
                    'ssap://com.webos.service.networkinput/getPointerInputSocket',
              })),
          _ => const WebSocketFrameDto(
              channel: 'pointer', text: 'type:button\nname:HOME\n\n'),
        };

    final session = WsSession(
      codec: codec,
      specYaml: 'yaml',
      host: '10.0.0.5',
      surface: lgSurface,
      credential: 'abc123',
      connect: (url, headers) async {
        urls.add(url);
        if (urls.length == 1) {
          scheduleMicrotask(() => main.send(jsonEncode({
                'type': 'registered',
                'payload': {'client-key': 'abc123'},
              })));
          return main;
        }
        return pointer;
      },
    );
    addTearDown(session.dispose);
    await session.open();

    // The request for the socket's address goes out on the main socket, and
    // the TV answers with it.
    final pressing = session.send('press_home', const {});
    await Future<void>.delayed(Duration.zero);
    main.send(jsonEncode({
      'payload': {'socketPath': 'ws://10.0.0.5:3000/pointer'}
    }));
    await pressing;

    expect(urls, hasLength(2));
    expect(urls[1], 'ws://10.0.0.5:3000/pointer');
    // Plain text, on the other socket entirely.
    expect(pointer.written.single, 'type:button\nname:HOME\n\n');

    // A second button reuses it: asking for a new address per press is what
    // the address exists to avoid.
    await session.send('press_back', const {});
    expect(urls, hasLength(2));
    expect(pointer.written, hasLength(2));
  });

  test('an ssap request goes to the main socket with a fresh id', () async {
    final tv = ScriptedWsSocket();
    codec.websocketFrameFor = (command, id) => WebSocketFrameDto(
        channel: 'ssap', text: jsonEncode({'id': id, 'uri': command}));
    final session = WsSession(
      codec: codec,
      specYaml: 'yaml',
      host: '10.0.0.5',
      surface: lgSurface,
      credential: 'abc123',
      connect: (url, headers) async {
        scheduleMicrotask(() => tv.send(jsonEncode({
              'payload': {'client-key': 'abc123'}
            })));
        return tv;
      },
    );
    addTearDown(session.dispose);
    await session.open();

    await session.send('volume_up', const {});
    await session.send('volume_up', const {});

    final ids = tv.written
        .map((f) => jsonDecode(f))
        .whereType<Map<String, dynamic>>()
        .map((f) => f['id'])
        .whereType<int>()
        .toList();
    // Two sends, two different correlation ids — a fixed one would match
    // every reply to the same request.
    expect(ids, hasLength(2));
    expect(ids[0], isNot(ids[1]));
  });

  test('sending before opening is refused, not silently dropped', () async {
    final session = WsSession(
      codec: codec,
      specYaml: 'yaml',
      host: '10.0.0.5',
      surface: lgSurface,
    );
    addTearDown(session.dispose);

    await expectLater(
      session.send('volume_up', const {}),
      throwsA(isA<WsConnectionException>()),
    );
  });

  test('closing shuts every socket the session opened', () async {
    final main = ScriptedWsSocket();
    final pointer = ScriptedWsSocket();
    var opened = 0;
    codec.websocketFrameFor = (command, id) => command == 'get_pointer_socket'
        ? WebSocketFrameDto(channel: 'ssap', text: jsonEncode({'id': id}))
        : const WebSocketFrameDto(channel: 'pointer', text: 'x');

    final session = WsSession(
      codec: codec,
      specYaml: 'yaml',
      host: '10.0.0.5',
      surface: lgSurface,
      credential: 'k',
      connect: (url, headers) async {
        opened++;
        if (opened == 1) {
          scheduleMicrotask(() => main.send(jsonEncode({
                'payload': {'client-key': 'k'}
              })));
          return main;
        }
        return pointer;
      },
    );
    await session.open();
    unawaited(session.send('press_home', const {}));
    await Future<void>.delayed(Duration.zero);
    main.send(jsonEncode({
      'payload': {'socketPath': 'ws://10.0.0.5:3000/pointer'}
    }));
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);

    await session.close();
    expect(main.closed, isTrue);
    expect(pointer.closed, isTrue,
        reason: 'the runtime socket leaks otherwise');
    expect(session.isConnected, isFalse);
    await session.dispose();
  });

  /// A pairing mode this build does not implement must not be improvised
  /// past: proceeding would open an unauthorised session whose every command
  /// is silently dropped.
  test('an unknown pairing mode is refused rather than skipped', () async {
    final tv = ScriptedWsSocket();
    final session = WsSession(
      codec: codec,
      specYaml: 'yaml',
      host: '10.0.0.5',
      surface: const WebSocketSurfaceDto(
        port: 1,
        scheme: 'ws',
        path: '/',
        headers: [],
        tlsSelfSigned: false,
        pairingMode: 'some_future_scheme',
        channels: [
          WebSocketChannelDto(name: 'main', isDefault: true, encoding: 'json')
        ],
      ),
      connect: (url, headers) async => tv,
    );
    addTearDown(session.dispose);

    await expectLater(
      session.open(),
      throwsA(isA<WsPairingException>()
          .having((e) => e.message, 'message', contains('some_future_scheme'))),
    );
  });

  /// A socket with no pairing block needs no authorisation, and must not sit
  /// waiting for a credential nobody is going to send.
  test('a surface with no pairing opens immediately', () async {
    final tv = ScriptedWsSocket();
    final session = WsSession(
      codec: codec,
      specYaml: 'yaml',
      host: '10.0.0.5',
      surface: const WebSocketSurfaceDto(
        port: 1,
        scheme: 'ws',
        path: '/',
        headers: [],
        tlsSelfSigned: false,
        channels: [
          WebSocketChannelDto(name: 'main', isDefault: true, encoding: 'json')
        ],
      ),
      connect: (url, headers) async => tv,
    );
    addTearDown(session.dispose);

    await session.open();
    expect(session.isConnected, isTrue);
    expect(session.credential, isNull);
  });

  // ── Lifecycle: teardown, keepalive, and the runtime socket's guards ──────

  test('the session tears down when the device hangs up', () async {
    final tv = ScriptedWsSocket();
    final session = WsSession(
      codec: codec,
      specYaml: 'yaml',
      host: '10.0.0.4',
      surface: samsungSurface,
      connect: (url, headers) async {
        scheduleMicrotask(() => tv.send(jsonEncode({
              'data': {'token': 't'}
            })));
        return tv;
      },
    );
    addTearDown(session.dispose);
    await session.open();
    expect(session.isConnected, isTrue);

    // The TV hangs up. The session must stop LOOKING connected — with the
    // socket still set, the sender cached this dead session forever and the
    // next press died inside a closed sink as a raw StateError.
    await tv.close();
    await Future<void>.delayed(Duration.zero);
    expect(session.isConnected, isFalse);
    await expectLater(
      session.send('anything', const {}),
      throwsA(isA<WsConnectionException>()),
    );
  });

  test('a pairing that cannot even start releases the socket', () async {
    // register_frame declared, no frame carried: _registerFrame() throws
    // SYNCHRONOUSLY. That throw used to escape the close-on-error block with
    // the socket already open — never closed, never listened to.
    const noFrame = WebSocketSurfaceDto(
      port: 3000,
      scheme: 'ws',
      path: '/',
      headers: [],
      tlsSelfSigned: true,
      tlsVerification: 'none',
      pairingMode: 'register_frame',
      credentialName: 'webos_client_key',
      issuedAt: 'payload.client-key',
      channels: [
        WebSocketChannelDto(name: 'ssap', isDefault: true, encoding: 'json'),
      ],
    );
    final tv = ScriptedWsSocket();
    final session = WsSession(
      codec: codec,
      specYaml: 'yaml',
      host: '10.0.0.5',
      surface: noFrame,
      connect: (url, headers) async => tv,
    );
    addTearDown(session.dispose);

    await expectLater(session.open(), throwsA(isA<WsPairingException>()));
    expect(tv.closed, isTrue, reason: 'the socket must not leak');
    expect(session.isConnected, isFalse);
  });

  test("the spec's heartbeat rides the protocol ping, not an empty frame",
      () async {
    const withHeartbeat = WebSocketSurfaceDto(
      port: 8002,
      scheme: 'wss',
      path: '/api',
      headers: [],
      tlsSelfSigned: true,
      tlsVerification: 'none',
      heartbeatSeconds: 5,
      channels: [
        WebSocketChannelDto(name: 'remote', isDefault: true, encoding: 'json'),
      ],
    );
    final tv = ScriptedWsSocket();
    final session = WsSession(
      codec: codec,
      specYaml: 'yaml',
      host: '10.0.0.4',
      surface: withHeartbeat,
      connect: (url, headers) async => tv,
    );
    addTearDown(session.dispose);
    await session.open();

    expect(tv.pings, const Duration(seconds: 5));
    expect(tv.written, isEmpty,
        reason: 'an empty TEXT frame is not a keepalive — LG\'s dispatcher '
            'reads it as a malformed request');
  });

  test('a runtime socket on a foreign host is refused', () async {
    final main = ScriptedWsSocket();
    final urls = <String>[];
    codec.websocketFrameFor = (command, id) => switch (command) {
          'get_pointer_socket' => WebSocketFrameDto(
              channel: 'ssap', text: jsonEncode({'id': id, 'uri': command})),
          _ => const WebSocketFrameDto(channel: 'pointer', text: 'x'),
        };
    final session = WsSession(
      codec: codec,
      specYaml: 'yaml',
      host: '10.0.0.5',
      surface: lgSurface,
      credential: 'abc123',
      connect: (url, headers) async {
        urls.add(url);
        scheduleMicrotask(() => main.send(jsonEncode({
              'payload': {'client-key': 'abc123'}
            })));
        return main;
      },
    );
    addTearDown(session.dispose);
    await session.open();

    final pressing = session.send('press_home', const {});
    await Future<void>.delayed(Duration.zero);
    // The "TV" answers with an address that is not this device at all.
    main.send(jsonEncode({
      'payload': {'socketPath': 'wss://attacker.example:443/collect'}
    }));
    await expectLater(pressing, throwsA(isA<WsConnectionException>()));
    // And nothing ever connected to it.
    expect(urls, hasLength(1));
  });

  test('concurrent presses share one runtime socket open', () async {
    final main = ScriptedWsSocket();
    final pointer = ScriptedWsSocket();
    final urls = <String>[];
    codec.websocketFrameFor = (command, id) => switch (command) {
          'get_pointer_socket' => WebSocketFrameDto(
              channel: 'ssap', text: jsonEncode({'id': id, 'uri': command})),
          _ => WebSocketFrameDto(channel: 'pointer', text: 'name:$command\n'),
        };
    final session = WsSession(
      codec: codec,
      specYaml: 'yaml',
      host: '10.0.0.5',
      surface: lgSurface,
      credential: 'abc123',
      connect: (url, headers) async {
        urls.add(url);
        if (urls.length == 1) {
          scheduleMicrotask(() => main.send(jsonEncode({
                'payload': {'client-key': 'abc123'}
              })));
          return main;
        }
        return pointer;
      },
    );
    addTearDown(session.dispose);
    await session.open();

    // Two presses race the FIRST use of the pointer socket. Before the
    // in-flight guard, both missed the cache and each opened its own socket;
    // the second overwrote the map and the first leaked, still open.
    final first = session.send('press_home', const {});
    final second = session.send('press_back', const {});
    await Future<void>.delayed(Duration.zero);
    main.send(jsonEncode({
      'payload': {'socketPath': 'ws://10.0.0.5:3000/pointer'}
    }));
    await first;
    await second;

    expect(urls, hasLength(2), reason: 'main + ONE pointer socket');
    expect(pointer.written, hasLength(2));
  });

  /// A spec-authored literal query value that merely ENDS in base64 padding
  /// is a value, not an empty pair. The old trailing-`=` rule deleted it.
  test('a literal query value ending in base64 padding survives', () async {
    final tv = ScriptedWsSocket();
    final urls = <String>[];
    const surface = WebSocketSurfaceDto(
      port: 8002,
      scheme: 'wss',
      path: '/api/v2/channels/x?fmt=YmFzZTY0=&name={client_name}&token={token}',
      headers: [],
      tlsSelfSigned: true,
      tlsVerification: 'none',
      pairingMode: 'token_query',
      credentialName: 'samsung_token',
      issuedAt: 'data.token',
      channels: [
        WebSocketChannelDto(name: 'remote', isDefault: true, encoding: 'json'),
      ],
    );
    final session = WsSession(
      codec: codec,
      specYaml: 'yaml',
      host: '10.0.0.4',
      surface: surface,
      connect: (url, headers) async {
        urls.add(url);
        scheduleMicrotask(() => tv.send(jsonEncode({
              'data': {'token': 't'}
            })));
        return tv;
      },
    );
    addTearDown(session.dispose);
    await session.open();

    expect(urls.single, contains('fmt=YmFzZTY0='));
    expect(urls.single, isNot(contains('token=')),
        reason: 'the genuinely empty pair still drops');
  });

  /// The TV hangs up exactly while send() is awaiting its render. The entry
  /// guard has already passed, so the socket must be re-read afterwards —
  /// this used to surface as a raw null-check TypeError no catch knows.
  test('a hang-up during a send reads as the device closing, not a crash',
      () async {
    final gated = _GatedRenderCodec();
    final tv = ScriptedWsSocket();
    final session = WsSession(
      codec: gated,
      specYaml: 'yaml',
      host: '10.0.0.4',
      surface: samsungSurface,
      connect: (url, headers) async {
        scheduleMicrotask(() => tv.send(jsonEncode({
              'data': {'token': 't'}
            })));
        return tv;
      },
    );
    addTearDown(session.dispose);
    await session.open();

    final pressing = session.send('press_power', const {});
    await tv.hangUp();
    await pumpEventQueue();
    gated.gate.complete();

    await expectLater(pressing, throwsA(isA<WsConnectionException>()));
  });

  /// The set idle-closes its button socket. A cached corpse would be served
  /// to every later press, add() silently dropping — the eviction is what
  /// makes the next press re-request the channel.
  test('an idle-closed runtime socket is evicted and re-requested', () async {
    final main = ScriptedWsSocket();
    final pointers = <ScriptedWsSocket>[];
    final urls = <String>[];
    codec.websocketFrameFor = (command, id) => switch (command) {
          'get_pointer_socket' => WebSocketFrameDto(
              channel: 'ssap', text: jsonEncode({'id': id, 'uri': command})),
          _ => WebSocketFrameDto(channel: 'pointer', text: 'name:$command\n'),
        };
    final session = WsSession(
      codec: codec,
      specYaml: 'yaml',
      host: '10.0.0.5',
      surface: lgSurface,
      credential: 'abc123',
      connect: (url, headers) async {
        urls.add(url);
        if (urls.length == 1) {
          scheduleMicrotask(() => main.send(jsonEncode({
                'payload': {'client-key': 'abc123'}
              })));
          return main;
        }
        final pointer = ScriptedWsSocket();
        pointers.add(pointer);
        return pointer;
      },
    );
    addTearDown(session.dispose);
    await session.open();

    Future<void> press() async {
      final pressing = session.send('press_home', const {});
      await Future<void>.delayed(Duration.zero);
      main.send(jsonEncode({
        'payload': {'socketPath': 'ws://10.0.0.5:3000/pointer'}
      }));
      await pressing;
    }

    await press();
    expect(pointers, hasLength(1));

    // The set closes the button socket while the screen sits idle.
    await pointers.single.hangUp();
    await pumpEventQueue();

    await press();
    expect(pointers, hasLength(2),
        reason: 'the dead socket must be re-requested, not served');
    expect(pointers.last.written, hasLength(1));
  });

  /// close() races a channel open still in flight: the socket that connect
  /// hands back afterwards must be closed, never cached on the spent
  /// session — nothing else would ever close it.
  test('a runtime socket resolving after close is closed, not cached',
      () async {
    final main = ScriptedWsSocket();
    final pointer = ScriptedWsSocket();
    final pointerGate = Completer<void>();
    final urls = <String>[];
    codec.websocketFrameFor = (command, id) => switch (command) {
          'get_pointer_socket' => WebSocketFrameDto(
              channel: 'ssap', text: jsonEncode({'id': id, 'uri': command})),
          _ => const WebSocketFrameDto(channel: 'pointer', text: 'x'),
        };
    final session = WsSession(
      codec: codec,
      specYaml: 'yaml',
      host: '10.0.0.5',
      surface: lgSurface,
      credential: 'abc123',
      connect: (url, headers) async {
        urls.add(url);
        if (urls.length == 1) {
          scheduleMicrotask(() => main.send(jsonEncode({
                'payload': {'client-key': 'abc123'}
              })));
          return main;
        }
        await pointerGate.future;
        return pointer;
      },
    );
    await session.open();

    final pressing = session.send('press_home', const {});
    await Future<void>.delayed(Duration.zero);
    main.send(jsonEncode({
      'payload': {'socketPath': 'ws://10.0.0.5:3000/pointer'}
    }));
    await pumpEventQueue();
    expect(urls, hasLength(2), reason: 'the channel connect is in flight');

    await session.close();
    pointerGate.complete();

    await expectLater(pressing, throwsA(isA<WsConnectionException>()));
    await pumpEventQueue();
    expect(pointer.closed, isTrue,
        reason: 'a socket born after close must be closed, not cached');
    await session.dispose();
  });

  /// Uri.parse lowercases the host; discovery may have recorded it in the
  /// case the device advertises. The comparison must not care.
  test('the runtime address host check is case-insensitive', () async {
    final main = ScriptedWsSocket();
    final pointer = ScriptedWsSocket();
    final urls = <String>[];
    codec.websocketFrameFor = (command, id) => switch (command) {
          'get_pointer_socket' => WebSocketFrameDto(
              channel: 'ssap', text: jsonEncode({'id': id, 'uri': command})),
          _ => const WebSocketFrameDto(channel: 'pointer', text: 'x'),
        };
    final session = WsSession(
      codec: codec,
      specYaml: 'yaml',
      host: 'LGwebOSTV.local',
      surface: lgSurface,
      credential: 'abc123',
      connect: (url, headers) async {
        urls.add(url);
        if (urls.length == 1) {
          scheduleMicrotask(() => main.send(jsonEncode({
                'payload': {'client-key': 'abc123'}
              })));
          return main;
        }
        return pointer;
      },
    );
    addTearDown(session.dispose);
    await session.open();

    final pressing = session.send('press_home', const {});
    await Future<void>.delayed(Duration.zero);
    main.send(jsonEncode({
      'payload': {'socketPath': 'ws://LGwebOSTV.local:3000/pointer'}
    }));
    await pressing;

    expect(urls, hasLength(2),
        reason: 'the same set, spelled as it advertises, is not refused');
    expect(pointer.written, hasLength(1));
  });
}
