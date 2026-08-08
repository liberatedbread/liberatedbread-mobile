// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import '../core/constants.dart';
import '../core/log.dart';
import '../models/ad_banner.dart';
import '../services/ad_banner_service.dart';
import 'ble_provider.dart' show isMockMode;
import 'saved_device_provider.dart';

/// The banner-config fetcher. Tests override with a service on a mocked
/// http client.
final adBannerServiceProvider = Provider<AdBannerService>((ref) {
  final client = http.Client();
  ref.onDispose(client.close);
  return AdBannerService(client: client);
});

/// The banner to show at the bottom of the scan screen, or null for none.
///
/// Deliberately non-blocking: [AdBannerNotifier.build] is synchronous — it
/// seeds from the last successfully fetched config (cached in
/// SharedPreferences) or the bundled [AdBanner.fallback], so the first frame
/// never waits on the network. The remote refresh runs fire-and-forget in the
/// background and only ever swaps the state after the fact; if it fails, the
/// seed simply stays.
final adBannerProvider =
    NotifierProvider<AdBannerNotifier, AdBanner?>(AdBannerNotifier.new);

class AdBannerNotifier extends Notifier<AdBanner?> {
  /// Raw JSON of the last config a fetch successfully parsed.
  static const cacheKey = 'ad_banner_config_json';

  /// Id of the banner the user last dismissed. That banner stays hidden until
  /// a config ships a different id.
  static const dismissedKey = 'ad_banner_dismissed_id';

  @override
  AdBanner? build() {
    // Guards the background refresh: after the container is disposed, writing
    // state would throw into an unawaited future.
    var disposed = false;
    ref.onDispose(() => disposed = true);

    // MOCK MODE MAKES NO OUTBOUND REQUEST.
    //
    // Mock mode is the app's established "no real hardware, no external
    // dependencies" switch — it is what swaps RealBleService for the mock —
    // and every automated device run passes it. Firing a background HTTPS
    // request to liberatedbread.com under it made the iOS simulator, Android
    // emulator and Linux desktop jobs depend on that host being reachable, in
    // a fetch whose whole design is that nobody waits for it.
    //
    // It did not fail quietly either. adBannerServiceProvider closes its
    // http.Client on dispose, and closing it while a connect is still in
    // flight makes dart:io deliver
    //
    //   SocketException: Connection attempt cancelled, host: liberatedbread.com
    //
    // to the ZONE as well as to the awaiting future. AdBannerService catches
    // its own copy — that path is careful and works — but the zone copy has no
    // owner, so flutter_test attributed it to whichever suite had most
    // recently finished and reported "This test failed after it had already
    // completed", naming a test that never touched the network. Seen on the
    // emulator; timing-dependent, so it was a latent flake before it was a
    // reproducible failure.
    //
    // Skipping the refresh removes the dependency rather than papering over
    // the error, and costs no coverage: the host `flutter test` run does NOT
    // pass the define, so ad_banner_provider_test.dart and
    // ad_banner_bar_test.dart still exercise this path in full against their
    // overridden service. What mock mode shows instead is the seed — the
    // cached config or the bundled fallback — which is exactly what an offline
    // launch shows, and a demo build arguably should not be pulling live
    // promotions anyway.
    if (!isMockMode) {
      unawaited(_refresh(isDisposed: () => disposed));
    }
    return _visible(_seedConfig().banner);
  }

  /// The synchronous seed: the cached remote config when one parses, else the
  /// bundled fallback.
  AdBannerConfig _seedConfig() {
    final cached = ref.read(sharedPreferencesProvider).getString(cacheKey);
    if (cached != null) {
      final config = AdBannerConfig.tryParse(cached);
      if (config != null) return config;
      Log.ads.warning('ignoring corrupt cached banner config');
    }
    return AdBannerConfig(banner: AdBanner.fallback);
  }

  /// Fetch the remote config, cache it, and swap the state. Failures leave the
  /// current banner in place — by the time this resolves the seed is already
  /// on screen, and a fetch problem is never a reason to yank it.
  Future<void> _refresh({required bool Function() isDisposed}) async {
    final service = ref.read(adBannerServiceProvider);
    final result = await service.fetch(AppConstants.adBannerConfigUrl);
    if (isDisposed()) return;
    switch (result) {
      case AdBannerFetchOk(:final config, :final rawJson):
        // Apply the fetched config first — a remote kill switch must work
        // even when the cache write below fails.
        state = _visible(config.banner);
        // Cache verbatim so the next launch seeds with this config — including
        // a "show nothing" one, which must keep the banner off from the first
        // frame, not flash the fallback and then hide it. Best-effort: this
        // future is unawaited by build(), so a platform-storage failure must
        // be swallowed here or it becomes an unhandled async error.
        try {
          await ref
              .read(sharedPreferencesProvider)
              .setString(cacheKey, rawJson);
        } catch (e) {
          Log.ads.warning('could not cache the banner config', error: e);
        }
      case AdBannerFetchFailed():
        break;
    }
  }

  /// [banner] unless the user has already dismissed that exact promotion.
  AdBanner? _visible(AdBanner? banner) {
    if (banner == null) return null;
    final dismissed =
        ref.read(sharedPreferencesProvider).getString(dismissedKey);
    return banner.id == dismissed ? null : banner;
  }

  /// Hide the current banner and remember its id, so it stays gone until a
  /// config ships a different promotion.
  Future<void> dismiss() async {
    final banner = state;
    if (banner == null) return;
    state = null;
    // Best-effort like the cache write in _refresh: the caller fires this
    // unawaited, and the banner is already hidden for this session even if
    // persisting the id fails.
    try {
      await ref
          .read(sharedPreferencesProvider)
          .setString(dismissedKey, banner.id);
    } catch (e) {
      Log.ads.warning('could not persist the ad dismissal', error: e);
    }
    Log.ads.info('banner "${banner.id}" dismissed');
  }
}
