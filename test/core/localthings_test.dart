// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/core/localthings.dart';
import 'package:liberated_bread_mobile/models/network_device.dart';

NetworkDevice _device({
  String host = '192.168.1.60',
  int? port,
  List<String> serviceTypes = const [],
  Map<String, String> txt = const {},
}) => NetworkDevice(
  host: host,
  name: '',
  port: port,
  serviceTypes: serviceTypes,
  txt: txt,
  sources: const {NetworkDiscoverySource.mdns},
  discoveredAt: DateTime(2026),
);

void main() {
  group('isSmartThingsDevice', () {
    test('either SmartThings type, in any spelling the scan produces', () {
      for (final type in const [
        '_smartthings._tcp.local',
        '_smartthings._tcp.local.',
        '_SmartThings._tcp',
        '_smartthings-hedge._tcp.local',
      ]) {
        expect(
          isSmartThingsDevice(_device(serviceTypes: [type])),
          isTrue,
          reason: type,
        );
      }
    });

    test('the hub\'s Matter advertisement alone is not SmartThings', () {
      // Every Matter device on the network announces _matter._tcp; it names
      // no vendor.
      expect(
        isSmartThingsDevice(_device(serviceTypes: ['_matter._tcp.local'])),
        isFalse,
      );
    });
  });

  test('isHomeAssistantServer keys on HA\'s own zeroconf type', () {
    expect(
      isHomeAssistantServer(
        _device(serviceTypes: ['_home-assistant._tcp.local']),
      ),
      isTrue,
    );
    expect(
      isHomeAssistantServer(_device(serviceTypes: ['_http._tcp.local'])),
      isFalse,
    );
  });

  group('homeAssistantUrlOf', () {
    test('prefers the internal_url the owner configured', () {
      final ha = _device(
        port: 8123,
        txt: {
          'internal_url': 'http://homeassistant.local:8123/',
          'base_url': 'https://example.ui.nabu.casa',
        },
      );
      expect(homeAssistantUrlOf(ha), 'http://homeassistant.local:8123');
    });

    test('falls back to base_url, then to the SRV address and port', () {
      expect(
        homeAssistantUrlOf(
          _device(txt: {'internal_url': '', 'base_url': 'http://ha.lan:8123'}),
        ),
        'http://ha.lan:8123',
      );
      expect(
        homeAssistantUrlOf(_device(port: 8124)),
        'http://192.168.1.60:8124',
      );
      expect(homeAssistantUrlOf(_device()), 'http://192.168.1.60:8123');
    });

    test('a TXT URL that is not http(s) is ignored, not opened', () {
      final ha = _device(port: 8123, txt: {'internal_url': 'shortcuts://run'});
      expect(homeAssistantUrlOf(ha), 'http://192.168.1.60:8123');
    });

    test('an IPv6 SRV address is bracketed', () {
      expect(
        homeAssistantUrlOf(_device(host: 'fd00::5', port: 8123)),
        'http://[fd00::5]:8123',
      );
    });
  });

  group('localThingsAddApplianceUrl', () {
    test('goes straight at a known instance', () {
      expect(
        localThingsAddApplianceUrl(
          haBaseUrl: 'http://ha.local:8123/',
        ).toString(),
        'http://ha.local:8123/_my_redirect/config_flow_start?domain=localthings',
      );
    });

    test('keeps a path prefix the instance is served under', () {
      expect(
        localThingsAddApplianceUrl(
          haBaseUrl: 'https://proxy.example/ha',
        ).toString(),
        'https://proxy.example/ha/_my_redirect/config_flow_start'
        '?domain=localthings',
      );
    });

    test('uses the hosted redirect when no instance is known', () {
      for (final base in const [null, '', 'not a url', 'ftp://ha']) {
        expect(
          localThingsAddApplianceUrl(haBaseUrl: base).toString(),
          'https://my.home-assistant.io/redirect/config_flow_start/'
          '?domain=localthings',
          reason: '$base',
        );
      }
    });
  });

  test('the HACS link names the LocalThings repository', () {
    expect(
      localThingsHacsUrl.toString(),
      'https://my.home-assistant.io/redirect/hacs_repository/'
      '?owner=mbillow&repository=localthings&category=integration',
    );
  });

  test('hasLocalThings accepts the domain or any of its platforms', () {
    expect(hasLocalThings(['http', 'localthings']), isTrue);
    expect(hasLocalThings(['localthings.sensor']), isTrue);
    expect(hasLocalThings(['smartthings', 'localthingsx']), isFalse);
  });
}
