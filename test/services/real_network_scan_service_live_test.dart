// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// RealNetworkScanService against emulated devices on a real wire.
//
// Its companion, real_network_scan_service_test.dart, covers the parsing and
// coalescing rules without a socket. This one covers the transports: the mDNS
// meta-query and its resolution chain, the SSDP M-SEARCH, and the merge of the
// two into one row per host. None of that has a plugin seam to substitute —
// `dart:io` sockets and package:multicast_dns are the implementation — so the
// only way to run it is to put something on the wire that answers, which is
// scripts/net_virtual_device.py.
//
// Multicast, without a network: both sides join their group on the loopback
// path with IP_MULTICAST_LOOP on, so this needs no second machine, no router
// and no privileges — just a host whose stack will loop a multicast datagram
// back to another socket, which is the same thing the app does on a phone.
//
// TAGGED, AND RUN SEPARATELY. `flutter test` excludes `netdisco` and a CI job
// of its own runs it, for two reasons: it opens ports 5353 and 1900, which a
// developer's machine may already have an mDNS responder on, and it spends
// real seconds waiting for datagrams rather than pumping a fake clock. Neither
// belongs in the suite that has to stay fast.
@Tags(['netdisco'])
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/models/network_device.dart';
import 'package:liberated_bread_mobile/services/multicast_lock.dart';
import 'package:liberated_bread_mobile/services/real_network_scan_service.dart';

/// The addresses scripts/net_virtual_device.py's bundled scenario advertises.
/// TEST-NET-2, so they cannot collide with anything real.
const _hueHost = '198.51.100.11';
const _wemoHost = '198.51.100.12';

/// The Snapmaker-style device: answers a direct PTR for `_snapmaker._tcp` but
/// is deaf to the `_services._dns-sd._udp.local` meta-query, so it is found
/// only when the scan is given its exact service type to ask for.
const _snapHost = '198.51.100.13';
const _snapType = '_snapmaker._tcp.local.';

/// Long enough for two multicast round trips on loopback, short enough that a
/// broken run fails in seconds. RealNetworkScanService splits this in half
/// between enumerating service types and resolving them, so it is the budget
/// for the whole mDNS half, not for one query.
const _scanWindow = Duration(seconds: 6);

/// The emulated devices, running as a child process for the whole suite.
class _VirtualNetwork {
  Process? _process;
  Directory? _work;

  Future<void> start() async {
    final work = await Directory.systemTemp.createTemp('lb-virtual-net');
    _work = work;
    final readyFile = File('${work.path}/ready');
    _process = await Process.start('python3', [
      'scripts/net_virtual_device.py',
      '--ready-file',
      readyFile.path,
    ]);
    // Surface the responder's own diagnostics — "port 5353 is taken" is the
    // failure a developer will actually hit, and it is worth reading.
    _process!.stdout
        .transform(const SystemEncoding().decoder)
        .listen((line) => printOnFailure('[virtual-net] $line'));
    final stderrText = StringBuffer();
    _process!.stderr
        .transform(const SystemEncoding().decoder)
        .listen(stderrText.write);

    // Wait on the fact that the sockets are listening, not on a sleep.
    final deadline = DateTime.now().add(const Duration(seconds: 10));
    while (DateTime.now().isBefore(deadline)) {
      if (readyFile.existsSync()) return;
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    throw StateError(
      'the virtual network device did not start listening within 10s. '
      'Ports 5353 and 1900 must be free — a system mDNS responder '
      '(avahi-daemon, systemd-resolved) holding 5353 is the usual cause.\n'
      '$stderrText',
    );
  }

  Future<void> stop() async {
    _process?.kill();
    _process = null;
    await _work?.delete(recursive: true);
    _work = null;
  }
}

void main() {
  final network = _VirtualNetwork();

  setUpAll(network.start);
  tearDownAll(network.stop);

  /// A scan, run to completion.
  ///
  /// `isSupported: false` on the lock because it is an Android platform channel
  /// and there is no engine here to answer it; on this host it would be a no-op
  /// anyway. multicast_lock_test.dart covers the lock itself.
  Future<List<NetworkDevice>> scan({List<String> mdnsTypes = const []}) async {
    final service = RealNetworkScanService(
        multicastLock: MulticastLock(isSupported: false));
    final found = <NetworkDevice>[];
    await for (final device in service.scan(
        timeout: _scanWindow, extraMdnsServiceTypes: mdnsTypes)) {
      found.add(device);
    }
    return found;
  }

  /// The last sighting of [host] — sightings accumulate as more is learned.
  NetworkDevice? deviceAt(List<NetworkDevice> found, String host) {
    final matches = found.where((d) => d.host == host);
    return matches.isEmpty ? null : matches.last;
  }

  test('finds an mDNS device, resolved all the way to an address', () async {
    final found = await scan();

    final hue = deviceAt(found, _hueHost);
    expect(hue, isNotNull,
        reason: 'the DNS-SD meta-query, the type PTR, SRV and A all had to '
            'succeed in order for a host to appear at all');
    expect(hue!.name, 'Philips Hue - 123456');
    expect(hue.hostname, 'hue-bridge.local');
    expect(hue.port, 443);
    expect(hue.serviceTypes, contains('_hue._tcp.local'));
    expect(hue.sources, contains(NetworkDiscoverySource.mdns));
  });

  test('reads the TXT record the device published', () async {
    final found = await scan();

    final hue = deviceAt(found, _hueHost);
    // A TXT record is its own query, answered separately from SRV, and the
    // client concatenates its strings with newlines before the app splits them
    // apart again. Worth asserting on: the round trip has three chances to
    // lose an entry.
    expect(hue?.txt['bridgeid'], '001788FFFE123456');
    expect(hue?.txt['modelid'], 'BSB002');
  });

  test('finds an SSDP-only device', () async {
    final found = await scan();

    final wemo = deviceAt(found, _wemoHost);
    expect(wemo, isNotNull,
        reason: 'this device answers no mDNS at all — it is the reason the '
            'scan runs both transports');
    expect(wemo!.sources, contains(NetworkDiscoverySource.ssdp));
    expect(wemo.ssdpTargets, contains('urn:Belkin:device:controllee:1'));
    expect(wemo.port, 49153, reason: 'taken from the LOCATION URL');
    expect(wemo.server, contains('UPnP/1.0'));
  });

  test('merges a device that answers on both transports into one row',
      () async {
    final found = await scan();

    final hue = deviceAt(found, _hueHost);
    expect(
        hue!.sources,
        {
          NetworkDiscoverySource.mdns,
          NetworkDiscoverySource.ssdp,
        },
        reason: 'one host, two transports, one row');
    // The merge must not lose either half: the name and port come from mDNS,
    // the target from SSDP.
    expect(hue.name, 'Philips Hue - 123456');
    expect(hue.ssdpTargets, contains('upnp:rootdevice'));
  });

  // Note the asymmetry with the other cases: this asserts only that supplying
  // the type FINDS the device, never that withholding it hides the device. A
  // clean net_virtual_device.py run would show the latter too (its responder
  // hides `_snapmaker._tcp` from the meta-query), but this host — like any dev
  // machine running avahi/systemd-resolved — has a cooperative mDNS daemon that
  // answers the meta-query from its own cache, so an absence assertion is not
  // reliable off a bare CI box. The mechanism itself is pinned by the unit test
  // for normalizeMdnsServiceType and the direct-query wiring.
  test(
      'a device deaf to the meta-query is found via its catalogue service '
      'type', () async {
    // Handed the type the catalogue declares, the scan queries it directly and
    // resolves the same PTR -> SRV -> A chain to a real address. This is the
    // fix for "the Snapmaker isn't showing up".
    final found = await scan(mdnsTypes: const [_snapType]);

    final snap = deviceAt(found, _snapHost);
    expect(snap, isNotNull,
        reason: 'a direct PTR for _snapmaker._tcp was answered and resolved '
            'all the way to an address');
    expect(snap!.serviceTypes, contains('_snapmaker._tcp.local'));
    expect(snap.hostname, 'snapmaker-u1.local');
    expect(snap.port, 1884, reason: 'the advertised port, metadata only');
    expect(snap.txt['sn'], 'SNAPU1TEST000');
    expect(snap.sources, contains(NetworkDiscoverySource.mdns));
  });

  test('a scan can be stopped early without leaving the stream open', () async {
    final service = RealNetworkScanService(
        multicastLock: MulticastLock(isSupported: false));
    var closed = false;
    final sub = service
        .scan(timeout: const Duration(minutes: 1))
        .listen((_) {}, onDone: () => closed = true);

    await Future<void>.delayed(const Duration(milliseconds: 500));
    await service.stopScan();
    await Future<void>.delayed(const Duration(seconds: 1));

    expect(closed, isTrue,
        reason: 'stopScan has to end the stream, not just the sockets — the '
            'button stays disabled until it closes');
    await sub.cancel();
  });
}
