// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// What the scan concludes when a UDP send is REFUSED.
//
// The verdict the Wi-Fi screen is built on comes from scanFailureFor, where a
// single `denied` beats every `heard`: one transport that observed
// EHOSTUNREACH is taken as proof the OS refused the network. So a refusal
// that is NOT about the network — a multicast group this host cannot route,
// a subnet-directed broadcast a spec pack named — must never reach that
// classifier, or a scan that found devices on every other transport still
// tells the user Local Network is off.
//
// Five commits tried to hold that line with try/catch around send() and
// held nothing: dart:io never throws from RawDatagramSocket.send. The
// SocketException lands on the socket's stream a microtask later and the
// socket closes. Nothing here modelled that, so the dead catches shipped and
// the false verdict stayed live through ten review passes. This file drives
// the real service through a fake that puts the refusal where dart:io does.
//
// Every case makes SSDP hear a device first, because that is the condition
// under which a false `denied` is visible at all.
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/services/multicast_lock.dart';
import 'package:liberated_bread_mobile/services/network_scan_service.dart';
import 'package:liberated_bread_mobile/services/real_network_scan_service.dart';
import 'package:liberated_bread_mobile/src/rust/api/spec_handle.dart';

import '../fakes/fake_datagram_socket.dart';

const _ssdpReply =
    'HTTP/1.1 200 OK\r\n'
    'ST: upnp:rootdevice\r\n'
    'USN: uuid:0000-test::upnp:rootdevice\r\n'
    'LOCATION: http://192.0.2.7/desc.xml\r\n'
    'SERVER: test/1.0\r\n'
    '\r\n';

/// A network of fakes: every bind the service asks for gets one, sends
/// matching [refuse] are refused the way dart:io refuses them, and any SSDP
/// M-SEARCH is answered so one transport hears a device.
class _Network {
  final bool Function(InternetAddress address, int port) refuse;
  final sockets = <FakeDatagramSocket>[];

  _Network({required this.refuse});

  Future<RawDatagramSocket> bind(
    dynamic host,
    int port, {
    bool reuseAddress = true,
    bool reusePort = false,
    int ttl = 1,
  }) async {
    final socket = FakeDatagramSocket(port: port, refuse: refuse)
      ..onSend = (socket, datagram) {
        if (datagram.port == 1900) socket.deliver(_ssdpReply.codeUnits);
      };
    sockets.add(socket);
    return socket;
  }

  /// The sockets that sent to [address]:[port].
  Iterable<FakeDatagramSocket> sentTo(String address, int port) =>
      sockets.where(
        (s) =>
            s.sent.any((d) => d.address.address == address && d.port == port),
      );
}

UdpProbeDto _probe({
  required String specKey,
  required String address,
  required int port,
}) => UdpProbeDto(
  specKey: specKey,
  index: 0,
  displayName: specKey,
  port: port,
  broadcastAddress: address,
  probe: Uint8List.fromList(const [0x01]),
  passiveOk: false,
  lanProtocols: const [],
  stableKeys: const [],
);

// The two shapes a spec can name. aqara-hub really declares the group; the
// broadcast one is on a port nothing else in the file uses, so refusing it
// refuses the catalogue's send and no other transport's.
final _aqara = _probe(
  specKey: 'aqara-hub.yaml',
  address: '230.0.0.1',
  port: 10008,
);
final _milight = _probe(
  specKey: 'limitlessled-milight-bridge.yaml',
  address: '255.255.255.255',
  port: 47777,
);

Future<Object?> _verdict(_Network network, {required bool apple}) async {
  final service = RealNetworkScanService(
    multicastLock: MulticastLock(isSupported: false),
    interfaceLister:
        ({
          bool includeLoopback = false,
          bool includeLinkLocal = false,
          InternetAddressType type = InternetAddressType.any,
        }) async => [],
    probeSource: () async => [_aqara, _milight],
    binder: network.bind,
    isApplePlatform: apple,
  );
  try {
    await service
        .scan(timeout: const Duration(milliseconds: 300))
        .drain<void>();
    return null;
  } catch (e) {
    return e;
  }
}

bool _is(InternetAddress a, int p, String address, int port) =>
    a.address == address && p == port;

void main() {
  test('a refused multicast probe is not a denied Local Network', () async {
    final network = _Network(refuse: (a, p) => a.address == '230.0.0.1');

    expect(await _verdict(network, apple: true), isNull);

    // The refusal cost aqara's socket and nothing else: the broadcast probe
    // on its own socket still went out. Grouped by port instead of by
    // destination, one refusal closed the socket carrying both.
    expect(network.sentTo('230.0.0.1', 10008).single.closed, isTrue);
    expect(network.sentTo('255.255.255.255', 47777), isNotEmpty);
  });

  test(
    'a refused broadcast probe on Apple is a denied Local Network',
    () async {
      final network = _Network(
        refuse: (a, p) => _is(a, p, '255.255.255.255', 47777),
      );

      expect(
        await _verdict(network, apple: true),
        isA<LocalNetworkDeniedException>(),
        reason:
            'EHOSTUNREACH to the broadcast address is the one refusal that '
            'proves the OS gate, and it must still reach the verdict',
      );
    },
  );

  test(
    'the same refusal off Apple is an empty network, not a denial',
    () async {
      final network = _Network(
        refuse: (a, p) => _is(a, p, '255.255.255.255', 47777),
      );

      expect(await _verdict(network, apple: false), isNull);
    },
  );

  test(
    'a refused Yeelight, KNX or Govee group is not a denial either',
    () async {
      final network = _Network(
        refuse: (a, p) =>
            _is(a, p, '239.255.255.250', 1982) ||
            _is(a, p, '224.0.23.12', 3671) ||
            _is(a, p, '239.255.255.250', 4001),
      );

      expect(await _verdict(network, apple: true), isNull);

      // Each refusal closed the socket it was attempted on — dart:io's doing —
      // and the transport met it there rather than at send().
      for (final (address, port) in const [
        ('239.255.255.250', 1982),
        ('224.0.23.12', 3671),
        ('239.255.255.250', 4001),
      ]) {
        expect(
          network.sentTo(address, port).single.closed,
          isTrue,
          reason: '$address:$port',
        );
      }
    },
  );

  test(
    'nothing refused, nothing denied — the fixture is not the verdict',
    () async {
      final network = _Network(refuse: (a, p) => false);

      expect(await _verdict(network, apple: true), isNull);
    },
  );
}
