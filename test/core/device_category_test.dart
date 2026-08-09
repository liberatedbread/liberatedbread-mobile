// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/core/device_category.dart';
import 'package:liberated_bread_mobile/providers/device_spec_provider.dart';

void main() {
  group('DeviceCategory.parse', () {
    test('reads the spec vocabulary, case- and whitespace-insensitively', () {
      expect(DeviceCategory.parse('light'), DeviceCategory.light);
      expect(DeviceCategory.parse('SENSOR'), DeviceCategory.sensor);
      expect(DeviceCategory.parse('  motor  '), DeviceCategory.motor);
    });

    test('maps the reserved-word category onto its wire spelling', () {
      // `switch` is a Dart keyword, so the member is `switch_` while the spec
      // says `switch`. If these ever come apart, every smart plug in the
      // catalogue quietly loses its icon.
      expect(DeviceCategory.parse('switch'), DeviceCategory.switch_);
      expect(DeviceCategory.switch_.wireName, 'switch');
    });

    test('answers null rather than throwing for a category it has not met', () {
      // The vocabulary is owned upstream and grows there first. A spec pack
      // refreshed at runtime can name a category this build has never heard
      // of, and losing the icon is the correct cost — losing the device is
      // not.
      expect(DeviceCategory.parse('teleporter'), isNull);
      expect(DeviceCategory.parse(''), isNull);
      expect(DeviceCategory.parse(null), isNull);
    });

    test('every member round-trips through its wire name', () {
      for (final category in DeviceCategory.values) {
        expect(DeviceCategory.parse(category.wireName), category,
            reason: '${category.name} does not parse back from its wire name');
      }
    });
  });

  test('every category the vendored catalogue uses is one this build knows',
      () {
    // The drift guard across the subtree boundary. The vocabulary is defined
    // upstream in protocol-specs' schema.json and arrives here as vendored
    // data, so a category added there lands with no code change — and shows up
    // as a device silently wearing the anonymous glyph. This turns that into a
    // failing test instead.
    //
    // It asserts what this repo is actually responsible for, and no more.
    // Whether a spec *states* a category is the upstream schema's rule, tested
    // upstream; restating it here would fail this branch until a spec release
    // lands, over something no app change can fix. So an absent category is
    // simply a device without an icon, which is exactly how the app treats it.
    final index = jsonDecode(
      File(specManifestPath).readAsStringSync(),
    ) as List<dynamic>;
    expect(index, isNotEmpty, reason: 'index.json should list specs');

    final unknown = <String, String>{};
    var stated = 0;
    for (final entry in index.cast<Map<String, dynamic>>()) {
      final category = entry['category'];
      if (category is! String || category.isEmpty) continue;
      stated++;
      if (DeviceCategory.parse(category) == null) {
        unknown[entry['name'] as String? ?? '?'] = category;
      }
    }

    printOnFailure('$stated of ${index.length} vendored spec(s) '
        'state a category');
    expect(unknown, isEmpty,
        reason: 'DeviceCategory is missing values used by vendored specs: '
            '$unknown. Add them here (with an icon) to match schema.json.');
  });
}
