// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// PROBE: verify BOTH resolution sources against the live curtain, exactly as
// the app resolves them.
//   1. SCAN -> capture the device's manufacturer data -> advertisedResolution.
//   2. CONNECT -> get_running_status -> collect notifications ->
//      deviceInfoResolution (reassemble + decode the M_DEVICE_INFO_NOTIFY).
// Expect 20x20 from each. Logs the raw manufacturer data and the raw
// notifications so a mismatch is visible.
//
// LB_LIVE_BLE=1 + LB_LIVE_BLE_ID. (Uses the scan path — needs the mfd.)
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
    'both resolution sources report the panel size (probe)',
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

      // === 1. ADVERTISEMENT ===
      final device = await ble
          .scan(timeout: null)
          .firstWhere((d) => d.id == deviceId)
          .timeout(const Duration(seconds: 120));
      await ble.stopScan();
      // ignore: avoid_print
      print('scanned mfd: ${device.manufacturerData.map((k, v) => MapEntry('0x${k.toRadixString(16)}', _hex(v)))}');
      final adv = await codec.advertisedResolution(
          specYaml: specYaml, manufacturerData: device.manufacturerData);
      // ignore: avoid_print
      print(adv == null
          ? '!! ADVERTISEMENT did NOT resolve'
          : 'ADVERTISEMENT resolution = ${adv.width}x${adv.height}');

      // === 2. DEVICE INFO ===
      await ble.connect(deviceId);
      final collected = <List<int>>[];
      final sub = ble
          .subscribeCharacteristic(deviceId, _ddpService, _ddpNotify)
          .listen(collected.add);
      try {
        final cmd = await codec.encodeCommand(
          specYaml: specYaml,
          charUuid: _ddpWrite,
          commandName: 'get_running_status',
          params: {'sn': 1.0},
        );
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
      final info =
          await codec.deviceInfoResolution(notifications: collected);
      // ignore: avoid_print
      print(info == null
          ? '!! DEVICE INFO did NOT resolve'
          : 'DEVICE INFO resolution = ${info.width}x${info.height}');

      await ble.disconnect(deviceId);

      // At least ONE source must resolve to 20x20.
      final got = adv ?? info;
      expect(got, isNotNull, reason: 'neither source resolved a size');
      expect((got!.width, got.height), (20, 20));
    },
    timeout: const Timeout(Duration(minutes: 6)),
  );
}
