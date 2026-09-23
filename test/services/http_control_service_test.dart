// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// The plain-HTTP control transport: build the URL from what discovery knows,
// send the rendered method/path, and turn the two failure shapes a device
// answers with into the right exceptions — 403 is a device-side setting, not
// a network fault.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:liberated_bread_mobile/core/error_text.dart';
import 'package:liberated_bread_mobile/services/http_control_service.dart';
import 'package:liberated_bread_mobile/services/settings_store.dart';
import 'package:liberated_bread_mobile/services/spec_codec.dart';
import 'package:liberated_bread_mobile/services/tls_trust.dart';
import 'package:liberated_bread_mobile/src/rust/api/device_api.dart'
    show HttpHeaderDto;

import '../fakes/in_memory_settings_store.dart';

/// A certificate is only ever asked for its DER here — the policy decisions
/// themselves are tested in tls_trust_test.dart; what this file cares about is
/// which SENTENCE each one turns into.
class _FakeCert implements X509Certificate {
  @override
  final Uint8List der;

  _FakeCert(String seed) : der = Uint8List.fromList(seed.codeUnits);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// A settings store whose reads throw: a locked keystore, a keyring-less
/// desktop. What matters is that a pin read CAN fail, not how.
class _FailingStore implements SettingsStore {
  @override
  Future<String?> read(String key) async => throw StateError('keystore locked');
  @override
  Future<void> write(String key, String value) async {}
  @override
  Future<void> delete(String key) async {}
  @override
  Future<Map<String, String>> readAll() async => const {};
}

void main() {
  const press = HttpRequestDto(
    method: 'POST',
    path: '/keypress/Home',
    body: '',
  );

  test(
    'a POST goes to the discovered host and port with an empty body',
    () async {
      late http.Request seen;
      final client = HttpControlClient(
        httpClient: MockClient((request) async {
          seen = request;
          return http.Response('', 200);
        }),
      );

      await client.send('10.0.0.9', 8060, press);

      expect(seen.method, 'POST');
      expect(seen.url.toString(), 'http://10.0.0.9:8060/keypress/Home');
      expect(seen.body, isEmpty);
    },
  );

  test('a rendered query string stays a query, not path data', () async {
    // The spec's /input endpoint carries its arguments in the query. Built
    // with Uri(path: ...) the '?' encodes as %3F and the device sees a path
    // it has never heard of.
    late http.Request seen;
    final client = HttpControlClient(
      httpClient: MockClient((request) async {
        seen = request;
        return http.Response('', 200);
      }),
    );

    await client.send(
      '10.0.0.9',
      8060,
      const HttpRequestDto(
        method: 'POST',
        path: '/input?acceleration.x=0.0',
        body: '',
      ),
    );

    expect(seen.url.path, '/input');
    expect(seen.url.query, 'acceleration.x=0.0');
  });

  test('a rendered percent-escape is not escaped again', () async {
    // The Rust renderer already encoded the value (Lit_%20 is a space); a
    // second pass would send Lit_%2520 and type a literal "%20".
    late http.Request seen;
    final client = HttpControlClient(
      httpClient: MockClient((request) async {
        seen = request;
        return http.Response('', 200);
      }),
    );

    await client.send(
      '10.0.0.9',
      8060,
      const HttpRequestDto(method: 'POST', path: '/keypress/Lit_%20', body: ''),
    );

    expect(seen.url.toString(), 'http://10.0.0.9:8060/keypress/Lit_%20');
  });

  test('a GET returns the response body for query endpoints', () async {
    final client = HttpControlClient(
      httpClient: MockClient((request) async {
        expect(request.method, 'GET');
        return http.Response('<device-info/>', 200);
      }),
    );

    final body = await client.send(
      '10.0.0.9',
      8060,
      const HttpRequestDto(method: 'GET', path: '/query/device-info', body: ''),
    );

    expect(body, '<device-info/>');
  });

  test('403 is the device refusing, with words a user can act on', () async {
    final client = HttpControlClient(
      httpClient: MockClient((request) async => http.Response('', 403)),
    );

    await expectLater(
      client.send('10.0.0.9', 8060, press),
      throwsA(isA<ControlRefusedException>()),
    );
    // The message is written for the screen: it must name the device-side
    // setting rather than suggest a rescan.
    expect(const ControlRefusedException(), isA<UserFacingException>());
    expect(
      const ControlRefusedException().message,
      contains('control by mobile apps'),
    );
  });

  test(
    '401 is the same refusal where the gate is a missing credential',
    () async {
      // The Envoy's firmware-7+ endpoints answer 401 until the entrez JWT rides
      // along — a device-side gate, not a network fault and not a bad request.
      final client = HttpControlClient(
        httpClient: MockClient((request) async => http.Response('', 401)),
      );

      await expectLater(
        client.send(
          '10.0.0.10',
          80,
          const HttpRequestDto(
            method: 'GET',
            path: '/api/v1/production',
            body: '',
          ),
        ),
        throwsA(isA<ControlRefusedException>()),
      );
    },
  );

  test(
    'a 400 naming Limited mode is the same refusal in its other spelling',
    () async {
      // Observed live on an OS 15.2.4 Roku TV: /query/apps answered
      // "400 Bad Request" with this body, then 403 for the same endpoint
      // minutes later. Both are the Limited-mode gate, not a bad request.
      final client = HttpControlClient(
        httpClient: MockClient(
          (request) async =>
              http.Response('ECP command not allowed in Limited mode.', 400),
        ),
      );

      await expectLater(
        client.send(
          '10.0.0.9',
          8060,
          const HttpRequestDto(method: 'GET', path: '/query/apps', body: ''),
        ),
        throwsA(isA<ControlRefusedException>()),
      );
    },
  );

  test(
    'a 400 without the Limited-mode body is a plain transport failure',
    () async {
      final client = HttpControlClient(
        httpClient: MockClient((request) async => http.Response('nah', 400)),
      );

      await expectLater(
        client.send('10.0.0.9', 8060, press),
        throwsA(isA<HttpControlException>()),
      );
    },
  );

  test(
    'any other non-2xx is a transport failure that names the request',
    () async {
      final client = HttpControlClient(
        httpClient: MockClient((request) async => http.Response('gone', 503)),
      );

      await expectLater(
        client.send('10.0.0.9', 8060, press),
        throwsA(
          isA<HttpControlException>().having(
            (e) => e.message,
            'message',
            contains('POST /keypress/Home'),
          ),
        ),
      );
    },
  );

  test(
    'a deadline with no answer says the device is asleep, not wrong',
    () async {
      // A Roku in deep standby keeps no ECP server: the request hangs until
      // the deadline. That must not surface as "the device did not accept
      // that" — nothing was refused, nobody was home.
      final client = HttpControlClient(
        httpClient: MockClient((request) async {
          await Future<void>.delayed(const Duration(minutes: 1));
          return http.Response('', 200);
        }),
      );

      await expectLater(
        client.send('10.0.0.9', 8060, press),
        throwsA(isA<ControlTimeoutException>()),
      );
      expect(const ControlTimeoutException(), isA<UserFacingException>());
      expect(const ControlTimeoutException().message, contains('asleep'));
    },
  );

  test('an unreachable device says so instead of blaming the button', () async {
    final client = HttpControlClient(
      httpClient: MockClient(
        (request) async => throw http.ClientException('Connection refused'),
      ),
    );

    await expectLater(
      client.send('10.0.0.9', 8060, press),
      throwsA(isA<ControlUnreachableException>()),
    );
    expect(
      const ControlUnreachableException().message,
      contains('not reachable'),
    );
  });

  test('a body travels under the content type it is written in', () async {
    // package:http defaults a string body to text/plain. The Rust renderer
    // now fills literal `body:` templates (JSON for WLED and Valetudo, XML
    // for Bose SoundTouch), and those endpoints are entitled to refuse a
    // body mislabelled as plain text. The empty-bodied ECP commands keep
    // sending no header at all.
    final seen = <http.Request>[];
    final client = HttpControlClient(
      httpClient: MockClient((request) async {
        seen.add(request);
        return http.Response('', 200);
      }),
    );

    await client.send(
      '10.0.0.9',
      80,
      const HttpRequestDto(
        method: 'POST',
        path: '/json/state',
        body: '{"on": true}',
      ),
    );
    await client.send(
      '10.0.0.9',
      8090,
      const HttpRequestDto(
        method: 'POST',
        path: '/key',
        body: '<key state="press">POWER</key>',
      ),
    );
    await client.send(
      '10.0.0.9',
      8060,
      const HttpRequestDto(method: 'POST', path: '/keypress/Home', body: ''),
    );

    expect(seen[0].headers['content-type'], 'application/json; charset=utf-8');
    expect(seen[1].headers['content-type'], 'text/xml; charset=utf-8');
    // package:http labels even an empty string body text/plain on its own;
    // the point is that this transport adds nothing to that.
    expect(
      seen[2].headers['content-type'] ?? '',
      isNot(anyOf(contains('json'), contains('xml'))),
      reason: 'an empty ECP body must not be labelled as either',
    );
    expect(contentTypeFor('   '), isNull);
  });

  test('spec-declared headers ride the request, on every method', () async {
    // R-032: the transport could send no header at all, so a Vizio key press
    // (PUT, JSON body, AUTH token) went out unauthenticated as text/plain. The
    // rendered request now carries what the spec declared, and a declared
    // Content-Type — in any letter case — replaces the inferred one rather
    // than joining it.
    final seen = <http.Request>[];
    final client = HttpControlClient(
      httpClient: MockClient((request) async {
        seen.add(request);
        return http.Response('{"STATUS":{"RESULT":"success"}}', 200);
      }),
    );

    await client.send(
      '10.0.0.9',
      7345,
      const HttpRequestDto(
        method: 'PUT',
        path: '/key_command/',
        body: '{"KEYLIST":[{"CODESET":11,"CODE":1,"ACTION":"KEYPRESS"}]}',
        headers: [
          HttpHeaderDto(name: 'content-type', value: 'application/json'),
          HttpHeaderDto(name: 'AUTH', value: 'Z2x6aHh4eQ=='),
        ],
      ),
    );
    await client.send(
      '10.0.0.9',
      7345,
      const HttpRequestDto(
        method: 'GET',
        path: '/state/device/power_mode',
        body: '',
        headers: [HttpHeaderDto(name: 'AUTH', value: 'Z2x6aHh4eQ==')],
      ),
    );
    await client.send(
      '10.0.0.9',
      7345,
      const HttpRequestDto(
        method: 'POST',
        path: '/pairing/start',
        body: '{"DEVICE_ID":"lb"}',
        headers: [HttpHeaderDto(name: 'X-Client', value: 'lb')],
      ),
    );

    expect(seen[0].method, 'PUT');
    expect(seen[0].headers['auth'], 'Z2x6aHh4eQ==');
    expect(
      seen[0].headers['content-type'],
      'application/json',
      reason: 'the declared Content-Type wins over the inferred one',
    );
    expect(seen[1].method, 'GET');
    expect(seen[1].headers['auth'], 'Z2x6aHh4eQ==');
    // No declared Content-Type: the body's own kind is still inferred, and
    // the other header rides beside it.
    expect(seen[2].headers['content-type'], 'application/json; charset=utf-8');
    expect(seen[2].headers['x-client'], 'lb');

    expect(
      headersFor(
        const HttpRequestDto(method: 'POST', path: '/keypress/Home', body: ''),
      ),
      isNull,
      reason: 'an ECP keypress still adds no header of its own',
    );
  });

  test(
    'a PUT carries its body — the write method the climate specs declare',
    () async {
      // Rust's SENDABLE_METHODS admits PUT, so a spec's PUT command renders as
      // a live control; this transport must carry it rather than throw.
      late http.Request seen;
      final client = HttpControlClient(
        httpClient: MockClient((request) async {
          seen = request;
          return http.Response('', 200);
        }),
      );

      await client.send(
        '10.0.0.9',
        8080,
        const HttpRequestDto(
          method: 'PUT',
          path: '/api/user/lights/2/state',
          body: '{"on":true}',
        ),
      );

      expect(seen.method, 'PUT');
      expect(
        seen.url.toString(),
        'http://10.0.0.9:8080/api/user/lights/2/state',
      );
      expect(seen.body, '{"on":true}');
    },
  );

  test(
    'a declared https scheme opens TLS and excuses the device certificate',
    () async {
      // A real loopback TLS server wearing the self-signed fixture cert (from
      // test/fixtures/hue_tls) — MockClient can never exercise the trust
      // decision, and the trust decision is the whole feature: an Envoy or a
      // SmartCast presents a certificate no platform store will ever accept.
      final context = SecurityContext()
        ..useCertificateChain('test/fixtures/hue_tls/bridge.crt')
        ..usePrivateKey('test/fixtures/hue_tls/bridge.key');
      final server = await HttpServer.bindSecure(
        InternetAddress.loopbackIPv4,
        0,
        context,
      );
      addTearDown(server.close);
      server.listen((request) {
        request.response.write('{"production": 42}');
        request.response.close();
      });

      final client = HttpControlClient();
      final body = await client.send(
        '127.0.0.1',
        server.port,
        const HttpRequestDto(
          method: 'GET',
          path: '/production.json',
          body: '',
          scheme: 'https',
        ),
      );

      expect(body, '{"production": 42}');
    },
  );

  test('an absent scheme stays plain http on the injected client', () async {
    // The https client is a separate lazy construction: a spec that says
    // nothing must keep riding the plain client, scheme http, as ever.
    late http.Request seen;
    final client = HttpControlClient(
      httpClient: MockClient((request) async {
        seen = request;
        return http.Response('', 200);
      }),
    );

    await client.send('10.0.0.9', 8060, press);

    expect(seen.url.scheme, 'http');
  });

  test(
    'a method this transport does not speak is refused before the wire',
    () async {
      var reached = false;
      final client = HttpControlClient(
        httpClient: MockClient((request) async {
          reached = true;
          return http.Response('', 200);
        }),
      );

      await expectLater(
        client.send(
          '10.0.0.9',
          8060,
          const HttpRequestDto(method: 'BREW', path: '/coffee', body: ''),
        ),
        throwsA(isA<HttpControlException>()),
      );
      expect(reached, isFalse, reason: 'nothing must reach the device');
    },
  );

  group('a response body is text, and the device rarely says in which code', () {
    // R-040. package:http reads a body whose Content-Type states no charset as
    // Latin-1 (what RFC 2616 required and RFC 7231 withdrew), and almost no LAN
    // device states one — so every accented name in a Roku app list, a UPnP
    // description or a state reply arrived as mojibake.
    const query = HttpRequestDto(method: 'GET', path: '/query/apps', body: '');

    Future<String> bodyFrom(List<int> bytes, {Map<String, String>? headers}) {
      final client = HttpControlClient(
        httpClient: MockClient(
          (request) async =>
              http.Response.bytes(bytes, 200, headers: headers ?? const {}),
        ),
      );
      return client.send('10.0.0.9', 8060, query);
    }

    test('UTF-8 with no declared charset reads as UTF-8', () async {
      expect(
        await bodyFrom(
          utf8.encode('<app>Pokémon Trading Card Game</app>'),
          headers: const {'content-type': 'text/xml'},
        ),
        '<app>Pokémon Trading Card Game</app>',
        reason: 'this used to come back as PokÃ©mon',
      );
      // And with no Content-Type at all, which is what an ECP keypress ack and
      // a good many state endpoints answer with.
      expect(await bodyFrom(utf8.encode('Küche – 21 °C')), 'Küche – 21 °C');
    });

    test('a charset the device DID state is taken at its word', () async {
      expect(
        await bodyFrom(
          latin1.encode('Küche'),
          headers: const {'content-type': 'text/plain; charset=iso-8859-1'},
        ),
        'Küche',
        reason: 'the device said which code, so the bytes are not guessed at',
      );
    });

    test('bytes that are not UTF-8 still come through as text', () async {
      // 0xFC alone is not a UTF-8 sequence. Latin-1 cannot fail, so the
      // fallback always produces something rather than throwing on the way to
      // the screen.
      expect(await bodyFrom(const [0x4B, 0xFC, 0x63, 0x68, 0x65]), 'Küche');
    });
  });

  test('a reply past the cap is refused rather than buffered', () async {
    // R-041. The device chooses the length, so an uncapped read is an
    // allocation something on the LAN sizes. The cap sits on the stream read
    // because a buffered body has already been allocated by the time anything
    // could measure it.
    final client = HttpControlClient(
      httpClient: MockClient(
        (request) async => http.Response.bytes(
          Uint8List(HttpControlClient.maxResponseBytes + 1),
          200,
        ),
      ),
    );

    await expectLater(
      client.send(
        '10.0.0.9',
        8060,
        const HttpRequestDto(method: 'GET', path: '/query/apps', body: ''),
      ),
      throwsA(
        isA<HttpControlException>().having(
          (e) => e.message,
          'message',
          contains('refusing to buffer further'),
        ),
      ),
    );
  });

  test('the deadline aborts the exchange, not just the waiting', () {
    // R-041. `Future.timeout` alone only stops listening: the request stays in
    // flight holding a socket (and a TLS session) until the device or the OS
    // gives up, and a control screen retried against a sleeping TV stacks one
    // of those per press.
    fakeAsync((async) {
      var aborted = false;
      final client = HttpControlClient(
        httpClient: MockClient.streaming((request, body) async {
          if (request case http.Abortable(:final abortTrigger?)) {
            unawaited(abortTrigger.then((_) => aborted = true));
          }
          // Connected, then silent — a Roku that went to sleep mid-exchange.
          return http.StreamedResponse(
            StreamController<List<int>>().stream,
            200,
          );
        }),
      );
      Object? thrown;
      unawaited(
        client
            .send(
              '10.0.0.9',
              8060,
              const HttpRequestDto(
                method: 'POST',
                path: '/keypress/Home',
                body: '',
              ),
            )
            .then<void>((_) {}, onError: (Object e) => thrown = e),
      );

      async.elapse(HttpControlClient.timeout + const Duration(seconds: 1));
      expect(thrown, isA<ControlTimeoutException>());
      expect(aborted, isTrue, reason: 'the request must actually end');
    });
  });

  group('a refused handshake says WHICH refusal it was', () {
    // R-042: nothing drove this client through a HandshakeException at all,
    // so the catch written for it — the one that makes any certificate
    // message reachable — was unpinned. R-038: every refusal then reported as
    // "presenting a different certificate than before", which is one of three
    // answers and the wrong one twice.
    const secure = HttpRequestDto(
      method: 'GET',
      path: '/production.json',
      body: '',
      scheme: 'https',
    );

    Future<Object?> sendThrough(TlsTrust? trust) async {
      final client = HttpControlClient(
        trust: trust,
        // HandshakeException extends TlsException, which IOClient wraps into
        // nothing: it escapes `on ClientException` untouched, which is how a
        // raw platform exception used to reach the UI.
        httpsClient: MockClient(
          (request) async =>
              throw const HandshakeException('CERTIFICATE_VERIFY_FAILED'),
        ),
      );
      if (trust != null) {
        await client.useTlsPolicy(
          host: '10.0.0.9',
          identity: 'envoy@10.0.0.9',
          policy: TlsPolicy.trustOnFirstUse,
        );
      }
      try {
        await client.send('10.0.0.9', 443, secure);
        return null;
      } catch (e) {
        return e;
      }
    }

    test('a handshake nobody refused on purpose is unreachable', () async {
      // No policy said no, so this is a device that is off, behind a proxy, or
      // simply not speaking TLS — and the honest answer is the network one.
      expect(await sendThrough(null), isA<ControlUnreachableException>());
    });

    test('a changed certificate names the only recovery there is', () async {
      final trust = TlsTrust(CertificatePinStore(InMemorySettingsStore()));
      // The certificate is evaluated INSIDE the request, where the real
      // badCertificate callback runs: send() clears the host's recorded
      // refusal before it opens, so only what THIS handshake refuses is
      // what the exception reports. Evaluating before send() modelled
      // nothing the app does, and its record was cleared away.
      late final HttpControlClient client;
      client = HttpControlClient(
        trust: trust,
        httpsClient: MockClient((request) async {
          expect(
            client.debugEvaluateCertificate(_FakeCert('real'), '10.0.0.9', 443),
            isTrue,
          );
          expect(
            client.debugEvaluateCertificate(
              _FakeCert('other'),
              '10.0.0.9',
              443,
            ),
            isFalse,
          );
          throw const HandshakeException('CERTIFICATE_VERIFY_FAILED');
        }),
      );
      await client.useTlsPolicy(
        host: '10.0.0.9',
        identity: 'envoy@10.0.0.9',
        policy: TlsPolicy.trustOnFirstUse,
      );

      final thrown = await client
          .send('10.0.0.9', 443, secure)
          .then<Object?>((_) => null, onError: (Object e) => e);
      expect(thrown, isA<ControlCertificateChangedException>());
      expect(
        (thrown! as UserFacingException).message,
        contains('different security certificate'),
      );
    });

    test('a standard-policy refusal does not claim anything changed', () async {
      // Nothing was ever pinned, so "remove it from Saved devices and add it
      // again" is advice for a different failure — and would not help.
      final trust = TlsTrust(CertificatePinStore(InMemorySettingsStore()));
      // The certificate is evaluated INSIDE the request, where the real
      // badCertificate callback runs: send() clears the host's recorded
      // refusal before it opens, so only what THIS handshake refuses is
      // what the exception reports. Evaluating before send() modelled
      // nothing the app does, and its record was cleared away.
      late final HttpControlClient client;
      client = HttpControlClient(
        trust: trust,
        httpsClient: MockClient((request) async {
          expect(
            client.debugEvaluateCertificate(
              _FakeCert('unchained'),
              '10.0.0.9',
              443,
            ),
            isFalse,
          );
          throw const HandshakeException('CERTIFICATE_VERIFY_FAILED');
        }),
      );
      await client.useTlsPolicy(
        host: '10.0.0.9',
        identity: 'envoy@10.0.0.9',
        policy: TlsPolicy.standard,
      );

      final thrown = await client
          .send('10.0.0.9', 443, secure)
          .then<Object?>((_) => null, onError: (Object e) => e);
      expect(thrown, isA<ControlCertificateUntrustedException>());
      expect(
        (thrown! as UserFacingException).message,
        allOf(
          contains('could not be verified'),
          contains('Nothing about it has changed'),
        ),
      );
    });

    test('an unreadable pin store blames the store, not the device', () async {
      // The certificate may be perfectly fine; what failed is reading the pin
      // to compare it against, and re-pairing would throw the good pin away.
      final trust = TlsTrust(CertificatePinStore(_FailingStore()));
      // The certificate is evaluated INSIDE the request, where the real
      // badCertificate callback runs: send() clears the host's recorded
      // refusal before it opens, so only what THIS handshake refuses is
      // what the exception reports. Evaluating before send() modelled
      // nothing the app does, and its record was cleared away.
      late final HttpControlClient client;
      client = HttpControlClient(
        trust: trust,
        httpsClient: MockClient((request) async {
          expect(
            client.debugEvaluateCertificate(
              _FakeCert('whatever'),
              '10.0.0.9',
              443,
            ),
            isFalse,
          );
          throw const HandshakeException('CERTIFICATE_VERIFY_FAILED');
        }),
      );
      await client.useTlsPolicy(
        host: '10.0.0.9',
        identity: 'envoy@10.0.0.9',
        policy: TlsPolicy.trustOnFirstUse,
      );

      final thrown = await client
          .send('10.0.0.9', 443, secure)
          .then<Object?>((_) => null, onError: (Object e) => e);
      expect(thrown, isA<ControlCertificatePinUnreadableException>());
      expect(
        (thrown! as UserFacingException).message,
        allOf(
          contains('could not be read'),
          contains('nothing wrong with the device'),
        ),
      );
    });
  });
}
