// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// IppStatusClient: the socket half of IPP status — the right request on the
// wire, the reply body back, and every failure as a result.
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/services/ipp_status_client.dart';

void main() {
  late HttpServer server;
  late List<({String path, String? type, List<int> body})> seen;
  var status = HttpStatus.ok;

  setUp(() async {
    seen = [];
    status = HttpStatus.ok;
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      final body = await request.fold<List<int>>([], (a, b) => a..addAll(b));
      seen.add((
        path: request.uri.path,
        type: request.headers.contentType?.mimeType,
        body: body,
      ));
      request.response
        ..statusCode = status
        ..headers.contentType = ContentType('application', 'ipp')
        ..add([0x02, 0x00, 0x00, 0x00, 0, 0, 0, 1, 0x03]);
      await request.response.close();
    });
  });

  tearDown(() => server.close(force: true));

  test('posts application/ipp to the resource and returns the body', () async {
    final result = await const IppStatusClient().fetch(
      host: '127.0.0.1',
      port: server.port,
      resourcePath: 'ipp/print',
      body: Uint8List.fromList([1, 2, 3]),
    );
    expect(result, isA<IppFetchOk>());
    expect((result as IppFetchOk).body.last, 0x03);
    expect(seen.single.path, '/ipp/print');
    expect(seen.single.type, 'application/ipp');
    expect(seen.single.body, [1, 2, 3]);
  });

  test('a printer that insists on TLS says so', () async {
    status = HttpStatus.upgradeRequired;
    final result = await const IppStatusClient().fetch(
      host: '127.0.0.1',
      port: server.port,
      resourcePath: '/ipp/print',
      body: Uint8List(1),
    );
    expect(result, isA<IppFetchFailed>());
    expect((result as IppFetchFailed).secureOnly, isTrue);
  });

  test('an unreachable printer is a result, not an exception', () async {
    final port = server.port;
    await server.close(force: true);
    final result = await const IppStatusClient(timeout: Duration(seconds: 1))
        .fetch(
          host: '127.0.0.1',
          port: port,
          resourcePath: 'ipp/print',
          body: Uint8List(1),
        );
    expect(result, isA<IppFetchFailed>());
  });
}
