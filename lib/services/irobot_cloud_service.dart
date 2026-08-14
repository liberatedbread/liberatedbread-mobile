// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../core/log.dart';
import 'roomba_credential_store.dart';

/// Reads a robot's BLID and local password out of iRobot's own API, using the
/// owner's account, and then gets out of the way.
///
/// # Why this exists at all
///
/// The account-free route — hold HOME, send the disclosure probe — is the one
/// this app prefers and the one the adoption wizard offers first. It does not
/// always complete: some firmware refuses to disclose locally, and some
/// robots' TLS is older than any cipher a phone still offers. This is the
/// fallback, and it is dorita980's `get-roomba-password-cloud`, transcribed.
///
/// # What it is not
///
/// It is not a control path. Nothing about talking to the robot afterwards
/// needs an account, and the credentials this returns are byte-for-byte the
/// ones the local handshake would have produced. Once they are in the keychain
/// the account is never needed again — which matters, because the very next
/// thing the guide tells the owner to do is firewall the robot, and that
/// breaks this route permanently.
///
/// # The account password
///
/// Passed in, used for exactly one request, and never written anywhere: not to
/// the keychain, not to preferences, not to a log. It lives in a parameter for
/// the duration of [fetchCredentials] and is gone when that future completes.
/// `irobot_cloud_service_test.dart` asserts that with a store that fails the
/// test if anything is written to it.
class IRobotCloudService {
  final http.Client _client;

  /// Where the regional endpoints are discovered. The only host this class
  /// knows without being told; everything else comes back from here.
  static const discoveryHost = 'disc-prod.iot.irobotapi.com';

  /// The client identifier the login call carries. A constant of the protocol,
  /// taken from dorita980 — the API rejects a request without one.
  static const appId = 'ANDROID-C7FB240E-DF34-42D7-AE4E-A8C17079A294';

  /// Generous, because this runs on someone's phone over their home Wi-Fi and
  /// three sequential round trips to a cloud API is the slowest thing the
  /// adoption wizard does.
  static const timeout = Duration(seconds: 20);

  IRobotCloudService({http.Client? client}) : _client = client ?? http.Client();

  /// Log in once and return every robot on the account.
  ///
  /// [countryCode] picks the regional endpoints; iRobot runs several and the
  /// wrong one answers with an empty robot list rather than an error, which is
  /// the confusing failure this parameter exists to avoid.
  ///
  /// Throws [IRobotCloudException] with text meant to be shown. The three
  /// failures a user actually hits — wrong password, no robots on the account,
  /// and "you already firewalled it" — read differently on purpose.
  Future<List<RoombaCredentials>> fetchCredentials({
    required String email,
    required String password,
    String countryCode = 'US',
  }) async {
    final endpoints = await _discoverEndpoints(countryCode);
    final assertion = await _gigyaLogin(
      endpoints: endpoints,
      email: email,
      password: password,
    );
    return _robots(endpoints: endpoints, assertion: assertion);
  }

  Future<_Endpoints> _discoverEndpoints(String countryCode) async {
    final uri = Uri.https(discoveryHost, '/v1/discover/endpoints', {
      'country_code': countryCode,
    });
    final body = await _getJson(uri, 'endpoint discovery');

    final apiKey = _firstString(body, const ['gigya', 'api_key']);
    final gigyaBase = _firstString(body, const ['gigya', 'datacenter_domain']);
    final httpBase = _firstString(body, const ['httpBase']);

    if (apiKey == null || gigyaBase == null || httpBase == null) {
      throw const IRobotCloudException(
        "iRobot's endpoint directory did not return the fields this sign-in "
        'needs. Their API may have changed — try the HOME-button route, or '
        'use dorita980 on a computer.',
      );
    }
    // The directory returns a bare domain for Gigya and a full URL for the
    // iRobot API. Normalising both here keeps the two call sites from each
    // guessing which they were handed.
    return _Endpoints(
      apiKey: apiKey,
      gigyaBase:
          gigyaBase.startsWith('http') ? gigyaBase : 'https://$gigyaBase',
      httpBase: httpBase.startsWith('http') ? httpBase : 'https://$httpBase',
    );
  }

  Future<_GigyaAssertion> _gigyaLogin({
    required _Endpoints endpoints,
    required String email,
    required String password,
  }) async {
    final uri = Uri.parse('${endpoints.gigyaBase}/accounts.login');
    final body = await _postForm(
      uri,
      {
        'apiKey': endpoints.apiKey,
        'loginID': email,
        // The one place the account password appears. It is not logged, not
        // stored, and not returned; it exists in this map and nowhere else.
        'password': password,
        'targetEnv': 'mobile',
        'format': 'json',
      },
      'iRobot sign-in',
    );

    final errorCode = body['errorCode'];
    if (errorCode is num && errorCode != 0) {
      // Gigya's own message is usually right ("Invalid loginID or password")
      // and is far more useful than anything we could substitute.
      final detail = body['errorMessage'] ?? body['errorDetails'];
      throw IRobotCloudException(
        'iRobot rejected the sign-in${detail == null ? '' : ': $detail'}.',
      );
    }

    final uid = body['UID'];
    final signature = body['UIDSignature'];
    final timestamp = body['signatureTimestamp'];
    if (uid is! String || signature is! String || timestamp == null) {
      throw const IRobotCloudException(
        'iRobot signed you in but did not return the assertion needed to list '
        'your robots.',
      );
    }
    return _GigyaAssertion(
      uid: uid,
      signature: signature,
      timestamp: timestamp.toString(),
    );
  }

  Future<List<RoombaCredentials>> _robots({
    required _Endpoints endpoints,
    required _GigyaAssertion assertion,
  }) async {
    final uri = Uri.parse('${endpoints.httpBase}/v2/login');
    final body = await _postJson(
      uri,
      {
        'app_id': appId,
        // Read the account's existing robots; do not claim ownership of
        // anything. Claiming would be a side effect on someone else's account
        // that this app has no business causing.
        'assume_robot_ownership': 0,
        'gigya': {
          'signature': assertion.signature,
          'timestamp': assertion.timestamp,
          'uid': assertion.uid,
        },
      },
      'robot list',
    );

    final robots = body['robots'];
    if (robots is! Map) {
      throw const IRobotCloudException(
        'iRobot returned no robots for this account.',
      );
    }

    final found = <RoombaCredentials>[];
    robots.forEach((blid, value) {
      if (value is! Map) return;
      final password = value['password'];
      if (password is! String || password.isEmpty) return;
      found.add(RoombaCredentials(
        blid: blid.toString(),
        password: password,
        name: value['name']?.toString(),
        sku: value['sku']?.toString(),
      ));
    });

    if (found.isEmpty) {
      throw const IRobotCloudException(
        'That account has no robots with a local password. If you have more '
        'than one iRobot account, try the other one.',
      );
    }
    // Count only. The BLIDs and passwords are exactly what must never reach a
    // log line.
    Log.hub.info('iRobot account returned ${found.length} robot(s)');
    return found;
  }

  // ── HTTP plumbing ─────────────────────────────────────────────────────────

  Future<Map<String, dynamic>> _getJson(Uri uri, String what) =>
      _send(() => _client.get(uri), uri, what);

  Future<Map<String, dynamic>> _postForm(
    Uri uri,
    Map<String, String> fields,
    String what,
  ) =>
      _send(() => _client.post(uri, body: fields), uri, what);

  Future<Map<String, dynamic>> _postJson(
    Uri uri,
    Map<String, Object?> body,
    String what,
  ) =>
      _send(
        () => _client.post(
          uri,
          headers: const {'Content-Type': 'application/json'},
          body: jsonEncode(body),
        ),
        uri,
        what,
      );

  Future<Map<String, dynamic>> _send(
    Future<http.Response> Function() request,
    Uri uri,
    String what,
  ) async {
    final http.Response response;
    try {
      response = await request().timeout(timeout);
    } on SocketException catch (e) {
      // The likeliest cause by far, and worth naming: the guide tells people
      // to firewall the robot, and someone who did that first lands here.
      throw IRobotCloudException(
        'Could not reach iRobot for the $what (${e.message}). If you have '
        'already blocked this network from iRobot, that block is why — the '
        'HOME-button route still works offline.',
      );
    } on TimeoutException {
      throw IRobotCloudException(
        'iRobot did not answer the $what within ${timeout.inSeconds}s.',
      );
    } on http.ClientException catch (e) {
      throw IRobotCloudException('The $what failed: ${e.message}');
    }

    if (response.statusCode >= 400) {
      throw IRobotCloudException(
        'iRobot answered the $what with HTTP ${response.statusCode}.',
      );
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(response.body);
    } on FormatException {
      throw IRobotCloudException("iRobot's $what reply was not JSON.");
    }
    if (decoded is! Map<String, dynamic>) {
      throw IRobotCloudException(
        "iRobot's $what reply was not the object this expects.",
      );
    }
    return decoded;
  }

  /// Read a string from a nested path, tolerating either a nested object or a
  /// flattened key. The endpoint directory has been seen both ways across
  /// regions, and a client that only knows one shape fails in exactly one
  /// country.
  static String? _firstString(Map<String, dynamic> body, List<String> path) {
    Object? cursor = body;
    for (final key in path) {
      if (cursor is! Map) return null;
      cursor = cursor[key];
    }
    if (cursor is String && cursor.isNotEmpty) return cursor;
    // Flattened fallback: the last path segment at the top level.
    final flat = body[path.last];
    return flat is String && flat.isNotEmpty ? flat : null;
  }

  void close() => _client.close();
}

class _Endpoints {
  final String apiKey;
  final String gigyaBase;
  final String httpBase;
  const _Endpoints({
    required this.apiKey,
    required this.gigyaBase,
    required this.httpBase,
  });
}

class _GigyaAssertion {
  final String uid;
  final String signature;
  final String timestamp;
  const _GigyaAssertion({
    required this.uid,
    required this.signature,
    required this.timestamp,
  });
}

/// A failure in the account route, with a message meant to be shown as-is.
class IRobotCloudException implements Exception {
  final String message;
  const IRobotCloudException(this.message);
  @override
  String toString() => message;
}
