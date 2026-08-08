// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/core/constants.dart';
import 'package:liberated_bread_mobile/models/ad_banner.dart';

String _config({
  Object? version = 1,
  Object? banner = const {
    'id': 'promo-1',
    'message': 'Buy dead devices cheap.',
    'cta': 'Shop deals',
    'url': 'https://liberatedbread.com/shop/',
    'enabled': true,
  },
}) =>
    jsonEncode({'version': version, 'banner': banner});

void main() {
  group('AdBannerConfig.tryParse', () {
    test('parses a full valid config', () {
      final config = AdBannerConfig.tryParse(_config());

      expect(config, isNotNull);
      final banner = config!.banner;
      expect(banner, isNotNull);
      expect(banner!.id, 'promo-1');
      expect(banner.message, 'Buy dead devices cheap.');
      expect(banner.cta, 'Shop deals');
      expect(banner.url, Uri.parse('https://liberatedbread.com/shop/'));
    });

    test('cta and enabled are optional', () {
      final config = AdBannerConfig.tryParse(_config(banner: {
        'id': 'promo-1',
        'message': 'Buy dead devices cheap.',
        'url': 'https://liberatedbread.com/shop/',
      }));

      expect(config?.banner, isNotNull);
      expect(config!.banner!.cta, 'Shop');
    });

    test('enabled:false is the kill switch — valid config, no banner', () {
      final config = AdBannerConfig.tryParse(_config(banner: {
        'id': 'promo-1',
        'message': 'Buy dead devices cheap.',
        'url': 'https://liberatedbread.com/shop/',
        'enabled': false,
      }));

      expect(config, isNotNull);
      expect(config!.banner, isNull);
    });

    test('a missing banner is valid and shows nothing', () {
      final config = AdBannerConfig.tryParse(jsonEncode({'version': 1}));

      expect(config, isNotNull);
      expect(config!.banner, isNull);
    });

    test('a newer config version is valid and shows nothing', () {
      // Forward-compat: a v2 schema may mean anything, so an old app must not
      // guess — but it must also not treat the document as corrupt and pin the
      // bundled fallback forever.
      final config = AdBannerConfig.tryParse(_config(version: 2));

      expect(config, isNotNull);
      expect(config!.banner, isNull);
    });

    test('rejects documents that are not a versioned config', () {
      expect(AdBannerConfig.tryParse('not json'), isNull);
      expect(AdBannerConfig.tryParse('[]'), isNull);
      expect(AdBannerConfig.tryParse('"str"'), isNull);
      expect(AdBannerConfig.tryParse(jsonEncode({'banner': null})), isNull);
      expect(AdBannerConfig.tryParse(_config(version: '1')), isNull);
      expect(AdBannerConfig.tryParse(_config(version: 0)), isNull);
      expect(AdBannerConfig.tryParse(_config(banner: 'yes')), isNull);
    });

    test('rejects banners missing required fields', () {
      expect(
        AdBannerConfig.tryParse(_config(banner: {
          'message': 'no id',
          'url': 'https://liberatedbread.com/shop/',
        })),
        isNull,
      );
      expect(
        AdBannerConfig.tryParse(_config(banner: {
          'id': 'promo-1',
          'url': 'https://liberatedbread.com/shop/',
        })),
        isNull,
      );
      expect(
        AdBannerConfig.tryParse(_config(banner: {
          'id': 'promo-1',
          'message': '   ',
          'url': 'https://liberatedbread.com/shop/',
        })),
        isNull,
      );
      expect(
        AdBannerConfig.tryParse(_config(banner: {
          'id': 'promo-1',
          'message': 'no url',
        })),
        isNull,
      );
    });

    test('rejects non-https and unparseable URLs', () {
      for (final url in [
        'http://liberatedbread.com/shop/',
        'ftp://liberatedbread.com/',
        'javascript:alert(1)',
        'https://',
        '::not a url::',
      ]) {
        expect(
          AdBannerConfig.tryParse(_config(banner: {
            'id': 'promo-1',
            'message': 'msg',
            'url': url,
          })),
          isNull,
          reason: 'should reject $url',
        );
      }
    });

    test('caps runaway field lengths', () {
      final config = AdBannerConfig.tryParse(_config(banner: {
        'id': 'promo-1',
        'message': 'm' * 5000,
        'cta': 'c' * 5000,
        'url': 'https://liberatedbread.com/shop/',
      }));

      expect(config?.banner, isNotNull);
      expect(config!.banner!.message.length, AdBannerConfig.maxMessageChars);
      expect(config.banner!.cta.length, AdBannerConfig.maxCtaChars);
    });
  });

  group('AdBanner.fallback', () {
    test('points at the shop page over https', () {
      expect(AdBanner.fallback.url.toString(), AppConstants.shopUrl);
      expect(AdBanner.fallback.url.scheme, 'https');
    });

    test('would survive its own parser', () {
      // The fallback mirrors the published banner.json; if it ever grows
      // content the parser would reject, the two have drifted.
      final config = AdBannerConfig.tryParse(jsonEncode({
        'version': AdBannerConfig.supportedVersion,
        'banner': {
          'id': AdBanner.fallback.id,
          'message': AdBanner.fallback.message,
          'cta': AdBanner.fallback.cta,
          'url': AdBanner.fallback.url.toString(),
          'enabled': true,
        },
      }));

      expect(config?.banner, AdBanner.fallback);
    });
  });
}
