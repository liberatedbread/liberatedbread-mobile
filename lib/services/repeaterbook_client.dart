// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// RepeaterBook: the amateur repeater directory, and the token it now needs.

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

/// What checking a token found out.
///
/// Five outcomes rather than a bool because they need five different things
/// said to the user. RepeaterBook distinguishes them itself — a value that is
/// not token-shaped is refused differently from one that is but is not known —
/// so the app can tell "you pasted the wrong thing" apart from "that token
/// was rejected", which are very different problems to be stuck on.
enum TokenCheck {
  /// The token worked.
  valid,

  /// Nothing was entered.
  missing,

  /// The service did not recognise this as a token at all — usually a
  /// half-copied paste, or the wrong field from the page.
  malformed,

  /// Token-shaped, and refused. Expired, revoked, or for another app.
  rejected,

  /// Asked too often to find out.
  rateLimited,

  /// Could not reach RepeaterBook to ask.
  unreachable,
}

/// Amateur repeaters from RepeaterBook.com.
///
/// Since March 2026 the export API requires an application token in an
/// `X-RB-App-Token` header; without one it answers 401 `auth_missing`. A
/// token is free but is requested from a logged-in RepeaterBook account, so
/// this source ships switched off with an explanation and a walkthrough
/// rather than silently returning nothing.
///
/// Their terms also ask for a User-Agent naming the app and a contact, for
/// caching to be kept minimal, and for the attribution line to appear
/// wherever the data does. All three are honoured here and in
/// [RadioSourceCache].
class RepeaterBookClient implements RepeaterSource {
  static const String sourceId = 'repeaterbook';
  static const String host = 'www.repeaterbook.com';
  static const String exportPath = '/api/export.php';

  /// Where a person goes to get a token. Opened from the settings screen.
  static const String tokenRequestUrl =
      'https://www.repeaterbook.com/api/token_request.php';

  static const String attributionLine = 'Data courtesy of RepeaterBook.com';

  final http.Client _client;
  final Duration timeout;
  final String userAgent;

  /// Reads the stored token. A function rather than a store so this class
  /// does not care where the secret lives.
  final Future<String?> Function() _readToken;

  /// Maps a postal code to the FIPS `state_id` the export API takes.
  final Future<String?> Function(String stateCode) _resolveStateId;

  RepeaterBookClient({
    required this._client,
    required this.userAgent,
    required this._readToken,
    required this._resolveStateId,
    this.timeout = const Duration(seconds: 25),
  });

  @override
  String get id => sourceId;

  @override
  String get displayName => 'RepeaterBook';

  @override
  String? get attribution => attributionLine;

  @override
  Future<bool> isConfigured() async {
    final token = await _readToken();
    return token != null && token.trim().isNotEmpty;
  }

  /// Ask RepeaterBook whether [token] works, with one small request.
  ///
  /// This is what the settings screen's Verify button runs. Nothing is
  /// accepted silently: a token that has been pasted but never used is a
  /// source that will fail at the worst moment, standing in a car park
  /// looking for a repeater.
  Future<TokenCheck> verifyToken(String token) async {
    final trimmed = token.trim();
    if (trimmed.isEmpty) return TokenCheck.missing;

    // Rhode Island: the smallest state, so the smallest answer to a token
    // check that must actually exercise the endpoint.
    final uri = Uri.https(host, exportPath, {'state_id': '44'});
    http.Response response;
    try {
      response = await _client
          .get(
            uri,
            headers: {
              'X-RB-App-Token': trimmed,
              'User-Agent': userAgent,
              'Accept': 'application/json',
            },
          )
          .timeout(timeout);
    } on TimeoutException {
      return TokenCheck.unreachable;
    } on http.ClientException {
      return TokenCheck.unreachable;
    } on SocketException {
      return TokenCheck.unreachable;
    }

    if (response.statusCode == 429) return TokenCheck.rateLimited;
    if (response.statusCode >= 200 && response.statusCode < 300) {
      return TokenCheck.valid;
    }
    if (response.statusCode == 401 || response.statusCode == 403) {
      return _authOutcome(response.body);
    }
    return TokenCheck.unreachable;
  }

  /// Read RepeaterBook's own error body to tell "not a token" from "not your
  /// token". It answers `auth_missing` when the header is absent or unknown,
  /// and `auth_invalid` with a message naming the format when the value does
  /// not parse.
  static TokenCheck _authOutcome(String body) {
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map<String, dynamic>) {
        final code = decoded['error_code'];
        final message = decoded['message'];
        if (code == 'auth_missing') return TokenCheck.missing;
        if (code == 'auth_invalid') {
          final text = message is String ? message.toLowerCase() : '';
          return text.contains('format')
              ? TokenCheck.malformed
              : TokenCheck.rejected;
        }
      }
    } on FormatException {
      // Fall through: an unparseable error body is still a refusal.
    }
    return TokenCheck.rejected;
  }

  @override
  Future<List<RepeaterListing>> fetchByState(String stateCode) async {
    final token = (await _readToken())?.trim();
    if (token == null || token.isEmpty) {
      throw _failure(
        SourceFailureKind.auth,
        'RepeaterBook needs a free access token. Set one up in radio source '
        'settings — it takes a minute.',
      );
    }

    final stateId = await _resolveStateId(stateCode);
    if (stateId == null || stateId.isEmpty) {
      throw _failure(
        SourceFailureKind.parse,
        'No RepeaterBook state id for $stateCode.',
      );
    }

    final uri = Uri.https(host, exportPath, {'state_id': stateId});
    http.Response response;
    try {
      response = await _client
          .get(
            uri,
            headers: {
              'X-RB-App-Token': token,
              'User-Agent': userAgent,
              'Accept': 'application/json',
            },
          )
          .timeout(timeout);
    } on TimeoutException {
      throw _failure(
        SourceFailureKind.network,
        'RepeaterBook did not answer in time.',
      );
    } on http.ClientException catch (error) {
      throw _failure(
        SourceFailureKind.network,
        'Could not reach RepeaterBook: ${error.message}',
      );
    } on SocketException catch (error) {
      throw _failure(
        SourceFailureKind.network,
        'Could not reach RepeaterBook: ${error.message}',
      );
    }

    if (response.statusCode == 429) {
      throw _failure(
        SourceFailureKind.rateLimited,
        'RepeaterBook asked us to slow down. Cached results are being shown; '
        'try again in a few minutes.',
      );
    }
    if (response.statusCode == 401 || response.statusCode == 403) {
      throw _failure(SourceFailureKind.auth, switch (_authOutcome(
        response.body,
      )) {
        TokenCheck.malformed =>
          'RepeaterBook did not recognise the saved token. Check it in '
              'radio source settings.',
        _ =>
          'RepeaterBook refused the saved token. It may have expired — '
              'request a new one in radio source settings.',
      });
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw _failure(
        SourceFailureKind.network,
        'RepeaterBook returned HTTP ${response.statusCode}.',
      );
    }

    Object? decoded;
    try {
      decoded = jsonDecode(response.body);
    } on FormatException {
      throw _failure(
        SourceFailureKind.parse,
        'RepeaterBook sent something that was not JSON.',
      );
    }
    final rows = _rowsFrom(decoded);
    if (rows == null) {
      throw _failure(
        SourceFailureKind.parse,
        'RepeaterBook sent no repeater list.',
      );
    }

    final listings = <RepeaterListing>[];
    for (final row in rows) {
      if (row is! Map<String, dynamic>) continue;
      final listing = _listingFrom(row);
      if (listing != null) listings.add(listing);
    }
    Log.radio.debug(
      'RepeaterBook $stateCode: ${listings.length} of ${rows.length} usable',
    );
    return listings;
  }

  /// Find the array of rows.
  ///
  /// Deliberately tolerant of which key it arrives under. The export has been
  /// documented as `results` and, elsewhere, as `data`; a source that stops
  /// working because a directory renamed a wrapper key is worse than one that
  /// looks in three places.
  static List<Object?>? _rowsFrom(Object? decoded) {
    if (decoded is List) return decoded;
    if (decoded is Map<String, dynamic>) {
      for (final key in ['results', 'data', 'items', 'repeaters']) {
        final value = decoded[key];
        if (value is List) return value;
      }
    }
    return null;
  }

  /// Field lookup that ignores case, spaces and underscores, because this
  /// export's column names are display labels ("Input Freq", "Operational
  /// Status") and their spelling has moved before.
  static Object? _field(Map<String, dynamic> row, List<String> names) {
    String norm(String value) =>
        value.toLowerCase().replaceAll(RegExp(r'[\s_]'), '');
    final normalized = {for (final e in row.entries) norm(e.key): e.value};
    for (final name in names) {
      final value = normalized[norm(name)];
      if (value != null) return value;
    }
    return null;
  }

  RepeaterListing? _listingFrom(Map<String, dynamic> row) {
    final rxHz = parseMegahertzToHz(
      _field(row, ['Frequency', 'freq'])?.toString(),
    );
    if (rxHz == null) return null;

    // An absent input frequency means simplex, which the directory does list.
    final txHz =
        parseMegahertzToHz(
          _field(row, ['Input Freq', 'inputfreq', 'input'])?.toString(),
        ) ??
        rxHz;

    final lat = _numField(row, ['Lat', 'Latitude']);
    final lon = _numField(row, ['Long', 'Longitude', 'Lon']);
    if (lat == null || lon == null) return null;
    final location = GeoPoint(lat, lon);
    if (!location.isValid) return null;

    final callsign = _text(_field(row, ['Callsign', 'call']));
    final landmark = _text(_field(row, ['Landmark', 'Nearest City', 'City']));
    final county = _text(_field(row, ['County']));
    final use = _text(_field(row, ['Use']));
    final status = _text(_field(row, ['Operational Status', 'status']));

    final notes = <String>[
      ?landmark,
      if (county != null) '$county County',
      if (use != null && use.toLowerCase() != 'open') 'Use: $use',
      if (status != null && status.toLowerCase() != 'on-air') 'Status: $status',
    ];

    return RepeaterListing(
      channel: RadioChannel(
        name: callsign ?? landmark ?? 'Repeater',
        rxFreqHz: rxHz,
        txFreqHz: txHz,
        // PL is what you send to open the repeater; TSQ is what it sends
        // back. Tone squelch on receive is deliberately not enabled from
        // TSQ -- it silences every simplex station on the frequency, which
        // is a surprise nobody asked this app for.
        txTone: _toneFrom(_field(row, ['PL', 'pl_tone', 'Tone'])),
        mode: ChannelMode.fm,
        comment: landmark ?? '',
      ),
      category: SuggestionCategory.repeater,
      location: location,
      callsign: callsign,
      details: notes.isEmpty ? null : notes.join(' · '),
    );
  }

  /// Read a tone cell: "100.0" is CTCSS, "D023"/"023" with a D is DCS, and
  /// "CSQ", "" or a dash all mean carrier squelch.
  static ToneSetting _toneFrom(Object? value) {
    final text = value?.toString().trim();
    if (text == null || text.isEmpty) return ToneSetting.none;
    final upper = text.toUpperCase();
    if (upper == 'CSQ' || upper == 'NONE' || upper == '-') {
      return ToneSetting.none;
    }

    if (upper.startsWith('D')) {
      final digits = RegExp(r'\d+').firstMatch(upper)?.group(0);
      final code = digits == null ? null : int.tryParse(digits);
      if (code == null || code <= 0) return ToneSetting.none;
      return ToneSetting.dcs(code, inverted: upper.endsWith('I'));
    }

    final hz = parseMegahertzToHz(text);
    // The tone cell is in Hz, not MHz, so the parser's "MHz" units are being
    // borrowed purely for its exactness: 107.2 arrives as 107200000 and the
    // tenths of a Hz this app stores are that divided by 100000.
    if (hz == null || hz <= 0) return ToneSetting.none;
    final tenths = hz ~/ 100000;
    return tenths > 0 ? ToneSetting.ctcss(tenths) : ToneSetting.none;
  }

  static double? _numField(Map<String, dynamic> row, List<String> names) {
    final value = _field(row, names);
    if (value is num) return value.toDouble();
    if (value is String) return double.tryParse(value.trim());
    return null;
  }

  static String? _text(Object? value) {
    if (value == null) return null;
    final trimmed = value.toString().trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  RepeaterSourceException _failure(SourceFailureKind kind, String message) =>
      RepeaterSourceException(
        SourceFailure(
          sourceId: sourceId,
          displayName: 'RepeaterBook',
          kind: kind,
          message: message,
        ),
      );
}
