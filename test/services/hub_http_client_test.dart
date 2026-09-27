// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// The hub transport against canned HTTP: request assembly, the v1 envelope
// rules the spec's payload_formats.V1Envelope states, and the scheme ladder —
// https first, plain http only for a bridge with no 443 at all, remembered
// either way, and never a downgrade after a TLS failure or once https is
// established. The TLS trust decision itself (CN check, pinning) runs against
// a real loopback server in hub_http_client_tls_test.dart; MockClient never
// touches dart:io.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:liberated_bread_mobile/services/hub_credential_store.dart';
import 'package:liberated_bread_mobile/services/hub_http_client.dart';
import 'package:liberated_bread_mobile/services/spec_codec.dart';

import '../fakes/in_memory_settings_store.dart';

const _bridgeId = '001788FFFEAABBCC';
const _put = HttpRequestDto(
  method: 'PUT',
  path: '/api/secretuser/lights/1/state',
  body: '{"on":true}',
);
const _get = HttpRequestDto(
  method: 'GET',
  path: '/api/secretuser/lights',
  body: '',
);

/// What a closed port really raises: ECONNREFUSED in the OSError — the
/// only failure the BSB001 downgrade may act on.
final _refused = SocketException(
  'Connection refused',
  osError: OSError('Connection refused', Platform.isMacOS ? 61 : 111),
);

void main() {
  late HubCredentialStore store;

  setUp(() {
    store = HubCredentialStore(InMemorySettingsStore());
  });

  HubHttpClient client({
    Future<http.Response> Function(http.Request)? secure,
    Future<http.Response> Function(http.Request)? plain,
  }) => HubHttpClient(
    credentials: store,
    secureClientFactory: (_) =>
        MockClient(secure ?? (_) async => throw _refused),
    plainClientFactory: () =>
        MockClient(plain ?? (_) async => throw const SocketException('no 80')),
  );

  test('a write goes out as the rendered method, path and JSON body', () async {
    late http.Request seen;
    final hub = client(
      secure: (request) async {
        seen = request;
        return http.Response('[{"success":{"/lights/1/state/on":true}}]', 200);
      },
    );

    await hub.send('10.0.0.2', _bridgeId, _put);

    expect(seen.method, 'PUT');
    // Uri elides the default port, so assert scheme/port structurally.
    expect(seen.url.scheme, 'https');
    expect(seen.url.port, 443);
    expect(seen.url.path, '/api/secretuser/lights/1/state');
    expect(seen.body, '{"on":true}');
    expect(seen.headers['Content-Type'], startsWith('application/json'));
  });

  test('a bare GET carries no body and returns the reply verbatim', () async {
    final hub = client(secure: (_) async => http.Response('{"1":{}}', 200));
    expect(await hub.send('10.0.0.2', _bridgeId, _get), '{"1":{}}');
  });

  test('a successful https send remembers the scheme', () async {
    final hub = client(secure: (_) async => http.Response('{}', 200));
    await hub.send('10.0.0.2', _bridgeId, _get);
    expect(await store.scheme(_bridgeId), 'https');
  });

  test(
    'no 443 listener falls back to plain http once, then remembers it',
    () async {
      var plainCalls = 0;
      final hub = client(
        plain: (request) async {
          plainCalls += 1;
          expect(request.url.scheme, 'http');
          expect(request.url.port, 80);
          return http.Response('{}', 200);
        },
      );

      await hub.send('10.0.0.2', _bridgeId, _get);
      expect(plainCalls, 1, reason: 'the BSB001 path');
      expect(await store.scheme(_bridgeId), 'http');

      // Next send goes straight to http — no https re-probe per request.
      await hub.send('10.0.0.2', _bridgeId, _get);
      expect(plainCalls, 2);
    },
  );

  test('a bridge that has spoken https is never downgraded', () async {
    await store.saveScheme(_bridgeId, 'https');
    var plainCalls = 0;
    final hub = client(
      plain: (_) async {
        plainCalls += 1;
        return http.Response('{}', 200);
      },
    );

    await expectLater(
      hub.send('10.0.0.2', _bridgeId, _get),
      throwsA(isA<HubTransportException>()),
    );
    expect(
      plainCalls,
      0,
      reason:
          'a refused 443 on an https bridge must not put the '
          'credential on the wire in clear',
    );
  });

  test(
    'a stored pin alone refuses the downgrade, even with no scheme record',
    () async {
      // The pin and the scheme are two separate keychain writes; a crash
      // between them can leave a bridge pinned with no scheme. The pin is the
      // durable proof 443 verified once, so it must refuse the plain-http
      // fallback on its own — otherwise a refused 443 plus an on-path attacker
      // on port 80 would get the credential in clear.
      await store.saveCertPin(_bridgeId, 'a' * 64);
      expect(
        await store.scheme(_bridgeId),
        isNull,
        reason: 'no scheme recorded',
      );
      var plainCalls = 0;
      final hub = client(
        plain: (_) async {
          plainCalls += 1;
          return http.Response('{}', 200);
        },
      );

      await expectLater(
        hub.send('10.0.0.2', _bridgeId, _get),
        throwsA(isA<HubTransportException>()),
      );
      expect(plainCalls, 0);
    },
  );

  test('a TLS failure is never followed by an http fallback', () async {
    var plainCalls = 0;
    final hub = client(
      secure: (_) async => throw const HandshakeException('rejected'),
      plain: (_) async {
        plainCalls += 1;
        return http.Response('{}', 200);
      },
    );

    await expectLater(
      hub.send('10.0.0.2', _bridgeId, _get),
      throwsA(isA<HubTlsException>()),
    );
    expect(plainCalls, 0);
  });

  test(
    'error type 1 surfaces as HubAuthException — the re-pair signal',
    () async {
      final hub = client(
        secure: (_) async => http.Response(
          '[{"error":{"type":1,"address":"/","description":"unauthorized user"}}]',
          200,
        ),
      );
      await expectLater(
        hub.send('10.0.0.2', _bridgeId, _put),
        throwsA(isA<HubAuthException>()),
      );
    },
  );

  test(
    'other envelope errors carry their type, and a mixed envelope throws',
    () async {
      final hub = client(
        secure: (_) async => http.Response(
          '[{"success":{"/lights/1/state/on":true}},'
          '{"error":{"type":201,"address":"/lights/1/state/bri",'
          '"description":"parameter, bri, is not modifiable. Device is set to off."}}]',
          200,
        ),
      );
      await expectLater(
        hub.send('10.0.0.2', _bridgeId, _put),
        throwsA(isA<HubApiException>().having((e) => e.type, 'type', 201)),
      );
    },
  );

  test(
    'sendUnchecked leaves the envelope to the caller (pairing needs 101)',
    () async {
      const keepWaiting =
          '[{"error":{"type":101,"address":"","description":"link button not pressed"}}]';
      final hub = client(secure: (_) async => http.Response(keepWaiting, 200));
      expect(await hub.sendUnchecked('10.0.0.2', _bridgeId, _put), keepWaiting);
    },
  );

  test(
    'a non-200 answer never echoes the path — the path is the credential',
    () async {
      final hub = client(secure: (_) async => http.Response('gone', 404));
      try {
        await hub.send('10.0.0.2', _bridgeId, _put);
        fail('expected HubTransportException');
      } on HubTransportException catch (e) {
        expect(e.toString(), isNot(contains('secretuser')));
        expect(e.toString(), contains('404'));
      }
    },
  );

  test(
    'fetchConfig works unauthenticated over plain http with no CN seen',
    () async {
      final hub = client(
        plain: (request) async {
          expect(request.url.path, '/api/config');
          return http.Response('{"bridgeid":"$_bridgeId"}', 200);
        },
      );
      final probe = await hub.fetchConfig('10.0.0.2');
      expect(probe.body, contains(_bridgeId));
      expect(probe.observedCn, isNull);
    },
  );

  test('parseV1Envelope: arrays are envelopes, objects are GET replies', () {
    expect(HubHttpClient.parseV1Envelope('{"1":{}}'), isNull);
    expect(HubHttpClient.parseV1Envelope('not json'), isNull);
    final outcomes = HubHttpClient.parseV1Envelope(
      '[{"success":{"username":"u"}},{"error":{"type":101,"description":"d"}}]',
    );
    expect(outcomes, hasLength(2));
    expect(outcomes![0].success?['username'], 'u');
    expect(outcomes[1].error?.isLinkButtonNotPressed, isTrue);
  });

  // ── Only a refused 443 is BSB001 ────────────────────────────────────────

  group('a first-contact failure that is not a refused connect', () {
    Future<void> expectNoDowngrade(Object failure) async {
      var plainCalls = 0;
      final hub = client(
        secure: (_) async => throw failure,
        plain: (_) async {
          plainCalls += 1;
          return http.Response('{}', 200);
        },
      );
      await expectLater(
        hub.send('10.0.0.2', _bridgeId, _get),
        throwsA(isA<HubTransportException>()),
      );
      expect(plainCalls, 0, reason: 'the credential must not go out in clear');
      expect(
        await store.scheme(_bridgeId),
        isNull,
        reason: 'one transient failure must not persist a cleartext scheme',
      );
    }

    test('an HTTP-level failure (a server answered) never downgrades', () {
      // package:http wraps an HttpException as a plain ClientException; it
      // was converted to a SocketException and read as "no 443 listener".
      return expectNoDowngrade(
        http.ClientException(
          'Connection closed before full header was received',
        ),
      );
    });

    test('a reset never downgrades', () {
      return expectNoDowngrade(
        SocketException(
          'Connection reset by peer',
          osError: OSError(
            'Connection reset by peer',
            Platform.isMacOS ? 54 : 104,
          ),
        ),
      );
    });

    test('a socket failure with no OS cause never downgrades', () {
      return expectNoDowngrade(const SocketException('no 443'));
    });
  });

  group('a plain-http (BSB001) bridge', () {
    test('a dropped request is a HubTransportException, like https', () async {
      // A raw SocketException from the plain path escaped every caller that
      // handles the https branch's HubTransportException — the pairing
      // loop's one-dropped-poll tolerance included.
      await store.saveScheme(_bridgeId, 'http');
      final hub = client(plain: (_) async => throw _refused);
      await expectLater(
        hub.send('10.0.0.2', _bridgeId, _get),
        throwsA(isA<HubTransportException>()),
      );
    });

    test('so is an HTTP-level failure on it', () async {
      await store.saveScheme(_bridgeId, 'http');
      final hub = client(
        plain: (_) async => throw http.ClientException('Invalid response line'),
      );
      await expectLater(
        hub.send('10.0.0.2', _bridgeId, _get),
        throwsA(isA<HubTransportException>()),
      );
    });
  });
}
