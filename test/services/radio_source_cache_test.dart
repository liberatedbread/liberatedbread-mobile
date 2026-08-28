// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/core/geo.dart';
import 'package:liberated_bread_mobile/models/radio_channel.dart';
import 'package:liberated_bread_mobile/models/suggested_channel.dart';
import 'package:liberated_bread_mobile/services/radio_source_cache.dart';
import 'package:liberated_bread_mobile/services/repeater_source.dart';

const _listing = RepeaterListing(
  channel: RadioChannel(
    name: 'WT1EST',
    rxFreqHz: 146940000,
    txFreqHz: 146340000,
    txTone: ToneSetting.ctcss(1000),
  ),
  category: SuggestionCategory.repeater,
  location: GeoPoint(41.7291, -72.7083),
  callsign: 'WT1EST',
  details: 'Testington',
);

void main() {
  late Directory temp;
  late RadioSourceCache cache;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('radio_cache_test');
    cache = RadioSourceCache(cacheDirResolver: () async => temp);
  });

  tearDown(() async {
    if (await temp.exists()) await temp.delete(recursive: true);
  });

  test('a miss is null, not an error', () async {
    expect(await cache.read('repeaterbook', 'CT'), isNull);
  });

  test('round-trips a listing', () async {
    await cache.write('repeaterbook', 'CT', [_listing]);
    final cached = await cache.read('repeaterbook', 'CT');

    expect(cached, isNotNull);
    expect(cached!.listings, hasLength(1));
    final listing = cached.listings.single;
    expect(listing.channel, _listing.channel);
    expect(listing.location, _listing.location);
    expect(listing.callsign, 'WT1EST');
    expect(listing.details, 'Testington');
    expect(listing.category, SuggestionCategory.repeater);
  });

  test('keeps sources and states apart', () async {
    await cache.write('repeaterbook', 'CT', [_listing]);
    expect(await cache.read('mygmrs', 'CT'), isNull);
    expect(await cache.read('repeaterbook', 'MA'), isNull);
  });

  test('reports staleness against its TTL', () async {
    final old = DateTime.now().subtract(const Duration(days: 30));
    await cache.write('repeaterbook', 'CT', [_listing], now: old);

    final cached = await cache.read('repeaterbook', 'CT');
    expect(cached!.isStale(const Duration(days: 7)), isTrue);
    expect(cached.isStale(const Duration(days: 60)), isFalse);
    // Stale is not gone: an offline search is answered from exactly this.
    expect(cached.listings, hasLength(1));
  });

  test('fresh is fresh', () async {
    await cache.write('repeaterbook', 'CT', [_listing]);
    final cached = await cache.read('repeaterbook', 'CT');
    expect(cached!.isStale(RadioSourceCache.defaultTtl), isFalse);
  });

  test('an unreadable file is a miss rather than a crash', () async {
    await cache.write('repeaterbook', 'CT', [_listing]);
    final file = File('${temp.path}/radio_cache/repeaterbook_CT.json');
    await file.writeAsString('{ this is not json');
    expect(await cache.read('repeaterbook', 'CT'), isNull);
  });

  test('a file with no timestamp is a miss', () async {
    final dir = Directory('${temp.path}/radio_cache');
    await dir.create(recursive: true);
    await File('${dir.path}/repeaterbook_CT.json')
        .writeAsString('{"listings": []}');
    expect(await cache.read('repeaterbook', 'CT'), isNull);
  });

  test('one corrupt listing costs itself, not the state', () async {
    final dir = Directory('${temp.path}/radio_cache');
    await dir.create(recursive: true);
    await File('${dir.path}/repeaterbook_CT.json').writeAsString(
      '{"fetchedAt": "2026-08-01T00:00:00.000Z", "listings": ['
      '{"channel": {"name": "ok", "rx": 146940000}},'
      '{"channel": {"name": "no frequency"}},'
      '"not a map"'
      ']}',
    );
    final cached = await cache.read('repeaterbook', 'CT');
    expect(cached!.listings, hasLength(1));
  });

  test('a listing with no location survives the round trip as one', () async {
    const placeless = RepeaterListing(
      channel:
          RadioChannel(name: 'X', rxFreqHz: 146520000, txFreqHz: 146520000),
      category: SuggestionCategory.gmrs,
    );
    await cache.write('mygmrs', 'WY', [placeless]);
    final cached = await cache.read('mygmrs', 'WY');
    expect(cached!.listings.single.location, isNull);
    expect(cached.listings.single.category, SuggestionCategory.gmrs);
  });

  test('scrubs the path components it is given', () async {
    // These ids come from this app, not from a server -- but a cache that can
    // be talked into writing outside its own directory is the kind of thing
    // that only becomes reachable later.
    await cache.write('../../etc', 'CT/../..', [_listing]);
    final root = Directory('${temp.path}/radio_cache');
    final names = [
      for (final entry in root.listSync()) entry.uri.pathSegments.last
    ];
    expect(names, hasLength(1));
    expect(names.single, isNot(contains('/')));
    expect(names.single, isNot(contains('..')));
    // ...and it still reads back through the same scrubbing.
    expect((await cache.read('../../etc', 'CT/../..'))!.listings, hasLength(1));
  });

  test('a write failure does not fail the search', () async {
    // The results are already in hand; failing to cache them is not worth
    // losing them over.
    final broken = RadioSourceCache(
      cacheDirResolver: () async => throw const FileSystemException('nope'),
    );
    await broken.write('repeaterbook', 'CT', [_listing]);
    expect(await broken.read('repeaterbook', 'CT'), isNull);
  });

  test('reports its size and clears', () async {
    expect(await cache.sizeInBytes(), 0);
    await cache.write('repeaterbook', 'CT', [_listing]);
    await cache.write('mygmrs', 'RI', [_listing]);
    expect(await cache.sizeInBytes(), greaterThan(0));

    await cache.clear();
    expect(await cache.read('repeaterbook', 'CT'), isNull);
    expect(await cache.sizeInBytes(), 0);
    // Clearing twice is not an error.
    await cache.clear();
  });
}
