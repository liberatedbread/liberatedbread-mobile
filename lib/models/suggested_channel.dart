// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// A channel the app is offering, with the provenance that makes it judgeable.

import 'radio_channel.dart';

/// Which pile a suggestion belongs in.
enum SuggestionCategory {
  repeater,
  gmrs,
  weather,
  preset;

  String get label => switch (this) {
    SuggestionCategory.repeater => 'Repeaters',
    SuggestionCategory.gmrs => 'GMRS',
    SuggestionCategory.weather => 'Weather',
    SuggestionCategory.preset => 'Standard channels',
  };
}

/// A [RadioChannel] the engine is proposing, plus everything the user needs to
/// decide whether they want it.
///
/// The provenance is not decoration. A repeater 60 km away behind a ridge, a
/// GMRS listing with no tone recorded, and a channel the radio can only
/// transmit on with its limits widened are all things the person choosing
/// ought to see before they tick the box.
class SuggestedChannel {
  final RadioChannel channel;
  final SuggestionCategory category;

  /// Which source produced it — a [RepeaterSource] id, or `bundled` /
  /// `preset`. Shown so a user can tell a RepeaterBook listing from a myGMRS
  /// one when the two disagree.
  final String sourceId;

  /// Distance from the search point, or null for suggestions that have no
  /// location (the standard-channel presets).
  final double? distanceKm;

  final String? callsign;

  /// Free text worth reading: "tone not published, confirm with owner", the
  /// repeater's location, an operating note from the source.
  final String? details;

  /// Whether the selected radio can legally and physically transmit here,
  /// under whatever unlock setting the request ran with. False means the
  /// channel is still offered — as listen-only.
  final bool txAllowed;

  /// True when [txAllowed] is only true because the transmit-range unlock was
  /// on. The UI badges these; a plan containing one is banner-marked.
  final bool requiresTxUnlock;

  const SuggestedChannel({
    required this.channel,
    required this.category,
    required this.sourceId,
    this.distanceKm,
    this.callsign,
    this.details,
    this.txAllowed = true,
    this.requiresTxUnlock = false,
  });

  /// The channel as it should be written to the radio: an un-transmittable
  /// suggestion becomes a receive-only memory, so ticking it can never leave a
  /// radio able to key up somewhere it should not.
  RadioChannel get channelForPlan => txAllowed
      ? channel
      : channel.copyWith(rxOnly: true, txFreqHz: channel.rxFreqHz);

  /// Identity for de-duplication: two listings of the same repeater from two
  /// sources are the same channel, whatever they called it.
  String get dedupeKey =>
      '${channel.rxFreqHz}/${channel.txFreqHz}/'
      '${channel.txTone.label}';

  SuggestedChannel copyWith({
    RadioChannel? channel,
    bool? txAllowed,
    bool? requiresTxUnlock,
    String? details,
  }) => SuggestedChannel(
    channel: channel ?? this.channel,
    category: category,
    sourceId: sourceId,
    distanceKm: distanceKm,
    callsign: callsign,
    details: details ?? this.details,
    txAllowed: txAllowed ?? this.txAllowed,
    requiresTxUnlock: requiresTxUnlock ?? this.requiresTxUnlock,
  );

  @override
  String toString() =>
      'SuggestedChannel(${channel.name}, ${category.name}, $sourceId)';
}
