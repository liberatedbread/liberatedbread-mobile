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
}) => jsonEncode({'version': version, 'banner': banner});

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
      final config = AdBannerConfig.tryParse(
        _config(
          banner: {
            'id': 'promo-1',
            'message': 'Buy dead devices cheap.',
            'url': 'https://liberatedbread.com/shop/',
          },
        ),
      );

      expect(config?.banner, isNotNull);
      expect(config!.banner!.cta, 'Shop');
    });

    test('enabled:false is the kill switch — valid config, no banner', () {
      final config = AdBannerConfig.tryParse(
        _config(
          banner: {
            'id': 'promo-1',
            'message': 'Buy dead devices cheap.',
            'url': 'https://liberatedbread.com/shop/',
            'enabled': false,
          },
        ),
      );

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
        AdBannerConfig.tryParse(
          _config(
            banner: {
              'message': 'no id',
              'url': 'https://liberatedbread.com/shop/',
            },
          ),
        ),
        isNull,
      );
      expect(
        AdBannerConfig.tryParse(
          _config(
            banner: {
              'id': 'promo-1',
              'url': 'https://liberatedbread.com/shop/',
            },
          ),
        ),
        isNull,
      );
      expect(
        AdBannerConfig.tryParse(
          _config(
            banner: {
              'id': 'promo-1',
              'message': '   ',
              'url': 'https://liberatedbread.com/shop/',
            },
          ),
        ),
        isNull,
      );
      expect(
        AdBannerConfig.tryParse(
          _config(banner: {'id': 'promo-1', 'message': 'no url'}),
        ),
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
          AdBannerConfig.tryParse(
            _config(banner: {'id': 'promo-1', 'message': 'msg', 'url': url}),
          ),
          isNull,
          reason: 'should reject $url',
        );
      }
    });

    test('caps runaway field lengths', () {
      final config = AdBannerConfig.tryParse(
        _config(
          banner: {
            'id': 'promo-1',
            'message': 'm' * 5000,
            'cta': 'c' * 5000,
            'url': 'https://liberatedbread.com/shop/',
          },
        ),
      );

      expect(config?.banner, isNotNull);
      expect(config!.banner!.message.length, AdBannerConfig.maxMessageChars);
      expect(config.banner!.cta.length, AdBannerConfig.maxCtaChars);
    });
  });

  group('targeted banners (targets[])', () {
    String withTargets(List<Map<String, Object?>> targets) => jsonEncode({
      'version': 1,
      'banner': {
        'id': 'global',
        'message': 'Shop.',
        'url': 'https://liberatedbread.com/shop/',
      },
      'targets': targets,
    });

    Map<String, Object?> target({
      String id = 't1',
      Object? match = const {
        'spec_keys': ['Brother QL|Brother'],
      },
      int? priority,
      bool? enabled,
      String url = 'https://liberatedbread.com/shop/labels/',
    }) => {
      'id': id,
      'message': 'Labels.',
      'cta': 'Buy',
      'url': url,
      'match': ?match,
      'priority': ?priority,
      'enabled': ?enabled,
    };

    test('parses spec_keys and categories under version 1 (additive)', () {
      final config = AdBannerConfig.tryParse(
        withTargets([
          target(
            match: {
              'spec_keys': ['Brother QL|Brother'],
              'categories': ['printer'],
            },
          ),
        ]),
      );
      expect(config, isNotNull);
      expect(config!.banner?.id, 'global');
      expect(config.targets, hasLength(1));
      final m = config.targets.single.match!;
      expect(m.specKeys, ['Brother QL|Brother']);
      expect(m.categories, ['printer']);
    });

    test('bestFor prefers spec_key, then category, then the global banner', () {
      final config = AdBannerConfig.tryParse(
        withTargets([
          target(
            id: 'byspec',
            match: {
              'spec_keys': ['Brother QL|Brother'],
            },
          ),
          target(
            id: 'bycat',
            match: {
              'categories': ['printer'],
            },
          ),
        ]),
      )!;
      expect(
        config.bestFor(category: 'printer', specKey: 'Brother QL|Brother')?.id,
        'byspec',
      );
      expect(
        config.bestFor(category: 'printer', specKey: 'Other|X')?.id,
        'bycat',
      );
      expect(
        config.bestFor(category: 'light', specKey: 'Bulb|X')?.id,
        'global',
      );
    });

    test('within a tier, higher priority wins', () {
      final config = AdBannerConfig.tryParse(
        withTargets([
          target(id: 'low', priority: 1),
          target(id: 'high', priority: 10),
        ]),
      )!;
      expect(config.bestFor(specKey: 'Brother QL|Brother')?.id, 'high');
    });

    test('exclude skips a tier and falls through', () {
      final config = AdBannerConfig.tryParse(
        withTargets([
          target(
            id: 'byspec',
            match: {
              'spec_keys': ['Brother QL|Brother'],
            },
          ),
          target(
            id: 'bycat',
            match: {
              'categories': ['printer'],
            },
          ),
        ]),
      )!;
      expect(
        config
            .bestFor(
              category: 'printer',
              specKey: 'Brother QL|Brother',
              exclude: {'byspec'},
            )
            ?.id,
        'bycat',
      );
      expect(
        config.bestFor(
          category: 'printer',
          specKey: 'Brother QL|Brother',
          exclude: {'byspec', 'bycat', 'global'},
        ),
        isNull,
      );
    });

    test('a target with no match axis is dropped, not treated as global', () {
      final config = AdBannerConfig.tryParse(
        withTargets([
          target(id: 'nomatch', match: null),
          target(
            id: 'empty',
            match: const {'spec_keys': <String>[], 'categories': <String>[]},
          ),
          target(id: 'good'),
        ]),
      )!;
      expect(config.targets.map((t) => t.id), ['good']);
    });

    test('an invalid or disabled target is dropped without failing the doc', () {
      final config = AdBannerConfig.tryParse(
        withTargets([
          target(id: 'nonhttps', url: 'http://liberatedbread.com/x/'),
          target(id: 'off', enabled: false),
          target(id: 'good'),
        ]),
      )!;
      // The document still parses (global banner intact) and only 'good' stays.
      expect(config.banner?.id, 'global');
      expect(config.targets.map((t) => t.id), ['good']);
    });

    test('caps the number of targets', () {
      final many = [
        for (var i = 0; i < AdBannerConfig.maxTargets + 10; i++)
          target(id: 't$i'),
      ];
      final config = AdBannerConfig.tryParse(withTargets(many))!;
      expect(config.targets.length, AdBannerConfig.maxTargets);
    });

    test('absent targets is simply no targets (old configs unaffected)', () {
      final config = AdBannerConfig.tryParse(
        jsonEncode({
          'version': 1,
          'banner': {
            'id': 'global',
            'message': 'Shop.',
            'url': 'https://liberatedbread.com/shop/',
          },
        }),
      )!;
      expect(config.targets, isEmpty);
    });
  });

  group('AdBannerConfig.bundled', () {
    test('the label-supplies promo targets the Brother QL label printer', () {
      // The specKey is `deviceName|manufacturer` verbatim from the catalogue;
      // if the spec renames upstream this asserts the bundled fallback drifted.
      final banner = AdBannerConfig.bundled.bestFor(
        category: 'printer',
        specKey: 'Brother QL-1110NWB Label Printer|Brother Industries',
      );
      expect(banner?.id, 'label-supplies-2026');
    });

    test('a 3D printer does NOT get the label-supplies promo', () {
      // Both are category `printer`; spec-key targeting is what keeps a 3D
      // printer from being told to buy label rolls.
      final banner = AdBannerConfig.bundled.bestFor(
        category: 'printer',
        specKey: 'Snapmaker U1 Multi-Color 3D Printer|Snapmaker',
      );
      expect(banner?.id, isNot('label-supplies-2026'));
    });

    test('a Rabbit Air gets the filter promo', () {
      final banner = AdBannerConfig.bundled.bestFor(
        category: 'climate',
        specKey:
            'Rabbit Air MinusA2 (SPA-700A/SPA-780A) / A3 (SPA-1000N) / '
            'BioGS 2.0 (SPA-550A/SPA-625A)|Rabbit Air',
      );
      expect(banner?.id, 'air-filter-2026');
    });

    test('every bundled config survives its own parser', () {
      // Round-trip the bundled config through the JSON contract so bundled
      // content the parser would reject cannot ship.
      final json = jsonEncode({
        'version': 1,
        'banner': {
          'id': AdBanner.fallback.id,
          'message': AdBanner.fallback.message,
          'cta': AdBanner.fallback.cta,
          'url': AdBanner.fallback.url.toString(),
        },
        'targets': [
          for (final t in AdBanner.bundledTargets)
            {
              'id': t.id,
              'message': t.message,
              'cta': t.cta,
              'url': t.url.toString(),
              'priority': t.priority,
              'match': {
                'spec_keys': t.match!.specKeys,
                'categories': t.match!.categories,
              },
            },
        ],
      });
      final parsed = AdBannerConfig.tryParse(json);
      expect(parsed, isNotNull);
      expect(parsed!.targets, hasLength(AdBanner.bundledTargets.length));
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
      final config = AdBannerConfig.tryParse(
        jsonEncode({
          'version': AdBannerConfig.supportedVersion,
          'banner': {
            'id': AdBanner.fallback.id,
            'message': AdBanner.fallback.message,
            'cta': AdBanner.fallback.cta,
            'url': AdBanner.fallback.url.toString(),
            'enabled': true,
          },
        }),
      );

      expect(config?.banner, AdBanner.fallback);
    });
  });
}
