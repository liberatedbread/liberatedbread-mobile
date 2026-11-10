// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/health_history_store.dart';
import 'saved_device_provider.dart' show sharedPreferencesProvider;

/// Where health readings are kept on this phone, or null when preferences
/// are not wired in this scope: the panel must still render in a screen test
/// without them, and simply keeps nothing.
final healthHistoryStoreProvider = Provider<HealthHistoryStore?>((ref) {
  try {
    return HealthHistoryStore(ref.watch(sharedPreferencesProvider));
  } on Object {
    return null;
  }
});
