// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/core/error_text.dart';
import 'package:liberated_bread_mobile/core/geo.dart';
import 'package:liberated_bread_mobile/models/radio_channel.dart';
import 'package:liberated_bread_mobile/models/suggested_channel.dart';
import 'package:liberated_bread_mobile/services/repeater_source.dart';

void main() {
  group('RepeaterListing', () {
    const listing = RepeaterListing(
      channel: RadioChannel(
        name: 'WT1EST',
        rxFreqHz: 146940000,
        txFreqHz: 146340000,
        txTone: ToneSetting.ctcss(1000),
      ),
      category: SuggestionCategory.repeater,
      location: GeoPoint(41.7291, -72.7083),
      callsign: 'WT1EST',
      details: 'Testington',
    );

    test('round-trips through JSON', () {
      final decoded = RepeaterListing.fromJson(
        jsonDecode(jsonEncode(listing.toJson())) as Map<String, dynamic>,
      );
      expect(decoded!.channel, listing.channel);
      expect(decoded.location, listing.location);
      expect(decoded.category, listing.category);
      expect(decoded.callsign, listing.callsign);
      expect(decoded.details, listing.details);
    });

    test('rejects a record with no usable channel', () {
      expect(RepeaterListing.fromJson(const {}), isNull);
      expect(RepeaterListing.fromJson(const {'channel': 'nope'}), isNull);
      expect(
        RepeaterListing.fromJson(const {
          'channel': {'name': 'x'},
        }),
        isNull,
      );
    });

    test('an unknown category falls back to repeater', () {
      final decoded = RepeaterListing.fromJson(const {
        'channel': {'name': 'x', 'rx': 146940000},
        'category': 'satellite',
      });
      expect(decoded!.category, SuggestionCategory.repeater);
    });

    test('blank optional fields decode as absent, not as empty text', () {
      final decoded = RepeaterListing.fromJson(const {
        'channel': {'name': 'x', 'rx': 146940000},
        'callsign': '',
        'details': '',
      });
      expect(decoded!.callsign, isNull);
      expect(decoded.details, isNull);
    });

    test('an unusable location decodes as no location', () {
      final decoded = RepeaterListing.fromJson(const {
        'channel': {'name': 'x', 'rx': 146940000},
        'location': {'lat': 200.0, 'lon': 0.0},
      });
      expect(decoded!.location, isNull);
    });
  });

  group('SourceFailure', () {
    SourceFailure failure(SourceFailureKind kind) => SourceFailure(
      sourceId: 'test',
      displayName: 'Test',
      kind: kind,
      message: 'something',
    );

    test('marks the kinds the user can act on', () {
      // The distinction drives whether the results screen offers a settings
      // link or just says what happened.
      expect(failure(SourceFailureKind.auth).isActionable, isTrue);
      expect(failure(SourceFailureKind.network).isActionable, isFalse);
      expect(failure(SourceFailureKind.rateLimited).isActionable, isFalse);
      expect(failure(SourceFailureKind.parse).isActionable, isFalse);
    });

    test('reads as the source plus the reason', () {
      expect(failure(SourceFailureKind.network).toString(), 'Test: something');
    });
  });

  test('a source exception carries a message written for a person', () {
    const exception = RepeaterSourceException(
      SourceFailure(
        sourceId: 'test',
        displayName: 'Test',
        kind: SourceFailureKind.auth,
        message: 'Needs a token.',
      ),
    );
    expect(exception, isA<UserFacingException>());
    expect(exception.message, 'Needs a token.');
    expect(
      friendlyErrorText(exception, fallback: 'fallback'),
      'Needs a token.',
    );
  });
}
