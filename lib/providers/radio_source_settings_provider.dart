// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import '../core/constants.dart';
import '../services/mygmrs_client.dart';
import '../services/radio_source_cache.dart';
import '../services/repeater_source.dart';
import '../services/repeaterbook_client.dart';
import 'json_setting.dart';
import 'radio_bundled_data_provider.dart';
import 'settings_store_provider.dart';

/// Identifies this app to the directories it queries.
///
/// RepeaterBook's terms ask for an app name and a way to reach whoever runs
/// it. Sent to myGMRS as well, whose endpoint asks for nothing — being
/// identifiable to a service you are querying anonymously is the polite
/// default, not a cost.
const String radioSourceUserAgent =
    'LiberatedBreadMobile/${AppConstants.appVersion} '
    '(+https://github.com/liberatedbread/liberatedbread-mobile)';

/// Which sources to ask, and how far to look.
class RadioSourceSettings {
  /// Search radius in km. The suggestion screen offers a short menu of these.
  final double radiusKm;

  /// Source ids the user has switched OFF. Stored as the exclusion set so a
  /// source added in a later build is on by default rather than invisible.
  final Set<String> disabledSourceIds;

  const RadioSourceSettings({
    this.radiusKm = defaultRadiusKm,
    this.disabledSourceIds = const {},
  });

  static const double defaultRadiusKm = 40;

  /// The choices the radius selector offers.
  static const List<double> radiusChoices = [10, 25, 40, 80, 160];

  bool isEnabled(String sourceId) => !disabledSourceIds.contains(sourceId);

  RadioSourceSettings withSource(String sourceId, {required bool enabled}) {
    final next = {...disabledSourceIds};
    if (enabled) {
      next.remove(sourceId);
    } else {
      next.add(sourceId);
    }
    return RadioSourceSettings(radiusKm: radiusKm, disabledSourceIds: next);
  }

  RadioSourceSettings withRadius(double km) =>
      RadioSourceSettings(radiusKm: km, disabledSourceIds: disabledSourceIds);

  Map<String, dynamic> toJson() => {
    'radiusKm': radiusKm,
    'disabled': disabledSourceIds.toList()..sort(),
  };

  static RadioSourceSettings fromJson(Map<String, dynamic> json) {
    final radius = json['radiusKm'];
    final disabled = json['disabled'];
    return RadioSourceSettings(
      radiusKm: radius is num && radius > 0 && radius <= 1000
          ? radius.toDouble()
          : defaultRadiusKm,
      disabledSourceIds: {
        if (disabled is List)
          for (final entry in disabled)
            if (entry is String && entry.isNotEmpty) entry,
      },
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is RadioSourceSettings &&
          radiusKm == other.radiusKm &&
          disabledSourceIds.length == other.disabledSourceIds.length &&
          disabledSourceIds.containsAll(other.disabledSourceIds);

  @override
  int get hashCode =>
      Object.hash(radiusKm, Object.hashAllUnordered(disabledSourceIds));
}

final radioSourceSettingsProvider =
    AsyncNotifierProvider<RadioSourceSettingsNotifier, RadioSourceSettings>(
      RadioSourceSettingsNotifier.new,
    );

class RadioSourceSettingsNotifier extends AsyncNotifier<RadioSourceSettings> {
  static const key = 'radio_source_settings_v1';

  @override
  Future<RadioSourceSettings> build() async {
    final stored = await readJsonSetting(ref, key);
    return stored == null
        ? const RadioSourceSettings()
        : RadioSourceSettings.fromJson(stored);
  }

  Future<void> _save(RadioSourceSettings settings) async {
    await writeJsonSetting(ref, key, settings.toJson());
    state = AsyncData(settings);
  }

  // Both setters await [future] rather than reading [state]: a caller that
  // never watched this provider can arrive while the first build is still
  // reading the store, [state] has no value yet, and a fallback to defaults
  // would be written back over the stored blob -- every source the user had
  // switched off back on, the chosen radius lost. Same guard as
  // TxUnlockNotifier.setEnabled, for the same reason.
  Future<void> setSourceEnabled(String sourceId, bool enabled) async {
    final current = await future;
    await _save(current.withSource(sourceId, enabled: enabled));
  }

  Future<void> setRadiusKm(double km) async {
    final current = await future;
    await _save(current.withRadius(km));
  }
}

/// The RepeaterBook application token, in the platform keychain.
///
/// A secret, so it lives in [SecureSettingsStore] rather than shared
/// preferences: it identifies a person's RepeaterBook account to their API.
final repeaterBookTokenProvider =
    AsyncNotifierProvider<RepeaterBookTokenNotifier, String?>(
      RepeaterBookTokenNotifier.new,
    );

class RepeaterBookTokenNotifier extends AsyncNotifier<String?> {
  static const key = 'repeaterbook_app_token';

  @override
  Future<String?> build() async {
    final store = ref.watch(settingsStoreProvider);
    final token = await store.read(key);
    return token == null || token.trim().isEmpty ? null : token.trim();
  }

  Future<void> setToken(String token) async {
    final trimmed = token.trim();
    final store = ref.read(settingsStoreProvider);
    if (trimmed.isEmpty) {
      await store.delete(key);
      state = const AsyncData(null);
      return;
    }
    await store.write(key, trimmed);
    state = AsyncData(trimmed);
  }

  Future<void> clear() => setToken('');
}

/// One http client for the radio sources, closed with the container.
final radioHttpClientProvider = Provider<http.Client>((ref) {
  final client = http.Client();
  ref.onDispose(client.close);
  return client;
});

final radioSourceCacheProvider = Provider<RadioSourceCache>((ref) {
  // Application Support, not Documents: see RadioSourceCache. Documents is
  // where earlier builds put it, so that copy is retired on first use, but
  // only where Documents is the app's own. On iOS, Android and the sandboxed
  // macOS build it is a per-app container; on Linux and Windows it is the
  // user's shared ~/Documents, where a `radio_cache` folder is not provably
  // ours, and retiring it is a recursive delete. There the old copy stays.
  return RadioSourceCache(
    cacheDirResolver: getApplicationSupportDirectory,
    legacyDirResolver: _documentsIsAppPrivate
        ? getApplicationDocumentsDirectory
        : null,
  );
});

/// Whether this platform's documents directory belongs to the app alone.
bool get _documentsIsAppPrivate => switch (defaultTargetPlatform) {
  TargetPlatform.iOS || TargetPlatform.android || TargetPlatform.macOS => true,
  _ => false,
};

final repeaterBookClientProvider = Provider<RepeaterBookClient>((ref) {
  final bundled = ref.watch(radioBundledDataProvider);
  return RepeaterBookClient(
    client: ref.watch(radioHttpClientProvider),
    userAgent: radioSourceUserAgent,
    readToken: () =>
        ref.read(settingsStoreProvider).read(RepeaterBookTokenNotifier.key),
    resolveStateId: (code) async {
      for (final state in await bundled.stateBounds()) {
        if (state.code == code) return state.fips;
      }
      return null;
    },
  );
});

final myGmrsClientProvider = Provider<MyGmrsClient>((ref) {
  return MyGmrsClient(
    client: ref.watch(radioHttpClientProvider),
    userAgent: radioSourceUserAgent,
  );
});

/// Every source the app can ask, in display order.
final repeaterSourcesProvider = Provider<List<RepeaterSource>>(
  (ref) => [
    ref.watch(repeaterBookClientProvider),
    ref.watch(myGmrsClientProvider),
  ],
);
