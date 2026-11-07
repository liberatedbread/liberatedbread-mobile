// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/localthings.dart';
import '../core/log.dart';
import '../services/ha_api_client.dart';
import 'ha_provider.dart';

/// What the connected Home Assistant says about LocalThings.
enum LocalThingsStatus {
  /// No Home Assistant is connected in the app, so nobody was asked.
  noHomeAssistant,

  /// Home Assistant has LocalThings loaded: the next step is adding an
  /// appliance, not installing anything.
  installed,

  /// Home Assistant answered and LocalThings is not among its integrations.
  notInstalled,

  /// Home Assistant is connected but did not answer the question — off this
  /// network, a revoked token, a server error. The card falls back to the
  /// install advice, worded so it does not claim LocalThings is missing.
  unknown,
}

/// Asks the connected Home Assistant whether LocalThings is loaded.
///
/// autoDispose: asked when a SmartThings device turns up in a scan and
/// forgotten when the card goes, so installing LocalThings and scanning again
/// gets a fresh answer rather than a stale "not installed".
final localThingsStatusProvider = FutureProvider.autoDispose<LocalThingsStatus>(
  (ref) async {
    final config = await ref.watch(haConfigProvider.future);
    if (config == null || config.baseUrl.isEmpty || config.token.isEmpty) {
      return LocalThingsStatus.noHomeAssistant;
    }
    try {
      final components = await ref
          .watch(haApiClientProvider)
          .loadedComponents(baseUrl: config.baseUrl, token: config.token);
      return hasLocalThings(components)
          ? LocalThingsStatus.installed
          : LocalThingsStatus.notInstalled;
    } on HaApiException catch (e) {
      // The typed hierarchy only, by design: its messages carry the host,
      // never the token. Anything else is a bug and should surface as one.
      Log.ha.info('could not ask Home Assistant about LocalThings: $e');
      return LocalThingsStatus.unknown;
    }
  },
);
