// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'package:liberated_bread_mobile/services/repeater_source.dart';

/// A [RepeaterSource] that answers from a map, or fails on command.
class FakeRepeaterSource implements RepeaterSource {
  @override
  final String id;

  @override
  final String displayName;

  @override
  final String? attribution;

  /// Listings per state code.
  final Map<String, List<RepeaterListing>> byState;

  /// When set, every fetch throws this instead of answering.
  SourceFailure? failure;

  /// Answered by [isConfigured].
  bool configured;

  /// Every state code fetched, in order — so a test can prove the engine
  /// asked for the states it should have, and only those.
  final List<String> fetched = [];

  FakeRepeaterSource({
    required this.id,
    String? displayName,
    this.attribution,
    Map<String, List<RepeaterListing>>? byState,
    this.failure,
    this.configured = true,
  }) : displayName = displayName ?? id,
       byState = byState ?? {};

  @override
  Future<bool> isConfigured() async => configured;

  @override
  Future<List<RepeaterListing>> fetchByState(String stateCode) async {
    fetched.add(stateCode);
    final problem = failure;
    if (problem != null) throw RepeaterSourceException(problem);
    return byState[stateCode] ?? const [];
  }
}
