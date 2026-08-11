// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/saved_designs_store.dart';
import 'saved_device_provider.dart' show sharedPreferencesProvider;

/// The per-device record of designs this app has stored, for the replay list.
final savedDesignsStoreProvider = Provider<SavedDesignsStore>(
  (ref) => SavedDesignsStore(ref.watch(sharedPreferencesProvider)),
);
