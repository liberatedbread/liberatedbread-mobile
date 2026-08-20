// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// Hardware proof for the Roku control path, against a real TV on the LAN.
//
// The bug this exists for: a Roku answers BOTH discovery transports, and its
// mDNS half advertises services that have nothing to do with control —
// `_airplay._tcp` on 7000, `_display._tcp` on 7250, `_hap._tcp` on 44003 —
// while ECP listens on the SSDP LOCATION port, 8060. `NetworkDevice.port`
// prefers the mDNS SRV port, so control aimed at it reached the AirPlay
// server, which answers a keypress with 403: byte-identical to the device's
// own "Control by mobile apps" gate. The app showed the settings note and the
// buttons did nothing, on a TV whose ECP was answering the whole time.
//
// So this asserts the end-to-end thing a unit test cannot: that a real scan
// of a real TV yields a `controlPort` ECP actually answers on, and that a
// press sent there lands — over plain ECP, or over the signed session when
// the TV is in Limited mode, exactly as NetworkDeviceScreen falls back.
//
// Same double guard as the live BLE suites: tagged `live_wifi` and
// self-skipping unless LB_LIVE_ROKU=1, target address from LB_LIVE_ROKU_HOST.
//
// Run it (with the TV in view):
//   LB_LIVE_ROKU=1 LB_LIVE_ROKU_HOST=10.0.0.9 \
//     flutter test --tags=live_wifi test/live/roku_control_live_test.dart
@Tags(['live_wifi'])
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/models/network_device.dart';
import 'package:liberated_bread_mobile/services/ecp2_control_service.dart';
import 'package:liberated_bread_mobile/services/http_control_service.dart';
import 'package:liberated_bread_mobile/services/multicast_lock.dart';
import 'package:liberated_bread_mobile/services/real_network_scan_service.dart';
import 'package:liberated_bread_mobile/services/spec_codec.dart';

/// The keys this test is allowed to press.
///
/// Deliberately a round trip that leaves the TV where it found it, and
/// deliberately NOT `FindRemote`: that one makes the physical remote chirp,
/// which is an unpleasant thing for a test suite to do to a room. Nothing
/// here changes an input, a volume or a power state either.
const _benignKeys = ['Up', 'Down'];

void main() {
  test(
    'a real Roku is controlled on the port ECP answers, not an mDNS one',
    () async {
      final host = Platform.environment['LB_LIVE_ROKU_HOST'];
      if (Platform.environment['LB_LIVE_ROKU'] != '1' || host == null) {
        markTestSkipped('live hardware run not requested '
            '(set LB_LIVE_ROKU=1 and LB_LIVE_ROKU_HOST=<ip>)');
        return;
      }

      // 1. Discovery, through the app's own scan — the merge of the mDNS and
      //    SSDP sightings is precisely what got the port wrong.
      final scan = RealNetworkScanService(
          multicastLock: MulticastLock(isSupported: false));
      final found = <String, NetworkDevice>{};
      await for (final device in scan.scan(
        timeout: const Duration(seconds: 12),
        extraSearchTargets: const ['roku:ecp'],
      )) {
        final existing = found[device.host];
        found[device.host] =
            existing == null ? device : existing.mergedWith(device);
      }
      final roku = found[host];
      expect(roku, isNotNull,
          reason: 'no device at $host answered discovery — is the TV awake '
              'and on this subnet?');
      expect(roku!.ssdpTargets, contains('roku:ecp'),
          reason: 'the device at $host is not answering as a Roku');

      final port = roku.controlPort;
      expect(port, isNotNull);
      // The regression itself, stated against real advertisements: whatever
      // service ports this TV publishes over mDNS, control goes to the ECP
      // endpoint the SSDP LOCATION named.
      expect(port, roku.ssdpPort,
          reason: 'control must use the SSDP LOCATION port; port=${roku.port} '
              'is an mDNS service port (${roku.serviceTypes})');

      // 2. An ungated query, to prove the port is right independently of the
      //    "Control by mobile apps" gate — device-info answers either way.
      final plain = HttpControlClient();
      final info = await plain.send(
          host,
          port!,
          const HttpRequestDto(
              method: 'GET', path: '/query/device-info', body: ''));
      expect(info, contains('<device-info>'),
          reason: 'port $port did not answer ECP — it is the wrong port');

      // 3. The press, down the same path NetworkDeviceScreen takes: plain
      //    ECP first, the signed session when the TV refuses it.
      Ecp2Session? session;
      var viaSignedSession = false;
      try {
        for (final key in _benignKeys) {
          final request =
              HttpRequestDto(method: 'POST', path: '/keypress/$key', body: '');
          try {
            await plain.send(host, port, request);
          } on ControlRefusedException {
            // Limited mode. The fallback is the whole reason the ECP2 client
            // exists, and a TV in this state is the normal case now.
            session ??= await Ecp2ControlService().connect(host, port);
            await session.send(request);
            viaSignedSession = true;
          }
        }
      } finally {
        await session?.close();
      }

      // Reaching here means every key was accepted by one path or the other;
      // a wrong port throws long before this, and a gate with no working
      // fallback throws ControlRefusedException out of the loop.
      printOnFailure('pressed $_benignKeys on $host:$port '
          '(signed session: $viaSignedSession)');
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
