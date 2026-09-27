// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// ScanGuess.collapseShadowed, setup help and the Wi-Fi guess all read a
// scan match's `specIndex` as an index into specIdentitiesProvider's list.
// That holds only while the catalogue's matcher numbers its results in the
// same order the identities are projected; pin it over the real vendored
// catalogue on the production codec. Requires the host-target Rust library;
// skipped without it.
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/providers/device_spec_match_provider.dart';
import 'package:liberated_bread_mobile/providers/device_spec_provider.dart';
import 'package:liberated_bread_mobile/providers/scan_match_provider.dart';
import 'package:liberated_bread_mobile/providers/spec_codec_provider.dart';
import 'package:liberated_bread_mobile/services/real_spec_codec.dart';
import 'package:liberated_bread_mobile/services/spec_codec.dart';

import '../helpers/host_rust_lib.dart';
import '../services/spec_catalogue_golden_test.dart' show bundledSpecs;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('matchScanned specIndex indexes specIdentitiesProvider', () async {
    if (!await initHostRustLib()) {
      markTestSkipped('Rust lib not loaded');
      return;
    }
    final specs = await bundledSpecs();
    final c = ProviderContainer(
      overrides: [
        specCodecProvider.overrideWithValue(RealSpecCodec()),
        deviceSpecsProvider.overrideWith((ref) => specs),
      ],
    );
    addTearDown(c.dispose);
    final catalogue = await c.read(specCatalogueProvider.future);
    final identities = await c.read(specIdentitiesProvider.future);
    expect(identities, hasLength(catalogue.specs.length));

    var checked = 0;
    for (final identity in identities) {
      final prefix = identity.localNamePrefixes.firstOrNull;
      if (prefix == null) continue;
      final matches = await catalogue.matchScanned(
        ScannedDeviceDto(
          name: '${prefix}unit-1',
          serviceUuids: identity.serviceUuids,
          companyIds: Uint16List(0),
          manufacturerData: const [],
          macAddress: null,
        ),
      );
      for (final m in matches) {
        checked++;
        final at = identities[m.specIndex];
        expect(
          specKeyOf(at.deviceName, at.manufacturer),
          specKeyOf(m.deviceName, m.manufacturer),
          reason: 'specIndex ${m.specIndex} names a different identity',
        );
      }
    }
    expect(checked, greaterThan(50));
  });
}
