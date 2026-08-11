// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import '../core/stop_signal.dart';
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
  /// fixed: a stop arriving during a sleep was not noticed until that sleep
  /// ended, so the stream stayed open for a quarter of the scan window after
  /// the scan had been told to stop. The interruptible-wait mechanism itself
  /// is [StopSignal], shared with the real service.
  ///
  /// Demo mode is the only place this class runs, but demo mode is what the
  /// screenshots, the walkthrough and every mock-mode integration test drive.
  StopSignal _stop = StopSignal();

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
    // A device whose spec declares a control surface with buttons (the Roku
    // remote), so demo mode can walk into a remote screen — the same reason
    // the Wemo entry above exists for switches. Answers only its own search
    // target, exactly like the hardware.
    NetworkDevice(
      host: '192.168.1.43',
      name: '',
      port: 8060,
      ssdpTargets: const ['roku:ecp'],
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
    // Accepted for interface parity; a simulated network answers every
    // question, so the extra targets change nothing here.
    List<String> extraSearchTargets = const [],
  }) async* {
    _stop = StopSignal();
    for (final device in _devices) {
      if (await _stop.sleep(const Duration(milliseconds: 350))) return;
      yield device;
    }
    // The tail is what makes the list look like it is still searching after
    // the last device arrives, which is the whole point of a demo scan — but
    // it races the stop like every other wait here.
    await _stop.sleep(timeout ~/ 4);
  }

  @override
  Future<void> stopScan() async {
    _stop.stop();
  }
}
