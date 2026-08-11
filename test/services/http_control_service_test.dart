// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// The plain-HTTP control transport: build the URL from what discovery knows,
// send the rendered method/path, and turn the two failure shapes a device
// answers with into the right exceptions — 403 is a device-side setting, not
// a network fault.

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:liberated_bread_mobile/core/error_text.dart';
import 'package:liberated_bread_mobile/services/http_control_service.dart';
import 'package:liberated_bread_mobile/services/spec_codec.dart';

void main() {
  const press =
      HttpRequestDto(method: 'POST', path: '/keypress/Home', body: '');

  test('a POST goes to the discovered host and port with an empty body',
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
  });

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
            method: 'POST', path: '/input?acceleration.x=0.0', body: ''));

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
        const HttpRequestDto(
            method: 'POST', path: '/keypress/Lit_%20', body: ''));

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
        const HttpRequestDto(
            method: 'GET', path: '/query/device-info', body: ''));

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
    expect(const ControlRefusedException().message,
        contains('control by mobile apps'));
  });

  test('any other non-2xx is a transport failure that names the request',
      () async {
    final client = HttpControlClient(
      httpClient: MockClient((request) async => http.Response('gone', 503)),
    );

    await expectLater(
      client.send('10.0.0.9', 8060, press),
      throwsA(isA<HttpControlException>().having(
          (e) => e.message, 'message', contains('POST /keypress/Home'))),
    );
  });

  test('a method this transport does not speak is refused before the wire',
      () async {
    var reached = false;
    final client = HttpControlClient(
      httpClient: MockClient((request) async {
        reached = true;
        return http.Response('', 200);
      }),
    );

    await expectLater(
      client.send('10.0.0.9', 8060,
          const HttpRequestDto(method: 'BREW', path: '/coffee', body: '')),
      throwsA(isA<HttpControlException>()),
    );
    expect(reached, isFalse, reason: 'nothing must reach the device');
  });
}
