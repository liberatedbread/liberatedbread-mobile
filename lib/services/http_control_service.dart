// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

import '../core/error_text.dart';
import 'spec_codec.dart' show HttpRequestDto;
import 'tls_trust.dart';

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
  http.Client? _https;
  final http.Client? _injectedHttps;

  /// Hosts an https request has been addressed to. The fallback trust rule,
  /// for a device whose spec states no TLS policy: excuse the certificate of a
  /// host the caller named, never a blanket "trust anything" on a shared
  /// client. Most of the catalogue is in this state and this is what those
  /// devices have always done.
  final Set<String> _trustedHosts = <String>{};

  /// The policy the SPEC states, when it states one, and the pin store that
  /// serves it. `identification.tls.verification` was parsed by nothing, so
  /// the two specs asking to be pinned got the host rule above — which excuses
  /// a swapped certificate as readily as the real one, since the host is all
  /// it looks at.
  final TlsTrust? _trust;

  /// One request's ceiling. ECP answers in tens of milliseconds on a LAN, so
  /// ten seconds is generous — but a TV in deep standby can sit on a request,
  /// and cutting it off early would misreport a device that was about to say
  /// 200.
  static const timeout = Duration(seconds: 10);

  HttpControlClient({
    http.Client? httpClient,
    http.Client? httpsClient,
    TlsTrust? trust,
  })  : _http = httpClient ?? http.Client(),
        _injectedHttps = httpsClient,
        _trust = trust;

  /// Each device's identity and declared policy, KEYED BY HOST.
  ///
  /// Not a single "current device": this client is a `Provider`, so one
  /// instance is shared by every sender in the app, and a group run drives
  /// several devices through it at once. A single mutable identity would let
  /// the second device's registration land while the first device's handshake
  /// was in flight — pinning one device's certificate under another's name,
  /// and then refusing the real device forever after as "the certificate
  /// changed". The callback is handed the host it is deciding about, so the
  /// host is what selects the policy and the two cannot cross.
  final Map<String, ({String identity, TlsPolicy? policy})> _policies = {};

  /// How many live senders are registered for each host.
  ///
  /// Counted because this client is shared and the registrations are not: the
  /// group runner drives several members at once and closes each sender in a
  /// `finally`, so two saved records pointing at one host — or a device screen
  /// open across a group run — is enough for one sender's close to erase the
  /// policy another is still relying on. The survivor never re-registers (its
  /// own handover is memoized), so its next https send falls through to the
  /// by-host fallback, which `send` has already added this host to. A device
  /// that asked to be pinned would quietly go back to accepting anything.
  final Map<String, int> _registrations = {};

  /// Tell the client which device answers at [host].
  ///
  /// Separate from [send] because pinning has to happen before the handshake
  /// and the store is async while `badCertificateCallback` is not: the pin is
  /// read here so the callback can answer from memory.
  Future<void> useTlsPolicy({
    required String host,
    required String identity,
    required TlsPolicy? policy,
  }) async {
    // The pin is loaded BEFORE the policy is published, and that order is the
    // whole invariant. Published first, a handshake landing in the gap sees a
    // registered trust-on-first-use policy with no pin in hand, takes the
    // first-contact branch — accept anything, and overwrite the stored
    // fingerprint with whatever just answered. Every caller awaiting this
    // before connecting would also close the gap, but that is a discipline
    // rather than a property, and there has already been one caller that got
    // these arguments wrong.
    if (policy != null) await _trust?.prepare(identity);
    _policies[host] = (identity: identity, policy: policy);
    _registrations.update(host, (n) => n + 1, ifAbsent: () => 1);
  }

  /// Forget everything remembered about [host].
  ///
  /// Called when a device screen goes away. Without it `_policies` and
  /// `_trustedHosts` grow for the life of the process on a client every
  /// surface shares — and `_trustedHosts` is the more pointed of the two,
  /// because a host in it is one whose certificate the fallback rule accepts
  /// without looking, forever, on the strength of one https request made once.
  void forgetHost(String host) {
    final remaining = (_registrations[host] ?? 0) - 1;
    if (remaining > 0) {
      _registrations[host] = remaining;
      return;
    }
    _registrations.remove(host);
    _policies.remove(host);
    _trustedHosts.remove(host);
  }

  /// The TLS client, built on first https use so a plain-http app never pays
  /// for it. Trust is per-host, granted the moment a request names the host.
  http.Client get _httpsClient => _https ??= _injectedHttps ??
      IOClient(HttpClient()..badCertificateCallback = _evaluateCertificate);

  /// Whether to accept a certificate the platform refused.
  ///
  /// The spec's policy when it states one, through the shared [TlsTrust] so
  /// this client, the WebSocket session and the MQTT session cannot answer the
  /// same question three different ways again. Otherwise the host rule, which
  /// is what every device without a declared policy has always got.
  /// [_evaluateCertificate], for the test that pins the isolation between two
  /// devices sharing this client. Exposed rather than reached through a real
  /// handshake because the thing under test is the DECISION, and standing up
  /// two TLS servers to observe it would test dart:io.
  @visibleForTesting
  bool debugEvaluateCertificate(X509Certificate cert, String host, int port) =>
      _evaluateCertificate(cert, host, port);

  bool _evaluateCertificate(X509Certificate cert, String host, int port) {
    bool byHost(X509Certificate _, String host, int __) =>
        _trustedHosts.contains(host);
    final trust = _trust;
    final registered = _policies[host];
    if (trust == null || registered == null) return byHost(cert, host, port);
    return trust.evaluator(
      identity: registered.identity,
      policy: registered.policy,
      fallback: byHost,
    )(cert, host, port);
  }

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
    // The scheme is the spec's to declare (`identification.default_scheme`):
    // absent means plain http, `https` means the device only answers over
    // TLS — and its certificate is excused for this host alone.
    final secure = request.scheme == 'https';
    final http.Client client;
    if (secure) {
      _trustedHosts.add(host);
      client = _httpsClient;
    } else {
      client = _http;
    }
    final scheme = secure ? 'https' : 'http';
    final uri = Uri.parse('$scheme://$host:$port').resolve(request.path);
    final http.Response response;
    try {
      switch (request.method.toUpperCase()) {
        case 'GET':
          response = await client.get(uri).timeout(timeout);
        case 'POST':
          // ECP commands carry an empty body and no headers; a spec that
          // declares a body gets it sent verbatim.
          response =
              await client.post(uri, body: request.body).timeout(timeout);
        case 'PUT':
          // The body-carrying sibling of POST — the Hue bridge's whole write
          // surface, and the Frigidaires'. Rust's SENDABLE_METHODS names it,
          // so a spec's PUT command renders as a live control; this arm is
          // what makes the press actually go somewhere.
          response = await client.put(uri, body: request.body).timeout(timeout);
        default:
          throw HttpControlException(
              'unsupported method ${request.method} for $uri');
      }
    } on TimeoutException {
      throw const ControlTimeoutException();
    } on http.ClientException {
      // A refused certificate arrives here looking exactly like a device that
      // is switched off: `badCertificateCallback` returns a bool, so the
      // handshake failure carries no reason. Asking the policy which it was is
      // the difference between "your Envoy is unreachable" and the one
      // sentence that names the only recovery there is.
      if (_trust?.refused(host) ?? false) {
        throw const ControlCertificateChangedException();
      }
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

/// The device presented a different certificate than the one it was pinned to.
///
/// Its own type rather than a flavour of unreachable, because the user's next
/// action is completely different: nothing about the network is wrong, and no
/// amount of rescanning or waiting will help. Either the device was reset (or
/// took new firmware) and needs re-pairing, or something is answering in its
/// place — and the app cannot tell which, which is exactly why it refuses
/// rather than guessing and why it has to say so plainly.
class ControlCertificateChangedException implements UserFacingException {
  const ControlCertificateChangedException();
  @override
  String get message =>
      'This device is presenting a different security certificate than it did '
      'before. If you reset it or updated its firmware, remove it from Saved '
      'devices and add it again. If you did not, something else may be '
      'answering at its address.';
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
