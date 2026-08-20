// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:async';

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
  /// throw — 403 (and Roku's 400 "Limited mode" spelling of the same answer)
  /// as its own type, because on this transport it is a device policy
  /// ("network control disabled") rather than a network failure, and the
  /// caller should say so instead of suggesting a rescan. Timeouts and
  /// refused connections are user-facing too: the generic "did not accept
  /// that" fallback blamed the button for what is a sleeping TV.
  Future<String> send(String host, int port, HttpRequestDto request) async {
    // Resolved against the device's address rather than assembled with
    // `Uri(path: ...)`, which treats the whole rendered target as path data:
    // a target carrying a query string (the spec's `/input?name=value`) comes
    // out as `/input%3Fname=value`, a path the device has never heard of. The
    // renderer already produced a valid relative reference — percent-encoding
    // included — so resolving preserves both halves as written.
    final uri = Uri.parse('http://$host:$port').resolve(request.path);
    final http.Response response;
    try {
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
    } on TimeoutException {
      throw const ControlTimeoutException();
    } on http.ClientException {
      // Connection refused, no route, DNS — the device is not there to
      // answer. Same user question as a timeout, different wording.
      throw const ControlUnreachableException();
    }
    if (response.statusCode == 403 ||
        // A firmware-gated API answers 401 until a credential rides along —
        // the Envoy's local endpoints since firmware 7 want the entrez JWT.
        // That is the same device-side policy 403 is ("the device will not
        // serve you yet"), not a network failure, so it gets the same type.
        response.statusCode == 401 ||
        // A Roku in "Limited" control mode answers some gated endpoints with
        // 400 and this body instead of 403 (observed both spellings on one
        // OS 15.2.4 fleet, against the same endpoint, minutes apart). It is
        // the same refusal, so it gets the same exception.
        (response.statusCode == 400 &&
            response.body.contains('Limited mode'))) {
      throw const ControlRefusedException();
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw HttpControlException('${request.method} ${request.path} failed: '
          'HTTP ${response.statusCode} from $uri');
    }
    return response.body;
  }
}

/// The device took too long to answer (the request deadline passed).
///
/// On the devices this transport exists for that usually means a TV whose
/// network stack is asleep: a Roku in deep standby keeps no ECP server, and
/// PowerOn only reaches one sitting in "Fast TV Start" standby. That is a
/// device state, not an app fault — so it gets a written message rather than
/// the generic "did not accept that" fallback, which blamed the button.
class ControlTimeoutException implements UserFacingException {
  const ControlTimeoutException();
  @override
  String get message => 'The device did not answer in time. It may be '
      'asleep or off the network — wake it and try again.';
}

/// The device could not be connected to at all (refused, no route).
class ControlUnreachableException implements UserFacingException {
  const ControlUnreachableException();
  @override
  String get message => 'The device is not reachable. It may be off or '
      'have a new address — try scanning again.';
}

/// The transport failed: unreachable host, unexpected status, bad method.
class HttpControlException implements Exception {
  final String message;
  const HttpControlException(this.message);
  @override
  String toString() => 'HttpControlException: $message';
}

/// The device understood the request and refused it (HTTP 403, or 401 where
/// the gate is a missing credential rather than a disabled setting).
///
/// On the devices this transport exists for, that is a settings toggle, not
/// a fault: since Roku OS 14.1 command endpoints answer 403 until
/// "Control by mobile apps" is enabled on the device itself, and the Envoy's
/// firmware-7+ endpoints want a token this app does not hold. The message
/// stays device-agnostic — the spec documents the exact menu path.
class ControlRefusedException implements UserFacingException {
  const ControlRefusedException();
  @override
  String get message =>
      'The device refused the command. Look for a "control by mobile apps" '
      'or "network control" setting on the device itself and enable it, '
      'then try again.';
}
