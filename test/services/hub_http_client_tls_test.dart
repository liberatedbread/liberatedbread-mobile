// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// The trust decision itself, against a real loopback TLS server — because on
// a Hue bridge `badCertificateCallback` fires on every connection (no public
// chain exists) and IS the whole verification, and MockClient can never
// exercise it. Certificates come from test/fixtures/hue_tls/ (see its
// README): `bridge` is the device itself, `impostor` a different key wearing
// the right CN, `wrongcn` not the bridge at all.
//
// The spec's TLS note, executed: CN must equal the bridgeid on first
// contact; the leaf is pinned keyed by bridgeid; a pin mismatch fails and is
// never silently re-pinned. Plain unit suite — loopback, ephemeral ports, no
// network — so it runs everywhere the ordinary tests do.

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/services/hub_credential_store.dart';
import 'package:liberated_bread_mobile/services/hub_http_client.dart';
import 'package:liberated_bread_mobile/services/spec_codec.dart';

import '../fakes/in_memory_settings_store.dart';

const _bridgeId = '001788FFFEAABBCC';
const _fixtures = 'test/fixtures/hue_tls';
const _get = HttpRequestDto(method: 'GET', path: '/api/config', body: '');

/// Serve `{}` over TLS with the named fixture certificate, on an ephemeral
/// loopback port.
Future<HttpServer> _serve(String certName) async {
  final context = SecurityContext()
    ..useCertificateChain('$_fixtures/$certName.crt')
    ..usePrivateKey('$_fixtures/$certName.key');
  final server =
      await HttpServer.bindSecure(InternetAddress.loopbackIPv4, 0, context);
  server.listen((request) {
    request.response
      ..headers.contentType = ContentType.json
      ..write('{}');
    request.response.close();
  });
  return server;
}

/// The sha256 the client should pin: over the certificate's DER bytes,
/// recomputed here from the PEM fixture so the expectation is independent of
/// the code under test.
String _expectedPin(String certName) {
  final pem = File('$_fixtures/$certName.crt').readAsStringSync();
  final base64Body = pem
      .split('\n')
      .where((line) => line.isNotEmpty && !line.startsWith('-----'))
      .join();
  return sha256.convert(base64Decode(base64Body)).toString();
}

void main() {
  late HubCredentialStore store;

  setUp(() {
    store = HubCredentialStore(InMemorySettingsStore());
  });

  HubHttpClient clientFor(HttpServer server) => HubHttpClient(
        credentials: store,
        httpsPort: server.port,
      );

  test('first contact with the right CN succeeds and pins the leaf', () async {
    final server = await _serve('bridge');
    addTearDown(server.close);

    final body = await clientFor(server).send('127.0.0.1', _bridgeId, _get);
    expect(body, '{}');
    expect(await store.certPin(_bridgeId), _expectedPin('bridge'));
    expect(await store.scheme(_bridgeId), 'https');
  });

  test('the pinned bridge keeps answering', () async {
    final server = await _serve('bridge');
    addTearDown(server.close);
    final hub = clientFor(server);

    await hub.send('127.0.0.1', _bridgeId, _get);
    expect(await hub.send('127.0.0.1', _bridgeId, _get), '{}');
  });

  test('an impostor with the right CN is caught by the pin, not re-pinned',
      () async {
    final real = await _serve('bridge');
    addTearDown(real.close);
    await clientFor(real).send('127.0.0.1', _bridgeId, _get);
    final pinned = await store.certPin(_bridgeId);

    // Same CN, different key — exactly what a CN check alone would miss.
    final impostor = await _serve('impostor');
    addTearDown(impostor.close);

    await expectLater(
      clientFor(impostor).send('127.0.0.1', _bridgeId, _get),
      throwsA(isA<HubTlsException>()),
    );
    expect(await store.certPin(_bridgeId), pinned,
        reason: 'a mismatch must never silently replace the pin');
  });

  test('a wrong CN is rejected on first contact, and nothing is pinned',
      () async {
    final server = await _serve('wrongcn');
    addTearDown(server.close);

    await expectLater(
      clientFor(server).send('127.0.0.1', _bridgeId, _get),
      throwsA(isA<HubTlsException>()),
    );
    expect(await store.certPin(_bridgeId), isNull);
  });

  test('an identity probe with no expectation records the CN it saw', () async {
    final server = await _serve('bridge');
    addTearDown(server.close);

    final probe = await clientFor(server).fetchConfig('127.0.0.1');
    expect(probe.body, '{}');
    // The caller cross-checks this against the bridgeid the body claims.
    expect(probe.observedCn, '001788fffeaabbcc');
  });
}
