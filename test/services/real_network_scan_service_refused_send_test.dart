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
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/models/network_device.dart';
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

  /// Answers any other send, the way a device on the network would: called
  /// with the datagram, and free to [deliver] to whichever port the device
  /// replies to — which for Govee and BiSecur is not the one probed.
  final void Function(_Network network, SentDatagram datagram)? answer;
  final sockets = <FakeDatagramSocket>[];

  _Network({required this.refuse, this.answer});

  /// A unicast datagram from [from] arriving at [port].
  ///
  /// Delivered to ONE socket, the most recently bound that is still open —
  /// what Linux does when two sockets share a UDP port through SO_REUSEADDR
  /// (measured with dart:io: every datagram went to the later bind, none to
  /// the earlier). A fake that copied it to every socket on the port would
  /// hide exactly the loss a second bind of a port causes.
  void deliver(int port, String data, {required String from}) {
    final open = sockets.where((s) => s.port == port && !s.closed);
    if (open.isEmpty) return;
    open.last.deliver(utf8.encode(data), from: InternetAddress(from));
  }

  /// How many times a socket was bound to [port].
  int bindsOf(int port) => sockets.where((s) => s.port == port).length;

  Future<RawDatagramSocket> bind(
    dynamic host,
    int port, {
    bool reuseAddress = true,
    bool reusePort = false,
    int ttl = 1,
  }) async {
    final socket = FakeDatagramSocket(port: port, refuse: refuse)
      ..onSend = (socket, datagram) {
        if (datagram.port == 1900) {
          socket.deliver(_ssdpReply.codeUnits);
        } else {
          answer?.call(this, datagram);
        }
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
  int? listenPort,
  List<UdpIdentityFieldDto> stableKeys = const [],
  List<String> lanProtocols = const [],
}) => UdpProbeDto(
  specKey: specKey,
  index: 0,
  displayName: specKey,
  port: port,
  listenPort: listenPort,
  broadcastAddress: address,
  probe: Uint8List.fromList(const [0x01]),
  passiveOk: false,
  lanProtocols: lanProtocols,
  stableKeys: stableKeys,
);

// The two shapes a spec can name, on the SAME port. aqara-hub really declares
// the group; the broadcast probe is put on aqara's port on purpose, because
// the grouping under test is by destination and not by port — with the two on
// different ports, a regression back to one-socket-per-port lands them on two
// sockets anyway and the refusal costs nothing it can be seen costing. 10008
// is a port nothing else in the file sends to, so refusing an address on it
// refuses the catalogue's send and no other transport's.
final _aqara = _probe(
  specKey: 'aqara-hub.yaml',
  address: '230.0.0.1',
  port: 10008,
);
final _milight = _probe(
  specKey: 'limitlessled-milight-bridge.yaml',
  address: '255.255.255.255',
  port: 10008,
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

/// BiSecur as its spec declares it: probed on 4001, answered on 4002, and
/// identified by the reply's `mac` attribute.
final _bisecur = _probe(
  specKey: 'hormann-bisecur-gateway.yaml',
  address: '255.255.255.255',
  port: 4001,
  listenPort: 4002,
  stableKeys: const [
    UdpIdentityFieldDto(dialect: 'xml', path: 'mac', name: 'mac'),
  ],
  lanProtocols: const ['bisecur'],
);

const _bisecurReply =
    '<LogicBox swVersion="2.5.0" hwVersion="1.0.0" '
    'mac="54:10:EC:00:00:01" protocol="MCP V3.0"/>';

const _goveeReply =
    '{"msg":{"cmd":"scan","data":{"ip":"192.0.2.50",'
    '"device":"AA:BB:CC:DD:EE:FF:00:11","sku":"H6159"}}}';

/// Every device a short scan with [probes] found on [network].
Future<List<NetworkDevice>> _scan(_Network network, List<UdpProbeDto> probes) {
  final service = RealNetworkScanService(
    multicastLock: MulticastLock(isSupported: false),
    interfaceLister:
        ({
          bool includeLoopback = false,
          bool includeLinkLocal = false,
          InternetAddressType type = InternetAddressType.any,
        }) async => [],
    probeSource: () async => probes,
    binder: network.bind,
    isApplePlatform: false,
  );
  return service.scan(timeout: const Duration(milliseconds: 300)).toList();
}

bool _is(InternetAddress a, int p, String address, int port) =>
    a.address == address && p == port;

void main() {
  test('a refused multicast probe is not a denied Local Network', () async {
    final network = _Network(refuse: (a, p) => a.address == '230.0.0.1');

    expect(await _verdict(network, apple: true), isNull);

    // The refusal cost aqara's socket and nothing else. `closed` cannot say
    // so — every socket is closed when the scan ends — but the SEND COUNT
    // can: the refused socket records the one send dart:io refused (the
    // second attempt meets a closed socket and records nothing), while the
    // broadcast probe, on its own socket, records both attempts. Grouped by
    // port instead of by destination, the two share one socket, aqara's
    // refusal closes it, and the broadcast probe is never recorded at all.
    expect(network.sentTo('230.0.0.1', 10008).single.sent, hasLength(1));
    final broadcast = network.sentTo('255.255.255.255', 10008).toList();
    expect(broadcast, hasLength(1), reason: 'its own socket');
    expect(
      broadcast.single.sent,
      hasLength(2),
      reason: 'both attempts went out, untouched by the refusal',
    );
  });

  test(
    'a refused broadcast probe on Apple is a denied Local Network',
    () async {
      final network = _Network(
        refuse: (a, p) => _is(a, p, '255.255.255.255', 10008),
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
        refuse: (a, p) => _is(a, p, '255.255.255.255', 10008),
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
    'a refused destination is reported without sitting out the sends',
    () async {
      // dart:io closes the socket a microtask after the refused send. The old
      // shape then slept 250 ms, sent again into the closed socket, and slept
      // again before the receive loop read the refusal already on the stream:
      // ~500 ms per refused destination doing nothing. The loop listens from
      // the first send now and the second send comes from a timer.
      final network = _Network(refuse: (a, p) => a.address == '230.0.0.1');

      expect(await _verdict(network, apple: true), isNull);

      // Observed on the socket, where it is unambiguous: the transport must
      // subscribe BEFORE its second send goes out. The old shape subscribed
      // only after both sends and both sleeps (listenedAt > sent[1].at); the
      // new one listens from the first send and the timer carries the second.
      final broadcast = network.sentTo('255.255.255.255', 10008).single;
      expect(broadcast.sent, hasLength(2));
      expect(broadcast.listenedAt, isNotNull);
      expect(
        broadcast.listenedAt!,
        lessThan(broadcast.sent[1].at),
        reason:
            'listening began ${broadcast.listenedAt}, the second send went '
            'out at ${broadcast.sent[1].at}: the receive loop waited on the '
            'sends instead of starting with the first',
      );
      // And the refused destination's socket was listened to at once as well —
      // the refusal on its stream is what ends its transport early.
      final refused = network.sentTo('230.0.0.1', 10008).single;
      expect(refused.listenedAt, isNotNull);
      expect(refused.listenedAt!, lessThan(const Duration(milliseconds: 200)));
    },
  );

  test('a stop that lands during mDNS start ends the scan promptly', () async {
    // R-027 for the one transport that had no stoppedDuringBind. A stop
    // landing while MDnsClient.start() enumerated interfaces found
    // session.mdns still null and stopped nothing; the lookup then ran out
    // its whole phase — half the scan window — on a quiet link, the
    // app-facing stream stayed open, and :5353 stayed bound. The lister is
    // slow on purpose, and completes [inStart] only on the mDNS call (the
    // one that asks for loopback), so the stop lands inside that window.
    final network = _Network(refuse: (a, p) => false);
    final inStart = Completer<void>();
    final service = RealNetworkScanService(
      multicastLock: MulticastLock(isSupported: false),
      interfaceLister:
          ({
            bool includeLoopback = false,
            bool includeLinkLocal = false,
            InternetAddressType type = InternetAddressType.any,
          }) async {
            if (includeLoopback && !inStart.isCompleted) inStart.complete();
            await Future<void>.delayed(const Duration(milliseconds: 300));
            return [];
          },
      probeSource: () async => [],
      binder: network.bind,
      isApplePlatform: false,
    );

    final clock = Stopwatch()..start();
    final scan = service
        .scan(timeout: const Duration(seconds: 20))
        .drain<void>();
    await inStart.future;
    await service.stopScan();
    await scan.timeout(
      const Duration(seconds: 3),
      onTimeout: () => fail(
        'the scan stream was still open 3 s after stopScan(): a phase is '
        '10 s here, and that is what a stop during start used to wait',
      ),
    );
    expect(clock.elapsed, lessThan(const Duration(seconds: 3)));
  });

  test('a declared reply port is bound before the probe is sent', () async {
    final network = _Network(refuse: (a, p) => false);
    final bisecur = _probe(
      specKey: 'hormann-bisecur-gateway.yaml',
      address: '255.255.255.255',
      port: 4001,
      listenPort: 4002,
    );
    final service = RealNetworkScanService(
      multicastLock: MulticastLock(isSupported: false),
      interfaceLister:
          ({
            bool includeLoopback = false,
            bool includeLinkLocal = false,
            InternetAddressType type = InternetAddressType.any,
          }) async => [],
      probeSource: () async => [bisecur],
      binder: network.bind,
      isApplePlatform: false,
    );

    await service
        .scan(timeout: const Duration(milliseconds: 300))
        .drain<void>();

    final socket = network.sentTo('255.255.255.255', 4001).single;
    expect(socket.port, 4002);
    expect(socket.sent, hasLength(2));
  });

  test('a malformed XML reply does not deafen the port to the next', () async {
    // A mismatched tag throws XmlTagException out of XmlDocument.parse, not
    // the XmlParserException the reader caught. Uncaught, it left the await
    // for over the socket, closed :4002, and the gateway answering a moment
    // later was never heard — so any LAN host, or one truncated reply, could
    // hide every BiSecur gateway from the scan.
    final network = _Network(
      refuse: (a, p) => false,
      answer: (network, datagram) {
        if (datagram.port != 4001) return;
        network
          ..deliver(4002, '<a></b>', from: '192.0.2.40')
          ..deliver(4002, '<p:LogicBox mac="x"/>', from: '192.0.2.41')
          ..deliver(4002, _bisecurReply, from: '192.0.2.42');
      },
    );

    final devices = await _scan(network, [_bisecur]);

    expect(devices.map((d) => d.host), contains('192.0.2.42'));
  });

  test('Govee and BiSecur share one :4002 and both are heard', () async {
    // Both protocols are answered on UDP 4002: Govee's JSON to its 4001
    // multicast scan, BiSecur's XML to its 4001 broadcast. Each transport
    // used to bind 4002 for itself in the same scan. On iOS and macOS the
    // second bind fails with EADDRINUSE; on Linux and Android it succeeds and
    // each unicast reply then reaches one of the two sockets, so one
    // protocol's devices go missing.
    final network = _Network(
      refuse: (a, p) => false,
      answer: (network, datagram) {
        if (datagram.port != 4001) return;
        if (datagram.address.address == '239.255.255.250') {
          network.deliver(4002, _goveeReply, from: '192.0.2.50');
        } else if (datagram.address.address == '255.255.255.255') {
          network.deliver(4002, _bisecurReply, from: '192.0.2.42');
        }
      },
    );

    final devices = await _scan(network, [_bisecur]);

    expect(network.bindsOf(4002), 1, reason: 'one :4002 per scan');
    final hosts = devices.map((d) => d.host).toSet();
    expect(hosts, contains('192.0.2.50'), reason: 'the Govee strip');
    expect(hosts, contains('192.0.2.42'), reason: 'the BiSecur gateway');
    // Each parser ignored the other's reply rather than inventing a device.
    final bisecur = devices.singleWhere((d) => d.host == '192.0.2.42');
    expect(bisecur.answeredLanProtocols, ['bisecur']);
    final govee = devices.singleWhere((d) => d.host == '192.0.2.50');
    expect(govee.txt['device'], 'AA:BB:CC:DD:EE:FF:00:11');
  });

  test(
    'nothing refused, nothing denied — the fixture is not the verdict',
    () async {
      final network = _Network(refuse: (a, p) => false);

      expect(await _verdict(network, apple: true), isNull);
    },
  );
}
