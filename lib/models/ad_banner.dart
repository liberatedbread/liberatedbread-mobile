// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../core/constants.dart';

/// One house ad. The global promotion shown on the scan screen, or — when
/// [match] is non-null — a promotion targeted at a device of a particular
/// category or matched spec (e.g. label-roll supplies for a label printer,
/// filter kits for a Rabbit Air).
///
/// Banners are described by a remote JSON config (see [AdBannerConfig]) so the
/// promotion can change — or be switched off — without an app-store release.
/// [fallback]/[bundledTargets] are the bundled copy of the same content, shown
/// until a fetch has ever succeeded so the banner works offline and on a slow
/// first launch.
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

  /// What device this promotion is for, or null for the global banner. A
  /// targeted banner is only ever shown against a device it matches.
  final AdBannerMatch? match;

  /// Ranks a targeted banner against other targeted banners that also match
  /// (higher wins; ties fall back to config order). Ignored for the global
  /// banner. Defaults to 0.
  final int priority;

  const AdBanner({
    required this.id,
    required this.message,
    required this.cta,
    required this.url,
    this.match,
    this.priority = 0,
  });

  /// The bundled global banner, mirroring the `banner` published at
  /// [AppConstants.adBannerConfigUrl] when this build shipped.
  static final AdBanner fallback = AdBanner(
    id: 'dead-devices-2026',
    message:
        'Cloud-dead smart devices sell for cheap. '
        'Grab one and liberate it.',
    cta: 'Shop',
    url: Uri.parse(AppConstants.shopUrl),
  );

  /// The bundled targeted banners, mirroring the `targets` published at
  /// [AppConstants.adBannerConfigUrl] when this build shipped. These are what a
  /// first, offline launch shows against a matched device before any remote
  /// fetch; the live config can add, retune or switch any of them off without
  /// an app release. Deliberately keyed by spec identity where a category would
  /// over-match: a label printer, a 3D printer and a UV printer are all
  /// `category: printer`, so label-roll supplies must target the spec, not the
  /// class.
  static final List<AdBanner> bundledTargets = [
    AdBanner(
      id: 'label-supplies-2026',
      message: 'Running low on labels? Rolls and refills for your printer.',
      cta: 'Label supplies',
      url: Uri.parse('${AppConstants.shopUrl}label-printer-supplies/'),
      priority: 20,
      // specKeyFor is `"deviceName|manufacturer"` verbatim from the spec, so
      // these are the exact (long) strings the catalogue ships. Brittle by
      // design — a rename upstream orphans a bundled key — but harmless: an
      // unmatched target just falls back to the global banner, and the live
      // banner.json (owner-updatable without a release) is the real source.
      match: const AdBannerMatch(
        specKeys: [
          'Brother QL-1110NWB Label Printer|Brother Industries',
          'NIIMBOT D110 / B21 Thermal Label Printer|NIIMBOT (Wuhan Jingchen '
              'Intelligent Identification Technology Co., Ltd., FCC ID 2ARXB)',
          'Fichero / AiYin D11 Thermal Label Printer|Xiamen Print Future '
              'Technology Co., Ltd',
          'Cat Printer Mini Thermal Printer|Unbranded / Yu Tian (YT01) / '
              'various OEMs',
          'Cat Printer MXW01 Mini Thermal Printer|Unbranded / various OEMs',
        ],
      ),
    ),
    // UV printer inks + 3D-printable refill jig. No eufy-make-e1 device spec
    // exists in the catalogue yet, so this matches nothing today; it is here so
    // the promotion is ready the moment that spec (and its specKey) land, and
    // the live banner.json can carry the real key ahead of an app release.
    AdBanner(
      id: 'uv-ink-2026',
      message: 'UV printer inks — plus our free 3D-printable refill jig.',
      cta: 'UV inks',
      url: Uri.parse('${AppConstants.shopUrl}uv-printer-ink/'),
      priority: 20,
      match: const AdBannerMatch(
        specKeys: ['eufyMake E1 UV Printer|eufy (Anker Innovations)'],
      ),
    ),
    AdBanner(
      id: 'air-filter-2026',
      message: 'Time for a fresh filter? Genuine Rabbit Air filter kits.',
      cta: 'Filters',
      url: Uri.parse('${AppConstants.shopUrl}air-filters/'),
      priority: 20,
      match: const AdBannerMatch(
        specKeys: [
          'Rabbit Air MinusA2 (SPA-700A/SPA-780A) / A3 (SPA-1000N) / '
              'BioGS 2.0 (SPA-550A/SPA-625A)|Rabbit Air',
        ],
      ),
    ),
  ];

  @override
  bool operator ==(Object other) =>
      other is AdBanner &&
      other.id == id &&
      other.message == message &&
      other.cta == cta &&
      other.url == url &&
      other.match == match &&
      other.priority == priority;

  @override
  int get hashCode => Object.hash(id, message, cta, url, match, priority);
}

/// What device a targeted [AdBanner] is for. A banner matches a device when its
/// [specKeys] contains that device's `specKeyFor` identity, or its [categories]
/// contains that device's `device.category`. `specKeys` is the precise axis
/// (one product); `categories` is the broad one (a whole class). Empty lists
/// mean "this axis names nothing"; a match with no axis at all is rejected at
/// parse time, since it would match every device and shadow the global banner.
@immutable
class AdBannerMatch {
  /// `specKeyFor` identities (`"deviceName|manufacturer"`) this promotion is
  /// for. The precise axis: matches exactly one product's spec.
  final List<String> specKeys;

  /// `device.category` wire values (e.g. `printer`, `climate`) this promotion
  /// is for. The broad axis: matches a whole device class.
  final List<String> categories;

  const AdBannerMatch({this.specKeys = const [], this.categories = const []});

  bool get isEmpty => specKeys.isEmpty && categories.isEmpty;

  bool matchesSpecKey(String? specKey) =>
      specKey != null && specKeys.contains(specKey);

  bool matchesCategory(String? category) =>
      category != null && categories.contains(category);

  @override
  bool operator ==(Object other) =>
      other is AdBannerMatch &&
      listEquals(other.specKeys, specKeys) &&
      listEquals(other.categories, categories);

  @override
  int get hashCode =>
      Object.hash(Object.hashAll(specKeys), Object.hashAll(categories));
}

/// A parsed banner config document.
///
/// The published JSON has the shape
/// `{"version": 1, "banner": {global banner}?, "targets": [targeted banner]?}`.
/// A targeted banner adds a `match` object (`{"spec_keys": [...],
/// "categories": [...]}`) and an optional integer `priority`.
///
/// [banner] is null for a config that is valid but has nothing global to show —
/// the remote kill switch (`enabled: false`, a missing `banner`, or a config
/// version newer than this app understands). That is distinct from a document
/// that does not parse at all, which [tryParse] reports as null so the caller
/// keeps whatever it was already showing.
///
/// `targets` is an ADDITIVE, backward-compatible extension: it lives under the
/// SAME `version: 1`, because a config whose `version` an app does not
/// recognise is shown as nothing at all (forward-compat kill switch). An older
/// build simply ignores the unknown `targets` key and shows only `banner`.
@immutable
class AdBannerConfig {
  /// The global banner to show, or null to show none.
  final AdBanner? banner;

  /// Device-targeted banners, best-first is NOT assumed — selection ranks by
  /// [AdBanner.priority] then order. Empty when the config declares none.
  final List<AdBanner> targets;

  const AdBannerConfig({required this.banner, this.targets = const []});

  /// The config version this app understands.
  static const int supportedVersion = 1;

  /// Caps that keep a hostile or corrupted config from producing a silly UI.
  static const int maxMessageChars = 200;
  static const int maxCtaChars = 40;
  static const int maxIdChars = 64;

  /// Most targeted banners we will keep from one config, so a hostile document
  /// cannot make selection walk an unbounded list. The real catalogue is a
  /// handful.
  static const int maxTargets = 32;

  /// The bundled config: the global fallback plus the bundled targeted banners.
  /// This is the synchronous seed for a first, offline launch.
  static AdBannerConfig get bundled => AdBannerConfig(
    banner: AdBanner.fallback,
    targets: AdBanner.bundledTargets,
  );

  /// The best banner to show for a device with [category]/[specKey], or null.
  ///
  /// A spec-key-targeted banner wins over a category-targeted one (a product
  /// beats its class); within each axis, higher [AdBanner.priority] wins, then
  /// config order. Falls back to the global [banner] when nothing targets the
  /// device — so a device screen always shows the most relevant promo it can.
  /// Ids in [exclude] (banners the user dismissed) are skipped at every tier,
  /// so dismissing the top promo falls through to the next, then to the global.
  AdBanner? bestFor({
    String? category,
    String? specKey,
    Set<String> exclude = const {},
  }) {
    AdBanner? bestAmong(Iterable<AdBanner> candidates) {
      AdBanner? best;
      for (final b in candidates) {
        if (exclude.contains(b.id)) continue;
        if (best == null || b.priority > best.priority) best = b;
      }
      return best;
    }

    final bySpec = bestAmong(
      targets.where((b) => b.match?.matchesSpecKey(specKey) ?? false),
    );
    if (bySpec != null) return bySpec;
    final byCategory = bestAmong(
      targets.where((b) => b.match?.matchesCategory(category) ?? false),
    );
    if (byCategory != null) return byCategory;
    if (banner != null && !exclude.contains(banner!.id)) return banner;
    return null;
  }

  /// Parse and validate config JSON. Returns null when [jsonText] is not a
  /// well-formed config document at all; returns a config with a null [banner]
  /// when the document is valid but nothing global should be shown.
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

    // Top-level kill switch: `enabled: false` at the root turns off EVERY ad —
    // global and targeted alike. Before targeted banners existed, disabling the
    // one `banner` was "ads off"; that no longer suppresses `targets`, so this
    // is the switch that still means all-off, in one place.
    if (decoded['enabled'] == false) return const AdBannerConfig(banner: null);

    // The global banner: null (kill switch) is valid; a non-map or an invalid
    // banner object fails the whole document, as before.
    final bannerRaw = decoded['banner'];
    AdBanner? banner;
    if (bannerRaw != null) {
      if (bannerRaw is! Map<String, dynamic>) return null;
      if (bannerRaw['enabled'] != false) {
        banner = _parseBanner(bannerRaw, match: null);
        if (banner == null) return null;
      }
    }

    // Targeted banners: additive and independent — a malformed or disabled
    // entry is DROPPED, never fails the document, so one bad promo cannot take
    // the whole config (and with it the kill switch) down. Absent/!list ==
    // none.
    final targets = <AdBanner>[];
    final targetsRaw = decoded['targets'];
    if (targetsRaw is List) {
      for (final item in targetsRaw) {
        if (targets.length >= maxTargets) break;
        if (item is! Map<String, dynamic>) continue;
        if (item['enabled'] == false) continue;
        final match = _parseMatch(item['match']);
        if (match == null) continue; // a target with no match is not a target
        final b = _parseBanner(item, match: match);
        if (b != null) targets.add(b);
      }
    }

    return AdBannerConfig(banner: banner, targets: targets);
  }

  /// Parse one banner object (global or targeted). [match] is attached as-is;
  /// null for the global banner. Returns null when a required field is missing
  /// or the URL is not a usable https URL.
  static AdBanner? _parseBanner(
    Map<String, dynamic> raw, {
    required AdBannerMatch? match,
  }) {
    final id = _boundedString(raw['id'], maxIdChars);
    final message = _boundedString(raw['message'], maxMessageChars);
    final urlText = raw['url'];
    if (id == null || message == null || urlText is! String) return null;
    final url = Uri.tryParse(urlText.trim());
    // https only: this config is fetched silently in the background, and the
    // one thing it can do is send the user somewhere. Never somewhere
    // unencrypted.
    if (url == null || url.scheme != 'https' || url.host.isEmpty) return null;
    final cta = _boundedString(raw['cta'], maxCtaChars) ?? 'Shop';
    final priorityRaw = raw['priority'];
    final priority = priorityRaw is int ? priorityRaw : 0;
    return AdBanner(
      id: id,
      message: message,
      cta: cta,
      url: url,
      match: match,
      priority: priority,
    );
  }

  /// Parse a `match` object into an [AdBannerMatch], or null when it names no
  /// axis (a match that targets everything is rejected — it would shadow the
  /// global banner on every device).
  static AdBannerMatch? _parseMatch(Object? raw) {
    if (raw is! Map<String, dynamic>) return null;
    List<String> stringList(Object? value) => value is List
        ? [
            for (final v in value)
              if (v is String && v.trim().isNotEmpty) v.trim(),
          ]
        : const [];
    final match = AdBannerMatch(
      specKeys: stringList(raw['spec_keys']),
      categories: stringList(raw['categories']),
    );
    return match.isEmpty ? null : match;
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
