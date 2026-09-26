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
final radioSuggestionProvider = FutureProvider.autoDispose
    .family<SuggestionResult, SuggestionRequest>((ref, request) {
      // Hold the result across a brief rebuild -- a keyboard opening, a rotation
      // -- so the fetches are not thrown away and redone.
      final link = ref.keepAlive();
      ref.onCancel(link.close);
      return ref.watch(channelSuggestionServiceProvider).suggest(request);
    });
