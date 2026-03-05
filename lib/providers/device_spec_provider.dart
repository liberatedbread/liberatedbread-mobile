// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Loaded device spec YAML strings, keyed by filename.
/// These are the raw YAML strings passed to Rust for parsing.
final deviceSpecsProvider = FutureProvider<Map<String, String>>((ref) async {
  // Load all YAML files from assets/device_specs/
  // AssetBundle doesn't have a directory listing API, so we maintain
  // an explicit list. New specs must be added here.
  const specFiles = [
    'assets/device_specs/example-bulb.yaml',
  ];

  final specs = <String, String>{};
  for (final path in specFiles) {
    try {
      specs[path] = await rootBundle.loadString(path);
    } catch (_) {
      // Skip missing files
    }
  }
  return specs;
});
