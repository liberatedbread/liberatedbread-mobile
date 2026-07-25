// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'spec_pack_provider.dart';

/// Loaded device spec YAML strings, keyed by source id. These are the raw YAML
/// strings passed to Rust for parsing.
///
/// Two sources are merged: the specs bundled as app assets (the fallback, keyed
/// by asset path) and any remote packs the user has installed (keyed
/// `pack:<name>/<file>`). Bundled specs always load even when no pack is
/// installed; a failure loading remote packs never removes a bundled spec.
final deviceSpecsProvider = FutureProvider<Map<String, String>>((ref) async {
  final specs = <String, String>{};

  // Bundled assets. AssetBundle has no directory listing API, so we maintain an
  // explicit list. New bundled specs must be added here.
  const bundledSpecFiles = [
    'assets/device_specs/example-bulb.yaml',
  ];
  for (final path in bundledSpecFiles) {
    try {
      specs[path] = await rootBundle.loadString(path);
    } on FlutterError {
      // Asset not bundled - skip silently.
    } catch (e, st) {
      debugPrint('Failed to load spec $path: $e\n$st');
    }
  }

  // Remote (cached) packs. Namespaced keys guarantee no collision with the
  // bundled asset paths above. This provider already swallows its own errors.
  final cached = await ref.watch(cachedSpecPacksProvider.future);
  specs.addAll(cached);

  return specs;
});
