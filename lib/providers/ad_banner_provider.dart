// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

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

/// The full ad state: the parsed config (global banner + targeted banners) and
/// the set of promotion ids the user has dismissed. Held whole so both the
/// global scan-screen banner and any device-targeted banner derive from one
/// source and react together to a refresh or a dismissal.
@immutable
class AdBannerState {
  final AdBannerConfig config;
  final Set<String> dismissed;

  const AdBannerState({required this.config, required this.dismissed});

  /// The global banner for the scan screen, or null when there is none or the
  /// user dismissed it.
  AdBanner? get globalBanner {
    final b = config.banner;
    return (b == null || dismissed.contains(b.id)) ? null : b;
  }

  /// The best banner for a device with [category]/[specKey], or null. A
  /// spec-key match beats a category match beats the global banner; dismissed
  /// promotions are skipped at every tier.
  AdBanner? bannerFor({String? category, String? specKey}) =>
      config.bestFor(category: category, specKey: specKey, exclude: dismissed);

  AdBannerState copyWith({AdBannerConfig? config, Set<String>? dismissed}) =>
      AdBannerState(
        config: config ?? this.config,
        dismissed: dismissed ?? this.dismissed,
      );
}

/// Identifies the device a targeted banner is chosen for. Both fields are
/// nullable — a device whose spec did not match still has neither, and then
/// only the global banner can show.
@immutable
class DeviceAdContext {
  final String? category;
  final String? specKey;

  const DeviceAdContext({this.category, this.specKey});

  @override
  bool operator ==(Object other) =>
      other is DeviceAdContext &&
      other.category == category &&
      other.specKey == specKey;

  @override
  int get hashCode => Object.hash(category, specKey);
}

/// The whole ad state. Seeds synchronously (cache or bundled) so the first
/// frame never waits on IO, then refreshes in the background.
final adBannerStateProvider = NotifierProvider<AdBannerNotifier, AdBannerState>(
  AdBannerNotifier.new,
);

/// The banner to show at the bottom of the scan screen, or null for none.
///
/// A thin view over [adBannerStateProvider] kept at its old name and type so
/// the scan screen and its tests read it unchanged.
final adBannerProvider = Provider<AdBanner?>(
  (ref) => ref.watch(adBannerStateProvider).globalBanner,
);

/// The banner to show against a specific device (its device screen), or null.
///
/// Falls back to the global banner when nothing targets the device, so a device
/// screen always shows the most relevant promotion available — a label printer
/// its label-supply promo, an unmatched device the general shop banner.
final deviceAdBannerProvider = Provider.family<AdBanner?, DeviceAdContext>((
  ref,
  context,
) {
  final state = ref.watch(adBannerStateProvider);
  return state.bannerFor(category: context.category, specKey: context.specKey);
});

class AdBannerNotifier extends Notifier<AdBannerState> {
  /// Raw JSON of the last config a fetch successfully parsed.
  static const cacheKey = 'ad_banner_config_json';

  /// Ids of banners the user has dismissed. Each stays hidden until a config
  /// ships a different id. Stored as a JSON array of ids; a bare-string value
  /// left by an older build (one id) is read as a single-element set.
  static const dismissedKey = 'ad_banner_dismissed_ids';

  /// The pre-set-of-ids key an older build wrote (one dismissed id). Read once
  /// for a smooth upgrade, then superseded by [dismissedKey].
  static const legacyDismissedKey = 'ad_banner_dismissed_id';

  /// Cap on remembered dismissals, so the set cannot grow without bound across
  /// many promotions over the app's life. FIFO by insertion.
  static const maxDismissed = 64;

  @override
  AdBannerState build() {
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
    return AdBannerState(config: _seedConfig(), dismissed: _loadDismissed());
  }

  /// SharedPreferences, or null when it is not wired in this scope. The banner
  /// is a non-critical, embeddable bit of UI (both bars can sit on any screen),
  /// so it must not hard-depend on the store being overridden: a screen test
  /// that shows the bar without providing prefs gets the bundled content with
  /// no persistence — exactly the offline behaviour — rather than an exception
  /// building the widget tree.
  SharedPreferences? _prefsOrNull() {
    try {
      return ref.read(sharedPreferencesProvider);
    } catch (_) {
      return null;
    }
  }

  /// The synchronous seed: the cached remote config when one parses, else the
  /// bundled config (global fallback + bundled targeted banners).
  AdBannerConfig _seedConfig() {
    final cached = _prefsOrNull()?.getString(cacheKey);
    if (cached != null) {
      final config = AdBannerConfig.tryParse(cached);
      if (config != null) return config;
      Log.ads.warning('ignoring corrupt cached banner config');
    }
    return AdBannerConfig.bundled;
  }

  /// The dismissed-id set from storage, tolerating the legacy single-id key.
  Set<String> _loadDismissed() {
    final prefs = _prefsOrNull();
    if (prefs == null) return <String>{};
    final stored = prefs.getString(dismissedKey);
    if (stored != null) {
      try {
        final decoded = jsonDecode(stored);
        if (decoded is List) {
          return {
            for (final e in decoded)
              if (e is String) e,
          };
        }
      } catch (_) {
        // Fall through to the legacy key / empty.
      }
    }
    final legacy = prefs.getString(legacyDismissedKey);
    return legacy == null ? <String>{} : {legacy};
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
        state = state.copyWith(config: config);
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

  /// Hide the banner with [id] and remember it, so it stays gone until a config
  /// ships a different promotion. Bounded FIFO.
  Future<void> dismiss(String id) async {
    if (state.dismissed.contains(id)) return;
    final next = <String>{...state.dismissed, id};
    // Trim oldest-first if we blew the cap: iteration order is insertion order.
    final trimmed = next.length > maxDismissed
        ? next.skip(next.length - maxDismissed).toSet()
        : next;
    state = state.copyWith(dismissed: trimmed);
    // Best-effort like the cache write in _refresh: the caller fires this
    // unawaited, and the banner is already hidden for this session even if
    // persisting fails.
    try {
      await ref
          .read(sharedPreferencesProvider)
          .setString(dismissedKey, jsonEncode(trimmed.toList()));
    } catch (e) {
      Log.ads.warning('could not persist the ad dismissal', error: e);
    }
    Log.ads.info('banner "$id" dismissed');
  }
}
