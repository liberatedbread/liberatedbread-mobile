// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/core/geo.dart';
import 'package:liberated_bread_mobile/services/radio_bundled_data.dart';
import 'package:liberated_bread_mobile/services/us_state_resolver.dart';

void main() {
  setUpAll(TestWidgetsFlutterBinding.ensureInitialized);

  final data = RadioBundledData();

  test('a small radius in the middle of a state names that state', () async {
    // Wichita, Kansas: about as interior as the lower 48 gets.
    final states = await statesNear(
      data,
      const GeoPoint(37.6872, -97.3301),
      radiusKm: 25,
    );
    expect(states, contains('KS'));
    expect(states, isNot(contains('FL')));
  });

  test('a search near a state line asks both sides', () async {
    // Kansas City sits on the Kansas/Missouri line. Someone here has
    // repeaters in both states within a few kilometres, and a resolver that
    // named only one would lose exactly the ones they are closest to.
    final states = await statesNear(
      data,
      const GeoPoint(39.1, -94.6),
      radiusKm: 30,
    );
    expect(states, containsAll(['KS', 'MO']));
  });

  test('a large radius reaches further without reaching everywhere', () async {
    final wide = await statesNear(
      data,
      const GeoPoint(39.1, -94.6),
      radiusKm: 300,
    );
    final narrow = await statesNear(
      data,
      const GeoPoint(39.1, -94.6),
      radiusKm: 10,
    );
    expect(wide.length, greaterThan(narrow.length));
    expect(wide.length, lessThan(52));
  });

  test('Miami does not ask Alaska', () async {
    // The antimeridian trap: Alaska's raw extent spans nearly every
    // longitude, so an unsplit box would make it a candidate from here.
    final states = await statesNear(
      data,
      const GeoPoint(25.7617, -80.1918),
      radiusKm: 50,
    );
    expect(states, contains('FL'));
    expect(states, isNot(contains('AK')));
  });

  test('Anchorage asks Alaska', () async {
    final states = await statesNear(
      data,
      const GeoPoint(61.2181, -149.9003),
      radiusKm: 50,
    );
    expect(states, contains('AK'));
  });

  test('the longitude pad widens with latitude', () async {
    // A degree of longitude is 111 km at the equator and 54 km at 61 N, so
    // the same radius must span more degrees the further north you go. If it
    // did not, a northern search would silently miss neighbouring states.
    final north = await statesNear(
      data,
      const GeoPoint(48.5, -101.0),
      radiusKm: 200,
    );
    expect(north, contains('ND'));
  });

  test('somewhere with no US state nearby returns nothing', () async {
    final states = await statesNear(
      data,
      const GeoPoint(-33.8688, 151.2093),
      radiusKm: 100,
    );
    expect(states, isEmpty);
  });

  test('an invalid point returns nothing rather than everything', () async {
    final states = await statesNear(
      data,
      const GeoPoint(double.nan, double.nan),
      radiusKm: 50,
    );
    expect(states, isEmpty);
  });

  test('the answer is stable, so a request key built from it is too',
      () async {
    const point = GeoPoint(39.1, -94.6);
    final first = await statesNear(data, point, radiusKm: 100);
    final second = await statesNear(data, point, radiusKm: 100);
    expect(first, second);
  });

  test('a pole does not divide by zero', () async {
    final states = await statesNear(
      data,
      const GeoPoint(89.9, 0),
      radiusKm: 100,
    );
    expect(states, isA<List<String>>());
  });

  group('stateContaining', () {
    test('names the state a point is in', () async {
      final state =
          await stateContaining(data, const GeoPoint(47.6062, -122.3321));
      expect(state?.code, 'WA');
    });

    test('is null outside the bundled extents', () async {
      final state =
          await stateContaining(data, const GeoPoint(-33.8688, 151.2093));
      expect(state, isNull);
    });
  });

  test('an empty bundle yields no states rather than throwing', () async {
    final empty = _EmptyBundleData();
    expect(await statesNear(empty, const GeoPoint(47.6, -122.3), radiusKm: 50),
        isEmpty);
    expect(await stateContaining(empty, const GeoPoint(47.6, -122.3)), isNull);
  });
}

class _EmptyBundleData implements RadioBundledData {
  @override
  Future<List<StateBounds>> stateBounds() async => const [];

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
}
