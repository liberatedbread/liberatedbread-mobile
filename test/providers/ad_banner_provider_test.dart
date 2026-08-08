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

const _remoteJson = '{"version": 1, "banner": {"id": "promo-2", '
    '"message": "Fresh deal.", "cta": "Go", '
    '"url": "https://liberatedbread.com/shop/"}}';

const _disabledJson = '{"version": 1, "banner": null}';

late SharedPreferences _prefs;

ProviderContainer _container(MockClientHandler handler) {
  final container = ProviderContainer(overrides: [
    sharedPreferencesProvider.overrideWithValue(_prefs),
    adBannerServiceProvider.overrideWithValue(
      AdBannerService(client: MockClient(handler)),
    ),
  ]);
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
    final container = _container((_) => throw http.ClientException('offline'));

    expect(container.read(adBannerProvider), AdBanner.fallback);
    // Give the failed refresh time to (wrongly) change state if it were going
    // to; then confirm nothing moved and nothing was cached.
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(container.read(adBannerProvider), AdBanner.fallback);
    expect(_prefs.getString(AdBannerNotifier.cacheKey), isNull);
  });

  test('a remote kill switch hides the banner and sticks for next launch',
      () async {
    final container =
        _container((_) async => http.Response(_disabledJson, 200));

    expect(container.read(adBannerProvider), AdBanner.fallback);
    await _until(() => container.read(adBannerProvider) == null);

    // A second container over the same prefs — "the next launch" — must seed
    // hidden from the cache, not flash the fallback first.
    final next = _container((_) async => http.Response(_disabledJson, 200));
    expect(next.read(adBannerProvider), isNull);
  });

  test('seeds from the cached config without waiting for the network',
      () async {
    SharedPreferences.setMockInitialValues(
        {AdBannerNotifier.cacheKey: _remoteJson});
    _prefs = await SharedPreferences.getInstance();
    // The network only ever fails; the cached banner must appear anyway.
    final container = _container((_) async => http.Response('', 500));

    expect(container.read(adBannerProvider)?.id, 'promo-2');
  });

  test('a corrupt cache falls back to the bundled banner', () async {
    SharedPreferences.setMockInitialValues(
        {AdBannerNotifier.cacheKey: '{not json'});
    _prefs = await SharedPreferences.getInstance();
    final container = _container((_) async => http.Response('', 500));

    expect(container.read(adBannerProvider), AdBanner.fallback);
  });

  test('dismiss hides the banner and persists per promotion id', () async {
    final container = _container((_) async => http.Response('', 500));
    expect(container.read(adBannerProvider), AdBanner.fallback);

    await container.read(adBannerProvider.notifier).dismiss();

    expect(container.read(adBannerProvider), isNull);
    expect(
        _prefs.getString(AdBannerNotifier.dismissedKey), AdBanner.fallback.id);

    // Next launch: same promotion stays hidden.
    final next = _container((_) async => http.Response('', 500));
    expect(next.read(adBannerProvider), isNull);
  });

  test('a new promotion id resurfaces after a dismissal', () async {
    SharedPreferences.setMockInitialValues(
        {AdBannerNotifier.dismissedKey: AdBanner.fallback.id});
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
    SharedPreferences.setMockInitialValues(
        {AdBannerNotifier.dismissedKey: 'promo-2'});
    _prefs = await SharedPreferences.getInstance();
    final container =
        _container((_) async => http.Response(dismissedRemote, 200));

    expect(container.read(adBannerProvider), AdBanner.fallback);
    // The fetch caches the config; the banner it names is dismissed, so the
    // fallback goes away and nothing replaces it.
    await _until(() => container.read(adBannerProvider) == null);
    expect(_prefs.getString(AdBannerNotifier.cacheKey), dismissedRemote);
  });
}
