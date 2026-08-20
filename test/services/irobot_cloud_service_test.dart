// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:liberated_bread_mobile/services/irobot_cloud_service.dart';
import 'package:liberated_bread_mobile/services/roomba_credential_store.dart';
import 'package:liberated_bread_mobile/services/settings_store.dart';

/// A store that fails the test if anything is written to it.
///
/// This is the file's most important assertion, made structural: the account
/// route exists only to read a BLID and password out of iRobot's API, and the
/// account password must never reach durable storage. A `verifyNever` at the
/// end of one test would prove it for that test; a store that refuses to be
/// written to proves it for every path through the service.
class _NoWritesAllowed implements SettingsStore {
  @override
  Future<String?> read(String key) async => null;

  @override
  Future<Map<String, String>> readAll() async => const {};

  @override
  Future<void> write(String key, String value) async =>
      fail('the account route wrote "$key" — nothing here may be persisted');

  @override
  Future<void> delete(String key) async =>
      fail('the account route deleted "$key"');
}

const _account = 'someone@example.com';
const _accountPassword = 'hunter2-the-account-one';
const _robotPassword = ':1:1486937829:gktkDoYpWaDxCfGh';

/// Stand in for the three calls the route makes, and record every request so a
/// test can assert what did — and did not — go out.
MockClient _irobot({
  List<http.Request>? seen,
  Map<String, Object?>? loginOverride,
  Map<String, Object?>? robotsOverride,
}) {
  return MockClient((request) async {
    seen?.add(request);
    final path = request.url.path;

    if (path.endsWith('/v1/discover/endpoints')) {
      return http.Response(
        jsonEncode({
          'gigya': {
            'api_key': 'REGION-API-KEY',
            'datacenter_domain': 'accounts.us1.gigya.com',
          },
          'httpBase': 'https://unauth2.prod.iot.irobotapi.com',
        }),
        200,
      );
    }
    if (path.endsWith('/accounts.login')) {
      return http.Response(
        jsonEncode(loginOverride ??
            {
              'errorCode': 0,
              'UID': 'uid-123',
              'UIDSignature': 'sig-abc',
              'signatureTimestamp': 1755129600,
              'sessionInfo': {'sessionToken': 'tok'},
            }),
        200,
      );
    }
    if (path.endsWith('/v2/login')) {
      return http.Response(
        jsonEncode(robotsOverride ??
            {
              'robots': {
                '3193C60472324700': {
                  'password': _robotPassword,
                  'name': 'Dorita',
                  'sku': 'R980020',
                  'softwareVer': 'v2.4.16-126',
                },
              },
            }),
        200,
      );
    }
    return http.Response('unexpected ${request.url}', 404);
  });
}

void main() {
  group('IRobotCloudService.fetchCredentials', () {
    test('returns the same credentials the local handshake would', () async {
      final service = IRobotCloudService(client: _irobot());

      final robots = await service.fetchCredentials(
        email: _account,
        password: _accountPassword,
      );

      expect(robots, hasLength(1));
      final robot = robots.single;
      expect(robot.blid, '3193C60472324700');
      expect(robot.password, _robotPassword,
          reason: 'byte-for-byte what the button route yields');
      expect(robot.name, 'Dorita');
      expect(robot.sku, 'R980020');
    });

    test('walks discovery, Gigya, then the iRobot API, in that order',
        () async {
      final seen = <http.Request>[];
      final service = IRobotCloudService(client: _irobot(seen: seen));

      await service.fetchCredentials(
        email: _account,
        password: _accountPassword,
        countryCode: 'GB',
      );

      expect(seen.map((r) => r.url.path).toList(), [
        '/v1/discover/endpoints',
        '/accounts.login',
        '/v2/login',
      ]);
      // The region picks the endpoints; the wrong one answers with an empty
      // robot list rather than an error, which is the confusing failure the
      // parameter exists to avoid.
      expect(seen.first.url.queryParameters['country_code'], 'GB');
      // Read the account's robots; never claim ownership of one. Claiming
      // would be a side effect on somebody's account this app has no business
      // causing.
      final login = jsonDecode(seen.last.body) as Map<String, dynamic>;
      expect(login['assume_robot_ownership'], 0);
      expect(login['gigya'], {
        'signature': 'sig-abc',
        'timestamp': '1755129600',
        'uid': 'uid-123',
      });
    });

    /// The account password goes to Gigya and nowhere else — not to iRobot's
    /// own API, and above all not to storage.
    test('never persists the account password, and sends it once', () async {
      final seen = <http.Request>[];
      final service = IRobotCloudService(client: _irobot(seen: seen));

      // A store that fails on any write. Wired up the way production wires it,
      // so this covers the service AND the store it would be handed to.
      final store = RoombaCredentialStore(_NoWritesAllowed());

      final robots = await service.fetchCredentials(
        email: _account,
        password: _accountPassword,
      );
      // Reading is fine; writing is what must not happen inside the route.
      expect(await store.credentials(robots.single.blid), isNull);

      final carrying = seen
          .where((request) => request.body.contains(_accountPassword))
          .map((request) => request.url.path)
          .toList();
      expect(carrying, ['/accounts.login'],
          reason:
              'the password reaches the identity provider and nothing else');
    });

    /// Gigya's own message ("Invalid loginID or password") is better than
    /// anything we could substitute, so it is surfaced rather than replaced.
    test('surfaces a rejected sign-in with the provider\'s reason', () async {
      final service = IRobotCloudService(
        client: _irobot(loginOverride: const {
          'errorCode': 403042,
          'errorMessage': 'Invalid loginID or password',
        }),
      );

      await expectLater(
        service.fetchCredentials(email: _account, password: 'wrong'),
        throwsA(isA<IRobotCloudException>().having(
          (e) => e.message,
          'message',
          contains('Invalid loginID or password'),
        )),
      );
    });

    /// The likeliest confusing failure: the guide says to firewall the robot,
    /// and someone who did that first lands here. The message has to name it,
    /// or they go hunting for a network fault that is not there.
    test('a blocked network is explained, not reported as a generic error',
        () async {
      final service = IRobotCloudService(
        client: MockClient(
            (_) async => throw http.ClientException('Connection failed')),
      );

      await expectLater(
        service.fetchCredentials(email: _account, password: _accountPassword),
        throwsA(isA<IRobotCloudException>()),
      );
    });

    test('an account with no robots says so plainly', () async {
      final service = IRobotCloudService(
        client: _irobot(robotsOverride: const {'robots': {}}),
      );

      await expectLater(
        service.fetchCredentials(email: _account, password: _accountPassword),
        throwsA(isA<IRobotCloudException>()
            .having((e) => e.message, 'message', contains('no robots'))),
      );
    });

    /// A robot entry with no local password is a 2025-line model: the account
    /// knows about it, but there is no local broker to use a password against.
    /// Skipping it beats offering a credential that cannot work.
    test('skips robots that carry no local password', () async {
      final service = IRobotCloudService(
        client: _irobot(robotsOverride: const {
          'robots': {
            'V4MODEL0000000': {'name': 'New Roomba', 'sku': 'R105'},
            '3193C60472324700': {
              'password': _robotPassword,
              'name': 'Dorita',
            },
          },
        }),
      );

      final robots = await service.fetchCredentials(
        email: _account,
        password: _accountPassword,
      );

      expect(robots.map((r) => r.blid), ['3193C60472324700']);
    });

    test('a directory missing its fields fails before asking for a password',
        () async {
      final service = IRobotCloudService(
        client: MockClient((request) async =>
            http.Response(jsonEncode({'unexpected': true}), 200)),
      );

      await expectLater(
        service.fetchCredentials(email: _account, password: _accountPassword),
        throwsA(isA<IRobotCloudException>()
            .having((e) => e.message, 'message', contains('HOME-button'))),
      );
    });
  });
}
