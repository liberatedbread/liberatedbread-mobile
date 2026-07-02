// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';

import '../core/constants.dart';
import '../core/ha_url.dart';
import '../models/ha_config.dart';
import '../services/ha_api_client.dart';
import '../services/ha_sensor_forwarder.dart';
import '../services/http_ha_api_client.dart';
import '../services/secure_settings_store.dart';
import '../services/settings_store.dart';

/// Key/value store for HA config. Tests override with an in-memory fake so
/// nothing touches the platform keychain.
final settingsStoreProvider =
    Provider<SettingsStore>((ref) => SecureSettingsStore());

/// The Home Assistant API client. Tests override with a fake.
final haApiClientProvider =
    Provider<HaApiClient>((ref) => HttpHaApiClient(http.Client()));

/// Opens external links (Tailscale docs). Injected so widget tests never hit
/// the url_launcher platform channel.
final urlOpenerProvider = Provider<Future<bool> Function(Uri)>(
    (ref) => (url) => launchUrl(url, mode: LaunchMode.externalApplication));

/// The app-wide sensor forwarder bridging decoded BLE values to HA.
final haForwarderProvider = Provider<HaSensorForwarder>((ref) {
  return HaSensorForwarder(
    api: ref.watch(haApiClientProvider),
    readConfig: () => ref.read(haConfigProvider.future),
  );
});

final haConfigProvider =
    AsyncNotifierProvider<HaConfigNotifier, HaConfig?>(HaConfigNotifier.new);

/// Loads, registers, and updates the persisted Home Assistant configuration.
class HaConfigNotifier extends AsyncNotifier<HaConfig?> {
  static const configKey = 'ha_config';

  /// Kept under its own key so the app identity survives a disconnect and a
  /// later re-registration updates the same HA device entry.
  static const deviceIdKey = 'ha_device_id';

  @override
  Future<HaConfig?> build() async {
    final raw = await ref.watch(settingsStoreProvider).read(configKey);
    if (raw == null) return null;
    return HaConfig.fromJson(jsonDecode(raw) as Map<String, dynamic>);
  }

  /// Register this app install with HA's mobile_app integration and persist
  /// the resulting config. Throws [HaApiException] subtypes for the screen
  /// to render.
  Future<void> register({
    required String baseUrl,
    required String token,
  }) async {
    final store = ref.read(settingsStoreProvider);
    final api = ref.read(haApiClientProvider);
    final normalized = normalizeHaBaseUrl(baseUrl);
    final deviceId = await _ensureDeviceId(store);
    final result = await api.registerDevice(
      baseUrl: normalized,
      token: token,
      deviceInfo: {
        'device_id': deviceId,
        'app_id': AppConstants.haAppId,
        'app_name': AppConstants.appName,
        'app_version': AppConstants.appVersion,
        'device_name': '${AppConstants.appName} on ${Platform.operatingSystem}',
        'manufacturer': 'Pigs Can Fly Labs',
        'model': Platform.operatingSystem,
        'os_name': Platform.operatingSystem,
        'os_version': Platform.operatingSystemVersion,
        'supports_encryption': false,
      },
    );
    final config = HaConfig(
      baseUrl: normalized,
      token: token,
      webhookId: result.webhookId,
      deviceId: deviceId,
    );
    await store.write(configKey, jsonEncode(config.toJson()));
    state = AsyncData(config);
  }

  Future<void> setEnabled(bool enabled) async {
    final config = state.valueOrNull;
    if (config == null) return;
    final updated = config.copyWith(enabled: enabled);
    await ref
        .read(settingsStoreProvider)
        .write(configKey, jsonEncode(updated.toJson()));
    state = AsyncData(updated);
  }

  /// Forget the local registration. HA has no unregister API, so the device
  /// entry must be removed in HA's own UI - the screen says so.
  Future<void> disconnect() async {
    await ref.read(settingsStoreProvider).delete(configKey);
    state = const AsyncData(null);
  }

  Future<String> _ensureDeviceId(SettingsStore store) async {
    final existing = await store.read(deviceIdKey);
    if (existing != null) return existing;
    final rng = Random.secure();
    final id = List.generate(
        16, (_) => rng.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
    await store.write(deviceIdKey, id);
    return id;
  }
}
