// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/log.dart';
import 'spec_pack_provider.dart';

/// Root of the vendored protocol-specs subtree, as an asset path.
///
/// Specs are bundled straight out of the subtree rather than copied into
/// `assets/`: a copy would be 1.2MB of the same YAML twice in the tree, and a
/// second thing to go stale. `pubspec.yaml` bundles these paths.
const specsRoot = 'vendor/protocol-specs';

/// Asset path of the spec catalogue index — upstream's own `index.json`, read
/// as-is rather than through a rewritten copy.
const specManifestPath = '$specsRoot/device-specs/index.json';

/// Used when the manifest is missing or unreadable, so a broken vendoring
/// degrades to "mock mode still works" rather than an app with no specs.
const fallbackSpecPath = 'device-specs/examples/example-bulb.yaml';

/// The asset path for an index entry's repo-relative [indexPath].
///
/// Index entries are relative to the specs repo root (`device-specs/devices/
/// foo.yaml`), and the subtree puts that root at [specsRoot].
String specAssetPath(String indexPath) => '$specsRoot/$indexPath';

/// Loaded device spec YAML strings, keyed by source id. These are the raw YAML
/// strings passed to Rust for parsing.
///
/// Bundled specs are discovered through the subtree's own `index.json`, so
/// adding or updating a device is a data-only refresh: pull the subtree and the
/// device is available, with no Dart edit. The previous hardcoded list meant
/// every new device needed a code change, which is why only the example bulb
/// ever shipped.
///
/// Two sources are merged: the bundled assets (keyed by asset path, which
/// always begins `vendor/`) and any remote packs the user has installed (keyed
/// `pack:<name>/<file>`). The two key spaces cannot collide, and a failure
/// loading remote packs never removes a bundled spec.
final deviceSpecsProvider = FutureProvider<Map<String, String>>((ref) async {
  final specs = <String, String>{};

  for (final path in await _bundledSpecPaths()) {
    try {
      specs[path] = await rootBundle.loadString(path);
    } on FlutterError {
      // Listed in the manifest but not bundled: skip rather than fail the whole
      // catalogue. The sync script keeps the two in step; this guards a
      // hand-edited manifest.
      debugPrint('Spec listed in manifest but not bundled: $path');
    } catch (e, st) {
      Log.spec.warning('failed to load bundled spec $path',
          error: e, stackTrace: st);
    }
  }

  // Remote (cached) packs. Namespaced keys guarantee no collision with the
  // bundled asset paths above. This provider already swallows its own errors.
  final cached = await ref.watch(cachedSpecPacksProvider.future);
  specs.addAll(cached);

  Log.spec.info('${specs.length} spec(s) available '
      '(${specs.length - cached.length} bundled, ${cached.length} from packs)');
  return specs;
});

/// Asset paths of every spec listed in the vendored index.
///
/// Falls back to the example bulb when the index is missing or unreadable, so a
/// broken vendoring degrades to the previous behaviour (mock mode still works)
/// rather than an app with no specs at all.
Future<List<String>> _bundledSpecPaths() async {
  final fallback = [specAssetPath(fallbackSpecPath)];
  try {
    final raw = await rootBundle.loadString(specManifestPath);
    final decoded = jsonDecode(raw);
    if (decoded is! List) return fallback;

    final paths = <String>[];
    for (final entry in decoded) {
      if (entry is! Map) continue;
      // `path` is upstream's field, relative to the specs repo root. `file` is
      // still accepted because an older vendored manifest wrote bare filenames,
      // and reading one of those must not empty the catalogue.
      final path = entry['path'] ?? entry['file'];
      if (path is! String || path.isEmpty) continue;
      paths.add(specAssetPath(path));
    }
    return paths.isEmpty ? fallback : paths;
  } catch (e) {
    debugPrint('Failed to read spec index ($e); using bundled fallback.');
    return fallback;
  }
}
