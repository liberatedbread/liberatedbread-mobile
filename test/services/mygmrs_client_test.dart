// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:liberated_bread_mobile/models/radio_channel.dart';
import 'package:liberated_bread_mobile/models/suggested_channel.dart';
import 'package:liberated_bread_mobile/services/mygmrs_client.dart';
import 'package:liberated_bread_mobile/services/repeater_source.dart';

const _userAgent = 'LiberatedBreadMobile/test (+https://example.invalid)';

MyGmrsClient _client(MockClient mock) =>
    MyGmrsClient(client: mock, userAgent: _userAgent);

MyGmrsClient _answering(String body, {int status = 200}) => _client(
  MockClient(
    (_) async => http.Response(
      body,
      status,
      headers: {'content-type': 'application/json'},
    ),
  ),
);

void main() {
  late String fixture;

  setUpAll(() async {
    fixture = await File('test/fixtures/radio/mygmrs_ri.json').readAsString();
  });

  test('identifies itself and its attribution', () {
    final client = _answering('{"items": []}');
    expect(client.id, 'mygmrs');
    expect(client.displayName, 'myGMRS');
    expect(client.attribution, contains('myGMRS'));
  });

  test('needs no configuration', () async {
    expect(await _answering('{"items": []}').isConfigured(), isTrue);
  });

  test(
    'asks for the state it was given, as JSON, identifying itself',
    () async {
      late http.Request seen;
      final client = _client(
        MockClient((request) async {
          seen = request;
          return http.Response('{"items": []}', 200);
        }),
      );
      await client.fetchByState('RI');

      expect(seen.url.host, 'api.mygmrs.com');
      expect(seen.url.path, '/repeaters');
      expect(seen.url.queryParameters['state'], 'RI');
      expect(seen.headers['User-Agent'], _userAgent);
      expect(seen.headers['Accept'], contains('json'));
    },
  );

  group('parsing', () {
    test('builds a GMRS repeater pair from an output frequency', () async {
      final listings = await _answering(fixture).fetchByState('RI');
      final first = listings.first;

      expect(first.channel.rxFreqHz, 462625000);
      // The input is fixed at +5 MHz by the channel plan, which is why the
      // feed does not carry one.
      expect(first.channel.txFreqHz, 467625000);
      expect(first.channel.offsetHz, MyGmrsClient.repeaterOffsetHz);
      expect(first.category, SuggestionCategory.gmrs);
      expect(first.callsign, 'kt1est');
      expect(first.location!.lat, closeTo(41.498, 0.001));
    });

    test('parses the frequency exactly', () async {
      // "462.625" through a double is 462624999.99999994. A hertz low here
      // would break de-duplication against the same repeater from elsewhere.
      final listings = await _answering(fixture).fetchByState('RI');
      expect(listings.first.channel.rxFreqHz, 462625000);
    });

    test('says on every listing that the tone is not published', () async {
      // The feed has no tone field at all, and most GMRS repeaters are
      // tone-protected: a channel built from this hears the repeater and
      // never keys it. Saying so is the difference between a working channel
      // and a mystery.
      final listings = await _answering(fixture).fetchByState('RI');
      expect(listings, isNotEmpty);
      for (final listing in listings) {
        expect(listing.channel.txTone, ToneSetting.none);
        expect(listing.details, contains('Tone not published'));
      }
    });

    test('carries the town and the system type into the details', () async {
      final listings = await _answering(fixture).fetchByState('RI');
      expect(listings.first.details, contains('Testville'));
      expect(listings.first.details, contains('Open System'));
    });

    test('flags a repeater that is not online', () async {
      final listings = await _answering(fixture).fetchByState('RI');
      final offline = listings.firstWhere(
        (l) => l.channel.name == 'Far Ridge 6500',
      );
      expect(offline.details, contains('Offline'));
    });

    test('drops listings that cannot be placed or tuned', () async {
      // Four items in the fixture; two are unusable. A listing with no
      // position cannot be distance-ranked, and offering it unranked would
      // put a repeater 400 km away at the top of the list.
      final listings = await _answering(fixture).fetchByState('RI');
      expect(listings, hasLength(2));
      expect([
        for (final l in listings) l.channel.name,
      ], isNot(contains('No Position')));
      expect([
        for (final l in listings) l.channel.name,
      ], isNot(contains('No Frequency')));
    });

    test('is narrowband, as the GMRS rules require', () async {
      final listings = await _answering(fixture).fetchByState('RI');
      for (final listing in listings) {
        expect(listing.channel.mode, ChannelMode.nfm);
      }
    });

    test('an empty state is an empty list, not a failure', () async {
      final listings = await _answering(
        '{"success": true, "items": []}',
      ).fetchByState('WY');
      expect(listings, isEmpty);
    });
  });

  group('failures', () {
    Future<SourceFailure> failureFrom(Future<void> Function() run) async {
      try {
        await run();
      } on RepeaterSourceException catch (error) {
        return error.failure;
      }
      fail('expected a RepeaterSourceException');
    }

    test('a rate limit says so, and says to wait', () async {
      final failure = await failureFrom(
        () => _answering('slow down', status: 429).fetchByState('RI'),
      );
      expect(failure.kind, SourceFailureKind.rateLimited);
      expect(failure.message.toLowerCase(), contains('slow down'));
      expect(failure.isActionable, isFalse);
    });

    test('a server error is a network failure', () async {
      final failure = await failureFrom(
        () => _answering('boom', status: 503).fetchByState('RI'),
      );
      expect(failure.kind, SourceFailureKind.network);
      expect(failure.message, contains('503'));
    });

    test('an unreachable service is a network failure', () async {
      final client = _client(
        MockClient(
          (_) async => throw const SocketException('no route to host'),
        ),
      );
      final failure = await failureFrom(() => client.fetchByState('RI'));
      expect(failure.kind, SourceFailureKind.network);
    });

    test('a timeout is a network failure that mentions the cache', () async {
      final client = MyGmrsClient(
        client: MockClient((_) => Completer<http.Response>().future),
        userAgent: _userAgent,
        timeout: const Duration(milliseconds: 20),
      );
      final failure = await failureFrom(() => client.fetchByState('RI'));
      expect(failure.kind, SourceFailureKind.network);
      expect(failure.message.toLowerCase(), contains('cached'));
    });

    test('a non-JSON body is a parse failure', () async {
      final failure = await failureFrom(
        () => _answering('<html>maintenance</html>').fetchByState('RI'),
      );
      expect(failure.kind, SourceFailureKind.parse);
    });

    test('JSON of the wrong shape is a parse failure', () async {
      for (final body in ['[1,2,3]', '{"success": true}', '{"items": 7}']) {
        final failure = await failureFrom(
          () => _answering(body).fetchByState('RI'),
        );
        expect(failure.kind, SourceFailureKind.parse, reason: body);
      }
    });

    test('a failure carries the source it came from', () async {
      final failure = await failureFrom(
        () => _answering('nope', status: 500).fetchByState('RI'),
      );
      expect(failure.sourceId, 'mygmrs');
      expect(failure.displayName, 'myGMRS');
    });
  });
}
