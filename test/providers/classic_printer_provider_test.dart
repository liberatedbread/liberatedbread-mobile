// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/providers/classic_printer_provider.dart';
import 'package:liberated_bread_mobile/providers/device_spec_provider.dart';
import 'package:liberated_bread_mobile/providers/saved_device_provider.dart';
import 'package:liberated_bread_mobile/providers/scan_match_provider.dart';
import 'package:liberated_bread_mobile/providers/spec_codec_provider.dart';
import 'package:liberated_bread_mobile/services/spec_codec.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../fakes/fake_spec_codec.dart';

const _id = '60:98:66:AA:BB:CC';
const _key = 'Brother QL-1110NWB Label Printer|Brother Industries';

DeviceSpecDto _spec({
  required String name,
  required String protocol,
  String? handler,
}) => DeviceSpecDto(
  nameMatchers: const [],
  platformFallbackTypes: const [],
  txtMatchGroups: const [],
  hiddenEntityNames: const [],
  deviceName: name,
  manufacturer: 'Brother Industries',
  manufacturerStatus: 'active',
  protocol: protocol,
  category: 'printer',
  localNamePrefixes: const ['QL-1110NWB'],
  localNames: const [],
  serviceUuids: const [],
  companyIds: Uint16List(0),
  macPrefixes: const [],
  mdnsServiceTypes: const [],
  ssdpSearchTargets: const [],
  lanProtocols: const [],
  defaultPort: 9100,
  entities: const [],
  services: const [],
  protocolHandler: handler,
);

final _ql = _spec(
  name: 'Brother QL-1110NWB Label Printer',
  protocol: 'wifi',
  handler: 'brother_ql_raster',
);
final _other = _spec(name: 'Other Printer', protocol: 'ble');

ScanMatch _match(DeviceSpecDto spec, {int index = 0}) => ScanMatch(
  specIndex: index,
  deviceName: spec.deviceName,
  manufacturer: spec.manufacturer,
  confidence: MatchConfidence.strong,
  matchedByNamePrefix: true,
  matchedServiceUuids: const [],
  matchedCompanyIds: Uint16List(0),
  matchedMacPrefix: null,
  matchedServiceTypes: const [],
);

const _request = ClassicPrinterRequest(
  deviceId: _id,
  identity: ScanIdentity(
    name: 'QL-1110NWB0000',
    serviceUuids: ['00001101-0000-1000-8000-00805f9b34fb'],
    companyIds: [],
    macAddress: _id,
  ),
);

void main() {
  Future<ProviderContainer> container({
    List<ScanMatch> Function(ScannedDeviceDto device)? matches,
    List<Map<String, Object?>> saved = const [],
  }) async {
    SharedPreferences.setMockInitialValues({
      if (saved.isNotEmpty) 'saved_devices_v1': jsonEncode(saved),
    });
    final prefs = await SharedPreferences.getInstance();
    final c = ProviderContainer(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        specCodecProvider.overrideWithValue(
          FakeSpecCodec(
            specByYaml: {'ql': _ql, 'other': _other},
            scanMatches: matches,
          ),
        ),
        deviceSpecsProvider.overrideWith(
          (ref) => {'ql.yaml': 'ql', 'other.yaml': 'other'},
        ),
      ],
    );
    await c.read(scanGuessProvider(_request.identity).future);
    addTearDown(c.dispose);
    return c;
  }

  test('a name-matched network/Classic QL is not sent to GATT', () async {
    final c = await container(matches: (_) => [_match(_ql)]);

    final profile = c.read(classicPrinterProfileProvider(_request));

    expect(profile, isNotNull);
    expect(profile!.specYaml, 'ql');
    expect(profile.specKey, _key);
  });

  test('the saved spec resolves without another scan match', () async {
    final c = await container(
      saved: [
        {
          'id': _id,
          'name': 'QL-1110NWB0000',
          'lastSeen': '2026-11-01T00:00:00.000',
          'specKey': _key,
        },
      ],
    );

    expect(c.read(classicPrinterProfileProvider(_request)), isNotNull);
  });

  test(
    'an ordinary BLE match and a contested match stay on the GATT path',
    () async {
      final ordinary = await container(matches: (_) => [_match(_other)]);
      expect(ordinary.read(classicPrinterProfileProvider(_request)), isNull);

      final tied = await container(
        matches: (_) => [_match(_ql), _match(_other, index: 1)],
      );
      expect(tied.read(classicPrinterProfileProvider(_request)), isNull);
    },
  );
}
