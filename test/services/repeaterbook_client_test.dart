// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:liberated_bread_mobile/models/radio_channel.dart';
import 'package:liberated_bread_mobile/models/suggested_channel.dart';
import 'package:liberated_bread_mobile/services/repeater_source.dart';
import 'package:liberated_bread_mobile/services/repeaterbook_client.dart';

const _userAgent = 'LiberatedBreadMobile/test (+https://example.invalid)';

/// The error bodies RepeaterBook actually answers with, confirmed against the
/// live service on 2026-08-28. See test/fixtures/radio/README.md.
const _authMissing =
    '{"ok":false,"error_code":"auth_missing","message":"Authorization required."}';
const _badHeaderFormat =
    '{"ok":false,"error_code":"auth_invalid","message":"Invalid token header format."}';
const _badUserTokenFormat =
    '{"ok":false,"error_code":"auth_invalid","message":"Invalid user app token format."}';
const _rejected =
    '{"ok":false,"error_code":"auth_unknown","message":"Unknown token."}';

RepeaterBookClient _client(
  MockClient mock, {
  String? token = 'rbuapp_testtoken',
  String? stateId = '09',
  Duration timeout = const Duration(seconds: 5),
}) => RepeaterBookClient(
  client: mock,
  userAgent: _userAgent,
  readToken: () async => token,
  resolveStateId: (_) async => stateId,
  timeout: timeout,
);

RepeaterBookClient _answering(
  String body, {
  int status = 200,
  String? token = 'rbuapp_testtoken',
}) => _client(
  MockClient(
    (_) async => http.Response(
      body,
      status,
      headers: {'content-type': 'application/json'},
    ),
  ),
  token: token,
);

Future<SourceFailure> _failureFrom(Future<void> Function() run) async {
  try {
    await run();
  } on RepeaterSourceException catch (error) {
    return error.failure;
  }
  fail('expected a RepeaterSourceException');
}

void main() {
  late String fixture;

  setUpAll(() async {
    fixture = await File(
      'test/fixtures/radio/repeaterbook_ct.json',
    ).readAsString();
  });

  test('identifies itself and carries the required attribution', () {
    final client = _answering('{"results": []}');
    expect(client.id, 'repeaterbook');
    expect(client.displayName, 'RepeaterBook');
    // Their terms require this line wherever the data appears. It is not a
    // courtesy, so it is not optional.
    expect(client.attribution, 'Data courtesy of RepeaterBook.com');
  });

  group('configuration', () {
    test('is unconfigured until a token is stored', () async {
      expect(await _answering('{}', token: null).isConfigured(), isFalse);
      expect(await _answering('{}', token: '   ').isConfigured(), isFalse);
      expect(await _answering('{}').isConfigured(), isTrue);
    });

    test('without a token it explains rather than failing obscurely', () async {
      final failure = await _failureFrom(
        () => _answering(fixture, token: null).fetchByState('CT'),
      );
      expect(failure.kind, SourceFailureKind.auth);
      expect(failure.isActionable, isTrue);
      expect(failure.message, contains('token'));
      expect(failure.message, contains('settings'));
    });
  });

  group('the request', () {
    test(
      'sends the token header, the user agent and the FIPS state id',
      () async {
        late http.Request seen;
        final client = _client(
          MockClient((request) async {
            seen = request;
            return http.Response('{"results": []}', 200);
          }),
          stateId: '09',
        );
        await client.fetchByState('CT');

        expect(seen.url.host, 'www.repeaterbook.com');
        expect(seen.url.path, '/api/export.php');
        // The export API keys on the FIPS number, not the postal code -- which
        // is why the bundled state data carries both.
        expect(seen.url.queryParameters['state_id'], '09');
        expect(seen.headers['X-RB-App-Token'], 'rbuapp_testtoken');
        expect(seen.headers['User-Agent'], _userAgent);
      },
    );

    test('a state with no known FIPS code fails clearly', () async {
      final failure = await _failureFrom(
        () => _client(
          MockClient((_) async => http.Response('{}', 200)),
          stateId: null,
        ).fetchByState('ZZ'),
      );
      expect(failure.kind, SourceFailureKind.parse);
      expect(failure.message, contains('ZZ'));
    });
  });

  group('parsing', () {
    test('builds a repeater from output, input and access tone', () async {
      final listings = await _answering(fixture).fetchByState('CT');
      final first = listings.first;

      expect(first.channel.rxFreqHz, 146940000);
      expect(first.channel.txFreqHz, 146340000);
      expect(first.channel.offsetHz, -600000);
      expect(first.channel.txTone, const ToneSetting.ctcss(1000));
      expect(first.callsign, 'WT1EST');
      expect(first.category, SuggestionCategory.repeater);
      expect(first.location!.lat, closeTo(41.7291, 0.0001));
    });

    test('does not turn on receive tone squelch', () async {
      // The fixture's first row has TSQ set. Enabling it would silence every
      // simplex station on the frequency -- a surprise nobody asked for.
      final listings = await _answering(fixture).fetchByState('CT');
      expect(listings.first.channel.rxTone, ToneSetting.none);
    });

    test('reads a DCS access code', () async {
      final listings = await _answering(fixture).fetchByState('CT');
      final dcs = listings.firstWhere((l) => l.callsign == 'WT2EST');
      expect(dcs.channel.txTone, const ToneSetting.dcs(23));
    });

    test('treats CSQ and blank as no tone', () async {
      final listings = await _answering(fixture).fetchByState('CT');
      final csq = listings.firstWhere((l) => l.callsign == 'WT3EST');
      expect(csq.channel.txTone, ToneSetting.none);
    });

    test('an empty input frequency means simplex', () async {
      final listings = await _answering(fixture).fetchByState('CT');
      final simplex = listings.firstWhere((l) => l.callsign == 'WT3EST');
      expect(simplex.channel.isSimplex, isTrue);
    });

    test('drops a listing with no coordinates', () async {
      final listings = await _answering(fixture).fetchByState('CT');
      expect([for (final l in listings) l.callsign], isNot(contains('WT4EST')));
      expect(listings, hasLength(3));
    });

    test('carries landmark, county, use and status into the details', () async {
      final listings = await _answering(fixture).fetchByState('CT');
      final closed = listings.firstWhere((l) => l.callsign == 'WT2EST');
      expect(closed.details, contains('Sea View'));
      expect(closed.details, contains('New Haven County'));
      expect(closed.details, contains('CLOSED'));
      expect(closed.details, contains('Off-air'));
      // An ordinary open, on-air repeater says neither -- the details are for
      // things worth reading, not for restating the default.
      expect(listings.first.details, isNot(contains('Use:')));
      expect(listings.first.details, isNot(contains('Status:')));
    });

    test('finds the rows whatever wrapper key they arrive under', () async {
      // Their export has been documented under more than one key, and a
      // source that breaks because a directory renamed a wrapper is worse
      // than one that looks in a few places.
      const row =
          '{"Frequency": "146.94", "Lat": "41.7", "Long": "-72.7", '
          '"Callsign": "WT9EST"}';
      for (final body in [
        '{"results": [$row]}',
        '{"data": [$row]}',
        '{"items": [$row]}',
        '{"repeaters": [$row]}',
        '[$row]',
      ]) {
        final listings = await _answering(body).fetchByState('CT');
        expect(listings, hasLength(1), reason: body);
      }
    });

    test('reads column names regardless of case and spacing', () async {
      const row =
          '{"frequency": "146.94", "input_freq": "146.34", '
          '"latitude": 41.7, "longitude": -72.7, "call": "WT8EST"}';
      final listings = await _answering(
        '{"results": [$row]}',
      ).fetchByState('CT');
      expect(listings.single.channel.txFreqHz, 146340000);
      expect(listings.single.callsign, 'WT8EST');
    });
  });

  group('token verification', () {
    Future<TokenCheck> check(String body, int status, String token) => _client(
      MockClient((_) async => http.Response(body, status)),
    ).verifyToken(token);

    test('an empty token is missing, without a request', () async {
      var called = false;
      final client = _client(
        MockClient((_) async {
          called = true;
          return http.Response('{}', 200);
        }),
      );
      expect(await client.verifyToken('   '), TokenCheck.missing);
      expect(called, isFalse);
    });

    test('a working token is valid', () async {
      expect(
        await check('{"results": []}', 200, 'rbuapp_good'),
        TokenCheck.valid,
      );
    });

    test('tells "not a token" apart from "not your token"', () async {
      // RepeaterBook distinguishes these itself, and they are very different
      // problems to be stuck on: one is a bad paste, the other an expired
      // credential.
      expect(
        await check(_badHeaderFormat, 401, 'garbage'),
        TokenCheck.malformed,
      );
      expect(
        await check(_badUserTokenFormat, 401, 'rbuapp_short'),
        TokenCheck.malformed,
      );
      expect(
        await check(_rejected, 401, 'rbuapp_unknown'),
        TokenCheck.rejected,
      );
      expect(await check(_authMissing, 401, 'anything'), TokenCheck.missing);
    });

    test('a rate limit is not a verdict on the token', () async {
      expect(
        await check('slow down', 429, 'rbuapp_good'),
        TokenCheck.rateLimited,
      );
    });

    test('an unreachable service is not a verdict either', () async {
      final client = _client(
        MockClient((_) async => throw const SocketException('offline')),
      );
      expect(await client.verifyToken('rbuapp_good'), TokenCheck.unreachable);

      final slow = _client(
        MockClient((_) => Completer<http.Response>().future),
        timeout: const Duration(milliseconds: 20),
      );
      expect(await slow.verifyToken('rbuapp_good'), TokenCheck.unreachable);
    });

    test('an unparseable refusal is still a refusal', () async {
      expect(
        await check('<html>nope</html>', 403, 'rbuapp_good'),
        TokenCheck.rejected,
      );
    });

    test('verification asks for the smallest state it can', () async {
      late Uri seen;
      final client = _client(
        MockClient((request) async {
          seen = request.url;
          return http.Response('{"results": []}', 200);
        }),
      );
      await client.verifyToken('rbuapp_good');
      // Rhode Island: the smallest answer that still exercises the endpoint.
      expect(seen.queryParameters['state_id'], '44');
    });
  });

  group('fetch failures', () {
    test('a refused token points at the settings screen', () async {
      final failure = await _failureFrom(
        () => _answering(_rejected, status: 401).fetchByState('CT'),
      );
      expect(failure.kind, SourceFailureKind.auth);
      expect(failure.isActionable, isTrue);
      expect(failure.message.toLowerCase(), contains('settings'));
    });

    test(
      'a malformed stored token says to check it, not to renew it',
      () async {
        final failure = await _failureFrom(
          () => _answering(_badUserTokenFormat, status: 401).fetchByState('CT'),
        );
        expect(failure.message.toLowerCase(), contains('did not recognise'));
      },
    );

    test('a rate limit says cached results are being shown', () async {
      final failure = await _failureFrom(
        () => _answering('slow down', status: 429).fetchByState('CT'),
      );
      expect(failure.kind, SourceFailureKind.rateLimited);
      expect(failure.message.toLowerCase(), contains('cached'));
    });

    test(
      'a server error, a dead socket and a timeout are network failures',
      () async {
        expect(
          (await _failureFrom(
            () => _answering('boom', status: 500).fetchByState('CT'),
          )).kind,
          SourceFailureKind.network,
        );

        final dead = _client(
          MockClient((_) async => throw const SocketException('offline')),
        );
        expect(
          (await _failureFrom(() => dead.fetchByState('CT'))).kind,
          SourceFailureKind.network,
        );

        final slow = _client(
          MockClient((_) => Completer<http.Response>().future),
          timeout: const Duration(milliseconds: 20),
        );
        expect(
          (await _failureFrom(() => slow.fetchByState('CT'))).kind,
          SourceFailureKind.network,
        );
      },
    );

    test('an unreadable body is a parse failure', () async {
      expect(
        (await _failureFrom(
          () => _answering('<html>down</html>').fetchByState('CT'),
        )).kind,
        SourceFailureKind.parse,
      );
      expect(
        (await _failureFrom(
          () => _answering('{"ok":true}').fetchByState('CT'),
        )).kind,
        SourceFailureKind.parse,
      );
    });
  });
}
