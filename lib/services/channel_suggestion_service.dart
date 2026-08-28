// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// Turning a position and a radio into a list of channels worth programming.

import 'package:flutter/foundation.dart' show immutable;

import '../core/geo.dart';
import '../core/log.dart';
import '../models/radio_channel.dart';
import '../models/radio_profile.dart';
import '../models/suggested_channel.dart';
import 'preset_channels.dart';
import 'radio_bundled_data.dart';
import 'radio_source_cache.dart';
import 'repeater_source.dart';
import 'us_state_resolver.dart';

/// What to suggest, and for whom.
///
/// A value class with real equality because it keys a `family` provider: a
/// fresh instance per rebuild that compared unequal would defeat the cache and
/// re-run every fetch on every frame.
@immutable
class SuggestionRequest {
  final GeoPoint where;
  final double radiusKm;
  final RadioProfile profile;

  /// Source ids to ask. Empty means "bundled data only", which is a real and
  /// useful request: it is what an offline search is.
  final Set<String> enabledSourceIds;

  /// Whether to treat the radio's expanded transmit ranges as available.
  /// Only ever widens anything for a profile that documents a software path.
  final bool txUnlockEnabled;

  const SuggestionRequest({
    required this.where,
    required this.radiusKm,
    required this.profile,
    this.enabledSourceIds = const {},
    this.txUnlockEnabled = false,
  });

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SuggestionRequest &&
          where == other.where &&
          radiusKm == other.radiusKm &&
          profile == other.profile &&
          txUnlockEnabled == other.txUnlockEnabled &&
          enabledSourceIds.length == other.enabledSourceIds.length &&
          enabledSourceIds.containsAll(other.enabledSourceIds);

  @override
  int get hashCode => Object.hash(
        where,
        radiusKm,
        profile,
        txUnlockEnabled,
        Object.hashAllUnordered(enabledSourceIds),
      );
}

/// Everything the suggestion screen renders.
class SuggestionResult {
  final List<SuggestedChannel> repeaters;
  final List<SuggestedChannel> gmrs;
  final List<SuggestedChannel> weather;
  final List<SuggestedChannel> presets;

  /// Sources that did not answer. Never fatal: a search with one directory
  /// down still returns the other one's results, the cached copies and the
  /// presets, and says what was missed.
  final List<SourceFailure> sourceFailures;

  /// True when some results came from a cache older than its TTL — the
  /// offline case, which the screen says out loud rather than presenting
  /// month-old data as current.
  final bool usedStaleCache;

  const SuggestionResult({
    this.repeaters = const [],
    this.gmrs = const [],
    this.weather = const [],
    this.presets = const [],
    this.sourceFailures = const [],
    this.usedStaleCache = false,
  });

  List<SuggestedChannel> forCategory(SuggestionCategory category) =>
      switch (category) {
        SuggestionCategory.repeater => repeaters,
        SuggestionCategory.gmrs => gmrs,
        SuggestionCategory.weather => weather,
        SuggestionCategory.preset => presets,
      };

  int get total =>
      repeaters.length + gmrs.length + weather.length + presets.length;

  bool get isEmpty => total == 0;

  /// Attribution lines to render, deduplicated, for the sources that actually
  /// contributed something.
  List<String> attributionsFor(List<RepeaterSource> sources) {
    final used = {
      for (final channel in [...repeaters, ...gmrs]) channel.sourceId,
    };
    final lines = <String>{};
    for (final source in sources) {
      final line = source.attribution;
      if (line != null && used.contains(source.id)) lines.add(line);
    }
    return lines.toList();
  }
}

/// Builds channel suggestions from every tier: bundled, cached and live.
///
/// The order of operations is the whole design. Candidates are gathered from
/// wherever they can be had, then filtered by distance, then judged against
/// the radio, then de-duplicated, then ranked. Judging against the radio
/// happens late on purpose: a channel the radio cannot transmit on is still
/// worth showing as listen-only, and one it cannot even hear is the only kind
/// worth dropping.
class ChannelSuggestionService {
  final List<RepeaterSource> _sources;
  final RadioSourceCache _cache;
  final RadioBundledData _bundled;

  /// How old a cached state may be before a live fetch is preferred. A stale
  /// copy is still used when the live fetch fails.
  final Duration cacheTtl;

  ChannelSuggestionService({
    required List<RepeaterSource> sources,
    required RadioSourceCache cache,
    required RadioBundledData bundled,
    this.cacheTtl = RadioSourceCache.defaultTtl,
  })  : _sources = sources,
        _cache = cache,
        _bundled = bundled;

  Future<SuggestionResult> suggest(SuggestionRequest request) async {
    final failures = <SourceFailure>[];
    var usedStale = false;

    final states = await statesNear(
      _bundled,
      request.where,
      radiusKm: request.radiusKm,
    );

    // Each listing is carried with the id of the source that produced it.
    // Deriving it later from the category would misattribute a GMRS listing
    // that came from RepeaterBook, and attribution is a term of use, not a
    // label.
    final listings = <({String sourceId, RepeaterListing listing})>[];
    for (final source in _sources) {
      if (!request.enabledSourceIds.contains(source.id)) continue;

      if (!await source.isConfigured()) {
        failures.add(SourceFailure(
          sourceId: source.id,
          displayName: source.displayName,
          kind: SourceFailureKind.auth,
          message: '${source.displayName} needs to be set up before it can '
              'be searched.',
        ));
        continue;
      }

      for (final state in states) {
        final outcome = await _listingsForState(source, state);
        listings.addAll([
          for (final listing in outcome.listings)
            (sourceId: source.id, listing: listing),
        ]);
        if (outcome.failure != null) failures.add(outcome.failure!);
        if (outcome.stale) usedStale = true;
      }
    }

    // One failure per source, not one per state: three states failing the same
    // way is one problem, and three identical rows is noise.
    final deduplicatedFailures = <String, SourceFailure>{};
    for (final failure in failures) {
      deduplicatedFailures.putIfAbsent(failure.sourceId, () => failure);
    }

    final online = _rank(_dedupe(_judgeAll(listings, request)));
    final presets = _presetSuggestions(request);

    return SuggestionResult(
      repeaters: [
        for (final channel in online)
          if (channel.category == SuggestionCategory.repeater) channel,
      ],
      gmrs: [
        for (final channel in online)
          if (channel.category == SuggestionCategory.gmrs) channel,
      ],
      weather: presets.weather,
      presets: presets.other,
      sourceFailures: deduplicatedFailures.values.toList(),
      usedStaleCache: usedStale,
    );
  }

  /// One state from one source: fresh cache, live fetch, or stale cache in
  /// that order of preference.
  Future<
      ({
        List<RepeaterListing> listings,
        SourceFailure? failure,
        bool stale,
      })> _listingsForState(RepeaterSource source, String state) async {
    final cached = await _cache.read(source.id, state);
    if (cached != null && !cached.isStale(cacheTtl)) {
      return (listings: cached.listings, failure: null, stale: false);
    }

    try {
      final fetched = await source.fetchByState(state);
      await _cache.write(source.id, state, fetched);
      return (listings: fetched, failure: null, stale: false);
    } on RepeaterSourceException catch (error) {
      if (cached != null) {
        // The stale copy is why this is worth doing at all: standing
        // somewhere with no signal, last week's repeater list is not
        // meaningfully worse than today's, and it is enormously better than
        // an error.
        Log.radio.info(
            '${source.id}/$state failed, using cache from ${cached.fetchedAt}');
        return (listings: cached.listings, failure: error.failure, stale: true);
      }
      return (
        listings: const <RepeaterListing>[],
        failure: error.failure,
        stale: false
      );
    }
  }

  /// Distance filter and capability judgement, in that order.
  List<SuggestedChannel> _judgeAll(
    List<({String sourceId, RepeaterListing listing})> entries,
    SuggestionRequest request,
  ) {
    final judged = <SuggestedChannel>[];
    for (final entry in entries) {
      final listing = entry.listing;
      final location = listing.location;
      // No position means no distance, and no distance means it cannot be
      // ranked against the ones that have one.
      if (location == null || !location.isValid) continue;

      final distance = haversineKm(request.where, location);
      if (distance > request.radiusKm) continue;

      final channel = _judge(listing.channel, request);
      if (channel == null) continue;

      judged.add(SuggestedChannel(
        channel: channel.channel,
        category: listing.category,
        sourceId: entry.sourceId,
        distanceKm: distance,
        callsign: listing.callsign,
        details: listing.details,
        txAllowed: channel.txAllowed,
        requiresTxUnlock: channel.requiresUnlock,
      ));
    }
    return judged;
  }

  /// Decide what a radio can do with a channel.
  ///
  /// Returns null only when the radio cannot even receive it: that is the one
  /// case where showing it would be pure noise. Everything else is offered,
  /// with transmit marked honestly.
  ({RadioChannel channel, bool txAllowed, bool requiresUnlock})? _judge(
    RadioChannel channel,
    SuggestionRequest request,
  ) {
    final profile = request.profile;
    if (!profile.canReceive(channel.rxFreqHz)) return null;

    if (channel.rxOnly) {
      return (channel: channel, txAllowed: false, requiresUnlock: false);
    }

    final canTransmit = profile.canTransmit(
      channel.txFreqHz,
      unlockEnabled: request.txUnlockEnabled,
    );
    final needsUnlock = request.txUnlockEnabled &&
        profile.needsUnlockToTransmit(channel.txFreqHz);

    return (
      channel: channel,
      txAllowed: canTransmit,
      requiresUnlock: canTransmit && needsUnlock,
    );
  }

  /// Keep one of each machine, preferring the nearest listing.
  ///
  /// Two directories describing the same repeater is the normal case, not an
  /// edge one, and a list showing it twice makes the user do the comparison.
  List<SuggestedChannel> _dedupe(List<SuggestedChannel> channels) {
    final best = <String, SuggestedChannel>{};
    for (final channel in channels) {
      final existing = best[channel.dedupeKey];
      if (existing == null) {
        best[channel.dedupeKey] = channel;
        continue;
      }
      final existingDistance = existing.distanceKm ?? double.infinity;
      final candidateDistance = channel.distanceKm ?? double.infinity;
      if (candidateDistance < existingDistance) {
        best[channel.dedupeKey] = channel;
      }
    }
    return best.values.toList();
  }

  List<SuggestedChannel> _rank(List<SuggestedChannel> channels) {
    final sorted = [...channels];
    sorted.sort((a, b) {
      final byDistance = (a.distanceKm ?? double.infinity)
          .compareTo(b.distanceKm ?? double.infinity);
      if (byDistance != 0) return byDistance;
      // A stable tie-break so the list does not reshuffle between identical
      // searches.
      return a.channel.rxFreqHz.compareTo(b.channel.rxFreqHz);
    });
    return sorted;
  }

  /// The offline tier, judged against the radio like everything else.
  ({List<SuggestedChannel> weather, List<SuggestedChannel> other})
      _presetSuggestions(SuggestionRequest request) {
    final weather = <SuggestedChannel>[];
    final other = <SuggestedChannel>[];

    for (final channel in allPresetChannels()) {
      final judged = _judge(channel, request);
      if (judged == null) continue;

      final isWeather = channel.rxOnly && channel.name.startsWith('WX');
      final suggestion = SuggestedChannel(
        channel: judged.channel,
        category:
            isWeather ? SuggestionCategory.weather : SuggestionCategory.preset,
        sourceId: 'bundled',
        details: channel.comment.isEmpty ? null : channel.comment,
        txAllowed: judged.txAllowed,
        requiresTxUnlock: judged.requiresUnlock,
      );
      (isWeather ? weather : other).add(suggestion);
    }
    return (weather: weather, other: other);
  }
}

/// The order to show categories in for a given radio.
///
/// A GMRS radio's owner is looking for GMRS repeaters, and burying them under
/// a list of amateur machines they cannot legally key is the wrong first
/// screen. Ordering rather than filtering: the amateur repeaters are still
/// there, still receivable, still worth having as listen-only.
List<SuggestionCategory> categoryOrderFor(RadioProfile profile) =>
    profile.gmrsLocked
        ? const [
            SuggestionCategory.gmrs,
            SuggestionCategory.repeater,
            SuggestionCategory.weather,
            SuggestionCategory.preset,
          ]
        : const [
            SuggestionCategory.repeater,
            SuggestionCategory.gmrs,
            SuggestionCategory.weather,
            SuggestionCategory.preset,
          ];
