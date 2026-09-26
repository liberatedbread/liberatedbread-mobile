// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/radio_bundled_data.dart';

/// The app's bundled radio data, parsed once and shared.
///
/// A plain [Provider] rather than a FutureProvider: the loader itself is
/// async and caches internally, so every consumer awaits the same parse
/// without the provider having to model a loading state nobody renders.
final radioBundledDataProvider = Provider<RadioBundledData>(
  (ref) => RadioBundledData(),
);
