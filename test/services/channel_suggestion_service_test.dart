// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/core/geo.dart';
import 'package:liberated_bread_mobile/models/radio_channel.dart';
import 'package:liberated_bread_mobile/models/radio_profile.dart';
import 'package:liberated_bread_mobile/models/suggested_channel.dart';
import 'package:liberated_bread_mobile/services/channel_suggestion_service.dart';
import 'package:liberated_bread_mobile/services/radio_bundled_data.dart';
import 'package:liberated_bread_mobile/services/radio_source_cache.dart';
import 'package:liberated_bread_mobile/services/repeater_source.dart';

import '../fakes/fake_repeater_source.dart';

/// Hartford, Connecticut — so the state resolver names CT and the distances
/// below are real ones.
const _hartford = GeoPoint(41.7658, -72.6734);

RepeaterListing _repeater({
  required String name,
  required int rxHz,
  int? txHz,
  required GeoPoint at,
  ToneSetting tone = ToneSetting.none,
  SuggestionCategory category = SuggestionCategory.repeater,
}) => RepeaterListing(
  channel: RadioChannel(
    name: name,
    rxFreqHz: rxHz,
    txFreqHz: txHz ?? rxHz,
    txTone: tone,
  ),
  category: category,
  location: at,
  callsign: name,
);

void main() {
  setUpAll(TestWidgetsFlutterBinding.ensureInitialized);

  late Directory temp;
  late RadioSourceCache cache;
  final bundled = RadioBundledData();

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('suggestion_test');
    cache = RadioSourceCache(cacheDirResolver: () async => temp);
  });

  tearDown(() async {
    if (await temp.exists()) await temp.delete(recursive: true);
  });

  ChannelSuggestionService service(List<RepeaterSource> sources) =>
      ChannelSuggestionService(
        sources: sources,
        cache: cache,
        bundled: bundled,
      );

  SuggestionRequest request({
    RadioProfile profile = uv5rProfile,
    double radiusKm = 40,
    Set<String> sources = const {'test'},
    bool unlock = false,
  }) => SuggestionRequest(
    where: _hartford,
    radiusKm: radiusKm,
    profile: profile,
    enabledSourceIds: sources,
    txUnlockEnabled: unlock,
  );

  group('the offline tier', () {
    test('answers with presets even when nothing is enabled', () async {
      final result = await service([]).suggest(request(sources: const {}));
      expect(result.presets, isNotEmpty);
      expect(result.weather, isNotEmpty);
      expect(result.repeaters, isEmpty);
      expect(result.sourceFailures, isEmpty);
    });

    test('separates the weather channels from the rest', () async {
      final result = await service([]).suggest(request(sources: const {}));
      expect(result.weather, hasLength(7));
      for (final channel in result.weather) {
        expect(channel.category, SuggestionCategory.weather);
        expect(channel.txAllowed, isFalse);
        expect(channel.channel.rxOnly, isTrue);
      }
      for (final channel in result.presets) {
        expect(channel.category, SuggestionCategory.preset);
      }
    });

    test('presets carry no distance, because they have no location', () async {
      final result = await service([]).suggest(request(sources: const {}));
      for (final channel in [...result.presets, ...result.weather]) {
        expect(channel.distanceKm, isNull);
      }
    });
  });

  group('the radius filter', () {
    test('keeps what is inside and drops what is outside', () async {
      final source = FakeRepeaterSource(
        id: 'test',
        byState: {
          'CT': [
            _repeater(
              name: 'CLOSE',
              rxHz: 146940000,
              txHz: 146340000,
              at: _hartford,
            ),
            // Roughly 90 km south-west, so outside a 40 km search.
            _repeater(
              name: 'FAR',
              rxHz: 147000000,
              txHz: 146400000,
              at: const GeoPoint(41.05, -73.55),
            ),
          ],
        },
      );
      final result = await service([source]).suggest(request(radiusKm: 40));

      expect([for (final c in result.repeaters) c.channel.name], ['CLOSE']);
    });

    test('a wider radius reaches further', () async {
      final source = FakeRepeaterSource(
        id: 'test',
        byState: {
          'CT': [
            _repeater(
              name: 'FAR',
              rxHz: 147000000,
              txHz: 146400000,
              at: const GeoPoint(41.05, -73.55),
            ),
          ],
        },
      );
      final result = await service([source]).suggest(request(radiusKm: 160));
      expect(result.repeaters, hasLength(1));
      expect(result.repeaters.single.distanceKm, greaterThan(40));
    });

    test('a listing with no position is dropped, not ranked last', () async {
      final source = FakeRepeaterSource(
        id: 'test',
        byState: {
          'CT': [
            const RepeaterListing(
              channel: RadioChannel(
                name: 'NOWHERE',
                rxFreqHz: 146940000,
                txFreqHz: 146340000,
              ),
              category: SuggestionCategory.repeater,
            ),
          ],
        },
      );
      final result = await service([source]).suggest(request());
      expect(result.repeaters, isEmpty);
    });
  });

  group('judging a channel against the radio', () {
    test('drops what the radio cannot even hear', () async {
      final source = FakeRepeaterSource(
        id: 'test',
        byState: {
          'CT': [
            // 900 MHz: outside every profile's receive range.
            _repeater(name: 'GHOST', rxHz: 927000000, at: _hartford),
          ],
        },
      );
      final result = await service([source]).suggest(request());
      expect(result.repeaters, isEmpty);
    });

    test(
      'offers what it can hear but not transmit on, as listen-only',
      () async {
        final source = FakeRepeaterSource(
          id: 'test',
          byState: {
            // 155 MHz is inside the UV-5R's receive range and outside its
            // transmit range.
            'CT': [_repeater(name: 'PUBLIC', rxHz: 155000000, at: _hartford)],
          },
        );
        final result = await service([source]).suggest(request());

        expect(result.repeaters, hasLength(1));
        final channel = result.repeaters.single;
        expect(channel.txAllowed, isFalse);
        // ...and the channel it would put in a plan cannot key anywhere else.
        expect(channel.channelForPlan.rxOnly, isTrue);
        expect(channel.channelForPlan.txFreqHz, 155000000);
      },
    );

    test('allows transmit inside the factory range', () async {
      final source = FakeRepeaterSource(
        id: 'test',
        byState: {
          'CT': [
            _repeater(
              name: 'HAM',
              rxHz: 146940000,
              txHz: 146340000,
              at: _hartford,
            ),
          ],
        },
      );
      final result = await service([source]).suggest(request());
      expect(result.repeaters.single.txAllowed, isTrue);
      expect(result.repeaters.single.requiresTxUnlock, isFalse);
    });

    test('a GMRS radio hears amateur repeaters but cannot key them', () async {
      final source = FakeRepeaterSource(
        id: 'test',
        byState: {
          'CT': [
            _repeater(
              name: 'HAM',
              rxHz: 146940000,
              txHz: 146340000,
              at: _hartford,
            ),
          ],
        },
      );
      final result = await service([
        source,
      ]).suggest(request(profile: uv5gMiniProfile));
      expect(result.repeaters.single.txAllowed, isFalse);
    });
  });

  group('the transmit-range unlock', () {
    // 140 MHz: outside the UV-5R Mini's factory transmit range and inside its
    // documented expanded one.
    FakeRepeaterSource marsBand() => FakeRepeaterSource(
      id: 'test',
      byState: {
        'CT': [_repeater(name: 'MARS', rxHz: 140000000, at: _hartford)],
      },
    );

    test('is listen-only with the unlock off', () async {
      final result = await service([
        marsBand(),
      ]).suggest(request(profile: uv5rProfile));
      expect(result.repeaters.single.txAllowed, isFalse);
      expect(result.repeaters.single.requiresTxUnlock, isFalse);
    });

    test('becomes transmittable, and badged, with the unlock on', () async {
      final result = await service([
        marsBand(),
      ]).suggest(request(profile: uv5rProfile, unlock: true));
      final channel = result.repeaters.single;
      expect(channel.txAllowed, isTrue);
      expect(channel.requiresTxUnlock, isTrue);
    });

    test('does not badge a channel that was always transmittable', () async {
      final source = FakeRepeaterSource(
        id: 'test',
        byState: {
          'CT': [
            _repeater(
              name: 'HAM',
              rxHz: 146940000,
              txHz: 146340000,
              at: _hartford,
            ),
          ],
        },
      );
      final result = await service([
        source,
      ]).suggest(request(profile: uv5rProfile, unlock: true));
      expect(result.repeaters.single.txAllowed, isTrue);
      expect(result.repeaters.single.requiresTxUnlock, isFalse);
    });

    test('changes nothing for a radio that cannot unlock', () async {
      // The setting is stored per profile, but a stale "on" must never grant
      // a range to a radio with no software path to it.
      const noUnlock = RadioProfile(
        id: 'test-no-unlock',
        displayName: 'Test',
        rxRanges: [FreqRange(136000000, 174000000)],
        factoryTxRanges: [FreqRange(144000000, 148000000)],
        channelCapacity: 16,
        nameLength: 6,
        programmingFamily: ProgrammingFamily.serialUv5r,
      );
      final result = await service([
        marsBand(),
      ]).suggest(request(profile: noUnlock, unlock: true));
      expect(result.repeaters.single.txAllowed, isFalse);
      expect(result.repeaters.single.requiresTxUnlock, isFalse);
    });

    test(
      'the request keys differ, so the two runs cannot share a cache entry',
      () {
        expect(request(unlock: true), isNot(request()));
        expect(request(unlock: true).hashCode, isNot(request().hashCode));
      },
    );
  });

  group('de-duplication', () {
    test('two directories describing one repeater yield one entry', () async {
      final near = FakeRepeaterSource(
        id: 'near',
        byState: {
          'CT': [
            _repeater(
              name: 'W1AW',
              rxHz: 146940000,
              txHz: 146340000,
              at: _hartford,
              tone: const ToneSetting.ctcss(1000),
            ),
          ],
        },
      );
      final far = FakeRepeaterSource(
        id: 'far',
        byState: {
          'CT': [
            _repeater(
              // Same machine, different name, and a position 10 km off.
              name: 'Newington',
              rxHz: 146940000,
              txHz: 146340000,
              at: const GeoPoint(41.85, -72.70),
              tone: const ToneSetting.ctcss(1000),
            ),
          ],
        },
      );

      final result = await service([
        near,
        far,
      ]).suggest(request(sources: {'near', 'far'}));

      expect(result.repeaters, hasLength(1));
      // The nearer listing wins, which is the one whose distance is right.
      expect(result.repeaters.single.channel.name, 'W1AW');
      expect(result.repeaters.single.sourceId, 'near');
    });

    test('keeps repeaters that differ only by access tone', () async {
      final source = FakeRepeaterSource(
        id: 'test',
        byState: {
          'CT': [
            _repeater(
              name: 'A',
              rxHz: 146940000,
              txHz: 146340000,
              at: _hartford,
              tone: const ToneSetting.ctcss(1000),
            ),
            _repeater(
              name: 'B',
              rxHz: 146940000,
              txHz: 146340000,
              at: _hartford,
              tone: const ToneSetting.ctcss(1072),
            ),
          ],
        },
      );
      final result = await service([source]).suggest(request());
      expect(result.repeaters, hasLength(2));
    });
  });

  test('results are ranked by distance, nearest first', () async {
    final source = FakeRepeaterSource(
      id: 'test',
      byState: {
        'CT': [
          _repeater(
            name: 'MID',
            rxHz: 146700000,
            txHz: 146100000,
            at: const GeoPoint(41.85, -72.75),
          ),
          _repeater(
            name: 'NEAR',
            rxHz: 146940000,
            txHz: 146340000,
            at: _hartford,
          ),
          _repeater(
            name: 'FARTHER',
            rxHz: 147150000,
            txHz: 147750000,
            at: const GeoPoint(42.05, -72.60),
          ),
        ],
      },
    );
    final result = await service([source]).suggest(request());

    expect(
      [for (final c in result.repeaters) c.channel.name],
      ['NEAR', 'MID', 'FARTHER'],
    );
    final distances = [for (final c in result.repeaters) c.distanceKm!];
    expect(distances, [...distances]..sort());
  });

  group('failures never sink the search', () {
    test('a failing source leaves the others and the presets intact', () async {
      final broken = FakeRepeaterSource(
        id: 'broken',
        displayName: 'Broken',
        failure: const SourceFailure(
          sourceId: 'broken',
          displayName: 'Broken',
          kind: SourceFailureKind.network,
          message: 'offline',
        ),
      );
      final working = FakeRepeaterSource(
        id: 'working',
        byState: {
          'CT': [
            _repeater(
              name: 'OK',
              rxHz: 146940000,
              txHz: 146340000,
              at: _hartford,
            ),
          ],
        },
      );

      final result = await service([
        broken,
        working,
      ]).suggest(request(sources: {'broken', 'working'}));

      expect(result.repeaters, hasLength(1));
      expect(result.presets, isNotEmpty);
      expect(result.sourceFailures, hasLength(1));
      expect(result.sourceFailures.single.sourceId, 'broken');
    });

    test(
      'an unconfigured source is reported as needing setup, not asked',
      () async {
        final unconfigured = FakeRepeaterSource(
          id: 'needs-token',
          configured: false,
        );
        final result = await service([
          unconfigured,
        ]).suggest(request(sources: {'needs-token'}));

        expect(unconfigured.fetched, isEmpty);
        expect(result.sourceFailures.single.kind, SourceFailureKind.auth);
        expect(result.sourceFailures.single.isActionable, isTrue);
      },
    );

    test('a disabled source is not asked and is not a failure', () async {
      final source = FakeRepeaterSource(id: 'test');
      final result = await service([
        source,
      ]).suggest(request(sources: const {}));
      expect(source.fetched, isEmpty);
      expect(result.sourceFailures, isEmpty);
    });

    test('one failure per source, however many states failed', () async {
      // Three states failing the same way is one problem; three identical
      // rows would be noise.
      final broken = FakeRepeaterSource(
        id: 'broken',
        failure: const SourceFailure(
          sourceId: 'broken',
          displayName: 'Broken',
          kind: SourceFailureKind.network,
          message: 'offline',
        ),
      );
      final result = await service([
        broken,
      ]).suggest(request(sources: {'broken'}, radiusKm: 160));

      expect(
        broken.fetched.length,
        greaterThan(1),
        reason: 'a 160 km radius from Hartford must reach several states',
      );
      expect(result.sourceFailures, hasLength(1));
    });
  });

  group('caching', () {
    test('a fresh cache is used instead of asking again', () async {
      final source = FakeRepeaterSource(
        id: 'test',
        byState: {
          'CT': [
            _repeater(
              name: 'OK',
              rxHz: 146940000,
              txHz: 146340000,
              at: _hartford,
            ),
          ],
        },
      );
      final engine = service([source]);

      await engine.suggest(request());
      final firstCallCount = source.fetched.length;
      await engine.suggest(request());

      expect(
        source.fetched.length,
        firstCallCount,
        reason: 'the second search must come from the cache',
      );
    });

    test('a stale cache answers when the live fetch fails', () async {
      // This is the offline case, and the reason the cache exists at all:
      // last week s repeater list beats an error by a wide margin.
      await cache.write('test', 'CT', [
        _repeater(
          name: 'CACHED',
          rxHz: 146940000,
          txHz: 146340000,
          at: _hartford,
        ),
      ], now: DateTime.now().subtract(const Duration(days: 30)));
      final broken = FakeRepeaterSource(
        id: 'test',
        failure: const SourceFailure(
          sourceId: 'test',
          displayName: 'Test',
          kind: SourceFailureKind.network,
          message: 'offline',
        ),
      );

      final result = await service([broken]).suggest(request());

      expect(result.repeaters.single.channel.name, 'CACHED');
      expect(
        result.usedStaleCache,
        isTrue,
        reason: 'the screen has to be able to say the data is old',
      );
      expect(result.sourceFailures, hasLength(1));
    });

    test('a fresh search does not claim to be stale', () async {
      final source = FakeRepeaterSource(
        id: 'test',
        byState: {
          'CT': [
            _repeater(
              name: 'OK',
              rxHz: 146940000,
              txHz: 146340000,
              at: _hartford,
            ),
          ],
        },
      );
      final result = await service([source]).suggest(request());
      expect(result.usedStaleCache, isFalse);
    });
  });

  group('attribution', () {
    test('is listed for the sources that actually contributed', () async {
      final used = FakeRepeaterSource(
        id: 'used',
        attribution: 'Data from Used',
        byState: {
          'CT': [
            _repeater(
              name: 'OK',
              rxHz: 146940000,
              txHz: 146340000,
              at: _hartford,
            ),
          ],
        },
      );
      final unused = FakeRepeaterSource(
        id: 'unused',
        attribution: 'Data from Unused',
      );

      final result = await service([
        used,
        unused,
      ]).suggest(request(sources: {'used', 'unused'}));

      final lines = result.attributionsFor([used, unused]);
      expect(lines, ['Data from Used']);
    });
  });

  group('category order', () {
    test('puts GMRS first for a GMRS radio', () {
      expect(categoryOrderFor(uv5gMiniProfile).first, SuggestionCategory.gmrs);
      expect(categoryOrderFor(uv5rProfile).first, SuggestionCategory.repeater);
    });

    test('lists every category exactly once, whichever radio', () {
      for (final profile in radioProfiles) {
        final order = categoryOrderFor(profile);
        expect(
          order.toSet(),
          SuggestionCategory.values.toSet(),
          reason: profile.id,
        );
        expect(order, hasLength(SuggestionCategory.values.length));
      }
    });
  });

  test('forCategory and total agree with the lists', () async {
    final source = FakeRepeaterSource(
      id: 'test',
      byState: {
        'CT': [
          _repeater(
            name: 'OK',
            rxHz: 146940000,
            txHz: 146340000,
            at: _hartford,
          ),
        ],
      },
    );
    final result = await service([source]).suggest(request());

    expect(result.forCategory(SuggestionCategory.repeater), result.repeaters);
    expect(result.forCategory(SuggestionCategory.weather), result.weather);
    expect(
      result.total,
      result.repeaters.length +
          result.gmrs.length +
          result.weather.length +
          result.presets.length,
    );
    expect(result.isEmpty, isFalse);
    expect(const SuggestionResult().isEmpty, isTrue);
  });
}
