// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../core/log.dart';
import '../models/ad_banner.dart';

/// Fetches the remote ad-banner config (see [AdBannerConfig]).
///
/// This runs unattended in the background on launch, so every failure path —
/// offline, slow network, non-2xx, oversized body, malformed JSON — resolves to
/// a typed [AdBannerFetchResult]; the service never throws and never blocks
/// anything: callers fire it and keep rendering the bundled/cached banner.
class AdBannerService {
  /// Largest config document we will accept. The real one is a few hundred
  /// bytes; anything near this cap is not our config.
  static const int maxConfigBytes = 64 * 1024;

  final http.Client _client;
  final Duration timeout;

  AdBannerService({
    required http.Client client,
    this.timeout = const Duration(seconds: 10),
  }) : _client = client;

  /// GET [configUrl] and parse it. Never throws.
  Future<AdBannerFetchResult> fetch(String configUrl) async {
    final uri = Uri.tryParse(configUrl.trim());
    // https only. The config is fetched silently — the user never vets this
    // URL — so it gets no plaintext escape hatch.
    if (uri == null || uri.scheme != 'https' || uri.host.isEmpty) {
      return const AdBannerFetchFailed('not a valid https URL');
    }

    final http.Response response;
    try {
      response = await _client
          .get(uri, headers: const {'accept': 'application/json'})
          .timeout(timeout);
    } on TimeoutException {
      // Routine on a slow or absent network: debug, not warning — this fires
      // on every offline launch and must not spam the console.
      Log.ads.debug('config fetch timed out');
      return const AdBannerFetchFailed('timed out');
    } on Object catch (e) {
      Log.ads.debug('config fetch failed', error: e);
      return const AdBannerFetchFailed('network error');
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      Log.ads.debug('config fetch returned HTTP ${response.statusCode}');
      return AdBannerFetchFailed('HTTP ${response.statusCode}');
    }
    if (response.bodyBytes.length > maxConfigBytes) {
      Log.ads.warning('config rejected: ${response.bodyBytes.length} bytes '
          'exceeds the $maxConfigBytes-byte cap');
      return const AdBannerFetchFailed('config too large');
    }

    final String text;
    try {
      text = utf8.decode(response.bodyBytes);
    } on FormatException {
      Log.ads.warning('config rejected: not valid UTF-8');
      return const AdBannerFetchFailed('not valid UTF-8');
    }
    final config = AdBannerConfig.tryParse(text);
    if (config == null) {
      // Unlike a network failure this one is on us — someone published a bad
      // config — so it is loud enough for a developer to notice.
      Log.ads.warning('config rejected: not a valid banner config');
      return const AdBannerFetchFailed('malformed config');
    }
    Log.ads.debug(config.banner == null
        ? 'config fetched: no banner to show'
        : 'config fetched: banner "${config.banner!.id}"');
    return AdBannerFetchOk(config, text);
  }
}

/// Outcome of [AdBannerService.fetch].
sealed class AdBannerFetchResult {
  const AdBannerFetchResult();
}

class AdBannerFetchOk extends AdBannerFetchResult {
  final AdBannerConfig config;

  /// The raw document, for caching verbatim so the next launch replays it.
  final String rawJson;

  const AdBannerFetchOk(this.config, this.rawJson);
}

@immutable
class AdBannerFetchFailed extends AdBannerFetchResult {
  final String reason;
  const AdBannerFetchFailed(this.reason);
}
