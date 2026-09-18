// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'device_description_provider.dart';
import 'device_spec_match_provider.dart';

/// Start the two big asset loads the first screen will want, as soon as the
/// app has a screen at all.
///
/// Both are lazy providers, and until this existed nothing asked for either
/// until the Nearby tab's FIRST SCAN RESULT did — so the 200-spec catalogue
/// parse and the 1.7 MB of number registries landed together, in the middle
/// of the radar sweep, exactly as the first rows were appearing. Kicking them
/// from the terms gate overlaps that work with a screen the user is reading
/// instead of one they are watching animate.
///
/// Warm-up only: the result is deliberately dropped, errors included. Every
/// consumer of these providers already handles its own failure (an unparseable
/// catalogue degrades to raw controls, absent registries to "no vendor name"),
/// and a warm-up that reported would be a second, earlier, unhandled place for
/// the same error to surface.
void warmStartupCaches(WidgetRef ref) {
  for (final future in <Future<Object?>>[
    ref.read(specCatalogueProvider.future),
    ref.read(numberRegistryProvider.future),
  ]) {
    unawaited(future.then((_) {}, onError: (Object _) {}));
  }
}
