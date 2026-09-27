// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:liberated_bread_mobile/services/repeater_source.dart';
import 'package:liberated_bread_mobile/services/repeaterbook_client.dart';

// A failed TLS handshake is a HandshakeException: an IOException, but not a
// SocketException, and package:http's IOClient does not wrap it. Both of
// RepeaterBook's network paths used to catch SocketException alone, so a
// captive portal or a wrong device clock escaped as a raw exception -- out
// of the token check, and out of the whole suggestion search.
RepeaterBookClient _handshakeFailing() => RepeaterBookClient(
  client: MockClient(
    (_) async => throw const HandshakeException('CERTIFICATE_VERIFY_FAILED'),
  ),
  userAgent: 'LiberatedBreadMobile/test (+https://example.invalid)',
  readToken: () async => 'rbuapp_testtoken',
  resolveStateId: (_) async => '09',
);

void main() {
  test('a failed handshake during the token check is unreachable', () async {
    expect(
      await _handshakeFailing().verifyToken('rbuapp_good'),
      TokenCheck.unreachable,
    );
  });

  test('a failed handshake during a fetch is a network failure', () async {
    try {
      await _handshakeFailing().fetchByState('CT');
      fail('expected a RepeaterSourceException');
    } on RepeaterSourceException catch (error) {
      expect(error.failure.kind, SourceFailureKind.network);
      expect(error.failure.message, contains('secure connection failed'));
    }
  });
}
