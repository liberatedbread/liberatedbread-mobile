// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/providers/device_spec_match_provider.dart';
import 'package:liberated_bread_mobile/services/spec_codec.dart';
import 'package:liberated_bread_mobile/src/rust/api/device_api.dart'
    show NameMatchDto;

/// A catalogue entry with only what ranking reads: its GATT services.
CatalogueSpec _entry(
  String name,
  int index,
  List<String> gatt, {
  List<String> localNamePrefixes = const [],
  List<String> localNames = const [],
  List<NameMatchDto> nameMatchers = const [],
}) => CatalogueSpec(
  index: index,
  key: '$name.yaml',
  yaml: '',
  identity: SpecIdentityDto(
    deviceName: name,
    manufacturer: 'Test',
    localNamePrefixes: localNamePrefixes,
    localNames: localNames,
    serviceUuids: const [],
    companyIds: Uint16List(0),
    macPrefixes: const [],
    mdnsServiceTypes: const [],
    ssdpSearchTargets: const [],
    lanProtocols: const [],
    nameMatchers: nameMatchers,
    txtMatchGroups: const [],
    platformFallbackTypes: const [],
  ),
  protocolHandler: null,
  gattServiceUuids: gatt,
);

void main() {
  // What Rust reports after connecting to a device named for its own spec
  // whose GATT table also carries Immediate Alert (0x1802): the own spec on
  // its name (`likely`), and the iTag spec admitted by the SIG UUID alone
  // (`possible`, no vendor UUID listed).
  final own = SpecMatch(
    entry: _entry('Own', 0, const ['1802', 'fff0']),
    matchedByNamePrefix: true,
    confidence: MatchConfidence.likely,
    matchedServiceUuids: const [],
  );
  final itag = SpecMatch(
    entry: _entry('iTag', 1, const ['1802']),
    matchedByNamePrefix: false,
    confidence: MatchConfidence.possible,
    matchedServiceUuids: const [],
  );
  const discovered = ['1802', 'fff0'];

  test('a name match outranks a match admitted by a SIG UUID alone', () {
    // Before confidence led the sort, both sat in the same evidence tier
    // with zero vendor UUIDs, so they tied and the user was asked to choose
    // between their own device's spec and an iTag.
    for (final input in [
      [itag, own],
      [own, itag],
    ]) {
      final ranked = rankSpecMatches(input, discoveredUuids: discovered);
      expect(ranked.first, same(own));
      expect(topTiedSpecMatches(ranked), [same(own)]);
    }
  });

  test('a SIG-only match with no rival still resolves', () {
    // A real iTag's only identifier IS 0x1802, so alone it must still win.
    final ranked = rankSpecMatches([itag], discoveredUuids: const ['1802']);
    expect(topTiedSpecMatches(ranked), [same(itag)]);
  });

  test('two SIG-only matches stay a genuine tie', () {
    // FTMS (0x1826) is both walking pads' service; with no name to tell them
    // apart the chooser is honest.
    SpecMatch pad(String name, int index) => SpecMatch(
      entry: _entry(name, index, const ['1826']),
      matchedByNamePrefix: false,
      confidence: MatchConfidence.possible,
      matchedServiceUuids: const [],
    );
    final ranked = rankSpecMatches(
      [pad('Kingsmith', 0), pad('Urevo', 1)],
      discoveredUuids: const ['1826'],
    );
    expect(topTiedSpecMatches(ranked), hasLength(2));
  });

  group('GATT fingerprint', () {
    SpecMatch strong(
      String name,
      int index,
      List<String> gatt, {
      bool named = false,
    }) => SpecMatch(
      entry: _entry(name, index, gatt),
      matchedByNamePrefix: named,
      confidence: MatchConfidence.strong,
      matchedServiceUuids: const ['ffe0'],
    );

    test('a wholly-present multi-service spec outranks a one-UUID match', () {
      // The real iTag's shape: the iTag spec only `possible` (SIG 0x1802),
      // an LED strip Strong on the shared ffe0. Fails on the old ranking,
      // where confidence led and the strip won.
      final tag = SpecMatch(
        entry: _entry('iTag', 0, const ['1802', '1803', 'ffe0', '180f']),
        matchedByNamePrefix: false,
        confidence: MatchConfidence.possible,
        matchedServiceUuids: const [],
      );
      final strip = strong('Strip', 1, const ['ffe0']);
      const table = ['1800', '1801', '1802', '1803', '180f', 'ffe0'];
      for (final input in [
        [strip, tag],
        [tag, strip],
      ]) {
        final ranked = rankSpecMatches(input, discoveredUuids: table);
        expect(ranked.first, same(tag));
        expect(topTiedSpecMatches(ranked, discoveredUuids: table), [same(tag)]);
      }
    });

    test('an absent optional service does not demote a named match', () {
      // Own spec declares ffe0 + ffe5; this unit omits ffe5. It is no
      // fingerprint, so the name corroboration still decides.
      final own = strong('Own', 0, const ['ffe0', 'ffe5'], named: true);
      final other = strong('Other', 1, const ['ffe0']);
      final ranked = rankSpecMatches(
        [other, own],
        discoveredUuids: const ['ffe0'],
      );
      expect(ranked.first, same(own));
    });

    test('a contradicting name voids the fingerprint on every name axis', () {
      // A spec named only by `local_names` or a `name_matchers` entry, whose
      // two services a differently-named device happens to carry. Fails on
      // the old gate, which read only `local_name_prefixes` and gave both
      // the full fingerprint 2 — the iPixel misroute on another axis.
      const table = ['1800', 'fa02', 'ae00'];
      for (final entry in [
        _entry('Exact', 0, const ['fa02', 'ae00'], localNames: const ['PX-1']),
        _entry(
          'Matcher',
          0,
          const ['fa02', 'ae00'],
          nameMatchers: const [NameMatchDto(kind: 'regex', value: '^PX')],
        ),
        _entry(
          'Prefix',
          0,
          const ['fa02', 'ae00'],
          localNamePrefixes: const ['PX'],
        ),
      ]) {
        SpecMatch match({required bool named}) => SpecMatch(
          entry: entry,
          matchedByNamePrefix: named,
          confidence: MatchConfidence.strong,
          matchedServiceUuids: const ['fa02'],
        );
        expect(
          gattFingerprintOf(
            match(named: false),
            discoveredUuids: table,
            deviceName: 'IDM-1234',
          ),
          0,
          reason: entry.key,
        );
        // Its own name, or no name at all, keeps the credit.
        expect(
          gattFingerprintOf(
            match(named: true),
            discoveredUuids: table,
            deviceName: 'PX-1',
          ),
          2,
          reason: entry.key,
        );
        expect(
          gattFingerprintOf(match(named: false), discoveredUuids: table),
          2,
          reason: entry.key,
        );
      }
    });

    test('infrastructure services are no fingerprint', () {
      // GAP, GATT, Device Information and Battery are on nearly everything.
      final generic = SpecMatch(
        entry: _entry('Generic', 0, const ['1800', '180a', '180f']),
        matchedByNamePrefix: false,
        confidence: MatchConfidence.possible,
        matchedServiceUuids: const [],
      );
      expect(
        gattFingerprintOf(generic, discoveredUuids: const ['1800', '180a']),
        0,
      );
    });
  });
}
