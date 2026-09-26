// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// The seam every online repeater directory plugs into.

import '../core/error_text.dart';
import '../core/geo.dart';
import '../models/radio_channel.dart';
import '../models/suggested_channel.dart';

/// One repeater as a directory describes it: a channel, and where it is.
///
/// Distinct from [SuggestedChannel] because a source knows the machine and
/// nothing about the person searching. Distance, whether the selected radio
/// can transmit there, and whether it survives de-duplication are all
/// decisions the suggestion engine makes afterwards — a source that tried to
/// make them would have to be told the radio profile and the search point,
/// and every new source would have to get that right again.
class RepeaterListing {
  final RadioChannel channel;

  /// Where the repeater is. Null when a listing carries no usable
  /// coordinates, which happens: the engine drops those rather than guessing.
  final GeoPoint? location;

  final SuggestionCategory category;
  final String? callsign;

  /// Anything worth reading before ticking the box — the town it sits in,
  /// whether it is open, whether the tone is unknown.
  final String? details;

  const RepeaterListing({
    required this.channel,
    required this.category,
    this.location,
    this.callsign,
    this.details,
  });

  Map<String, dynamic> toJson() => {
    'channel': channel.toJson(),
    if (location != null) 'location': location!.toJson(),
    'category': category.name,
    if (callsign != null) 'callsign': callsign,
    if (details != null) 'details': details,
  };

  /// Returns null for a listing that cannot be read, so one bad record in a
  /// cached state costs itself and not the state.
  static RepeaterListing? fromJson(Map<String, dynamic> json) {
    final rawChannel = json['channel'];
    if (rawChannel is! Map<String, dynamic>) return null;
    final channel = RadioChannel.fromJson(rawChannel);
    if (channel == null) return null;

    final rawLocation = json['location'];
    final location = rawLocation is Map<String, dynamic>
        ? GeoPoint.fromJson(rawLocation)
        : null;

    final categoryName = json['category'];
    var category = SuggestionCategory.repeater;
    for (final value in SuggestionCategory.values) {
      if (value.name == categoryName) category = value;
    }

    final callsign = json['callsign'];
    final details = json['details'];
    return RepeaterListing(
      channel: channel,
      category: category,
      location: location,
      callsign: callsign is String && callsign.isNotEmpty ? callsign : null,
      details: details is String && details.isNotEmpty ? details : null,
    );
  }
}

/// Why a source did not answer.
///
/// The kind matters because the recoveries differ completely: a missing token
/// wants a settings screen, a rate limit wants patience, and a network
/// failure wants the cached copy the engine already fell back to.
enum SourceFailureKind {
  /// No credential configured, or the one configured was refused.
  auth,

  /// Asked too often. Back off.
  rateLimited,

  /// Could not reach the service at all.
  network,

  /// Reached it, and could not make sense of the answer.
  parse,
}

/// A source that did not answer, in a form the results screen can show.
class SourceFailure {
  final String sourceId;
  final String displayName;
  final SourceFailureKind kind;
  final String message;

  const SourceFailure({
    required this.sourceId,
    required this.displayName,
    required this.kind,
    required this.message,
  });

  /// Whether the fix is something the user does in settings rather than
  /// something they wait out.
  bool get isActionable => kind == SourceFailureKind.auth;

  @override
  String toString() => '$displayName: $message';
}

/// Thrown by a source when a fetch fails. Carries the failure the engine will
/// surface, so the mapping from "what went wrong" to "what to tell the user"
/// lives in the client that knows, not in the engine that does not.
class RepeaterSourceException implements UserFacingException {
  final SourceFailure failure;

  const RepeaterSourceException(this.failure);

  @override
  String get message => failure.message;

  @override
  String toString() => failure.toString();
}

/// A directory of repeaters that can be queried a state at a time.
///
/// State-scoped because that is what both services offer: neither has a
/// proximity query. The engine turns a position and a radius into state codes
/// and filters by distance afterwards.
abstract class RepeaterSource {
  /// Stable id, used in cache paths, settings keys and suggestion provenance.
  String get id;

  String get displayName;

  /// Attribution that must appear wherever this source's data is shown, or
  /// null if the service asks for none. Not optional where it is set: it is a
  /// term of use, not a courtesy.
  String? get attribution;

  /// Whether this source can run at all right now — false when it needs a
  /// credential nobody has entered. Checked before fetching so the UI can
  /// explain rather than fail.
  Future<bool> isConfigured();

  /// Every listing this source has for [stateCode] (a postal abbreviation).
  ///
  /// Throws [RepeaterSourceException] on any failure. Returning an empty list
  /// means "this state genuinely has none", which is a different thing.
  Future<List<RepeaterListing>> fetchByState(String stateCode);
}
