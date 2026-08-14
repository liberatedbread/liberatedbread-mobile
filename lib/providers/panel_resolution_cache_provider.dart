// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/panel_resolution_cache.dart';
import 'saved_device_provider.dart' show sharedPreferencesProvider;

/// Persistent per-device cache of a panel's real resolution, so a reconnect
/// with no advertisement still sizes the canvas correctly. Overridden in tests
/// that exercise the cache path.
final panelResolutionCacheProvider = Provider<PanelResolutionCache>(
  (ref) => PanelResolutionCache(ref.watch(sharedPreferencesProvider)),
);
