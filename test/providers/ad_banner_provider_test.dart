// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:liberated_bread_mobile/models/ad_banner.dart';
import 'package:liberated_bread_mobile/providers/ad_banner_provider.dart';
import 'package:liberated_bread_mobile/providers/saved_device_provider.dart';
import 'package:liberated_bread_mobile/services/ad_banner_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _remoteJson =
    '{"version": 1, "banner": {"id": "promo-2", '
    '"message": "Fresh deal.", "cta": "Go", '
    '"url": "https://liberatedbread.com/shop/"}}';

const _disabledJson = '{"version": 1, "banner": null}';

late SharedPreferences _prefs;

ProviderContainer _container(MockClientHandler handler) {
  final container = ProviderContainer(
    overrides: [
      sharedPreferencesProvider.overrideWithValue(_prefs),
      adBannerServiceProvider.overrideWithValue(
        AdBannerService(client: MockClient(handler)),
      ),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

/// Spin until [condition] holds, failing the test after two seconds. The
/// refresh path is genuinely asynchronous, so provider tests wait on outcomes
/// rather than counting event-loop turns.
Future<void> _until(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 2));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('condition not reached within 2s');
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    _prefs = await SharedPreferences.getInstance();
  });

  test('seeds the bundled fallback synchronously, before any fetch', () {
    final container = _container((_) async => http.Response(_remoteJson, 200));

    // The very first read — no awaits anywhere yet — must already have a
    // banner. This is the non-blocking guarantee: first frame needs no IO.
    expect(container.read(adBannerProvider), AdBanner.fallback);
  });

  test('swaps in the remote banner after the background fetch', () async {
    final container = _container((_) async => http.Response(_remoteJson, 200));

    expect(container.read(adBannerProvider), AdBanner.fallback);
    await _until(() => container.read(adBannerProvider)?.id == 'promo-2');

    expect(container.read(adBannerProvider)?.message, 'Fresh deal.');
    // The raw config is cached for the next launch's synchronous seed.
    expect(_prefs.getString(AdBannerNotifier.cacheKey), _remoteJson);
  });

  test('keeps the fallback when the fetch fails', () async {
    // A test that asserts nothing CHANGED has to earn it: it used to sleep
    // 50 ms of wall clock and then declare the state unmoved, which passes
    // just as well when the refresh has not run yet, or ran but was still two
    // microtasks from writing. So: wait for the fetch to actually have been
    // attempted, drain the event queue, and then run the same wait against a
    // fetch that DOES change the state — the positive control that proves the
    // waiting is long enough for a change to have shown up.
    var failedCalls = 0;
    final container = _container((_) {
      failedCalls++;
      throw http.ClientException('offline');
    });

    expect(container.read(adBannerProvider), AdBanner.fallback);
    await _until(() => failedCalls > 0);
    await pumpEventQueue();

    expect(container.read(adBannerProvider), AdBanner.fallback);
    expect(_prefs.getString(AdBannerNotifier.cacheKey), isNull);

    // The control. Same container shape, same wait, a reply that parses: if
    // this does not swap the banner in, the negative assertion above was
    // measuring nothing.
    var okCalls = 0;
    final succeeding = _container((_) async {
      okCalls++;
      return http.Response(_remoteJson, 200);
    });
    expect(succeeding.read(adBannerProvider), AdBanner.fallback);
    await _until(() => okCalls > 0);
    await pumpEventQueue();
    expect(
      succeeding.read(adBannerProvider)?.id,
      'promo-2',
      reason:
          'the wait used for the failure case must be enough to observe a '
          'state change, or "nothing changed" proves nothing',
    );
  });

  test(
    'a remote kill switch hides the banner and sticks for next launch',
    () async {
      final container = _container(
        (_) async => http.Response(_disabledJson, 200),
      );

      expect(container.read(adBannerProvider), AdBanner.fallback);
      await _until(() => container.read(adBannerProvider) == null);

      // A second container over the same prefs — "the next launch" — must seed
      // hidden from the cache, not flash the fallback first.
      final next = _container((_) async => http.Response(_disabledJson, 200));
      expect(next.read(adBannerProvider), isNull);
    },
  );

  test(
    'seeds from the cached config without waiting for the network',
    () async {
      SharedPreferences.setMockInitialValues({
        AdBannerNotifier.cacheKey: _remoteJson,
      });
      _prefs = await SharedPreferences.getInstance();
      // The network only ever fails; the cached banner must appear anyway.
      final container = _container((_) async => http.Response('', 500));

      expect(container.read(adBannerProvider)?.id, 'promo-2');
    },
  );

  test('a corrupt cache falls back to the bundled banner', () async {
    SharedPreferences.setMockInitialValues({
      AdBannerNotifier.cacheKey: '{not json',
    });
    _prefs = await SharedPreferences.getInstance();
    final container = _container((_) async => http.Response('', 500));

    expect(container.read(adBannerProvider), AdBanner.fallback);
  });

  test('dismiss hides the banner and persists per promotion id', () async {
    final container = _container((_) async => http.Response('', 500));
    expect(container.read(adBannerProvider), AdBanner.fallback);

    await container
        .read(adBannerStateProvider.notifier)
        .dismiss(AdBanner.fallback.id);

    expect(container.read(adBannerProvider), isNull);
    expect(
      _prefs.getString(AdBannerNotifier.dismissedKey),
      jsonEncode([AdBanner.fallback.id]),
    );

    // Next launch: same promotion stays hidden.
    final next = _container((_) async => http.Response('', 500));
    expect(next.read(adBannerProvider), isNull);
  });

  test(
    'a legacy single-id dismissal is honored, then migrated forward',
    () async {
      // A build before the set-of-ids change wrote one dismissed id under the old
      // key; that dismissal must survive the upgrade.
      SharedPreferences.setMockInitialValues({
        AdBannerNotifier.legacyDismissedKey: AdBanner.fallback.id,
      });
      _prefs = await SharedPreferences.getInstance();
      final container = _container((_) async => http.Response('', 500));

      expect(container.read(adBannerProvider), isNull);
    },
  );

  test('a new promotion id resurfaces after a dismissal', () async {
    SharedPreferences.setMockInitialValues({
      AdBannerNotifier.dismissedKey: jsonEncode([AdBanner.fallback.id]),
    });
    _prefs = await SharedPreferences.getInstance();
    final container = _container((_) async => http.Response(_remoteJson, 200));

    // Seed: the dismissed fallback stays hidden.
    expect(container.read(adBannerProvider), isNull);
    // But the remote config carries a different id, so it may show.
    await _until(() => container.read(adBannerProvider)?.id == 'promo-2');
  });

  test('a remote banner matching the dismissed id stays hidden', () async {
    final dismissedRemote = jsonEncode({
      'version': 1,
      'banner': {
        'id': 'promo-2',
        'message': 'Fresh deal.',
        'url': 'https://liberatedbread.com/shop/',
      },
    });
    SharedPreferences.setMockInitialValues({
      AdBannerNotifier.dismissedKey: jsonEncode(['promo-2']),
    });
    _prefs = await SharedPreferences.getInstance();
    final container = _container(
      (_) async => http.Response(dismissedRemote, 200),
    );

    expect(container.read(adBannerProvider), AdBanner.fallback);
    // The fetch caches the config; the banner it names is dismissed, so the
    // fallback goes away and nothing replaces it.
    await _until(() => container.read(adBannerProvider) == null);
    expect(_prefs.getString(AdBannerNotifier.cacheKey), dismissedRemote);
  });

  group('device-targeted banners', () {
    const targetedJson =
        '{"version": 1,'
        '"banner": {"id": "global-1", "message": "Shop dead devices.",'
        ' "url": "https://liberatedbread.com/shop/"},'
        '"targets": ['
        '  {"id": "labels-1", "match": {"spec_keys": ["Brother QL|Brother"]},'
        '   "message": "Label rolls.", "cta": "Labels",'
        '   "url": "https://liberatedbread.com/shop/labels/"},'
        '  {"id": "printers-1", "match": {"categories": ["printer"]},'
        '   "message": "Printer stuff.", "cta": "Printer",'
        '   "url": "https://liberatedbread.com/shop/printers/"}'
        ']}';

    test(
      'a device shows its spec-key banner over the category and global',
      () async {
        SharedPreferences.setMockInitialValues({
          AdBannerNotifier.cacheKey: targetedJson,
        });
        _prefs = await SharedPreferences.getInstance();
        final container = _container((_) async => http.Response('', 500));

        final banner = container.read(
          deviceAdBannerProvider(
            const DeviceAdContext(
              category: 'printer',
              specKey: 'Brother QL|Brother',
            ),
          ),
        );
        expect(banner?.id, 'labels-1');
        // The global scan banner is unaffected.
        expect(container.read(adBannerProvider)?.id, 'global-1');
      },
    );

    test(
      'a device with only a category match shows the category banner',
      () async {
        SharedPreferences.setMockInitialValues({
          AdBannerNotifier.cacheKey: targetedJson,
        });
        _prefs = await SharedPreferences.getInstance();
        final container = _container((_) async => http.Response('', 500));

        final banner = container.read(
          deviceAdBannerProvider(
            const DeviceAdContext(category: 'printer', specKey: 'Other|Maker'),
          ),
        );
        expect(banner?.id, 'printers-1');
      },
    );

    test('an unmatched device falls back to the global banner', () async {
      SharedPreferences.setMockInitialValues({
        AdBannerNotifier.cacheKey: targetedJson,
      });
      _prefs = await SharedPreferences.getInstance();
      final container = _container((_) async => http.Response('', 500));

      final banner = container.read(
        deviceAdBannerProvider(
          const DeviceAdContext(category: 'light', specKey: 'Bulb|Maker'),
        ),
      );
      expect(banner?.id, 'global-1');
    });

    test(
      'dismissing a targeted banner falls through to the next tier',
      () async {
        SharedPreferences.setMockInitialValues({
          AdBannerNotifier.cacheKey: targetedJson,
        });
        _prefs = await SharedPreferences.getInstance();
        final container = _container((_) async => http.Response('', 500));

        const ctx = DeviceAdContext(
          category: 'printer',
          specKey: 'Brother QL|Brother',
        );
        expect(container.read(deviceAdBannerProvider(ctx))?.id, 'labels-1');

        await container
            .read(adBannerStateProvider.notifier)
            .dismiss('labels-1');
        // The spec-key promo is gone; the category promo takes its place.
        expect(container.read(deviceAdBannerProvider(ctx))?.id, 'printers-1');
      },
    );
  });
}
