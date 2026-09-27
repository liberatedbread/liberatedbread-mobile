// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// Post-connect ranking over the REAL vendored catalogue: a GATT table that
// carries every service a spec declares must name that spec, however many
// other specs share one vendor UUID with it. Requires the host-target Rust
// library; skipped without it.
import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/core/hex.dart';
import 'package:liberated_bread_mobile/providers/device_spec_match_provider.dart';
import 'package:liberated_bread_mobile/services/real_spec_codec.dart';
import 'package:liberated_bread_mobile/services/spec_codec.dart';

import '../helpers/host_rust_lib.dart';
import '../services/spec_catalogue_golden_test.dart' show bundledSpecs;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late final bool rustReady;
  late final SpecCatalogue catalogue;

  setUpAll(() async {
    rustReady = await initHostRustLib();
    if (rustReady) {
      catalogue = await RealSpecCodec().loadCatalogue(await bundledSpecs());
    }
  });

  Future<List<SpecMatch>> topFor(String name, List<String> uuids) async {
    final matches = await catalogue.matchDevice(
      deviceName: name,
      serviceUuids: uuids,
    );
    final ranked = rankSpecMatches(matches, discoveredUuids: uuids);
    return topTiedSpecMatches(ranked, discoveredUuids: uuids);
  }

  test(
    'a real iTag resolves to the iTag spec, not an ffe0 LED strip',
    () async {
      if (!rustReady) {
        markTestSkipped('Rust lib not loaded');
        return;
      }
      // The table a real iTag returned after connecting. Before the GATT
      // fingerprint key, eight specs matched Strong on ffe0 alone (banlanx,
      // govee-h6101, leds2rave4, …) and the iTag spec — admitted only by
      // the SIG 0x1802, so `possible` — ranked last though every service it
      // declares was present.
      final top = await topFor('iTAG', const [
        '1800',
        '1801',
        '1802',
        '1803',
        '180f',
        'ffe0',
      ]);
      expect(
        [for (final m in top) m.entry.key],
        ['vendor/protocol-specs/device-specs/devices/itag-ble-tracker.yaml'],
      );
    },
  );

  test(
    'a named device carrying its spec\'s whole GATT table picks it',
    () async {
      if (!rustReady) {
        markTestSkipped('Rust lib not loaded');
        return;
      }
      // Catalogue-wide: every spec with a name prefix and GATT services, fed
      // its own name and exactly its own table. Before the fingerprint key
      // four of these (ble-pulse-oximeter, foreo-peach-2, safetech padlock,
      // thermopro-tp357) lost to a spec sharing one vendor UUID.
      final lost = <String>[];
      var tried = 0;
      for (final entry in catalogue.specs) {
        final prefix = entry.identity.localNamePrefixes.firstOrNull;
        if (prefix == null || entry.gattServiceUuids.isEmpty) continue;
        tried++;
        final uuids = [for (final u in entry.gattServiceUuids) normalizeUuid(u)]
          ..sort();
        final top = await topFor('${prefix}unit-1', uuids);
        final own = specKeyOf(entry.deviceName, entry.manufacturer);
        if (!top.any(
          (m) => specKeyOf(m.entry.deviceName, m.entry.manufacturer) == own,
        )) {
          lost.add('${entry.key} -> ${top.firstOrNull?.entry.key}');
        }
      }
      expect(tried, greaterThan(50));
      expect(lost, isEmpty);
    },
  );
}
