// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/channel_suggestion_service.dart';
import 'radio_bundled_data_provider.dart';
import 'radio_source_settings_provider.dart';

/// The suggestion engine, wired to the sources and the cache.
final channelSuggestionServiceProvider = Provider<ChannelSuggestionService>((
  ref,
) {
  return ChannelSuggestionService(
    sources: ref.watch(repeaterSourcesProvider),
    cache: ref.watch(radioSourceCacheProvider),
    bundled: ref.watch(radioBundledDataProvider),
  );
});

/// Suggestions for one request.
///
/// `autoDispose` because a result set is large and belongs to one visit to
/// one screen; `family` keyed by [SuggestionRequest], which has real value
/// equality precisely so that a rebuild handing over an equal-but-new request
/// reuses this rather than re-running every fetch.
///
/// No `keepAlive` here, and deliberately: a rebuild never drops the screen's
/// watch (an equal key reclaims the same subscription), so there is nothing
/// for a hold to bridge, and the only time the watch really goes is when the
/// request changes -- at which point the old result is not wanted. A
/// `keepAlive` link closed from `onCancel` was tried and is a no-op: the last
/// listener leaving is exactly when a plain autoDispose element is disposed,
/// and both land on the same scheduler tick. The disk cache is what makes a
/// repeat search cheap.
final radioSuggestionProvider = FutureProvider.autoDispose
    .family<SuggestionResult, SuggestionRequest>((ref, request) {
      return ref.watch(channelSuggestionServiceProvider).suggest(request);
    });
