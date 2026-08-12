// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// DIAGNOSTIC: does a STORED animation actually RENDER, or does the device only
// ACK the upload? Uploads an unmistakable animation — N solid-RED frames, then
// N GREEN, then N BLUE — plays it, and holds so a webcam can photograph the
// R->G->B cycle. Solid colours read clearly at webcam distance where a subtle
// twinkle does not.
//
// Guarded like the other live tests: LB_LIVE_BLE=1 + LB_LIVE_BLE_ID; set
// LB_LIVE_BLE_DIRECT=1 to skip the fbp scan and connect straight to the address
// (pre-connect with `bluetoothctl connect <mac>`).
@Tags(['live_ble'])
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_blue_plus_linux/flutter_blue_plus_linux.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/services/real_ble_service.dart';
import 'package:liberated_bread_mobile/services/real_spec_codec.dart';
import 'package:liberated_bread_mobile/services/spec_codec.dart'
    show StoredUploadEventDto, StoredUploadEventKind;

import '../helpers/host_rust_lib.dart';

const _width = 20;
const _height = 20;
const _ddpService = '00000074-1972-1925-3022-077119514e44';
const _ddpWrite = '01020074-1972-1925-3022-077119514e44';

/// One solid-colour 20x20 RGB888 frame (row-major).
List<int> _solid(int r, int g, int b) {
  final f = Uint8List(_width * _height * 3);
  for (var i = 0; i < f.length; i += 3) {
    f[i] = r;
    f[i + 1] = g;
    f[i + 2] = b;
  }
  return f;
}

void main() {
  test(
    'stored R/G/B animation renders on a live DN curtain',
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
            .scan()
            .firstWhere((d) => d.id == deviceId)
            .timeout(const Duration(seconds: 45));
        await ble.stopScan();
      }
      await ble.connect(deviceId);

      var seq = 0;
      int nextSeq() {
        seq = (seq % 0xFFFF) + 1;
        return seq;
      }

      try {
        // 8 frames each of pure red, green, blue → a slow, obvious cycle.
        const perColor = 8;
        final frames = <List<int>>[
          for (var i = 0; i < perColor; i++) _solid(255, 0, 0),
          for (var i = 0; i < perColor; i++) _solid(0, 255, 0),
          for (var i = 0; i < perColor; i++) _solid(0, 0, 255),
        ];
        final cid = 900001 + (DateTime.now().millisecondsSinceEpoch % 90000);
        // ignore: avoid_print
        print('RGB diag: cid=$cid frames=${frames.length}');

        final plan = await codec.encodeStoredAnimation(
          specYaml: specYaml,
          width: _width,
          height: _height,
          frames: frames,
          name: 'RGB diag',
          cid: cid,
          frameMs: 250, // ~4 fps requested (device may impose its own)
          sequence: nextSeq(),
        );

        final verdictF = ble
            .subscribeCharacteristic(
                deviceId, plan.serviceUuid, plan.responseCharacteristicUuid!)
            .asyncMap((bytes) =>
                codec.decodeStoredUploadEvent(specYaml: specYaml, bytes: bytes))
            .where((e) => e != null)
            .cast<StoredUploadEventDto>()
            .firstWhere((e) =>
                e.kind == StoredUploadEventKind.complete ||
                e.kind == StoredUploadEventKind.failed ||
                e.kind == StoredUploadEventKind.startRejected)
            .timeout(const Duration(seconds: 30));

        for (final w in plan.uploadWrites) {
          await ble.writeCharacteristic(
              deviceId, plan.serviceUuid, w.characteristicUuid, w.bytes);
        }
        final verdict = await verdictF;
        // ignore: avoid_print
        print('VERDICT: ${verdict.kind} (code ${verdict.code}) '
            'at ${DateTime.now().millisecondsSinceEpoch}');
        expect(verdict.kind, StoredUploadEventKind.complete);

        // effect_list then play, matching the vendor.
        final el = await codec.encodeCommand(
            specYaml: specYaml,
            charUuid: _ddpWrite,
            commandName: 'effect_list',
            params: {'sn': nextSeq().toDouble()});
        await ble.writeCharacteristic(deviceId, _ddpService, _ddpWrite, el);

        final play = plan.playWrite!;
        // ignore: avoid_print
        print('PLAY at ${DateTime.now().millisecondsSinceEpoch}');
        await ble.writeCharacteristic(
            deviceId, plan.serviceUuid, play.characteristicUuid, play.bytes);

        // Hold ~25s so the webcam catches multiple R/G/B cycles.
        for (var t = 0; t < 25; t++) {
          await Future<void>.delayed(const Duration(seconds: 1));
        }
        // ignore: avoid_print
        print('DONE_HOLD at ${DateTime.now().millisecondsSinceEpoch}');
      } finally {
        await ble.disconnect(deviceId);
      }
    },
    timeout: const Timeout(Duration(minutes: 5)),
  );
}
