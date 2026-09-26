// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/log.dart';

/// The HTTP half of reading an IPP printer's status: POST the request body
/// Rust built to `http://host:port/<rp>` and hand back the reply body. Rust
/// owns every IPP byte; this owns the socket. Never throws — like the other
/// network transports, every failure is a result.
///
/// Plain HTTP only. IPP Everywhere printers serve the same resource on 631
/// without TLS; one that answers only `_ipps` is reported as such, and its
/// admin page is the way in until pinned TLS lands here.
class IppStatusClient {
  final Duration timeout;

  const IppStatusClient({this.timeout = const Duration(seconds: 6)});

  Future<IppFetchResult> fetch({
    required String host,
    required int port,
    required String resourcePath,
    required Uint8List body,
  }) async {
    final path = resourcePath.startsWith('/') ? resourcePath : '/$resourcePath';
    final client = HttpClient()..connectionTimeout = timeout;
    try {
      final request = await client
          .postUrl(Uri(scheme: 'http', host: host, port: port, path: path))
          .timeout(timeout);
      request.headers.contentType = ContentType('application', 'ipp');
      request.contentLength = body.length;
      request.add(body);
      final response = await request.close().timeout(timeout);
      final bytes = await response
          .fold<BytesBuilder>(BytesBuilder(), (b, chunk) => b..add(chunk))
          .timeout(timeout);
      if (response.statusCode == HttpStatus.upgradeRequired) {
        return const IppFetchFailed(
          'This printer only answers over a secure connection.',
          secureOnly: true,
        );
      }
      if (response.statusCode != HttpStatus.ok) {
        return IppFetchFailed(
          'The printer answered HTTP ${response.statusCode}.',
        );
      }
      return IppFetchOk(bytes.takeBytes());
    } on Object catch (e) {
      Log.net.debug('IPP status from $host:$port failed', error: e);
      return IppFetchFailed('Could not reach the printer at $host:$port.');
    } finally {
      client.close(force: true);
    }
  }
}

sealed class IppFetchResult {
  const IppFetchResult();
}

class IppFetchOk extends IppFetchResult {
  final Uint8List body;
  const IppFetchOk(this.body);
}

class IppFetchFailed extends IppFetchResult {
  final String reason;

  /// The printer wants TLS (HTTP 426), so plain IPP will not work.
  final bool secureOnly;

  const IppFetchFailed(this.reason, {this.secureOnly = false});
}

final ippStatusClientProvider = Provider<IppStatusClient>(
  (ref) => const IppStatusClient(),
);
