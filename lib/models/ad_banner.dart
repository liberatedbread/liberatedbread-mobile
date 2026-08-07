// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../core/constants.dart';

/// One house ad shown in the small banner at the bottom of the scan screen.
///
/// Banners are described by a remote JSON config (see [AdBannerConfig]) so the
/// promotion can change — or be switched off — without an app-store release.
/// [fallback] is the bundled copy of the same content, shown until a fetch has
/// ever succeeded so the banner works offline and on a slow first launch.
@immutable
class AdBanner {
  /// Stable identity for this promotion. Dismissal is recorded against the id,
  /// so publishing a config with a new id resurfaces the banner.
  final String id;

  /// Short pitch, rendered at most two lines.
  final String message;

  /// Call-to-action label next to the message, e.g. "Shop".
  final String cta;

  /// Where a tap goes. Always https — enforced by [AdBannerConfig.tryParse].
  final Uri url;

  const AdBanner({
    required this.id,
    required this.message,
    required this.cta,
    required this.url,
  });

  /// The bundled banner, mirroring the content published at
  /// [AppConstants.adBannerConfigUrl] when this build shipped.
  static final AdBanner fallback = AdBanner(
    id: 'dead-devices-2026',
    message: 'Cloud-dead smart devices sell for cheap. '
        'Grab one and liberate it.',
    cta: 'Shop',
    url: Uri.parse(AppConstants.shopUrl),
  );

  @override
  bool operator ==(Object other) =>
      other is AdBanner &&
      other.id == id &&
      other.message == message &&
      other.cta == cta &&
      other.url == url;

  @override
  int get hashCode => Object.hash(id, message, cta, url);
}

/// A parsed banner config document.
///
/// The published JSON has the shape
/// `{"version": 1, "banner": {"id": str, "message": str, "cta": str?,
/// "url": str, "enabled": bool?}}`.
///
/// [banner] is null for a config that is valid but has nothing to show — the
/// remote kill switch (`enabled: false`, a missing `banner`, or a config
/// version newer than this app understands). That is distinct from a document
/// that does not parse at all, which [tryParse] reports as null so the caller
/// keeps whatever it was already showing.
@immutable
class AdBannerConfig {
  /// The banner to show, or null to show none.
  final AdBanner? banner;

  const AdBannerConfig({required this.banner});

  /// The config version this app understands.
  static const int supportedVersion = 1;

  /// Caps that keep a hostile or corrupted config from producing a silly UI.
  static const int maxMessageChars = 200;
  static const int maxCtaChars = 40;
  static const int maxIdChars = 64;

  /// Parse and validate config JSON. Returns null when [jsonText] is not a
  /// well-formed config document at all; returns a config with a null [banner]
  /// when the document is valid but nothing should be shown.
  static AdBannerConfig? tryParse(String jsonText) {
    Object? decoded;
    try {
      decoded = jsonDecode(jsonText);
    } catch (_) {
      return null;
    }
    if (decoded is! Map<String, dynamic>) return null;
    final version = decoded['version'];
    if (version is! int || version < 1) return null;
    // A newer config format than this build understands: valid, show nothing.
    // Stale fallback content would be wrong more often than a quiet bottom bar.
    if (version > supportedVersion) return const AdBannerConfig(banner: null);

    final banner = decoded['banner'];
    if (banner == null) return const AdBannerConfig(banner: null);
    if (banner is! Map<String, dynamic>) return null;
    if (banner['enabled'] == false) return const AdBannerConfig(banner: null);

    final id = _boundedString(banner['id'], maxIdChars);
    final message = _boundedString(banner['message'], maxMessageChars);
    final urlText = banner['url'];
    if (id == null || message == null || urlText is! String) return null;
    final url = Uri.tryParse(urlText.trim());
    // https only: this config is fetched silently in the background, and the
    // one thing it can do is send the user somewhere. Never somewhere
    // unencrypted.
    if (url == null || url.scheme != 'https' || url.host.isEmpty) return null;
    final cta = _boundedString(banner['cta'], maxCtaChars) ?? 'Shop';

    return AdBannerConfig(
      banner: AdBanner(id: id, message: message, cta: cta, url: url),
    );
  }

  /// [value] as a trimmed non-empty string, truncated to [maxChars]; null when
  /// it is not a usable string.
  static String? _boundedString(Object? value, int maxChars) {
    if (value is! String) return null;
    final trimmed = value.trim();
    if (trimmed.isEmpty) return null;
    return trimmed.length > maxChars ? trimmed.substring(0, maxChars) : trimmed;
  }
}
