// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// PROBE: verify the DeviceInfo resolution path end-to-end on hardware. Subscribe
// to the DDP notify char, poke the device with get_running_status, collect the
// raw notifications (so we can SEE how M_DEVICE_INFO_NOTIFY fragments at the
// 23-byte MTU), and run the core's reassemble+decode over them. Expect
// width=height=20 for the JY25CUT curtain.
//
// LB_LIVE_BLE=1 + LB_LIVE_BLE_ID; LB_LIVE_BLE_DIRECT=1 to skip the fbp scan.
@Tags(['live_ble'])
library;

import 'dart:io';

import 'package:flutter_blue_plus_linux/flutter_blue_plus_linux.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/services/real_ble_service.dart';
import 'package:liberated_bread_mobile/services/real_spec_codec.dart';

import '../helpers/host_rust_lib.dart';

const _ddpService = '00000074-1972-1925-3022-077119514e44';
const _ddpWrite = '01020074-1972-1925-3022-077119514e44';
const _ddpNotify = '01010074-1972-1925-3022-077119514e44';

String _hex(List<int> b) =>
    b.map((x) => x.toRadixString(16).padLeft(2, '0')).join(' ');

void main() {
  test(
    'DeviceInfo push decodes to the panel resolution (probe)',
    () async {
      final deviceId = Platform.environment['LB_LIVE_BLE_ID'];
      if (Platform.environment['LB_LIVE_BLE'] != '1' || deviceId == null) {
        markTestSkipped('live hardware run not requested');
        return;
      }
      expect(await initHostRustLib(), isTrue);
      FlutterBluePlusLinux.registerWith();

      final specYaml = File(
              'vendor/protocol-specs/device-specs/devices/smartdawn-smart-lights.yaml')
          .readAsStringSync();
      const codec = RealSpecCodec();
      final ble = RealBleService();

      if (Platform.environment['LB_LIVE_BLE_DIRECT'] != '1') {
        await ble
            .scan(timeout: null)
            .firstWhere((d) => d.id == deviceId)
            .timeout(const Duration(seconds: 120));
        await ble.stopScan();
      }
      await ble.connect(deviceId);

      final collected = <List<int>>[];
      final sub = ble
          .subscribeCharacteristic(deviceId, _ddpService, _ddpNotify)
          .listen(collected.add);
      try {
        // Poke it (the device also pushes DeviceInfo on connect, which the
        // early subscribe above may already have caught).
        final cmd = await codec.encodeCommand(
          specYaml: specYaml,
          charUuid: _ddpWrite,
          commandName: 'get_running_status',
          params: {'sn': 1.0},
        );
        // ignore: avoid_print
        print('>> get_running_status -> ${_hex(cmd)}');
        await ble.writeCharacteristic(deviceId, _ddpService, _ddpWrite, cmd);
        await Future<void>.delayed(const Duration(seconds: 3));
      } finally {
        await sub.cancel();
      }

      // ignore: avoid_print
      print('collected ${collected.length} notification(s):');
      for (final n in collected) {
        // ignore: avoid_print
        print('  len=${n.length} ${_hex(n)}');
      }

      final res = await codec.deviceInfoResolution(notifications: collected);
      // ignore: avoid_print
      print(res == null
          ? '!! DeviceInfo did NOT decode (no resolution)'
          : 'DeviceInfo resolution = ${res.width}x${res.height}');

      await ble.disconnect(deviceId);
      expect(res, isNotNull,
          reason: 'the DeviceInfo push should decode to a resolution');
      expect((res!.width, res.height), (20, 20));
    },
    timeout: const Timeout(Duration(minutes: 6)),
  );
}
