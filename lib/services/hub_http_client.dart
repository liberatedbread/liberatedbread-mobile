// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

import '../core/log.dart';
import 'hub_credential_store.dart';
import 'spec_codec.dart' show HttpRequestDto;

/// The transport half of hub control: send a rendered HTTP request to a
/// bridge, verifying its TLS certificate the way the spec says a Hue bridge
/// must be verified, and hand the reply body back for the Rust codec to read.
///
/// Deliberately knows nothing about any device beyond the spec's stated TLS
/// shape. What to send and what a reply means live in the spec and are
/// answered by the Rust codec; this class only moves bytes — the same
/// division as SOAP and BLE.
///
/// TLS, per the spec's own TLS note: the bridge's certificate is a per-device
/// leaf whose subject CN is the bridgeid (lowercase), issued by Signify's
/// private CA — no public chain, so `badCertificateCallback` fires on every
/// single connection and IS the trust decision:
///
///   * leaf CN must equal the bridgeid this request is for;
///   * the leaf is pinned (sha256 of DER) on first use, keyed by bridgeid;
///   * a later pin mismatch is a different device or an interception — the
///     connection fails as [HubTlsException], the pin is never silently
///     replaced, and there is NO fallback to plain HTTP on a pin failure.
///
/// Plain HTTP exists only as the compatibility path for bridges with no 443
/// at all (the v1 round bridge): tried once when nothing is known yet, and
/// remembered. A bridge that has spoken HTTPS never gets downgraded — a
/// refused 443 on a pinned bridge is an outage or an attack, not a reason to
/// put the credential on the wire in clear.
///
/// One more rule this file owns: rendered paths embed the credential, so
/// paths are never logged — log lines carry host and method only.
class HubHttpClient {
  final HubCredentialStore _credentials;
  final http.Client Function(
    bool Function(X509Certificate cert, String host, int port) evaluate,
  ) _secureClientFactory;
  final http.Client Function()? _plainClientFactory;

  /// The bridge's real ports. Overridable because the loopback TLS tests and
  /// the virtual bridge listen on ephemeral ports; production callers never
  /// pass them.
  final int httpsPort;
  final int httpPort;

  static const timeout = Duration(seconds: 10);

  HubHttpClient({
    required HubCredentialStore credentials,
    http.Client Function(
      bool Function(X509Certificate cert, String host, int port) evaluate,
    )? secureClientFactory,
    http.Client Function()? plainClientFactory,
    this.httpsPort = 443,
    this.httpPort = 80,
  })  : _credentials = credentials,
        _secureClientFactory = secureClientFactory ??
            ((evaluate) =>
                IOClient(HttpClient()..badCertificateCallback = evaluate)),
        _plainClientFactory = plainClientFactory;

  /// Send one rendered request to the bridge and return the raw reply body.
  ///
  /// Picks the scheme the store remembers for [bridgeId]; with nothing
  /// remembered, probes HTTPS:443 and falls back to HTTP:80 only on a
  /// connection-level failure (no listener — the BSB001 case), remembering
  /// whichever worked. Writes' v1 envelopes are checked here — error type 1
  /// surfaces as [HubAuthException] so the UI can offer re-pairing.
  Future<String> send(
    String host,
    String bridgeId,
    HttpRequestDto request,
  ) async {
    final body = await _sendRaw(host, bridgeId, request);
    checkV1Envelope(body);
    return body;
  }

  /// [send] without the envelope check. The pairing flow reads outcomes
  /// itself, because its error 101 is a keep-waiting signal rather than a
  /// failure — everything else should use [send].
  Future<String> sendUnchecked(
    String host,
    String bridgeId,
    HttpRequestDto request,
  ) =>
      _sendRaw(host, bridgeId, request);

  /// Fetch the unauthenticated `/api/config` identity, over whichever scheme
  /// answers. Used before pairing (and for an SSDP-only sighting that never
  /// carried a bridgeid), so [expectedBridgeId] may be null — the TLS check
  /// then records what it saw instead of matching, and the caller must
  /// cross-check the returned bridgeid against [observedCn].
  Future<HubConfigProbe> fetchConfig(String host,
      {String? expectedBridgeId}) async {
    String? observedCn;
    final body = await _sendRaw(
      host,
      expectedBridgeId,
      const HttpRequestDto(method: 'GET', path: '/api/config', body: ''),
      onCn: (cn) => observedCn = cn,
    );
    return HubConfigProbe(body: body, observedCn: observedCn);
  }

  Future<String> _sendRaw(
    String host,
    String? bridgeId,
    HttpRequestDto request, {
    void Function(String cn)? onCn,
  }) async {
    final remembered =
        bridgeId == null ? null : await _credentials.scheme(bridgeId);
    if (remembered == 'http') {
      return _sendPlain(host, request);
    }

    try {
      final body = await _sendSecure(host, bridgeId, request, onCn: onCn);
      if (bridgeId != null && remembered == null) {
        await _credentials.saveScheme(bridgeId, 'https');
      }
      return body;
    } on HubTlsException {
      // The one failure that must never downgrade: someone answered 443 and
      // failed verification. Falling back would hand them the credential.
      rethrow;
    } on SocketException catch (e) {
      // "Has spoken HTTPS before" is the pin, not just the scheme record. The
      // pin and the scheme are two separate keychain writes (saveCertPin then
      // saveScheme); a crash or a failed second write between them would leave
      // a bridge pinned with no scheme, and keying the downgrade guard on the
      // scheme alone would then put the credential-bearing path on the wire in
      // clear to whoever answers port 80. A stored pin is the durable proof
      // that 443 verified once, so it refuses the downgrade on its own.
      final pinned =
          bridgeId != null && await _credentials.certPin(bridgeId) != null;
      if (remembered == 'https' || pinned) {
        // This bridge has spoken HTTPS before; a dead 443 now is an outage
        // or a downgrade attempt, and either way not a reason to go clear.
        throw HubTransportException('bridge unreachable over https: $e');
      }
      Log.hub
          .info('no https listener on $host; trying plain http (BSB001 path)');
      final body = await _sendPlain(host, request);
      if (bridgeId != null) {
        await _credentials.saveScheme(bridgeId, 'http');
      }
      return body;
    }
  }

  Future<String> _sendSecure(
    String host,
    String? bridgeId,
    HttpRequestDto request, {
    void Function(String cn)? onCn,
  }) async {
    final pinned =
        bridgeId == null ? null : await _credentials.certPin(bridgeId);
    String? tlsFailure;
    String? observedPin;

    bool evaluate(X509Certificate cert, String certHost, int port) {
      final fingerprint = sha256.convert(cert.der).toString();
      final cn = _subjectCn(cert.subject);
      if (cn != null) onCn?.call(cn);

      if (pinned != null) {
        if (fingerprint != pinned) {
          tlsFailure = 'certificate changed: pinned '
              '${_shortPin(pinned)}, presented ${_shortPin(fingerprint)}';
          return false;
        }
      } else if (bridgeId != null) {
        // First contact: the CN carries the bridge's own claim of identity,
        // and it must match the bridge this request is for.
        if (cn == null || cn.toUpperCase() != bridgeId.toUpperCase()) {
          tlsFailure =
              'certificate CN ${cn ?? '<none>'} is not bridge $bridgeId';
          return false;
        }
        observedPin = fingerprint;
      } else {
        // Identity probe with no expectation yet: accept, record, and let
        // the caller cross-check CN against the body it fetched.
        observedPin = fingerprint;
      }
      return true;
    }

    final client = _secureClientFactory(evaluate);
    try {
      final body = await _dispatch(client, 'https', host, httpsPort, request);
      // Trust on first use happens only after the request SUCCEEDED against
      // the CN-checked certificate.
      if (bridgeId != null && pinned == null && observedPin != null) {
        await _credentials.saveCertPin(bridgeId, observedPin!);
        Log.hub.info('pinned $bridgeId leaf ${_shortPin(observedPin!)}');
      }
      return body;
    } on HandshakeException catch (e) {
      final reason = tlsFailure ?? 'TLS handshake failed: $e';
      Log.hub.warning('TLS rejected for ${bridgeId ?? host}: $reason');
      throw HubTlsException(reason);
    } finally {
      client.close();
    }
  }

  Future<String> _sendPlain(String host, HttpRequestDto request) async {
    final client = _plainClientFactory?.call() ?? http.Client();
    try {
      return await _dispatch(client, 'http', host, httpPort, request);
    } finally {
      client.close();
    }
  }

  Future<String> _dispatch(
    http.Client client,
    String scheme,
    String host,
    int port,
    HttpRequestDto request,
  ) async {
    final uri = Uri(scheme: scheme, host: host, port: port, path: request.path);
    // An empty body means no body (a GET, or a bodiless POST): send no
    // Content-Type and nothing on the wire. The renderer returns "" rather
    // than null for that case — the DTO body is a plain String.
    final hasBody = request.body.isNotEmpty;
    final headers = hasBody
        ? const {'Content-Type': 'application/json'}
        : const <String, String>{};

    late final http.Response response;
    try {
      response = switch (request.method) {
        'GET' => await client.get(uri).timeout(timeout),
        'POST' => await client
            .post(uri, headers: headers, body: hasBody ? request.body : null)
            .timeout(timeout),
        'PUT' => await client
            .put(uri, headers: headers, body: hasBody ? request.body : null)
            .timeout(timeout),
        'DELETE' => await client.delete(uri).timeout(timeout),
        _ =>
          throw HubTransportException('unsupported method ${request.method}'),
      };
    } on http.ClientException catch (e) {
      // package:http wraps connection failures; unwrap the socket-level
      // cause so the caller's fallback logic sees one exception type.
      throw SocketException(e.message);
    }

    if (response.statusCode != 200) {
      // No path in the message: on this device the path is the credential.
      throw HubTransportException(
          '${request.method} to $host answered HTTP ${response.statusCode}');
    }
    return response.body;
  }

  /// Throw if [body] is a v1 outcome envelope carrying errors.
  ///
  /// The spec's `payload_formats.V1Envelope` transcribed: an array is an
  /// envelope (one element per attribute; a mixed envelope is possible, so
  /// every element is checked); a bare object is a successful GET reply.
  /// Error type 1 — unauthorized user — means the stored credential no
  /// longer exists on the bridge, and retrying cannot succeed: it surfaces
  /// as [HubAuthException] so the UI offers re-pairing instead of a spinner.
  static void checkV1Envelope(String body) {
    final outcomes = parseV1Envelope(body);
    if (outcomes == null) return;
    for (final outcome in outcomes) {
      final error = outcome.error;
      if (error == null) continue;
      if (error.type == 1) {
        throw HubAuthException(error.description);
      }
      throw HubApiException(error.type, error.description);
    }
  }

  /// Parse [body] as the v1 array envelope, or null when it is not one (a
  /// bare GET reply, or not JSON at all — the codec deals with those).
  static List<HueOutcome>? parseV1Envelope(String body) {
    final Object? parsed;
    try {
      parsed = jsonDecode(body);
    } on FormatException {
      return null;
    }
    if (parsed is! List) return null;
    return [
      for (final element in parsed)
        if (element is Map<String, dynamic>) HueOutcome.fromJson(element),
    ];
  }

  /// `CN=001788fffe61fcb0` out of a distinguished-name string. dart:io
  /// renders the subject platform-dependently (`/CN=x` on BoringSSL,
  /// `CN=x, O=y` elsewhere), so this matches the attribute, not the shape.
  ///
  /// `CN=` must begin a DN component — anchored to the start of the string or
  /// a `,`/`/` separator — so a `CN=` appearing inside another attribute's
  /// value (`O=xCN=…`) cannot be mistaken for the common name. Not a known
  /// exploit (on first contact the attacker owns the cert and would just set
  /// the real CN), but the check is the whole first-contact identity gate, so
  /// it reads the field it means to.
  static String? _subjectCn(String subject) {
    final match = RegExp(r'(?:^|[,/])\s*CN=([^,/]+)').firstMatch(subject);
    return match?.group(1)?.trim();
  }

  /// Enough of a pin to name it in an error without dumping the whole hash.
  static String _shortPin(String sha256Hex) =>
      'sha256:${sha256Hex.substring(0, 12)}…';
}

/// One element of a v1 outcome envelope.
class HueOutcome {
  final Map<String, dynamic>? success;
  final HueApiError? error;

  const HueOutcome({this.success, this.error});

  factory HueOutcome.fromJson(Map<String, dynamic> json) {
    final error = json['error'];
    final success = json['success'];
    return HueOutcome(
      success: success is Map<String, dynamic> ? success : null,
      error: error is Map<String, dynamic> ? HueApiError.fromJson(error) : null,
    );
  }
}

/// The `error` half of an envelope element: integer `type`, human text.
class HueApiError {
  /// 101 = link button not pressed (create_user's keep-polling signal);
  /// 1 = unauthorized user (re-pair); 201 = attribute not modifiable.
  final int type;
  final String description;

  const HueApiError({required this.type, required this.description});

  factory HueApiError.fromJson(Map<String, dynamic> json) => HueApiError(
        type: json['type'] is int ? json['type'] as int : -1,
        description: json['description']?.toString() ?? '',
      );

  /// create_user's keep-waiting signal — not a failure.
  bool get isLinkButtonNotPressed => type == 101;
}

/// The result of an unauthenticated identity probe: the `/api/config` body
/// plus the certificate CN observed while fetching it (null over plain HTTP).
class HubConfigProbe {
  final String body;
  final String? observedCn;

  const HubConfigProbe({required this.body, this.observedCn});
}

/// Connection-level failure: nothing answered, or spoke something that was
/// not HTTP 200.
class HubTransportException implements Exception {
  final String message;
  HubTransportException(this.message);
  @override
  String toString() => 'HubTransportException: $message';
}

/// TLS verification failed — wrong CN on first contact, or a pinned
/// certificate changed. Never followed by an HTTP fallback.
class HubTlsException implements Exception {
  final String message;
  HubTlsException(this.message);
  @override
  String toString() => 'HubTlsException: $message';
}

/// The bridge answered with a v1 error envelope.
class HubApiException implements Exception {
  final int type;
  final String description;
  HubApiException(this.type, this.description);
  @override
  String toString() => 'HubApiException(type $type): $description';
}

/// Error type 1 — the stored username no longer exists on the bridge.
/// Retrying cannot succeed; the fix is re-pairing.
class HubAuthException implements Exception {
  final String description;
  HubAuthException(this.description);
  @override
  String toString() => 'HubAuthException: $description';
}
