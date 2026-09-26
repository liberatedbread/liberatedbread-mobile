// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// myGMRS: the GMRS repeater directory.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../core/frequency.dart';
import '../core/geo.dart';
import '../core/log.dart';
import '../models/radio_channel.dart';
import '../models/suggested_channel.dart';
import 'repeater_source.dart';

/// GMRS repeaters from myGMRS.com.
///
/// Anonymous: no token, no account. The endpoint is undocumented but public
/// and stable in shape -- `{"success": true, "items": [...]}` with a
/// `Frequency` string in MHz and numeric `Latitude`/`Longitude`.
///
/// TONES ARE NOT IN THIS FEED. The response carries no CTCSS or DCS at all,
/// which matters more for GMRS than it would for amateur: most GMRS repeaters
/// are tone-protected, so a channel built from this data will hear the
/// repeater and not key it. Every listing therefore says so in its details
/// rather than looking complete.
class MyGmrsClient implements RepeaterSource {
  static const String sourceId = 'mygmrs';
  static const String host = 'api.mygmrs.com';

  /// GMRS repeater inputs sit exactly 5 MHz above their outputs. This is
  /// fixed by the channel plan in 47 CFR 95.1763, not a per-repeater choice,
  /// which is why the feed does not carry an input frequency.
  static const int repeaterOffsetHz = 5000000;

  final http.Client _client;
  final Duration timeout;
  final String userAgent;

  MyGmrsClient({
    required this._client,
    required this.userAgent,
    this.timeout = const Duration(seconds: 20),
  });

  @override
  String get id => sourceId;

  @override
  String get displayName => 'myGMRS';

  @override
  String? get attribution => 'GMRS repeater data from myGMRS.com';

  /// Nothing to configure — it answers anonymously.
  @override
  Future<bool> isConfigured() async => true;

  @override
  Future<List<RepeaterListing>> fetchByState(String stateCode) async {
    final uri = Uri.https(host, '/repeaters', {'state': stateCode});

    http.Response response;
    try {
      response = await _client
          .get(
            uri,
            headers: {'User-Agent': userAgent, 'Accept': 'application/json'},
          )
          .timeout(timeout);
    } on TimeoutException {
      throw _failure(
        SourceFailureKind.network,
        'myGMRS did not answer in time. Showing what was cached.',
      );
    } on http.ClientException catch (error) {
      throw _failure(
        SourceFailureKind.network,
        'Could not reach myGMRS: ${error.message}',
      );
    } on SocketException catch (error) {
      throw _failure(
        SourceFailureKind.network,
        'Could not reach myGMRS: ${error.message}',
      );
    }

    if (response.statusCode == 429) {
      throw _failure(
        SourceFailureKind.rateLimited,
        'myGMRS asked us to slow down. Try again in a few minutes.',
      );
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw _failure(
        SourceFailureKind.network,
        'myGMRS returned HTTP ${response.statusCode}.',
      );
    }

    Object? decoded;
    try {
      decoded = jsonDecode(response.body);
    } on FormatException {
      throw _failure(
        SourceFailureKind.parse,
        'myGMRS sent something that was not JSON.',
      );
    }
    if (decoded is! Map<String, dynamic>) {
      throw _failure(
        SourceFailureKind.parse,
        'myGMRS sent an unexpected response.',
      );
    }
    final items = decoded['items'];
    if (items is! List) {
      throw _failure(SourceFailureKind.parse, 'myGMRS sent no repeater list.');
    }

    final listings = <RepeaterListing>[];
    for (final entry in items) {
      if (entry is! Map<String, dynamic>) continue;
      final listing = _listingFrom(entry);
      if (listing != null) listings.add(listing);
    }
    Log.radio.debug(
      'myGMRS $stateCode: ${listings.length} of ${items.length} usable',
    );
    return listings;
  }

  RepeaterListing? _listingFrom(Map<String, dynamic> item) {
    final rxHz = parseMegahertzToHz(item['Frequency']?.toString());
    if (rxHz == null) return null;

    final lat = item['Latitude'];
    final lon = item['Longitude'];
    final location = lat is num && lon is num
        ? GeoPoint(lat.toDouble(), lon.toDouble())
        : null;
    // A listing with no usable position cannot be distance-filtered, and
    // offering it unranked among ones that can would put a repeater 400 km
    // away at the top of the list.
    if (location == null || !location.isValid) return null;

    final name = _text(item['Name']) ?? _text(item['Location']) ?? 'GMRS';
    final town = _text(item['Location']);
    final type = _text(item['Type']);
    final status = _text(item['Status']);

    final notes = <String>[
      ?town,
      ?type,
      if (status != null && status.toLowerCase() != 'online') 'Status: $status',
      // Said every time, because a tone-protected repeater that the app
      // silently programmed without a tone would hear fine and never key.
      'Tone not published — confirm with the repeater owner',
    ];

    return RepeaterListing(
      channel: RadioChannel(
        name: name,
        rxFreqHz: rxHz,
        txFreqHz: rxHz + repeaterOffsetHz,
        mode: ChannelMode.nfm,
        comment: town ?? '',
      ),
      category: SuggestionCategory.gmrs,
      location: location,
      callsign: _text(item['Owner']),
      details: notes.join(' · '),
    );
  }

  static String? _text(Object? value) {
    if (value is! String) return null;
    final trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  RepeaterSourceException _failure(SourceFailureKind kind, String message) =>
      RepeaterSourceException(
        SourceFailure(
          sourceId: sourceId,
          displayName: 'myGMRS',
          kind: kind,
          message: message,
        ),
      );
}
