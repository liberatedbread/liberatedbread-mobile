// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/models/ble_discovered_service.dart';
import 'package:liberated_bread_mobile/models/network_device.dart';
import 'package:liberated_bread_mobile/models/svc_report.dart';
import 'package:liberated_bread_mobile/providers/saved_device_provider.dart';
import 'package:liberated_bread_mobile/providers/svc_report_provider.dart';
import 'package:liberated_bread_mobile/services/spec_codec.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _svcUuid = '0000fff0-0000-1000-8000-00805f9b34fb';
const _dfuUuid = '0000fe59-0000-1000-8000-00805f9b34fb';

final _bleSpec = DeviceSpecDto(
  nameMatchers: const [],
  platformFallbackTypes: const [],
  txtMatchGroups: const [],
  hiddenEntityNames: const [],
  deviceName: 'Bulb',
  manufacturer: 'Acme',
  manufacturerStatus: 'active',
  protocol: 'ble',
  localNamePrefixes: const ['ACME_'],
  localNames: const [],
  serviceUuids: const [_svcUuid],
  companyIds: Uint16List(0),
  macPrefixes: const [],
  mdnsServiceTypes: const [],
  ssdpSearchTargets: const [],
  lanProtocols: const [],
  defaultPort: null,
  entities: const <EntityDto>[],
  services: const [
    ServiceDto(uuid: _svcUuid, name: 'Control', characteristics: []),
  ],
);

BleDiscoveredService _service(
  String uuid, [
  List<BleDiscoveredCharacteristic> chars = const [],
]) => BleDiscoveredService(uuid: uuid, characteristics: chars);

CatalogueSpec _wifiEntry() => CatalogueSpec(
  index: 0,
  key: 'device-specs/acme-hub.yaml',
  yaml: '',
  identity: SpecIdentityDto(
    deviceName: 'Hub',
    manufacturer: 'Acme',
    localNamePrefixes: const [],
    localNames: const [],
    serviceUuids: const [],
    companyIds: Uint16List(0),
    manufacturerDataPrefixes: const [],
    macPrefixes: const [],
    mdnsServiceTypes: const ['_acme._tcp'],
    ssdpSearchTargets: const [],
    lanProtocols: const [],
    nameMatchers: const [],
    txtMatchGroups: const [],
    platformFallbackTypes: const [],
  ),
  protocolHandler: null,
  gattServiceUuids: const [],
);

NetworkDevice _netDevice({List<String> types = const []}) => NetworkDevice(
  host: '192.168.1.40',
  name: "Someone's living room hub",
  hostname: 'acme-hub-00a1b2.local',
  sources: const {NetworkDiscoverySource.mdns},
  discoveredAt: DateTime(2026),
  serviceTypes: types,
  ssdpTargets: const ['uuid:serial-1234', 'upnp:rootdevice'],
  txt: const {'mac': '00:11:22:33:44:55'},
);

void main() {
  group('buildBleSvcReport', () {
    test('null when the spec declares every non-ubiquitous service', () {
      expect(
        buildBleSvcReport(
          spec: _bleSpec,
          services: [_service(_svcUuid), _service('1800')],
          advertisedName: 'ACME_1',
        ),
        isNull,
      );
    });

    test('carries the unexpected service and its characteristics', () {
      final report = buildBleSvcReport(
        spec: _bleSpec,
        services: [
          _service(_svcUuid),
          _service(_dfuUuid, const [
            BleDiscoveredCharacteristic(
              uuid: '8ec90001-f315-4f60-9fb8-838830daea50',
              canRead: false,
              canWrite: true,
              canWriteWithResponse: true,
              canNotify: true,
            ),
          ]),
        ],
        advertisedName: 'ACME_1',
      )!;
      final json = report.toJson();
      expect(json['transport'], 'ble');
      expect(json['advertised_name'], 'ACME_1');
      expect((json['spec'] as Map)['key'], 'Bulb|Acme');
      expect(json['unexpected'], [
        {
          'kind': 'gatt',
          'id': 'fe59',
          'characteristics': [
            {
              'uuid': '8ec90001-f315-4f60-9fb8-838830daea50',
              'properties': ['write', 'notify'],
            },
          ],
        },
      ]);
      expect(json['discovered'], ['fe59', 'fff0']);
      expect(json['declared'], ['fff0']);
      expect(json['schema_version'], SvcReport.schemaVersion);
    });
  });

  group('buildWifiSvcReport', () {
    test('null when the spec covers every announced type', () {
      expect(
        buildWifiSvcReport(
          entry: _wifiEntry(),
          device: _netDevice(types: ['_acme._tcp.local', '_http._tcp.local']),
        ),
        isNull,
      );
    });

    test('reports an extra mDNS type and leaks no identifier', () {
      final report = buildWifiSvcReport(
        entry: _wifiEntry(),
        device: _netDevice(types: ['_acme._tcp.local', '_matter._tcp.local']),
      )!;
      expect(report.unexpected.map((e) => '${e.kind}:${e.id}'), [
        'mdns:_matter._tcp',
      ]);
      final wire = jsonEncode(report.toJson());
      // PRIVACY: none of what identifies this unit or its owner goes out.
      for (final secret in [
        '192.168.1.40',
        'living room',
        'acme-hub-00a1b2',
        '00:11:22:33:44:55',
        'serial-1234',
      ]) {
        expect(wire, isNot(contains(secret)), reason: secret);
      }
      expect(report.toJson().containsKey('advertised_name'), isFalse);
    });
  });

  group('SvcReport', () {
    test('mailto encodes spaces as %20, not +', () {
      final report = buildBleSvcReport(
        spec: _bleSpec,
        services: [_service(_dfuUuid)],
        advertisedName: 'ACME 1',
      )!;
      final uri = report.mailtoUri('svc-reports@liberatedbread.com');
      expect(uri.scheme, 'mailto');
      expect(uri.path, 'svc-reports@liberatedbread.com');
      expect(uri.toString(), isNot(contains('+')));
      expect(uri.queryParameters['subject'], contains('Acme Bulb'));
      expect(uri.queryParameters['body'], contains(report.reportId));
    });

    test('itemKeys ignore the random report id', () {
      SvcReport build() => buildBleSvcReport(
        spec: _bleSpec,
        services: [_service(_dfuUuid)],
        advertisedName: 'ACME_1',
      )!;
      final a = build();
      final b = build();
      expect(a.reportId, isNot(b.reportId));
      expect(a.itemKeys, b.itemKeys);
    });

    test('without() drops handled findings and keeps the rest', () {
      final report = buildBleSvcReport(
        spec: _bleSpec,
        services: [_service(_dfuUuid)],
        advertisedName: 'ACME_1',
        responses: [
          SvcReportResponse.undecodableBle(
            charUuid: 'fff1',
            bytes: const [1, 2, 3],
            error: 'expected 4 bytes',
          ),
        ],
      )!;
      expect(report.headline, 'unexpected services and responses');
      final rest = report.without({report.itemKeys.first})!;
      expect(rest.unexpected, isEmpty);
      expect(rest.responses, hasLength(1));
      expect(rest.headline, 'unexpected response');
      expect(report.without(report.itemKeys.toSet()), isNull);
    });

    test('newReportId is a version-4 UUID', () {
      final id = newReportId(Random(1));
      expect(
        id,
        matches(
          RegExp(
            r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-'
            r'[0-9a-f]{12}$',
          ),
        ),
      );
    });
  });

  group('SvcReportHandledNotifier', () {
    test('persists handled keys across containers', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      ProviderContainer make() => ProviderContainer(
        overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
      );
      final first = make();
      addTearDown(first.dispose);
      await first.read(svcReportHandledProvider.notifier).markHandled(['k1']);
      final second = make();
      addTearDown(second.dispose);
      expect(second.read(svcReportHandledProvider), {'k1'});
    });

    test('a corrupt stored value reads as empty', () async {
      SharedPreferences.setMockInitialValues({
        'svc_report_handled_keys': '{not json',
      });
      final prefs = await SharedPreferences.getInstance();
      final c = ProviderContainer(
        overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
      );
      addTearDown(c.dispose);
      expect(c.read(svcReportHandledProvider), isEmpty);
    });
  });

  group('SvcReportResponse', () {
    test('a BLE sample is hex, capped at 32 bytes', () {
      final r = SvcReportResponse.undecodableBle(
        charUuid: 'fff1',
        entity: 'Temperature',
        bytes: List<int>.generate(40, (i) => i),
        error: 'FormatException:\n  bad length',
      );
      expect(r.sample, hasLength(64));
      expect(r.sample, startsWith('000102'));
      expect(r.detail, '40 bytes; FormatException: bad length');
      expect(r.where, 'gatt:fff1');
    });

    test('an unmapped Wi-Fi state carries key names only, redacted', () {
      final r = SvcReportResponse.unmappedState(
        command: 'get_sysinfo',
        entity: 'Power',
        keys: const [
          'system.get_sysinfo.relay_state',
          'children.8006A1B2C3D4E5F60718293A4B5C6D7E.state',
          'devices.00:11:22:33:44:55.on',
          'hosts.192.168.1.40.up',
          'clients.a1b2c3d4-0000-4000-8000-1234567890ab.rssi',
        ],
      );
      expect(r.sample, isNull);
      for (final leak in ['8006A1B2', '00:11:22', '192.168', 'a1b2c3d4']) {
        expect(r.detail, isNot(contains(leak)), reason: leak);
      }
      expect(r.detail, contains('system.get_sysinfo.relay_state'));
      expect(r.detail, contains('children.<id>.state'));
      expect(r.detail, contains('hosts.<id>.up'));
    });

    test('an unrecognized value keeps a short raw sample', () {
      final r = SvcReportResponse.unrecognizedValue(
        where: 'command:get_mode',
        entity: 'Mode',
        raw: '7',
      );
      expect(r.toJson(), containsPair('sample', '7'));
      expect(r.itemKey, 'resp:unrecognized_value:command:get_mode:Mode');
    });
  });

  group('ResponseAnomalyNotifier', () {
    test('records once per finding, and caps per device', () {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      final notifier = c.read(responseAnomaliesProvider.notifier);
      SvcReportResponse r(int i) => SvcReportResponse.unmappedState(
        command: 'c$i',
        entity: 'E',
        keys: const ['a'],
      );
      notifier
        ..record('wifi:h', r(0))
        ..record('wifi:h', r(0));
      expect(c.read(responseAnomaliesProvider)['wifi:h'], hasLength(1));
      for (var i = 1; i < 40; i++) {
        notifier.record('wifi:h', r(i));
      }
      expect(
        c.read(responseAnomaliesProvider)['wifi:h'],
        hasLength(ResponseAnomalyNotifier.maxPerDevice),
      );
      expect(c.read(responseAnomaliesProvider)['ble:x'], isNull);
    });

    test('anomaly keys are scoped by spec, so a switch starts clean', () {
      expect(
        bleAnomalyKey('d', 'spec: a'),
        isNot(bleAnomalyKey('d', 'spec: b')),
      );
      expect(bleAnomalyKey('d', 'spec: a'), bleAnomalyKey('d', 'spec: a'));
      final device = _netDevice();
      expect(
        wifiAnomalyKey(device, 'Hub|Acme'),
        isNot(wifiAnomalyKey(device, 'Plug|Acme')),
      );
    });

    test('a Wi-Fi report built from responses alone', () {
      final report = buildWifiSvcReport(
        entry: _wifiEntry(),
        device: _netDevice(types: ['_acme._tcp.local']),
        responses: [
          SvcReportResponse.unmappedState(
            command: 'get_state',
            entity: 'Power',
            keys: const ['on'],
          ),
        ],
      )!;
      expect(report.unexpected, isEmpty);
      expect(report.headline, 'unexpected response');
      expect(report.toJson()['responses'], hasLength(1));
    });
  });

  group('user note', () {
    SvcReport report() => buildBleSvcReport(
      spec: _bleSpec,
      services: [_service(_dfuUuid)],
      advertisedName: 'ACME_1',
    )!;

    test('blank is no note', () {
      expect(report().withUserNote('   ').userNote, isNull);
      expect(
        report().withUserNote(null).toJson(),
        isNot(contains('user_note')),
      );
    });

    test('trimmed, capped, and kept through without()', () {
      final long = 'x' * (SvcReport.maxUserNoteChars + 50);
      final r = report().withUserNote('  $long  ');
      expect(r.userNote, hasLength(SvcReport.maxUserNoteChars));
      expect(r.without(const {})!.userNote, r.userNote);
      expect(r.itemKeys, report().itemKeys);
    });
  });
}
