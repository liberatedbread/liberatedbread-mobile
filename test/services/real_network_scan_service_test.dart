// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// Pure parsing and coalescing rules from the network scanner, exercised without
// a socket. The transports themselves need a real network; these are the parts
// that get wrong answers silently, so they are the parts worth testing.

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/models/network_device.dart';
import 'package:liberated_bread_mobile/services/network_scan_service.dart';
import 'package:liberated_bread_mobile/services/real_network_scan_service.dart';

NetworkDevice _device({
  String host = '192.168.1.10',
  String name = '',
  String? hostname,
  int? port,
  List<String> serviceTypes = const [],
  List<String> ssdpTargets = const [],
  Map<String, String> txt = const {},
  String? server,
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
      server: server,
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
    test('splits a location into host, port and description path', () {
      final parsed = parseSsdpLocation('http://192.168.1.41:49153/setup.xml');
      expect(parsed?.host, '192.168.1.41');
      expect(parsed?.port, 49153);
      expect(parsed?.path, '/setup.xml');
      // A Viera advertises its description under its own spelling.
      expect(parseSsdpLocation('http://192.168.1.41:55000/nrc/ddd.xml')?.path,
          '/nrc/ddd.xml');
    });

    test('a location with no explicit port reports the scheme default', () {
      // `http://host/path` states port 80 the way URLs state it — by scheme.
      // Reporting null here made the control screen refuse to talk to a
      // device that advertised its port fine; only a scheme with no default
      // genuinely leaves the port unsaid.
      expect(parseSsdpLocation('http://192.168.1.41/setup.xml')?.port, 80);
      expect(parseSsdpLocation('foo://192.168.1.41/setup.xml')?.port, isNull);
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

  group('normalizeMdnsServiceType', () {
    test(
        'strips the trailing dot a spec writes so it dedupes with the '
        'meta-query', () {
      // Specs declare `_snapmaker._tcp.local.`; the enumeration and the
      // `resolving` set carry `_snapmaker._tcp.local`. Without stripping the
      // dot a direct query would re-resolve a type the enumeration found.
      expect(normalizeMdnsServiceType('_snapmaker._tcp.local.'),
          '_snapmaker._tcp.local');
      expect(normalizeMdnsServiceType('_hue._tcp.local'), '_hue._tcp.local');
      expect(normalizeMdnsServiceType('  _coap._udp.local.  '),
          '_coap._udp.local');
    });

    test('drops anything not shaped like a DNS-SD service type', () {
      // A malformed catalogue entry must not become a junk PTR query.
      expect(normalizeMdnsServiceType(''), isNull);
      expect(normalizeMdnsServiceType('snapmaker'), isNull);
      expect(normalizeMdnsServiceType('_snapmaker.local'), isNull);
      expect(normalizeMdnsServiceType('http://x'), isNull);
    });
  });

  group('mDNS source-capture wire helpers', () {
    test('mdnsPtrQuery encodes the name as length-prefixed labels + PTR/IN',
        () {
      final q = mdnsPtrQuery('_snapmaker._tcp.local');
      // Header: 12 bytes, qdcount 1.
      expect(q.sublist(0, 12), [0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0]);
      // Labels: <len>_snapmaker <len>_tcp <len>local <root>.
      expect(q[12], 10); // len("_snapmaker")
      expect(String.fromCharCodes(q.sublist(13, 23)), '_snapmaker');
      expect(q[23], 4); // len("_tcp")
      // Ends with the root label then QTYPE PTR (12) + QCLASS IN (1).
      expect(q.sublist(q.length - 5), [0, 0, 12, 0, 1]);
    });

    test('mdnsFirstLabelBytes returns the vendor label, or null when tiny', () {
      expect(
          String.fromCharCodes(mdnsFirstLabelBytes('_snapmaker._tcp.local')!),
          '_snapmaker');
      // A 2-char label is too weak a discriminator.
      expect(mdnsFirstLabelBytes('_x._tcp.local'), isNull);
    });

    test('containsBytes finds a contiguous subsequence', () {
      // The wire carries `\x0a_snapmaker`, so the label bytes appear verbatim.
      final packet = [
        1,
        2,
        10,
        ...'_snapmaker'.codeUnits,
        4,
        ...'_tcp'.codeUnits
      ];
      expect(containsBytes(packet, '_snapmaker'.codeUnits), isTrue);
      expect(containsBytes(packet, '_printer'.codeUnits), isFalse);
      expect(containsBytes(packet, const []), isFalse);
    });
  });

  group('parseUbiquitiDiscovery', () {
    test('reads hostname, platform and MAC from a real TLV reply', () {
      // Shape captured from an EdgeSwitch 10X: v1 header, then 0x0c platform,
      // 0x0b hostname, 0x01 MAC.
      final reply = <int>[
        0x01, 0x00, 0x00, 0x82, // version 1, cmd 0, length
        0x0c, 0x00, 0x06, ...'ES-10X'.codeUnits, // platform
        0x0b, 0x00, 0x11, ...'livingroom-switch'.codeUnits, // hostname (17)
        0x01, 0x00, 0x06, 0x74, 0xac, 0xb9, 0x01, 0x02, 0x03, // MAC
      ];
      final p = parseUbiquitiDiscovery(reply);
      expect(p.hostname, 'livingroom-switch');
      expect(p.platform, 'ES-10X');
      expect(p.mac, '74:ac:b9:01:02:03');
    });

    test('rejects a non-v1 datagram and a truncated one', () {
      expect(
          parseUbiquitiDiscovery(const [0x02, 0x00, 0x00, 0x00]).mac, isNull);
      expect(parseUbiquitiDiscovery(const [0x01]).hostname, isNull);
    });

    test('ubiquitiPictogram maps the platform to a glyph token', () {
      expect(ubiquitiPictogram('UVC G4 Pro'), 'ip-camera');
      expect(ubiquitiPictogram('UVC G4 Doorbell'), 'video-doorbell');
      expect(ubiquitiPictogram('UNVR'), 'nvr');
      expect(ubiquitiPictogram('UNASPRO'), 'nas');
      expect(ubiquitiPictogram('ES-10X'), 'network-switch');
      expect(ubiquitiPictogram('UFP-UAP-B'), 'wifi-ap');
      expect(ubiquitiPictogram('U6-LR'), 'wifi-ap');
      expect(ubiquitiPictogram('UDM-Pro'), 'cloud-key');
      // Unknown platform falls back to the generic spec glyph.
      expect(ubiquitiPictogram('SomethingNew'), isNull);
      expect(ubiquitiPictogram(null), isNull);
    });
  });

  group('parseMndp (MikroTik)', () {
    test('reads identity, MAC and version from a real beacon', () {
      // Captured from a "Pleakley-switch": 4-byte header, then 0x0001 MAC,
      // 0x0005 Identity, 0x0007 Version. Types and lengths are 2 bytes BE.
      final beacon = <int>[
        0x00, 0x02, 0x6e, 0xb6, // header
        0x00, 0x01, 0x00, 0x06, 0x18, 0xfd, 0x74, 0x41, 0x73, 0xd7, // MAC
        0x00, 0x05, 0x00, 0x0f, ...'Pleakley-switch'.codeUnits, // identity
        0x00, 0x07, 0x00, 0x03, ...'7.9'.codeUnits, // version
      ];
      final p = parseMndp(beacon);
      expect(p.identity, 'Pleakley-switch');
      expect(p.mac, '18:fd:74:41:73:d7');
      expect(p.version, '7.9');
    });

    test('mikrotikPictogram picks switch vs router', () {
      expect(mikrotikPictogram(identity: 'CoreSwitch'), 'network-switch');
      expect(mikrotikPictogram(board: 'CRS328-24P-4S+'), 'network-switch');
      expect(mikrotikPictogram(board: 'RB4011', identity: 'newhouse-core'),
          'router');
    });
  });

  group('mdnsPictogram', () {
    test('a legacy printer type (no _ipp) still resolves to printer', () {
      // A Brother DCP-7065DN advertises only _printer._tcp / _pdl-datastream,
      // never _ipp._tcp, so it fails the IPP spec match — the per-device
      // pictogram is what draws its glyph.
      expect(mdnsPictogram(['_printer._tcp.local']), 'printer');
      expect(mdnsPictogram(['_pdl-datastream._tcp.local.']), 'printer');
      expect(mdnsPictogram(['_ipp._tcp']), 'printer');
      expect(mdnsPictogram(['_ipps._tcp.local']), 'printer');
    });

    test('the trailing dot and .local suffix do not matter', () {
      expect(mdnsPictogram(['_PRINTER._TCP.LOCAL.']), 'printer');
    });

    test('a non-printer type resolves to nothing', () {
      expect(mdnsPictogram(['_http._tcp.local']), isNull);
      expect(mdnsPictogram(['_snapmaker._tcp.local']), isNull);
      expect(mdnsPictogram(const []), isNull);
    });

    test('a printer type anywhere in the list wins', () {
      expect(mdnsPictogram(['_http._tcp.local', '_pdl-datastream._tcp.local']),
          'printer');
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

    test('a second transport re-emits even when it adds no identifier', () {
      // The row's transport label comes from `sources`, so a device already
      // known over mDNS that answers SSDP has to redraw — even when the reply
      // carries no ST/NT and therefore adds no search target. The merge was
      // always stored correctly; it was the "nothing changed" verdict that
      // left the row reading "mDNS" for the rest of the scan.
      final coalescer = NetworkScanCoalescer();
      coalescer.next(_device(serviceTypes: const ['_hue._tcp.local']));
      final updated = coalescer.next(_device(
        serviceTypes: const ['_hue._tcp.local'],
        server: 'Unspecified, UPnP/1.0, Unspecified',
        source: NetworkDiscoverySource.ssdp,
      ));

      expect(updated, isNotNull,
          reason: 'gaining a transport is a visible change');
      expect(updated!.sources, {
        NetworkDiscoverySource.mdns,
        NetworkDiscoverySource.ssdp,
      });
      expect(updated.server, 'Unspecified, UPnP/1.0, Unspecified');
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
        _device(txt: const {'macaddr': 'b8:94:d9:1e:e7:67'}).advertisedMac,
        'B8:94:D9:1E:E7:67',
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

  group('scanFailureFor', () {
    // The rule that decides what an empty scan means. It used to be
    // unreachable: both transports reported "did the socket open", which is
    // true even when the OS is dropping every reply, so the denial branch
    // could not fire on the one platform that has a denial to report.
    test('a transport that heard something means nothing is wrong', () {
      for (final other in TransportOutcome.values) {
        expect(
          scanFailureFor(
            outcomes: [TransportOutcome.heard, other],
            isApplePlatform: true,
          ),
          isNull,
          reason: 'traffic reached us, so nothing is filtering it',
        );
      }
    });

    test('neither transport starting is unavailable, on every platform', () {
      for (final apple in [true, false]) {
        expect(
          scanFailureFor(
            outcomes: const [TransportOutcome.failed, TransportOutcome.failed],
            isApplePlatform: apple,
          ),
          isA<NetworkUnavailableException>(),
          reason: 'no interface and no multicast route is not a permission '
              'question, it is a missing network',
        );
      }
    });

    test('total silence on Apple offers the local-network permission', () {
      expect(
        scanFailureFor(
          outcomes: const [TransportOutcome.silent, TransportOutcome.silent],
          isApplePlatform: true,
        ),
        isA<LocalNetworkDeniedException>(),
      );
      // One started and heard nothing while the other never started at all:
      // still silence, still the same advice.
      expect(
        scanFailureFor(
          outcomes: const [TransportOutcome.silent, TransportOutcome.failed],
          isApplePlatform: true,
        ),
        isA<LocalNetworkDeniedException>(),
      );
    });

    test('total silence elsewhere is just an empty network', () {
      // Android reaches this state legitimately -- it takes a multicast lock
      // rather than inferring a permission problem after the fact -- and a
      // desktop on a quiet LAN reaches it honestly. Neither should be told to
      // go change a setting that does not exist.
      expect(
        scanFailureFor(
          outcomes: const [TransportOutcome.silent, TransportOutcome.silent],
          isApplePlatform: false,
        ),
        isNull,
      );
    });
  });

  group('LIFX discovery', () {
    test('the probe is a tagged-broadcast GetService, byte for byte', () {
      final probe = lifxGetServiceProbe();
      // These exact bytes are what crate::protocol::lifx::get_service(0) builds;
      // a Rust test pins the same values, so the two builders cannot drift.
      expect(probe.length, 36);
      expect(probe.sublist(0, 2), [36, 0], reason: 'size');
      expect(probe.sublist(2, 4), [0x00, 0x34],
          reason: 'protocol|addressable|tagged');
      expect(probe.sublist(4, 8), [0x47, 0x52, 0x42, 0x4C],
          reason: 'source LBRG');
      expect(probe[22], 0x01, reason: 'res_required');
      expect(probe.sublist(32, 34), [2, 0], reason: 'GetService type');
    });

    test('a StateService reply yields the device MAC', () {
      final reply = Uint8List(41);
      // Header target (offset 8) carries the 6-byte MAC.
      reply.setRange(8, 14, const [0xd0, 0x73, 0xd5, 0x00, 0x04, 0xa3]);
      reply[32] = 3; // StateService
      expect(lifxStateServiceMac(reply), 'd0:73:d5:00:04:a3');
    });

    test('a non-StateService or short datagram yields nothing', () {
      final other = Uint8List(41)
        ..[32] = 107; // a light State, not StateService
      expect(lifxStateServiceMac(other), isNull);
      expect(lifxStateServiceMac(const [1, 2, 3]), isNull);
    });
  });
}
