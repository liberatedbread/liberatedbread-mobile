// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/core/geo.dart';
import 'package:liberated_bread_mobile/services/radio_bundled_data.dart';

/// A bundle that answers one asset with whatever a test hands it.
class _FakeBundle extends CachingAssetBundle {
  _FakeBundle(this.payload);

  final String? payload;

  @override
  Future<ByteData> load(String key) async {
    final body = payload;
    if (body == null) throw FlutterError('asset not found: $key');
    return ByteData.sublistView(Uint8List.fromList(body.codeUnits));
  }

  @override
  Future<String> loadString(String key, {bool cache = true}) async {
    final body = payload;
    if (body == null) throw FlutterError('asset not found: $key');
    return body;
  }
}

void main() {
  group('StateBounds', () {
    const washington = StateBounds(
      code: 'WA',
      name: 'Washington',
      boxes: [
        (minLat: 45.5443, minLon: -124.7258, maxLat: 49.0025, maxLon: -116.916),
      ],
    );

    test('overlaps a window that touches it', () {
      expect(
        washington.overlaps(minLat: 47, maxLat: 48, minLon: -123, maxLon: -122),
        isTrue,
      );
      // Sharing only an edge still counts: the window is already padded by a
      // search radius, so an exclusive test would drop a state the user is
      // standing on the line of.
      expect(
        washington.overlaps(
          minLat: 49.0025,
          maxLat: 51,
          minLon: -120,
          maxLon: -119,
        ),
        isTrue,
      );
    });

    test('does not overlap a window elsewhere', () {
      expect(
        washington.overlaps(minLat: 25, maxLat: 26, minLon: -81, maxLon: -80),
        isFalse,
      );
    });

    test('contains a point inside its box', () {
      expect(washington.contains(const GeoPoint(47.6062, -122.3321)), isTrue);
      expect(washington.contains(const GeoPoint(25.7617, -80.1918)), isFalse);
    });

    test('decodes defensively', () {
      expect(StateBounds.fromJson(const {}), isNull);
      expect(
        StateBounds.fromJson(const {'code': '', 'boxes': <Object>[]}),
        isNull,
      );
      expect(StateBounds.fromJson(const {'code': 'WA'}), isNull);
      // A boxes list whose entries are all unusable is no better than none.
      expect(
        StateBounds.fromJson(const {
          'code': 'WA',
          'boxes': [
            {'minLat': 'north'},
          ],
        }),
        isNull,
      );
    });

    test('falls back to the code when the name is missing', () {
      final bounds = StateBounds.fromJson(const {
        'code': 'WA',
        'boxes': [
          {'minLat': 45.0, 'minLon': -125.0, 'maxLat': 49.0, 'maxLon': -117.0},
        ],
      });
      expect(bounds!.name, 'WA');
    });
  });

  group('loading', () {
    test('a missing asset costs the online sources, not the app', () async {
      final data = RadioBundledData(bundle: _FakeBundle(null));
      expect(await data.stateBounds(), isEmpty);
    });

    test('a non-JSON asset degrades to empty', () async {
      final data = RadioBundledData(bundle: _FakeBundle('not json at all'));
      expect(await data.stateBounds(), isEmpty);
    });

    test('a JSON array where an object belongs degrades to empty', () async {
      final data = RadioBundledData(bundle: _FakeBundle('[1, 2, 3]'));
      expect(await data.stateBounds(), isEmpty);
    });

    test('skips unreadable states and keeps the rest', () async {
      final data = RadioBundledData(
        bundle: _FakeBundle(
          '{"states": ['
          '{"code": "WA", "name": "Washington", "boxes": ['
          '{"minLat": 45.0, "minLon": -125.0, "maxLat": 49.0, '
          '"maxLon": -117.0}]},'
          '{"code": "", "boxes": []},'
          '"not a map"'
          ']}',
        ),
      );
      final states = await data.stateBounds();
      expect(states, hasLength(1));
      expect(states.single.code, 'WA');
    });

    test('parses once and caches', () async {
      final data = RadioBundledData(bundle: _FakeBundle('{"states": []}'));
      final first = await data.stateBounds();
      expect(identical(first, await data.stateBounds()), isTrue);
    });
  });

  // Against the real shipped asset, so a bad regeneration is caught here
  // rather than by a user whose repeater search quietly returns nothing.
  group('the bundled state extents', () {
    setUpAll(TestWidgetsFlutterBinding.ensureInitialized);

    test('cover every state, DC and Puerto Rico', () async {
      final states = await RadioBundledData().stateBounds();
      expect(states.length, greaterThanOrEqualTo(52));
      final codes = {for (final state in states) state.code};
      for (final code in ['WA', 'CA', 'TX', 'NY', 'FL', 'HI', 'AK', 'DC']) {
        expect(codes, contains(code), reason: code);
      }
    });

    test('put a few known cities in the right state', () async {
      final states = await RadioBundledData().stateBounds();
      StateBounds? find(String code) =>
          states.where((s) => s.code == code).firstOrNull;

      expect(find('WA')!.contains(const GeoPoint(47.6062, -122.3321)), isTrue);
      expect(find('FL')!.contains(const GeoPoint(25.7617, -80.1918)), isTrue);
      expect(find('CT')!.contains(const GeoPoint(41.7291, -72.7083)), isTrue);
      // ...and not in the wrong one.
      expect(find('WA')!.contains(const GeoPoint(25.7617, -80.1918)), isFalse);
    });

    test('split Alaska at the antimeridian', () async {
      // The Aleutians run past 180 east. Left as one box, Alaska spans nearly
      // every longitude and becomes a candidate state from Miami.
      final states = await RadioBundledData().stateBounds();
      final alaska = states.firstWhere((s) => s.code == 'AK');
      expect(alaska.boxes.length, 2);
      expect(alaska.contains(const GeoPoint(61.2181, -149.9003)), isTrue);
      expect(alaska.contains(const GeoPoint(25.7617, -80.1918)), isFalse);
    });

    test('every box is a box', () async {
      final states = await RadioBundledData().stateBounds();
      for (final state in states) {
        expect(state.boxes, isNotEmpty, reason: state.code);
        for (final box in state.boxes) {
          expect(box.minLat, lessThanOrEqualTo(box.maxLat), reason: state.code);
          expect(box.minLon, lessThanOrEqualTo(box.maxLon), reason: state.code);
          expect(box.minLat, greaterThanOrEqualTo(-90.0));
          expect(box.maxLat, lessThanOrEqualTo(90.0));
        }
      }
    });
  });
}
