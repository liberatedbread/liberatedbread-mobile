// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/services/number_registry.dart';

/// Builds a table body from key/value pairs, sorted the way a real registry is.
String _table(Map<String, String> rows) {
  final keys = rows.keys.toList()..sort();
  return keys.map((k) => '$k\t${rows[k]}\n').join();
}

void main() {
  group('RegistryTable', () {
    final table = RegistryTable.parse(
      _table({
        'AAAAAA': 'Alpha Corp',
        'BBBBBB': 'Beta Ltd',
        'CCCCCC': 'Gamma GmbH',
        'FFFFFF': 'Omega Inc',
      }),
      keyWidth: 6,
    );

    test('finds the first, last and middle entries', () {
      // Binary search bugs live at the ends.
      expect(table['AAAAAA'], 'Alpha Corp');
      expect(table['BBBBBB'], 'Beta Ltd');
      expect(table['FFFFFF'], 'Omega Inc');
    });

    test('misses return null rather than a neighbour', () {
      expect(table['000000'], isNull);
      expect(table['DDDDDD'], isNull);
      expect(table['ZZZZZZ'], isNull);
    });

    test('a key of the wrong width never matches', () {
      expect(table['AAAA'], isNull);
      expect(table['AAAAAAA'], isNull);
    });

    test('rejects an unsorted table instead of answering wrongly', () {
      // Binary search over unsorted data returns a confident wrong answer,
      // which for a vendor name is worse than no answer at all.
      expect(
        () => RegistryTable.parse('BBBBBB\tBeta\nAAAAAA\tAlpha\n', keyWidth: 6),
        throwsFormatException,
      );
    });

    test('skips rows whose key is not followed by a tab', () {
      final t = RegistryTable.parse(
        'AAAAAA\tAlpha\nnot-a-record\nBBBBBB\tBeta\n',
        keyWidth: 6,
      );
      expect(t.length, 2);
      expect(t['BBBBBB'], 'Beta');
    });

    test('ignores a trailing line with no newline', () {
      // A truncated vendoring must not produce a half-record.
      final t = RegistryTable.parse('AAAAAA\tAlpha\nBBBBBB\tBet', keyWidth: 6);
      expect(t.length, 1);
      expect(t['BBBBBB'], isNull);
    });

    test('an empty table misses everything without throwing', () {
      expect(RegistryTable.empty['AAAAAA'], isNull);
      expect(RegistryTable.parse('', keyWidth: 6).isEmpty, isTrue);
    });

    test('values may contain spaces, commas and periods', () {
      final t = RegistryTable.parse('AAAAAA\tHHCC Plant Technology Co.,Ltd.\n',
          keyWidth: 6);
      expect(t['AAAAAA'], 'HHCC Plant Technology Co.,Ltd.');
    });
  });

  group('NumberRegistry.vendorForMac', () {
    // Deliberately mirrors the real subdivision: the 24-bit block is absent
    // (IEEE holds it), the 28-bit block belongs to the actual maker.
    final registry = NumberRegistry(
      addressBlocks: [
        RegistryTable.parse(_table({'C47C8D6A1': 'Deep Block Ltd'}),
            keyWidth: 9),
        RegistryTable.parse(_table({'C47C8D6': 'HHCC Plant Technology'}),
            keyWidth: 7),
        RegistryTable.parse(_table({'001788': 'Philips Lighting BV'}),
            keyWidth: 6),
      ],
      companyIds: RegistryTable.parse(
          _table({'00961': 'Ember Technologies', '00820': 'Airthings AS'}),
          keyWidth: 5),
      serviceUuids: RegistryTable.parse(
          _table({'180f': 'Battery Service', '181a': 'Environmental Sensing'}),
          keyWidth: 4),
    );

    test('resolves a plain 24-bit assignment', () {
      expect(registry.vendorForMac('00:17:88:11:22:33'), 'Philips Lighting BV');
    });

    test('prefers the longest matching block', () {
      // The whole reason three tables ship: a 24-bit-only lookup finds nothing
      // usable for exactly the small vendors worth naming.
      expect(registry.vendorForMac('C4:7C:8D:6A:1B:2C'), 'Deep Block Ltd');
      expect(
          registry.vendorForMac('C4:7C:8D:6F:FF:FF'), 'HHCC Plant Technology');
    });

    test('an unassigned address resolves to nothing', () {
      expect(registry.vendorForMac('02:00:00:11:22:33'), isNull);
    });

    test('accepts hyphens and mixed case, rejects non-addresses', () {
      expect(registry.vendorForMac('00-17-88-11-22-33'), 'Philips Lighting BV');
      expect(registry.vendorForMac('00:17:88:aa:bb:cc'), 'Philips Lighting BV');
      expect(registry.vendorForMac(null), isNull);
      // A CoreBluetooth UUID has the wrong length once separators are stripped.
      expect(
        registry.vendorForMac('C47C8DAB-1234-5678-9ABC-DEF012345678'),
        isNull,
      );
      expect(registry.vendorForMac('not an address'), isNull);
    });

    test('company ids resolve, out-of-range ones do not', () {
      expect(registry.companyName(961), 'Ember Technologies');
      expect(registry.companyName(820), 'Airthings AS');
      expect(registry.companyName(1), isNull);
      expect(registry.companyName(-1), isNull);
      expect(registry.companyName(0x10000), isNull);
    });

    test('service names resolve from both UUID forms', () {
      expect(registry.serviceName('180f'), 'Battery Service');
      expect(
        registry.serviceName('0000180F-0000-1000-8000-00805F9B34FB'),
        'Battery Service',
      );
    });

    test('a vendor 128-bit UUID has no standard name', () {
      // It means something specific to one product, which is a spec's business.
      expect(
        registry.serviceName('fc543622-236c-4c94-8fa9-944a3e5353fa'),
        isNull,
      );
    });

    test('the empty registry answers null to everything', () {
      expect(NumberRegistry.empty.vendorForMac('00:17:88:11:22:33'), isNull);
      expect(NumberRegistry.empty.companyName(961), isNull);
      expect(NumberRegistry.empty.serviceName('180f'), isNull);
    });
  });

  group('NumberRegistry.load', () {
    test('a missing asset degrades to no lookups, not a crash', () async {
      // An app that cannot name a vendor is a smaller problem than one that
      // cannot scan.
      final registry = await NumberRegistry.load(
        (asset) async => throw Exception('no such asset: $asset'),
      );
      expect(registry.addressBlocks, isEmpty);
      expect(registry.companyName(961), isNull);
    });

    test('loads every declared asset', () async {
      final requested = <String>[];
      await NumberRegistry.load((asset) async {
        requested.add(asset);
        return '';
      });
      expect(
        requested,
        containsAll([
          ...NumberRegistry.addressBlockAssets.map((a) => a.asset),
          NumberRegistry.companyIdsAsset,
          NumberRegistry.serviceUuidsAsset,
        ]),
      );
    });

    test('address block assets are declared longest first', () {
      // Load order is the lookup order, so this ordering is load-bearing.
      final widths =
          NumberRegistry.addressBlockAssets.map((a) => a.keyWidth).toList();
      expect(widths, [9, 7, 6]);
    });
  });

  // Against the real vendored files, so a mangled or forgotten
  // scripts/sync_device_specs.sh run is caught here rather than on a phone.
  group('the vendored registries', () {
    setUpAll(TestWidgetsFlutterBinding.ensureInitialized);

    test('load, index and resolve the addresses the specs document', () async {
      final registry = await NumberRegistry.load(rootBundle.loadString);

      expect(registry.addressBlocks, hasLength(3),
          reason: 'all three IEEE block sizes must be vendored');
      expect(registry.companyIds.length, greaterThan(3000));
      expect(registry.serviceUuids.length, greaterThan(50));

      // hue-bridge.yaml's two documented OUIs.
      expect(registry.vendorForMac('00:17:88:11:22:33'), contains('Philips'));
      expect(registry.vendorForMac('C4:29:96:11:22:33'), contains('Signify'));

      // The subdivided block that justifies shipping the longer tables:
      // 24-bit says nothing, 28-bit names who actually builds the Mi Flora.
      expect(registry.vendorForMac('C4:7C:8D:6A:1B:2C'), contains('HHCC'));

      // An OUI names whoever bought the block, which here is the chip vendor
      // inside the Lutron bridge -- the reason that spec carries no prefix.
      expect(
        registry.vendorForMac('B8:94:D9:1E:E7:67'),
        contains('Texas Instruments'),
      );

      // ember-mug.yaml and airthings-wave-family.yaml company IDs.
      expect(registry.companyName(961), contains('Ember'));
      expect(registry.companyName(820), contains('Airthings'));

      expect(registry.serviceName('180f'), 'Battery Service');
    });
  });

  group('shortUuid', () {
    test('passes a 16-bit shorthand through, lowercased', () {
      expect(shortUuid('180F'), '180f');
    });

    test('extracts the shorthand from a base-UUID 128-bit form', () {
      expect(shortUuid('0000180f-0000-1000-8000-00805f9b34fb'), '180f');
    });

    test('a vendor UUID has no shorthand', () {
      expect(shortUuid('fc543622-236c-4c94-8fa9-944a3e5353fa'), isNull);
      // Right suffix, but the leading group is not the 16-bit padding.
      expect(shortUuid('1234180f-0000-1000-8000-00805f9b34fb'), isNull);
    });
  });
}
