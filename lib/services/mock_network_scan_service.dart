// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:async';

import '../models/network_device.dart';
import 'network_scan_service.dart';

/// Simulated local-network discovery for demo mode.
///
/// Mirrors the BLE mock's approach: the entries advertise different things on
/// purpose, so the Wi-Fi list exercises every rung of the confidence ladder
/// without needing a Hue bridge on the desk.
class MockNetworkScanService implements NetworkScanService {
  bool _stopped = false;

  /// Deliberately varied:
  ///  - a bridge announcing a vendor mDNS service type (strong),
  ///  - one answering only an SSDP search target (strong, other transport),
  ///  - one recognisable purely by its branded hostname (likely),
  ///  - one that is just a host with an open port (possible / unknown).
  static final List<NetworkDevice> _devices = [
    NetworkDevice(
      host: '192.168.1.40',
      name: 'Philips Hue',
      hostname: 'Philips-hue.local',
      port: 443,
      serviceTypes: const ['_hue._tcp.local'],
      txt: const {'bridgeid': '001788FFFE1234AB', 'modelid': 'BSB002'},
      sources: const {NetworkDiscoverySource.mdns},
      discoveredAt: DateTime(2026),
    ),
    NetworkDevice(
      host: '192.168.1.41',
      name: '',
      port: 49153,
      ssdpTargets: const ['urn:Belkin:device:controllee:1'],
      server: 'Unspecified, UPnP/1.0, Unspecified',
      sources: const {NetworkDiscoverySource.ssdp},
      discoveredAt: DateTime(2026),
    ),
    NetworkDevice(
      host: '192.168.1.42',
      name: '',
      hostname: 'Lutron-083e013d.local',
      port: 8081,
      serviceTypes: const ['_leap._tcp.local'],
      txt: const {'macaddr': 'b8:94:d9:aa:bb:cc'},
      sources: const {NetworkDiscoverySource.mdns},
      discoveredAt: DateTime(2026),
    ),
    NetworkDevice(
      host: '192.168.1.99',
      name: 'office-printer',
      hostname: 'office-printer.local',
      port: 631,
      serviceTypes: const ['_ipp._tcp.local'],
      sources: const {NetworkDiscoverySource.mdns},
      discoveredAt: DateTime(2026),
    ),
  ];

  @override
  Stream<NetworkDevice> scan({
    Duration timeout = const Duration(seconds: 8),
  }) async* {
    _stopped = false;
    for (final device in _devices) {
      if (_stopped) return;
      await Future<void>.delayed(const Duration(milliseconds: 350));
      yield device;
    }
    await Future<void>.delayed(timeout ~/ 4);
  }

  @override
  Future<void> stopScan() async => _stopped = true;
}
