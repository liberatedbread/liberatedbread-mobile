// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// savedPrintersProvider: which saved devices the asset-label picker offers —
// printers this build can actually drive, each over its own transport.
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/providers/device_spec_match_provider.dart';
import 'package:liberated_bread_mobile/providers/printer_provider.dart';
import 'package:liberated_bread_mobile/providers/saved_device_provider.dart';
import 'package:liberated_bread_mobile/providers/spec_codec_provider.dart';
import 'package:liberated_bread_mobile/services/spec_codec.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../fakes/fake_spec_codec.dart';

DeviceSpecDto _spec(String name) => DeviceSpecDto(
  nameMatchers: const [],
  platformFallbackTypes: const [],
  txtMatchGroups: const [],
  hiddenEntityNames: const [],
  deviceName: name,
  manufacturer: 'Test',
  manufacturerStatus: 'active',
  protocol: 'ble',
  localNamePrefixes: const [],
  localNames: const [],
  serviceUuids: const [],
  companyIds: Uint16List(0),
  macPrefixes: const [],
  mdnsServiceTypes: const [],
  ssdpSearchTargets: const [],
  lanProtocols: const [],
  defaultPort: null,
  entities: const [],
  services: const [],
);

/// Answers per spec YAML, the way the real codec would per spec.
class _PerSpecCodec extends FakeSpecCodec {
  final Map<String, RasterPrintDto?> bySpec;
  _PerSpecCodec(this.bySpec);

  @override
  Future<RasterPrintDto?> rasterPrintForSpec({
    required String specYaml,
  }) async => bySpec[specYaml];
}

RasterPrintDto _raster(String? transport) => RasterPrintDto(
  transport: transport,
  encodable: transport != null,
  dpi: 203,
  dpiAssumed: false,
  media: const [],
);

void main() {
  test('offers printers this build drives, over the right transport', () async {
    SharedPreferences.setMockInitialValues({
      'saved_devices_v1':
          '['
          '{"id":"a","name":"Cat","lastSeen":"2026-07-30T12:00:00.000",'
          '"category":"printer","specKey":"Cat|Test"},'
          '{"id":"b","name":"MXW01","lastSeen":"2026-07-30T12:00:00.000",'
          '"category":"printer","specKey":"MXW01|Test"},'
          '{"id":"c","name":"Lamp","lastSeen":"2026-07-30T12:00:00.000",'
          '"category":"light","specKey":"Lamp|Test"},'
          '{"id":"d","name":"Odd","lastSeen":"2026-07-30T12:00:00.000",'
          '"category":"printer","specKey":"Odd|Test"}'
          ']',
    });
    final prefs = await SharedPreferences.getInstance();
    final codec = _PerSpecCodec({
      'cat-yaml': _raster('ble_write_plan'),
      // Named in its spec, no encoder in this build.
      'mxw01-yaml': _raster(null),
      'lamp-yaml': null,
      // A raw-stream printer saved as a BLE device cannot be printed to.
      'odd-yaml': _raster('raw_stream'),
    });
    final container = ProviderContainer(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        specCodecProvider.overrideWithValue(codec),
        specCatalogueProvider.overrideWith(
          (ref) async => FallbackSpecCatalogue.fromParsed(codec, [
            (spec: _spec('Cat'), yaml: 'cat-yaml'),
            (spec: _spec('MXW01'), yaml: 'mxw01-yaml'),
            (spec: _spec('Lamp'), yaml: 'lamp-yaml'),
            (spec: _spec('Odd'), yaml: 'odd-yaml'),
          ]),
        ),
      ],
    );
    addTearDown(container.dispose);

    final printers = await container.read(savedPrintersProvider.future);
    expect(printers.map((p) => p.name), ['Cat']);
    expect(printers.single.isBle, isTrue);
    expect(printers.single.specYaml, 'cat-yaml');
  });
}
