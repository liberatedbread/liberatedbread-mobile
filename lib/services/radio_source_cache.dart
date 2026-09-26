// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// Keeping a state's listings on disk so the second search is instant and the
// offline one still answers.

import 'dart:convert';
import 'dart:io';

import '../core/log.dart';
import 'repeater_source.dart';
import 'spec_pack_service.dart' show CacheDirResolver;

/// What a cache read found.
class CachedListings {
  final List<RepeaterListing> listings;
  final DateTime fetchedAt;

  const CachedListings({required this.listings, required this.fetchedAt});

  bool isStale(Duration ttl, {DateTime? now}) =>
      (now ?? DateTime.now()).difference(fetchedAt) > ttl;
}

/// Per-source, per-state listing cache under the app documents directory.
///
/// Two jobs, and the second is the important one. The first is not asking a
/// third party for the same state twice in a minute -- RepeaterBook's terms
/// ask for exactly that restraint. The second is that a search with no
/// network still answers: a stale copy of the repeaters near you is worth
/// enormously more than an error, and a repeater directory is not a thing
/// that changes hourly.
class RadioSourceCache {
  /// How long a copy is considered fresh. Repeater listings change on the
  /// scale of months; a week is already conservative.
  static const Duration defaultTtl = Duration(days: 7);

  final CacheDirResolver _resolveCacheDir;
  final Duration ttl;

  RadioSourceCache({
    required CacheDirResolver cacheDirResolver,
    this.ttl = defaultTtl,
  }) : _resolveCacheDir = cacheDirResolver;

  Future<Directory> _root() async {
    final base = await _resolveCacheDir();
    return Directory('${base.path}/radio_cache');
  }

  /// Cache paths are built from ids this app controls, but they are still
  /// scrubbed: a source id or state code that ever came from a server must
  /// not be able to write outside the cache directory.
  static String _safe(String value) =>
      value.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');

  Future<File> _file(String sourceId, String stateCode) async => File(
    '${(await _root()).path}/'
    '${_safe(sourceId)}_${_safe(stateCode)}.json',
  );

  /// What is cached for this source and state, fresh or stale, or null.
  ///
  /// Never throws: an unreadable cache is a cache miss.
  Future<CachedListings?> read(String sourceId, String stateCode) async {
    try {
      final file = await _file(sourceId, stateCode);
      if (!await file.exists()) return null;
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map<String, dynamic>) return null;

      final fetchedAt = decoded['fetchedAt'];
      final parsedAt = fetchedAt is String
          ? DateTime.tryParse(fetchedAt)
          : null;
      if (parsedAt == null) return null;

      final raw = decoded['listings'];
      if (raw is! List) return null;
      final listings = <RepeaterListing>[];
      for (final entry in raw) {
        if (entry is! Map<String, dynamic>) continue;
        final listing = RepeaterListing.fromJson(entry);
        if (listing != null) listings.add(listing);
      }
      return CachedListings(listings: listings, fetchedAt: parsedAt);
    } catch (error) {
      Log.radio.debug(
        'cache read failed for $sourceId/$stateCode',
        error: error,
      );
      return null;
    }
  }

  /// Store [listings]. A write failure is logged and swallowed: failing a
  /// search because its results could not be cached would be absurd.
  Future<void> write(
    String sourceId,
    String stateCode,
    List<RepeaterListing> listings, {
    DateTime? now,
  }) async {
    try {
      final file = await _file(sourceId, stateCode);
      await file.parent.create(recursive: true);
      await file.writeAsString(
        jsonEncode({
          'fetchedAt': (now ?? DateTime.now()).toIso8601String(),
          'listings': [for (final listing in listings) listing.toJson()],
        }),
        flush: true,
      );
    } catch (error) {
      Log.radio.debug(
        'cache write failed for $sourceId/$stateCode',
        error: error,
      );
    }
  }

  /// Forget everything. Offered in settings because a user who has been told
  /// a listing is wrong needs a way to stop being shown it.
  Future<void> clear() async {
    try {
      final root = await _root();
      if (await root.exists()) await root.delete(recursive: true);
    } catch (error) {
      Log.radio.warning('cache clear failed', error: error);
    }
  }

  /// Bytes currently held, for the settings screen to report.
  Future<int> sizeInBytes() async {
    try {
      final root = await _root();
      if (!await root.exists()) return 0;
      var total = 0;
      await for (final entry in root.list()) {
        if (entry is File) total += await entry.length();
      }
      return total;
    } catch (error) {
      Log.radio.debug('cache sizing failed', error: error);
      return 0;
    }
  }
}
