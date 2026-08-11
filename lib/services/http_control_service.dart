// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'package:http/http.dart' as http;

import '../core/error_text.dart';
import 'spec_codec.dart' show HttpRequestDto;

/// The transport half of plain-HTTP device control: send a rendered request
/// to the device's own address.
///
/// [SoapControlClient]'s sibling for the transport with no envelope. Roku ECP
/// is the model: the whole instruction is the method and the path, the body
/// is empty, and there is nothing to resolve first — discovery already knows
/// the host and port from the SSDP LOCATION. Deliberately knows nothing about
/// any device; what to send comes from the spec via the Rust codec.
class HttpControlClient {
  final http.Client _http;

  /// One request's ceiling. ECP answers in tens of milliseconds on a LAN, so
  /// ten seconds is generous — but a TV in deep standby can sit on a request,
  /// and cutting it off early would misreport a device that was about to say
  /// 200.
  static const timeout = Duration(seconds: 10);

  HttpControlClient({http.Client? httpClient})
      : _http = httpClient ?? http.Client();

  /// Send one rendered request and return the response body.
  ///
  /// The body is returned rather than discarded because query endpoints ride
  /// the same transport; a keypress caller just ignores it. Non-2xx statuses
  /// throw — 403 as its own type, because on this transport it is a device
  /// policy ("network control disabled") rather than a network failure, and
  /// the caller should say so instead of suggesting a rescan.
  Future<String> send(String host, int port, HttpRequestDto request) async {
    final uri = Uri(scheme: 'http', host: host, port: port, path: request.path);
    final http.Response response;
    switch (request.method.toUpperCase()) {
      case 'GET':
        response = await _http.get(uri).timeout(timeout);
      case 'POST':
        // ECP commands carry an empty body and no headers; a spec that
        // declares a body gets it sent verbatim.
        response = await _http.post(uri, body: request.body).timeout(timeout);
      default:
        throw HttpControlException(
            'unsupported method ${request.method} for $uri');
    }
    if (response.statusCode == 403) {
      throw const ControlRefusedException();
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw HttpControlException('${request.method} ${request.path} failed: '
          'HTTP ${response.statusCode} from $uri');
    }
    return response.body;
  }
}

/// The transport failed: unreachable host, unexpected status, bad method.
class HttpControlException implements Exception {
  final String message;
  const HttpControlException(this.message);
  @override
  String toString() => 'HttpControlException: $message';
}

/// The device understood the request and refused it (HTTP 403).
///
/// On the devices this transport exists for, that is a settings toggle, not
/// a fault: since Roku OS 14.1 command endpoints answer 403 until
/// "Control by mobile apps" is enabled on the device itself. The message
/// stays device-agnostic — the spec documents the exact menu path.
class ControlRefusedException implements UserFacingException {
  const ControlRefusedException();
  @override
  String get message =>
      'The device refused the command. Look for a "control by mobile apps" '
      'or "network control" setting on the device itself and enable it, '
      'then try again.';
}
