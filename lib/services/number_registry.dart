// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// Lookup over the vendored IEEE and Bluetooth SIG number registries.
//
// These answer the question the device specs cannot: *who made this thing?*,
// for hardware that is in no catalogue at all — which is most of what a scan
// actually returns. See vendor/protocol-specs/registries/SOURCES.md.

import '../core/hex.dart';
import '../core/log.dart';

/// One sorted, fixed-width-keyed registry table.
///
/// Holds the file as a single string and binary-searches it in place. The
/// alternative — parsing 50,000 lines into a `Map<String, String>` at startup —
/// would cost several megabytes of Dart heap on a phone to answer a question
/// asked a few dozen times per scan. A `String` is one allocation, and a lookup
/// is ~17 comparisons.
///
/// Correctness rests on the file's invariants (sorted, unique, fixed-width
/// keys, trailing newline), which `scripts/test_registries.py` enforces
/// upstream. [RegistryTable.parse] re-checks the cheap ones rather than trusting
/// a file that could have been mangled in vendoring.
class RegistryTable {
  final String _text;

  /// Number of characters in every key. Keys are fixed-width so that
  /// lexicographic order matches lookup order.
  final int keyWidth;

  /// Offsets of each line's first character, so a search can address lines
  /// without splitting the string.
  final List<int> _lineStarts;

  const RegistryTable._(this._text, this.keyWidth, this._lineStarts);

  /// An empty table. Every lookup misses. Used when an asset is absent or
  /// unreadable, so a missing registry degrades to "no vendor name" rather than
  /// taking out the scan.
  static const RegistryTable empty = RegistryTable._('', 0, []);

  int get length => _lineStarts.length;
  bool get isEmpty => _lineStarts.isEmpty;

  /// Index [text], rejecting it if it does not look like a registry table.
  ///
  /// A malformed table is worse than an absent one: binary search over unsorted
  /// data returns a wrong answer instead of no answer, and a wrong vendor name
  /// is a confident lie. Sortedness is verified in full — it is a single linear
  /// pass over data we have just read anyway.
  static RegistryTable parse(String text, {required int keyWidth}) {
    final lineStarts = <int>[];
    var start = 0;
    String? previousKey;
    while (start < text.length) {
      final end = text.indexOf('\n', start);
      if (end < 0) break; // A trailing partial line is not a record.
      if (end - start > keyWidth && text.codeUnitAt(start + keyWidth) == 0x09) {
        final key = text.substring(start, start + keyWidth);
        if (previousKey != null && key.compareTo(previousKey) <= 0) {
          throw FormatException(
              'registry is not sorted: "$key" follows "$previousKey"');
        }
        previousKey = key;
        lineStarts.add(start);
      }
      start = end + 1;
    }
    if (lineStarts.isEmpty) return empty;
    return RegistryTable._(text, keyWidth, lineStarts);
  }

  /// The value for [key], or null. [key] must already be in the table's casing.
  String? operator [](String key) {
    if (key.length != keyWidth || isEmpty) return null;
    var low = 0;
    var high = _lineStarts.length - 1;
    while (low <= high) {
      final middle = (low + high) >> 1;
      final start = _lineStarts[middle];
      final comparison =
          _text.substring(start, start + keyWidth).compareTo(key);
      if (comparison == 0) {
        final end = _text.indexOf('\n', start);
        return _text.substring(start + keyWidth + 1, end);
      }
      if (comparison < 0) {
        low = middle + 1;
      } else {
        high = middle - 1;
      }
    }
    return null;
  }
}

/// Every vendored registry, indexed.
///
/// Construct via [NumberRegistry.load]; [NumberRegistry.empty] is the
/// no-registries-available state, in which every lookup returns null.
class NumberRegistry {
  /// IEEE MAC address block tables, ordered LONGEST BLOCK FIRST. That order is
  /// load-bearing: IEEE subdivides some 24-bit blocks into 28- and 36-bit
  /// assignments, so a 24-bit-only lookup misses precisely the small vendors
  /// worth naming. `C4:7C:8D` finds nothing at 24 bits, while `C47C8D6` is HHCC
  /// Plant Technology — who actually build the Mi Flora.
  final List<RegistryTable> addressBlocks;

  /// Bluetooth SIG company identifiers, keyed by 5-digit zero-padded decimal.
  final RegistryTable companyIds;

  /// Bluetooth SIG 16-bit service UUIDs, keyed by 4 lowercase hex digits.
  final RegistryTable serviceUuids;

  const NumberRegistry({
    required this.addressBlocks,
    required this.companyIds,
    required this.serviceUuids,
  });

  static const NumberRegistry empty = NumberRegistry(
    addressBlocks: [],
    companyIds: RegistryTable.empty,
    serviceUuids: RegistryTable.empty,
  );

  /// Where the registries live in the bundle.
  ///
  /// The subtree path, not a copy under `assets/`: these files need no
  /// transform on the way in, so duplicating 1.7MB of them into `assets/` would
  /// buy nothing but a second copy to go stale. `pubspec.yaml` bundles them
  /// from here directly.
  static const _dir = 'vendor/protocol-specs/registries';

  /// Asset paths and key widths, longest address block first.
  static const addressBlockAssets = <({String asset, int keyWidth})>[
    (asset: '$_dir/ieee-oui36.tsv', keyWidth: 9),
    (asset: '$_dir/ieee-oui28.tsv', keyWidth: 7),
    (asset: '$_dir/ieee-oui.tsv', keyWidth: 6),
  ];
  static const companyIdsAsset = '$_dir/bluetooth-company-ids.tsv';
  static const serviceUuidsAsset = '$_dir/bluetooth-service-uuids.tsv';

  /// Load and index every table using [loadAsset].
  ///
  /// A table that is missing or malformed is skipped with a warning rather than
  /// failing the load: an app that cannot name a device vendor is a smaller
  /// problem than an app that cannot scan.
  static Future<NumberRegistry> load(
    Future<String> Function(String asset) loadAsset,
  ) async {
    Future<RegistryTable> table(String asset, int keyWidth) async {
      try {
        return RegistryTable.parse(await loadAsset(asset), keyWidth: keyWidth);
      } catch (e) {
        Log.spec.warning('registry $asset unavailable', error: e);
        return RegistryTable.empty;
      }
    }

    // All five tables in flight together — they are independent asset loads
    // totalling ~1.7MB on the startup path, and nothing below needs one
    // before another.
    final tables = await Future.wait([
      for (final entry in addressBlockAssets)
        table(entry.asset, entry.keyWidth),
      table(companyIdsAsset, 5),
      table(serviceUuidsAsset, 4),
    ]);
    final blocks = [
      for (final loaded in tables.take(addressBlockAssets.length))
        if (!loaded.isEmpty) loaded,
    ];
    final registry = NumberRegistry(
      addressBlocks: blocks,
      companyIds: tables[addressBlockAssets.length],
      serviceUuids: tables[addressBlockAssets.length + 1],
    );
    Log.spec.info('registries: ${blocks.fold(0, (n, t) => n + t.length)} '
        'address block(s), ${registry.companyIds.length} company id(s), '
        '${registry.serviceUuids.length} service uuid(s)');
    return registry;
  }

  /// Who bought the address block [macAddress] falls in, or null.
  ///
  /// This is the block's registrant, which is frequently the *chip* vendor
  /// rather than the product vendor — the Lutron Caséta bridge's address sits
  /// in a Texas Instruments block, because that is the radio module inside it.
  /// Label a device with this; never claim it identifies one.
  String? vendorForMac(String? macAddress) {
    if (macAddress == null) return null;
    final hex = normalizeMacHex(macAddress);
    if (hex == null || hex.length != 12) return null;
    for (final table in addressBlocks) {
      final hit = table[hex.substring(0, table.keyWidth)];
      if (hit != null) return hit;
    }
    return null;
  }

  /// The company that registered Bluetooth SIG identifier [companyId], or null.
  ///
  /// Says which company registered the identifier, not which built the device:
  /// squatting on an unassigned ID is common.
  String? companyName(int companyId) {
    if (companyId < 0 || companyId > 0xFFFF) return null;
    return companyIds[companyId.toString().padLeft(5, '0')];
  }

  /// The standard service name for a UUID, or null when it is not a 16-bit
  /// SIG-allocated one. Accepts either the 16-bit shorthand (`180f`) or the
  /// full 128-bit form built on the Bluetooth base UUID.
  String? serviceName(String uuid) {
    final short = shortUuid(uuid);
    return short == null ? null : serviceUuids[short];
  }
}

/// The Bluetooth base UUID that 16-bit shorthand expands against.
const _bluetoothBaseSuffix = '-0000-1000-8000-00805f9b34fb';

/// Reduce a service UUID to its 16-bit SIG shorthand, or null when it carries
/// no shorthand — i.e. when it is a vendor's own 128-bit UUID, which means
/// something specific to one product and belongs to a device spec rather than
/// to a registry.
String? shortUuid(String uuid) {
  final lower = uuid.toLowerCase();
  if (lower.length == 4) return lower;
  if (lower.length == 36 &&
      lower.startsWith('0000') &&
      lower.endsWith(_bluetoothBaseSuffix)) {
    return lower.substring(4, 8);
  }
  return null;
}
