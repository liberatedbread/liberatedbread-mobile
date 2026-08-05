// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// Pure parsing and coalescing rules from the network scanner, exercised without
// a socket. The transports themselves need a real network; these are the parts
// that get wrong answers silently, so they are the parts worth testing.

import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/models/network_device.dart';
import 'package:liberated_bread_mobile/services/real_network_scan_service.dart';

NetworkDevice _device({
  String host = '192.168.1.10',
  String name = '',
  String? hostname,
  int? port,
  List<String> serviceTypes = const [],
  List<String> ssdpTargets = const [],
  Map<String, String> txt = const {},
  NetworkDiscoverySource source = NetworkDiscoverySource.mdns,
}) =>
    NetworkDevice(
      host: host,
      name: name,
      hostname: hostname,
      port: port,
      serviceTypes: serviceTypes,
      ssdpTargets: ssdpTargets,
      txt: txt,
      sources: {source},
      discoveredAt: DateTime(2026),
    );

void main() {
  group('parseSsdpHeaders', () {
    const response = 'HTTP/1.1 200 OK\r\n'
        'CACHE-CONTROL: max-age=86400\r\n'
        'LOCATION: http://192.168.1.41:49153/setup.xml\r\n'
        'SERVER: Unspecified, UPnP/1.0, Unspecified\r\n'
        'ST: urn:Belkin:device:controllee:1\r\n'
        '\r\n';

    test('reads the headers a device actually sends', () {
      final headers = parseSsdpHeaders(response);
      expect(headers['location'], 'http://192.168.1.41:49153/setup.xml');
      expect(headers['st'], 'urn:Belkin:device:controllee:1');
      expect(headers['server'], 'Unspecified, UPnP/1.0, Unspecified');
    });

    test('the status line is not mistaken for a header', () {
      expect(
          parseSsdpHeaders(response).containsKey('http/1.1 200 ok'), isFalse);
    });

    test('tolerates the casing and line endings shipped hardware uses', () {
      // Real SSDP stacks are famously sloppy here, and a strict parser would
      // silently drop real devices.
      final headers = parseSsdpHeaders(
          'HTTP/1.1 200 OK\nst:   urn:x:1  \r\nLoCaTiOn:http://a/b\r');
      expect(headers['st'], 'urn:x:1');
      expect(headers['location'], 'http://a/b');
    });

    test('a header with an empty value is dropped', () {
      expect(parseSsdpHeaders('HTTP/1.1 200 OK\r\nST:\r\n')['st'], isNull);
    });
  });

  group('parseSsdpLocation', () {
    test('splits a location into host and port', () {
      final parsed = parseSsdpLocation('http://192.168.1.41:49153/setup.xml');
      expect(parsed?.host, '192.168.1.41');
      expect(parsed?.port, 49153);
    });

    test('a location with no explicit port reports none', () {
      // Defaulting to 80 here would invent a fact; the device did not say it.
      expect(parseSsdpLocation('http://192.168.1.41/setup.xml')?.port, isNull);
    });

    test('unparseable locations yield nothing', () {
      expect(parseSsdpLocation(null), isNull);
      expect(parseSsdpLocation(''), isNull);
      expect(parseSsdpLocation('not a url'), isNull);
    });
  });

  group('parseTxtRecord', () {
    test('splits key=value entries and lowercases keys', () {
      final txt =
          parseTxtRecord(['bridgeid=001788FFFE1234AB', 'ModelId=BSB002']);
      expect(txt['bridgeid'], '001788FFFE1234AB');
      expect(txt['modelid'], 'BSB002');
    });

    test('a value containing = survives intact', () {
      expect(parseTxtRecord(['data=a=b'])['data'], 'a=b');
    });

    test('a bare key is kept as a flag, not dropped', () {
      // Its presence is the signal.
      expect(parseTxtRecord(['secure']), {'secure': ''});
    });
  });

  group('service instance names', () {
    test('splits an instance into its name and type', () {
      const instance = 'Philips Hue - AB12CD._hue._tcp.local';
      expect(serviceTypeOf(instance), '_hue._tcp.local');
      expect(instanceNameOf(instance), 'Philips Hue - AB12CD');
    });

    test('a bare service type has no instance name', () {
      expect(serviceTypeOf('_hue._tcp.local'), '_hue._tcp.local');
      expect(instanceNameOf('_hue._tcp.local'), '');
    });

    test('handles udp service types too', () {
      expect(serviceTypeOf('Thing._coap._udp.local'), '_coap._udp.local');
    });
  });

  group('NetworkScanCoalescer', () {
    test('a first sighting is emitted', () {
      final coalescer = NetworkScanCoalescer();
      expect(coalescer.next(_device()), isNotNull);
      expect(coalescer.deviceCount, 1);
    });

    test('an identical re-announcement is suppressed', () {
      // mDNS devices re-announce constantly; forwarding each would make the
      // list flicker and re-run matching for nothing.
      final coalescer = NetworkScanCoalescer();
      coalescer.next(_device(serviceTypes: const ['_hue._tcp.local']));
      expect(
        coalescer.next(_device(serviceTypes: const ['_hue._tcp.local'])),
        isNull,
      );
    });

    test('the same host on two transports becomes one merged device', () {
      // A bridge answering both mDNS and SSDP is one device, and the union of
      // what both said is better evidence than either alone.
      final coalescer = NetworkScanCoalescer();
      coalescer.next(_device(
        name: 'Hue',
        serviceTypes: const ['_hue._tcp.local'],
      ));
      final merged = coalescer.next(_device(
        ssdpTargets: const ['urn:schemas-upnp-org:device:Basic:1'],
        port: 80,
        source: NetworkDiscoverySource.ssdp,
      ));

      expect(coalescer.deviceCount, 1);
      expect(merged, isNotNull);
      expect(merged!.name, 'Hue', reason: 'a known name must not be lost');
      expect(merged.serviceTypes, ['_hue._tcp.local']);
      expect(merged.ssdpTargets, ['urn:schemas-upnp-org:device:Basic:1']);
      expect(merged.port, 80);
      expect(merged.sources, {
        NetworkDiscoverySource.mdns,
        NetworkDiscoverySource.ssdp,
      });
    });

    test('a newly-learned service type re-emits', () {
      final coalescer = NetworkScanCoalescer();
      coalescer.next(_device(serviceTypes: const ['_hue._tcp.local']));
      final updated =
          coalescer.next(_device(serviceTypes: const ['_hap._tcp.local']));
      expect(updated!.serviceTypes, hasLength(2));
    });

    test('different hosts are tracked separately', () {
      final coalescer = NetworkScanCoalescer();
      coalescer.next(_device(host: '192.168.1.10'));
      coalescer.next(_device(host: '192.168.1.11'));
      expect(coalescer.deviceCount, 2);
    });
  });

  group('NetworkDevice', () {
    test('displayName prefers the name, then the hostname, then the address',
        () {
      expect(_device(name: 'Hue', hostname: 'a.local').displayName, 'Hue');
      // The .local suffix is on every hostname and carries no information.
      expect(_device(hostname: 'Lutron-083e.local').displayName, 'Lutron-083e');
      expect(
          _device(hostname: 'Lutron-083e.local.').displayName, 'Lutron-083e');
      expect(_device(host: '192.168.1.10').displayName, '192.168.1.10');
    });

    test('finds a MAC published in a TXT record', () {
      // The one thing on the network side the IEEE registry can name -- and
      // unlike the IP, it does not move.
      expect(
        _device(txt: const {'macaddr': 'b8:94:d9:aa:bb:cc'}).advertisedMac,
        'B8:94:D9:AA:BB:CC',
      );
      // A Hue bridgeid is an EUI-64: the address with FFFE spliced in. Naively
      // truncating to twelve digits would give 00:17:88:FF:FE:12, which is not
      // an address at all and resolves to nothing.
      expect(
        _device(txt: const {'bridgeid': '001788FFFE1234AB'}).advertisedMac,
        '00:17:88:12:34:AB',
      );
    });

    test('reports no MAC when the TXT record holds none', () {
      expect(_device().advertisedMac, isNull);
      expect(_device(txt: const {'mac': 'nonsense'}).advertisedMac, isNull);
      // 16 hex digits without FFFE in the middle is some other identifier.
      expect(
        _device(txt: const {'bridgeid': '0017881234567890'}).advertisedMac,
        isNull,
      );
    });
  });
}
