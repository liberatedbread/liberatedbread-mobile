// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'spec_pack_provider.dart';

/// Asset path of the vendored spec catalogue index.
const _manifestPath = 'assets/device_specs/manifest.json';
const _specDir = 'assets/device_specs';

/// Loaded device spec YAML strings, keyed by source id. These are the raw YAML
/// strings passed to Rust for parsing.
///
/// Bundled specs are discovered through `manifest.json`, vendored from the
/// protocol-specs repo's `index.json` by `scripts/sync_device_specs.sh`. That
/// indirection is the point: adding or updating a device becomes a data-only
/// refresh — re-run the sync script and the device is available, with no Dart
/// edit. The previous hardcoded list meant every new device needed a code
/// change, which is why only the example bulb ever shipped.
///
/// Two sources are merged: the bundled assets (keyed by asset path) and any
/// remote packs the user has installed (keyed `pack:<name>/<file>`). A failure
/// loading remote packs never removes a bundled spec.
final deviceSpecsProvider = FutureProvider<Map<String, String>>((ref) async {
  final specs = <String, String>{};

  for (final file in await _bundledSpecFiles()) {
    final path = '$_specDir/$file';
    try {
      specs[path] = await rootBundle.loadString(path);
    } on FlutterError {
      // Listed in the manifest but not bundled: skip rather than fail the whole
      // catalogue. The sync script keeps the two in step; this guards a
      // hand-edited manifest.
      debugPrint('Spec listed in manifest but not bundled: $path');
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

/// Spec filenames listed in the vendored manifest.
///
/// Falls back to the example bulb when the manifest is missing or unreadable,
/// so a broken vendor step degrades to the previous behaviour (mock mode still
/// works) rather than an app with no specs at all.
Future<List<String>> _bundledSpecFiles() async {
  const fallback = ['example-bulb.yaml'];
  try {
    final raw = await rootBundle.loadString(_manifestPath);
    final decoded = jsonDecode(raw);
    if (decoded is! List) return fallback;

    final files = <String>[];
    for (final entry in decoded) {
      if (entry is! Map) continue;
      // `file` is written by the sync script; `path` is the upstream field,
      // accepted as a fallback so a manually copied index.json still works.
      final file = entry['file'] ?? entry['path'];
      if (file is! String || file.isEmpty) continue;
      files.add(file.split('/').last);
    }
    return files.isEmpty ? fallback : files;
  } catch (e) {
    debugPrint('Failed to read spec manifest ($e); using bundled fallback.');
    return fallback;
  }
}
