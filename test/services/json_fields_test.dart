// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/services/json_fields.dart';
import 'package:liberated_bread_mobile/src/rust/api/device_api.dart'
    show roombaStateFields;

import '../helpers/host_rust_lib.dart';

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

    test(
      'scalars stringify; arrays keep their JSON; nulls and empty maps drop',
      () {
        final fields = jsonStateFields(
          '{"on":true,"alias":"Desk","rssi":-42,'
          '"children":[{"state":1}],"next":null,"empty":{}}',
        );
        expect(fields['on'], 'true');
        expect(fields['alias'], 'Desk');
        expect(fields['rssi'], '-42');
        // R-043: the Kasa flattener has always kept an array as its JSON text,
        // and these two are one `state_mapping` convention — so a spec path
        // naming an array used to resolve on a plug and resolve to nothing over
        // HTTP, the same key working on one transport and silently not on the
        // other.
        expect(fields['children'], '[{"state":1}]');
        expect(fields.containsKey('next'), isFalse);
        expect(fields.containsKey('empty'), isFalse);
      },
    );

    test('a document nested past the cap is dropped, not followed', () {
      // Device-supplied, so its depth is the device's choice; recursion the
      // sender does not bound is a stack overflow that takes the poll down.
      var json = '{"leaf":1}';
      for (var i = 0; i < 40; i++) {
        json = '{"a":$json}';
      }
      final fields = jsonStateFields(json);
      expect(fields, isEmpty);
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

  group('how the Rust flattener differs from this one (R-147)', () {
    late final bool rustReady;

    setUpAll(() async {
      TestWidgetsFlutterBinding.ensureInitialized();
      rustReady = await initHostRustLib();
    });

    // R-147 reads these as the same decoder written twice. They are nearly
    // that, and they differ on exactly one thing, on purpose and in both
    // directions:
    //
    //   * `roomba::state_fields` renders a JSON boolean as 1/0, because the
    //     robot's spec says `on_when: nonzero` for `bin.full` and a reading
    //     of "true" would never satisfy it;
    //   * this one renders true/false, because the entity reader turns those
    //     straight into on/off (soap.rs) and the Rabbit Air spec relies on
    //     it — its boolean fields deliberately declare no `on_when` at all.
    //
    // …and on one more, for the same kind of reason: this one keeps an array
    // as its JSON text because a Kasa power strip's `children` array IS its
    // outlets and a spec path names it, while the robot's flattener skips
    // arrays because nothing in that spec binds one.
    //
    // So neither is wrong and neither can simply adopt the other. What the
    // duplication does risk is drifting somewhere NOBODY intended, which is
    // what this pins: those two are the whole difference, and anything else
    // fails here.
    const payloads = [
      '{"on":true,"alias":"Desk","rssi":-42}',
      '{"state":{"reported":{"batPct":93,"bin":{"full":false}}}}',
      '{"deep":{"a":{"b":{"c":"value"}}},"n":1.5}',
      '{"empty":{},"nothing":null,"zero":0}',
      '{"children":[{"state":1}]}',
      'not json at all',
      '[1,2,3]',
    ];

    test('they agree everywhere except how a boolean is spelled', () async {
      if (!rustReady) {
        markTestSkipped('Rust lib not loaded');
        return;
      }

      /// Both sides with the two documented differences taken out, so what
      /// is left is everything they are supposed to agree about.
      Map<String, String> normalised(Map<String, String> fields) => {
        for (final e in fields.entries)
          if (!e.value.startsWith('['))
            e.key: switch (e.value) {
              'true' => '1',
              'false' => '0',
              final other => other,
            },
      };

      for (final payload in payloads) {
        expect(
          normalised(jsonStateFields(payload)),
          normalised(await roombaStateFields(payload: payload)),
          reason: 'the two flatteners diverge on $payload beyond booleans',
        );
      }
    });

    test(
      'an array is kept here and skipped there, as each spec needs',
      () async {
        if (!rustReady) {
          markTestSkipped('Rust lib not loaded');
          return;
        }
        const payload = '{"children":[{"state":1}],"alias":"Strip"}';
        expect(jsonStateFields(payload)['children'], '[{"state":1}]');
        expect(
          (await roombaStateFields(payload: payload)).containsKey('children'),
          isFalse,
        );
      },
    );

    test('and the boolean difference is the documented one', () async {
      if (!rustReady) {
        markTestSkipped('Rust lib not loaded');
        return;
      }
      const payload = '{"power":true,"lock":false}';
      expect(jsonStateFields(payload), {'power': 'true', 'lock': 'false'});
      expect(await roombaStateFields(payload: payload), {
        'power': '1',
        'lock': '0',
      });
    });
  });
}
