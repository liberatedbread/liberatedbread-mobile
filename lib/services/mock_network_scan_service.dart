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
  /// Completes when [stopScan] is called, so every wait below can wake early.
  ///
  /// A plain `bool` checked between sleeps is what this was, and it made
  /// `stopScan()` a lie in the same way the real service's did before it was
  /// fixed (see the `Future.any` in `real_network_scan_service.dart`): the flag
  /// was read at the TOP of the loop, so a stop arriving during a sleep was not
  /// noticed until that sleep ended, and the sleep AFTER the loop did not read
  /// it at all — the stream stayed open for a quarter of the scan window
  /// (two seconds at the default) after the scan had been told to stop. A
  /// caller that waits for the stream to close before re-enabling its button —
  /// which is what "stop scanning" looks like from the UI — waited it out.
  ///
  /// Demo mode is the only place this class runs, but demo mode is what the
  /// screenshots, the walkthrough and every mock-mode integration test drive.
  Completer<void> _stop = Completer<void>();

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
    _stop = Completer<void>();
    for (final device in _devices) {
      if (await _sleepOrStop(const Duration(milliseconds: 350))) return;
      yield device;
    }
    // The tail is what makes the list look like it is still searching after
    // the last device arrives, which is the whole point of a demo scan — but
    // it races the stop like every other wait here.
    await _sleepOrStop(timeout ~/ 4);
  }

  /// Waits [d], or until the scan is stopped. True when it was stopped.
  Future<bool> _sleepOrStop(Duration d) async {
    await Future.any([Future<void>.delayed(d), _stop.future]);
    return _stop.isCompleted;
  }

  @override
  Future<void> stopScan() async {
    if (!_stop.isCompleted) _stop.complete();
  }
}
