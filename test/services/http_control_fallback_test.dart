// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// The second spelling of a path, and the narrow door it comes through.
//
// A ratgdo board addresses its cover one way up to ESPHome 2025.12 and
// another from 2026.7, so its spec states both and Rust renders both. The
// rule the schema writes in capitals is that the SECOND is only ever tried
// when the device gave an unambiguous "there is no such thing here" — a 404.
// Not a timeout, not a refusal, not a 5xx: a garage door that opens twice
// because the first send was merely slow is a worse failure than the 404 this
// exists to survive.

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:liberated_bread_mobile/services/http_control_service.dart';
import 'package:liberated_bread_mobile/services/spec_codec.dart';

void main() {
  // What Rust renders for ratgdo's door_open: the name-addressed path current
  // firmware serves, and the object_id one older boards do.
  const open = HttpRequestDto(
    method: 'POST',
    path: '/cover/Door/open',
    body: '',
    pathFallback: '/cover/door/open',
  );

  test('a 404 on the primary path sends the declared fallback', () async {
    final sent = <String>[];
    final client = HttpControlClient(
      httpClient: MockClient((request) async {
        sent.add(request.url.path);
        return request.url.path == '/cover/door/open'
            ? http.Response('', 200)
            : http.Response('', 404);
      }),
    );

    await client.send('10.0.0.9', 80, open);

    expect(sent, ['/cover/Door/open', '/cover/door/open']);
  });

  test('a 200 on the primary path never sends the fallback', () async {
    final sent = <String>[];
    final client = HttpControlClient(
      httpClient: MockClient((request) async {
        sent.add(request.url.path);
        return http.Response('', 200);
      }),
    );

    await client.send('10.0.0.9', 80, open);

    expect(sent, ['/cover/Door/open']);
  });

  test('a timeout does not send the command a second time', () async {
    // The failure this rule exists for. The device may well have received and
    // acted on the first send; the app just did not hear back in time.
    final sent = <String>[];
    final client = HttpControlClient(
      httpClient: MockClient((request) async {
        sent.add(request.url.path);
        throw TimeoutException('slow');
      }),
    );

    await expectLater(
      client.send('10.0.0.9', 80, open),
      throwsA(isA<ControlTimeoutException>()),
    );
    expect(sent, ['/cover/Door/open']);
  });

  test('a refusal and a server error keep their own answers', () async {
    for (final status in [401, 403, 500, 503]) {
      final sent = <String>[];
      final client = HttpControlClient(
        httpClient: MockClient((request) async {
          sent.add(request.url.path);
          return http.Response('', status);
        }),
      );

      await expectLater(
        client.send('10.0.0.9', 80, open),
        throwsA(
          status == 500 || status == 503
              ? isA<HttpControlException>()
              : isA<ControlRefusedException>(),
        ),
        reason: 'HTTP $status must not be read as "no such path"',
      );
      expect(sent, ['/cover/Door/open'], reason: 'on HTTP $status');
    }
  });

  test('a 404 with no declared fallback fails, as it always did', () async {
    final client = HttpControlClient(
      httpClient: MockClient((_) async => http.Response('', 404)),
    );

    await expectLater(
      client.send(
        '10.0.0.9',
        8060,
        const HttpRequestDto(method: 'POST', path: '/keypress/Home', body: ''),
      ),
      throwsA(
        isA<HttpControlException>().having(
          (e) => e.message,
          'message',
          contains('404'),
        ),
      ),
    );
  });

  test('both spellings 404: the failure names the primary', () async {
    final sent = <String>[];
    final client = HttpControlClient(
      httpClient: MockClient((request) async {
        sent.add(request.url.path);
        return http.Response('', 404);
      }),
    );

    await expectLater(
      client.send('10.0.0.9', 80, open),
      throwsA(
        isA<HttpControlException>().having(
          (e) => e.message,
          'message',
          allOf(contains('/cover/Door/open'), contains('/cover/door/open')),
        ),
      ),
    );
    expect(sent, ['/cover/Door/open', '/cover/door/open']);
  });

  test('the fallback read carries the body back to the caller', () async {
    // The state half: a cover's reading is a GET of its path, and an older
    // board serves it under the legacy spelling. The retry has to hand the
    // reply back, not just succeed.
    final client = HttpControlClient(
      httpClient: MockClient((request) async {
        return request.url.path == '/cover/door'
            ? http.Response('{"state":"OPEN"}', 200)
            : http.Response('', 404);
      }),
    );

    final body = await client.send(
      '10.0.0.9',
      80,
      const HttpRequestDto(
        method: 'GET',
        path: '/cover/Door',
        body: '',
        pathFallback: '/cover/door',
      ),
    );

    expect(body, '{"state":"OPEN"}');
  });
}
