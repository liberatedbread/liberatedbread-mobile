// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// MockNetworkScanService had no test at all — 0 of 17 lines — which is how the
// stop-scan bug below survived being fixed in the real service.
//
// "It is only the mock" is not a reason to leave it uncovered. This class is
// what runs in every mock-mode build: the Wi-Fi tab of the Linux, Android and
// iOS integration suites, the screenshot walkthrough, and the demo the app
// ships with LIBERATED_BREAD_MOCK=true. RealNetworkScanService, by contrast,
// runs in exactly one place in CI — the netdisco job — against emulated
// devices. The mock is the more travelled path.
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/models/network_device.dart';
import 'package:liberated_bread_mobile/services/mock_network_scan_service.dart';

void main() {
  // The service sleeps 350ms between devices, so a full enumeration is real
  // seconds. Every test that does not need the whole list passes a short
  // `timeout`, which only shortens the tail — the inter-device delay is fixed.
  group('MockNetworkScanService', () {
    test('yields a catalogue that is varied on purpose', () async {
      final service = MockNetworkScanService();
      final devices = await service
          .scan(timeout: const Duration(milliseconds: 40))
          .toList();

      expect(devices.map((d) => d.host), [
        '192.168.1.40',
        '192.168.1.41',
        '192.168.1.43',
        '192.168.1.42',
        '192.168.1.99',
      ]);

      // The fixture exists so the Wi-Fi list is not four rows of the same
      // thing — it is meant to walk the confidence ladder the real scan
      // produces. Asserting the SHAPE rather than the exact entries, so they
      // can be re-tuned freely, but a fixture that collapses to one kind of
      // device (which is what makes a demo screenshot misleading) is rejected.
      expect(devices.expand((d) => d.sources).toSet(),
          {NetworkDiscoverySource.mdns, NetworkDiscoverySource.ssdp},
          reason: 'both transports must be represented');
      expect(devices.where((d) => d.ssdpTargets.isNotEmpty), hasLength(2));
      expect(devices.where((d) => d.serviceTypes.isNotEmpty), hasLength(3));
      expect(devices.where((d) => d.name.isNotEmpty), isNotEmpty,
          reason: 'at least one device names itself outright');
      expect(devices.where((d) => d.name.isEmpty && d.hostname != null),
          isNotEmpty,
          reason: 'and at least one is recognisable only by its hostname');
    });

    test('stopScan during the tail wait closes the stream at once', () async {
      // The regression, and it has to be provoked AFTER the last device:
      // the tail used to be an unconditional `Future.delayed(timeout ~/ 4)`,
      // the one wait in the whole class that never looked at the stop flag. A
      // stop earlier than this is noticed at the top of the next loop
      // iteration, so it hides the bug rather than showing it.
      //
      // Two seconds at the default eight-second timeout, during which a UI
      // that re-enables its button on stream close is still showing
      // "scanning" for a scan that has stopped.
      final service = MockNetworkScanService();
      final seen = <NetworkDevice>[];
      final sinceStop = Stopwatch();
      final done = service.scan(timeout: const Duration(seconds: 8)).forEach(
        (device) {
          seen.add(device);
          if (seen.length == 5) {
            sinceStop.start();
            unawaited(service.stopScan());
          }
        },
      );

      await done.timeout(const Duration(seconds: 6));

      expect(seen, hasLength(5));
      expect(sinceStop.elapsed, lessThan(const Duration(milliseconds: 500)),
          reason: 'stopScan must wake the tail wait rather than be noticed '
              'when it expires 2s later. Elapsed after stop: '
              '${sinceStop.elapsed}');
    });

    test('a stop mid-sleep drops the device that sleep was waiting for',
        () async {
      final service = MockNetworkScanService();
      final seen = <NetworkDevice>[];
      final done = service
          .scan(timeout: const Duration(milliseconds: 40))
          .forEach(seen.add);

      // Inside the first 350ms delay, before anything has been yielded.
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await service.stopScan();
      await done.timeout(const Duration(seconds: 3));

      expect(seen, isEmpty,
          reason: 'The flag used to be read only at the top of the loop, so a '
              'stop during a sleep still yielded the device after it.');
    });

    test('a second scan runs again after a stop', () async {
      // `_stop` is a Completer, and a completed one stays completed — so the
      // scan has to install a fresh one or every run after the first would
      // return immediately, with the mock silently going empty.
      final service = MockNetworkScanService();
      await service.scan(timeout: const Duration(milliseconds: 40)).first;
      await service.stopScan();

      final second = await service
          .scan(timeout: const Duration(milliseconds: 40))
          .toList();
      expect(second, hasLength(5));
    });

    test('stopScan before any scan is harmless', () async {
      final service = MockNetworkScanService();
      await service.stopScan();
      await service.stopScan();

      final devices = await service
          .scan(timeout: const Duration(milliseconds: 40))
          .toList();
      expect(devices, hasLength(5));
    });
  });
}
