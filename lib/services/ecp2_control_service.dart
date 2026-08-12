// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import 'http_control_service.dart' show ControlRefusedException;
import 'spec_codec.dart' show HttpRequestDto;

/// ECP2: the authenticated WebSocket session every Roku also listens on, and
/// the way through the "Control by mobile apps = Limited" gate that plain ECP
/// stops at.
///
/// Reverse-engineered from The Roku App (Official) 14.0.0.9462138 and verified
/// live against a Limited-mode fleet (the spec's `ecp2` block is the full
/// write-up). The session rides the same port 8060 as plain ECP: connect to
/// `ws://<ip>:8060/ecp-session` with subprotocol `ecp-2`, answer the device's
/// authenticate challenge, and the whole command vocabulary opens — including
/// the endpoints Limited mode refuses over HTTP.
///
/// Deliberately a fallback, never the primary path: the secret is the official
/// app's client id, and Roku can rotate or revoke it in a firmware update.
/// Plain ECP answers first; this exists for when it is refused.
class Ecp2ControlService {
  final Ecp2SocketConnector _connector;

  /// One request's ceiling, matching [HttpControlClient.timeout].
  final Duration timeout;

  Ecp2ControlService({Ecp2SocketConnector? connector, this.timeout = _timeout})
      : _connector = connector ?? _defaultConnector;

  static const _timeout = Duration(seconds: 10);

  /// The real socket: RFC 6455 to the device's ECP port, subprotocol `ecp-2`.
  /// The origin headers are what the official app sends — the APK sets
  /// `Sec-WebSocket-Origin: Android` (yw/e.java), and the live probe that
  /// verified this protocol sent `Origin: Android`; the device takes either,
  /// so both go out.
  static Future<Ecp2Socket> _defaultConnector(String host, int port) async {
    // ignore: close_sinks — ownership passes to the session, which closes it.
    final socket = await WebSocket.connect(
      'ws://$host:$port/ecp-session',
      protocols: ['ecp-2'],
      headers: const {'Origin': 'Android', 'Sec-WebSocket-Origin': 'Android'},
    ).timeout(_timeout);
    return _WebSocketEcp2Socket(socket);
  }

  /// Open a session and authenticate it. Throws when the device does not
  /// answer, refuses the client id, or never sends its challenge — the caller
  /// treats any of those as "no ECP2 here" and keeps the plain-ECP answer.
  Future<Ecp2Session> connect(String host, int port) async {
    final socket = await _connector(host, port);
    final session = Ecp2Session._(socket, timeout);
    try {
      await session._authenticate();
    } catch (_) {
      await session.close();
      rethrow;
    }
    return session;
  }
}

/// The minimal slice of a WebSocket the session uses, so tests can drive the
/// protocol from a script instead of a network.
abstract class Ecp2Socket {
  Stream<dynamic> get stream;
  void add(String frame);
  Future<void> close();
}

typedef Ecp2SocketConnector = Future<Ecp2Socket> Function(
    String host, int port);

class _WebSocketEcp2Socket implements Ecp2Socket {
  final WebSocket _socket;
  _WebSocketEcp2Socket(this._socket);
  @override
  Stream<dynamic> get stream => _socket;
  @override
  void add(String frame) => _socket.add(frame);
  @override
  Future<void> close() => _socket.close();
}

/// One authenticated session. Requests are matched to responses by
/// `request-id`; query payloads arrive base64 in `content-data` and come back
/// decoded — the same XML plain ECP would have answered, so the query-source
/// parser reads it unchanged.
class Ecp2Session {
  final Ecp2Socket _socket;
  final Duration _timeout;

  /// The device's authenticate challenge, completed by the first notify.
  final _challenge = Completer<String>();

  /// Waiters by request-id. One subscription dispatches everything, so frame
  /// order is preserved and no listener-attach timing can drop a frame.
  final Map<String, Completer<({String status, String body})>> _pending = {};

  late final StreamSubscription<dynamic> _subscription;
  var _nextId = 0;
  var _closed = false;

  Ecp2Session._(this._socket, this._timeout) {
    _subscription = _socket.stream
        .listen(_onFrame, onError: _failAll, onDone: () => _failAll(null));
  }

  /// The client id the official APK ships (jw/b.java), and the shift that
  /// turns it into the shared secret: every hex nibble n becomes
  /// `(24 - n) & 15`, non-hex characters pass through. Kept as the published
  /// UUID with the transform in code, so the provenance reads in the source.
  static const _apkClientId = '95E610D0-7C29-44EF-FB0F-97F1FCE4C297';
  static final String _secret = _apkClientId.split('').map((c) {
    final nibble = int.tryParse(c, radix: 16);
    return nibble == null
        ? c
        : ((24 - nibble) & 15).toRadixString(16).toUpperCase();
  }).join();

  /// The challenge-response: base64(SHA-1(challenge + secret)) where the
  /// challenge is the base64 STRING as received — not decoded — and the
  /// whole concatenation is UTF-8 encoded. Byte-exact with the APK's
  /// ClientIdChallengeResponseStrategy, and what the live fleet accepted.
  static String paramResponse(String challenge) =>
      base64.encode(sha1.convert(utf8.encode(challenge + _secret)).bytes);

  void _onFrame(dynamic data) {
    if (data is! String) return;
    final Object? decoded;
    try {
      decoded = jsonDecode(data);
    } on FormatException {
      return;
    }
    if (decoded is! Map<String, dynamic>) return;
    final challenge = decoded['param-challenge'];
    if (decoded['notify'] == 'authenticate' && challenge is String) {
      if (!_challenge.isCompleted) _challenge.complete(challenge);
      return;
    }
    // Unsolicited notifies (events, textedit state) are nobody's answer.
    final id = decoded['response-id'];
    if (id is! String) return;
    final completer = _pending.remove(id);
    if (completer == null) return;
    final status = '${decoded['status']}';
    final data64 = decoded['content-data'];
    completer.complete((
      status: status,
      body: data64 is String
          ? utf8.decode(base64.decode(data64), allowMalformed: true)
          : '',
    ));
  }

  void _failAll(Object? error) {
    _closed = true;
    final failure = error is Exception ? error : null;
    if (!_challenge.isCompleted) {
      _challenge.completeError(failure ??
          const Ecp2Exception('the session closed before authenticating'));
    }
    for (final completer in _pending.values) {
      if (!completer.isCompleted) {
        completer.completeError(
            failure ?? const Ecp2Exception('the session closed mid-request'));
      }
    }
    _pending.clear();
  }

  Future<void> _authenticate() async {
    final challenge = await _challenge.future.timeout(_timeout, onTimeout: () {
      throw const Ecp2Exception('the device sent no authenticate challenge');
    });
    final result = await _roundTrip(
        'authenticate', {'param-response': paramResponse(challenge)});
    if (result.status != '200') {
      throw Ecp2Exception('authenticate answered status ${result.status}');
    }
  }

  /// Send one request and wait for the response carrying its request-id.
  Future<({String status, String body})> _roundTrip(
      String request, Map<String, Object?> params) {
    if (_closed) throw const Ecp2Exception('the session is closed');
    final id = '${++_nextId}';
    final completer = Completer<({String status, String body})>();
    _pending[id] = completer;
    _socket.add(jsonEncode({'request': request, 'request-id': id, ...params}));
    return completer.future.timeout(_timeout, onTimeout: () {
      _pending.remove(id);
      throw Ecp2Exception('$request: no answer within $_timeout');
    });
  }

  /// Send one rendered ECP request down the session, translating the ECP path
  /// to its ECP2 verb — the request names ARE the ECP paths dashed
  /// (`/query/apps` → `query-apps`, `/keypress/X` → `key-press` with
  /// `param-key`). Returns what plain ECP would have: the decoded XML body
  /// for queries, an empty string for commands.
  ///
  /// A path with no ECP2 equivalent throws [ControlRefusedException] — the
  /// same answer the plain transport already gave, so the caller's fallback
  /// handling stays honest instead of inventing a new failure. A non-200 from
  /// the device throws likewise when it is 403, or [Ecp2Exception] otherwise.
  Future<String> send(HttpRequestDto request) async {
    final frame = _frameFor(request);
    if (frame == null) throw const ControlRefusedException();
    final verb = frame.remove('request')! as String;
    final result = await _roundTrip(verb, frame);
    if (result.status == '200') return result.body;
    if (result.status == '403') throw const ControlRefusedException();
    throw Ecp2Exception('$verb answered status ${result.status}');
  }

  static Map<String, Object?>? _frameFor(HttpRequestDto request) {
    final method = request.method.toUpperCase();
    // The rendered path is a relative reference; Uri handles the query half
    // and percent-decoding (pathSegments come back decoded).
    final uri = Uri.parse(request.path);
    final segments = uri.pathSegments;

    if (method == 'GET' && segments.length == 2 && segments[0] == 'query') {
      const queries = {
        'apps': 'query-apps',
        'active-app': 'query-active-app',
        'device-info': 'query-device-info',
        'media-player': 'query-media-player',
        'tv-channels': 'query-tv-channels-ex',
      };
      final verb = queries[segments[1]];
      if (verb != null) return {'request': verb};
    }
    if (method == 'POST' && segments.length == 2) {
      const keys = {
        'keypress': 'key-press',
        'keydown': 'key-down',
        'keyup': 'key-up',
      };
      final verb = keys[segments[0]];
      if (verb != null) {
        // pathSegments already percent-decoded: /keypress/Lit_%20 arrives as
        // "Lit_ ", which is the key name ECP2 wants verbatim.
        return {'request': verb, 'param-key': segments[1]};
      }
      if (segments[0] == 'launch') {
        return {
          'request': 'launch',
          'param-channel-id': segments[1],
          // The APK carries launch arguments as a JSON-encoded string of the
          // same map ECP puts in the query string (iw/h.java).
          if (uri.queryParameters.isNotEmpty)
            'param-params': jsonEncode(uri.queryParameters),
        };
      }
    }
    return null;
  }

  Future<void> close() async {
    _closed = true;
    await _subscription.cancel();
    await _socket.close();
  }
}

/// The ECP2 session itself failed: no challenge, a refused client id, a dead
/// socket, or a non-200 answer with no plain-ECP meaning.
class Ecp2Exception implements Exception {
  final String message;
  const Ecp2Exception(this.message);
  @override
  String toString() => 'Ecp2Exception: $message';
}
