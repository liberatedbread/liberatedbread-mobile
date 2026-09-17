// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/services/json_fields.dart';

void main() {
  group('jsonStateFields', () {
    test('a flat reply keeps its keys as named', () {
      // The Envoy's /api/v1/production shape — the keys a state_mapping of
      // `wattsNow` looks up verbatim.
      final fields = jsonStateFields(
        '{"wattsNow":2532,"wattHoursToday":18320,'
        '"wattHoursLifetime":10324050}',
      );
      expect(fields['wattsNow'], '2532');
      expect(fields['wattHoursToday'], '18320');
      expect(fields['wattHoursLifetime'], '10324050');
    });

    test('nested maps flatten to dotted paths from the root', () {
      // The Kasa emeter shape — the keys a state_mapping of
      // `emeter.get_realtime.voltage` looks up.
      final fields = jsonStateFields(
        '{"emeter":{"get_realtime":{"voltage":120.4,"current":0.5}}}',
      );
      expect(fields['emeter.get_realtime.voltage'], '120.4');
      expect(fields['emeter.get_realtime.current'], '0.5');
      expect(
        fields.containsKey('voltage'),
        isFalse,
        reason: 'only the full dotted path is a key, not the leaf name',
      );
    });

    test('scalars stringify; arrays, nulls and empty maps drop out', () {
      final fields = jsonStateFields(
        '{"on":true,"alias":"Desk","rssi":-42,'
        '"children":[{"state":1}],"next":null,"empty":{}}',
      );
      expect(fields['on'], 'true');
      expect(fields['alias'], 'Desk');
      expect(fields['rssi'], '-42');
      expect(
        fields.containsKey('children'),
        isFalse,
        reason: 'a dotted path cannot name an array entry',
      );
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

  group('xmlStateFields', () {
    // The Denon receiver's status document, which is what its spec's
    // `state_mapping` paths (`Power.value`, `MasterVolume.value`) are written
    // against — counted from the root's children, not including <item>.
    const denon =
        '<?xml version="1.0" encoding="utf-8"?>'
        '<item>'
        '<Power><value>ON</value></Power>'
        '<InputFuncSelect><value>TV AUDIO</value></InputFuncSelect>'
        '<MasterVolume><value>-40.0</value></MasterVolume>'
        '<Mute><value>off</value></Mute>'
        '</item>';

    test('elements flatten to dotted paths from the root\'s children', () {
      final fields = xmlStateFields(denon);
      expect(fields['Power.value'], 'ON');
      expect(fields['MasterVolume.value'], '-40.0');
      expect(fields['InputFuncSelect.value'], 'TV AUDIO');
      expect(
        fields.containsKey('item.Power.value'),
        isFalse,
        reason: 'the root is the envelope, as it is for a SOAP body',
      );
    });

    test('a namespace prefix does not change the path', () {
      // Some firmware serves these documents without their namespace and some
      // with it; matching the prefixed name would lose whichever it is.
      final fields = xmlStateFields(
        '<x:item xmlns:x="urn:test"><x:Power><x:value>ON</x:value>'
        '</x:Power></x:item>',
      );
      expect(fields['Power.value'], 'ON');
    });

    test('an unparseable reply yields no fields', () {
      expect(xmlStateFields('<unclosed>'), isEmpty);
      expect(xmlStateFields('not xml at all'), isEmpty);
    });
  });

  group('httpStateFields', () {
    test('dispatches on the reply it actually got', () {
      // A state_topic names a resource and the schema says nothing about what
      // that resource serves: the Snapmaker answers JSON, the Denon XML, and
      // both spell their state_mapping paths the same way.
      expect(
        httpStateFields('{"heater_bed":{"temperature":58.2}}'),
        containsPair('heater_bed.temperature', '58.2'),
      );
      expect(
        httpStateFields('<item><Power><value>ON</value></Power></item>'),
        containsPair('Power.value', 'ON'),
      );
    });

    test('leading whitespace does not hide the shape', () {
      expect(
        httpStateFields('\n  <item><a>1</a></item>'),
        containsPair('a', '1'),
      );
      expect(httpStateFields('\n  {"a":1}'), containsPair('a', '1'));
    });
  });
}
