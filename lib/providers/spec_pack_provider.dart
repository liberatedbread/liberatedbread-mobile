// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/constants.dart';
import '../services/prefs_settings_store.dart';
import '../services/settings_store.dart';
import '../services/spec_pack_service.dart';
import 'spec_codec_provider.dart';

/// SharedPreferences-backed store for non-secret settings (the pack URL). Tests
/// override this with an in-memory fake so nothing touches platform prefs.
final prefsSettingsStoreProvider = FutureProvider<SettingsStore>((ref) async {
  final prefs = await SharedPreferences.getInstance();
  return PrefsSettingsStore(prefs);
});

/// The spec-pack downloader/cache. Tests override with a service pointed at a
/// temp dir and a mocked http client.
final specPackServiceProvider = Provider<SpecPackService>((ref) {
  final client = http.Client();
  ref.onDispose(client.close);
  // Validate downloaded specs with the SAME codec device matching uses, so a
  // spec that would later fail to parse is rejected at install time instead of
  // being reported as installed and then silently skipped.
  final codec = ref.watch(specCodecProvider);
  return SpecPackService(
    client: client,
    cacheDirResolver: getApplicationDocumentsDirectory,
    specValidator: (yaml) async {
      try {
        await codec.loadDeviceSpec(yaml);
        return true;
      } catch (_) {
        return false;
      }
    },
  );
});

/// The persisted spec-pack manifest URL, defaulting to
/// [AppConstants.defaultSpecPackUrl] until the user overrides it.
final specPackUrlProvider =
    AsyncNotifierProvider<SpecPackUrlNotifier, String>(SpecPackUrlNotifier.new);

class SpecPackUrlNotifier extends AsyncNotifier<String> {
  static const key = 'spec_pack_url';

  @override
  Future<String> build() async {
    final store = await ref.watch(prefsSettingsStoreProvider.future);
    final saved = await store.read(key);
    if (saved == null || saved.trim().isEmpty) {
      return AppConstants.defaultSpecPackUrl;
    }
    return saved.trim();
  }

  /// Persist a new manifest URL.
  Future<void> setUrl(String url) async {
    final trimmed = url.trim();
    final store = await ref.read(prefsSettingsStoreProvider.future);
    await store.write(key, trimmed);
    state = AsyncData(trimmed);
  }

  /// Revert to the built-in default URL.
  Future<void> resetToDefault() async {
    final store = await ref.read(prefsSettingsStoreProvider.future);
    await store.delete(key);
    state = const AsyncData(AppConstants.defaultSpecPackUrl);
  }
}

/// Cached remote specs, keyed by `pack:<name>/<file>`, for
/// [deviceSpecsProvider] to merge with the bundled assets.
///
/// This feeds live device matching, which MUST always fall back to the bundled
/// specs, so a total failure is tolerated (empty map) — but it is logged, not
/// silently swallowed. [SpecPackService.loadCachedSpecs] already degrades
/// gracefully per record; this catch only guards against unexpected throws
/// (e.g. platform channels unavailable under unit tests).
final cachedSpecPacksProvider =
    FutureProvider<Map<String, String>>((ref) async {
  final service = ref.watch(specPackServiceProvider);
  try {
    return await service.loadCachedSpecs();
  } catch (e) {
    debugPrint('cachedSpecPacksProvider: falling back to bundled specs: $e');
    return const <String, String>{};
  }
});

/// Metadata for every installed pack, for the settings screen's list.
///
/// Read failures are NOT swallowed: they surface as an [AsyncError] so the
/// settings screen shows a real error state instead of an empty
/// "No packs installed yet." [SpecPackService.listInstalledPacks] still tolerates
/// individual corrupt records internally.
final installedSpecPacksProvider = FutureProvider<List<SpecPack>>((ref) async {
  final service = ref.watch(specPackServiceProvider);
  return service.listInstalledPacks();
});
