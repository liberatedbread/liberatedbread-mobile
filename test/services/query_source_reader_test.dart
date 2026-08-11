// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// The options_source/state_source contract, against the documents the Roku
// spec publishes as its own examples — including the one every Roku spends
// most of its life on, the home screen, whose app element has no id at all.

import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/services/query_source_reader.dart';
import 'package:liberated_bread_mobile/services/spec_codec.dart';

const _apps = '''
<apps>
  <app id="12" subtype="ndka" type="appl" version="4.1.218">Netflix</app>
  <app id="837" subtype="ndka" type="appl" version="1.0.80">YouTube</app>
  <app id="551012" subtype="ndka" type="appl" version="9.0.1">Apple TV</app>
</apps>
''';

const _activeApp = '''
<active-app>
  <app id="837" subtype="ndka" type="appl" version="1.0.80">YouTube</app>
</active-app>
''';

const _source = QuerySourceDto(
  method: 'GET',
  path: '/query/apps',
  item: 'app',
  valueAttribute: 'id',
);

void main() {
  test('reads every element with the item name, value and label', () {
    final entries = readQuerySource(_apps, _source);

    expect(entries, [
      const QueryEntry(value: '12', label: 'Netflix'),
      const QueryEntry(value: '837', label: 'YouTube'),
      const QueryEntry(value: '551012', label: 'Apple TV'),
    ]);
  });

  test('the current selection is the first entry value', () {
    expect(readCurrentValue(_activeApp, _source), '837');
  });

  test('an element with no value attribute reads as no current selection', () {
    // The home screen: <app>Roku</app>, no id. It is an answer — nothing is
    // foreground — and treating it as one is what keeps the picker from
    // showing a stale channel as current.
    expect(
        readCurrentValue('<active-app><app>Roku</app></active-app>', _source),
        isNull);
    // The entry itself survives the read, so a caller can still see what the
    // device called it.
    expect(readQuerySource('<active-app><app>Roku</app></active-app>', _source),
        [const QueryEntry(value: null, label: 'Roku')]);
  });

  test('matches local names, so a namespaced answer still reads', () {
    const namespaced = '''
<r:apps xmlns:r="urn:roku:ecp">
  <r:app id="12">Netflix</r:app>
</r:apps>
''';
    expect(readQuerySource(namespaced, _source),
        [const QueryEntry(value: '12', label: 'Netflix')]);
  });

  test('finds items at any depth, not just below the root', () {
    const nested = '<outer><group><app id="7">Deep</app></group></outer>';
    expect(readQuerySource(nested, _source),
        [const QueryEntry(value: '7', label: 'Deep')]);
  });

  test('an empty or unparseable document costs the list, not the screen', () {
    // A device answering with something unexpected must not throw into a
    // widget build; the caller shows an empty list and the other controls
    // keep working.
    expect(readQuerySource('<apps></apps>', _source), isEmpty);
    expect(readQuerySource('not xml at all', _source), isEmpty);
    expect(readQuerySource('', _source), isEmpty);
    expect(readCurrentValue('not xml at all', _source), isNull);
  });
}
