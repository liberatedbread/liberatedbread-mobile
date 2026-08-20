// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/services/json_fields.dart';

void main() {
  group('jsonStateFields', () {
    test('a flat reply keeps its keys as named', () {
      // The Envoy's /api/v1/production shape — the keys a state_mapping of
      // `wattsNow` looks up verbatim.
      final fields = jsonStateFields('{"wattsNow":2532,"wattHoursToday":18320,'
          '"wattHoursLifetime":10324050}');
      expect(fields['wattsNow'], '2532');
      expect(fields['wattHoursToday'], '18320');
      expect(fields['wattHoursLifetime'], '10324050');
    });

    test('nested maps flatten to dotted paths from the root', () {
      // The Kasa emeter shape — the keys a state_mapping of
      // `emeter.get_realtime.voltage` looks up.
      final fields = jsonStateFields(
          '{"emeter":{"get_realtime":{"voltage":120.4,"current":0.5}}}');
      expect(fields['emeter.get_realtime.voltage'], '120.4');
      expect(fields['emeter.get_realtime.current'], '0.5');
      expect(fields.containsKey('voltage'), isFalse,
          reason: 'only the full dotted path is a key, not the leaf name');
    });

    test('scalars stringify; arrays, nulls and empty maps drop out', () {
      final fields = jsonStateFields('{"on":true,"alias":"Desk","rssi":-42,'
          '"children":[{"state":1}],"next":null,"empty":{}}');
      expect(fields['on'], 'true');
      expect(fields['alias'], 'Desk');
      expect(fields['rssi'], '-42');
      expect(fields.containsKey('children'), isFalse,
          reason: 'a dotted path cannot name an array entry');
      expect(fields.containsKey('next'), isFalse);
      expect(fields.containsKey('empty'), isFalse);
    });

    test('an unparseable or non-object reply yields no fields', () {
      expect(jsonStateFields('not json at all'), isEmpty);
      expect(jsonStateFields('[1,2,3]'), isEmpty);
      expect(jsonStateFields('"just a string"'), isEmpty);
      expect(jsonStateFields('42'), isEmpty);
    });
  });
}
