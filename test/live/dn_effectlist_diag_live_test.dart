// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// DIAGNOSTIC (log-based, no webcam): store one solid-red frame, then request
// M_EFFECT_LIST and DUMP the device's reply. Tells us whether our stored custom
// registers as a playable effect and, if so, the device-assigned SLOT to use in
// play/playlist. Answers "static multicolor / not playing" without needing to
// see the panel.
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

const _w = 20;
const _h = 20;
const _ddpService = '00000074-1972-1925-3022-077119514e44';
const _ddpWrite = '01020074-1972-1925-3022-077119514e44';
const _ddpNotify = '01010074-1972-1925-3022-077119514e44';

String _hex(List<int> b) =>
    b.map((x) => x.toRadixString(16).padLeft(2, '0')).join('');

void main() {
  test(
    'stored frame registers in the effect list — dump cid + slot',
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
        final cid = 912000 + (DateTime.now().millisecondsSinceEpoch % 6000);
        final rgb = Uint8List(_w * _h * 3);
        for (var i = 0; i < rgb.length; i += 3) {
          rgb[i] = 255; // solid red
        }
        // ignore: avoid_print
        print('STORE red cid=$cid');
        final plan = await codec.encodeStoredImage(
          specYaml: specYaml,
          width: _w,
          height: _h,
          rgb: rgb,
          name: 'EL diag',
          cid: cid,
          timeSecs: 5,
          scroll: 'none',
          speed: 5,
          sequence: nextSeq(),
        );
        final verdictF = ble
            .subscribeCharacteristic(
                deviceId, plan.serviceUuid, plan.responseCharacteristicUuid!)
            .asyncMap((b) =>
                codec.decodeStoredUploadEvent(specYaml: specYaml, bytes: b))
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
        final v = await verdictF;
        // ignore: avoid_print
        print('VERDICT ${v.kind} code ${v.code}  (looking for cid=$cid = '
            '0x${cid.toRadixString(16)})');

        // Now request the effect list and DUMP every DDP notify for ~5s.
        final notifs = <String>[];
        final sub = ble
            .subscribeCharacteristic(deviceId, _ddpService, _ddpNotify)
            .listen((b) => notifs.add(_hex(b)));
        final el = await codec.encodeCommand(
            specYaml: specYaml,
            charUuid: _ddpWrite,
            commandName: 'effect_list',
            params: {'sn': nextSeq().toDouble()});
        await ble.writeCharacteristic(deviceId, _ddpService, _ddpWrite, el);
        await Future<void>.delayed(const Duration(seconds: 5));
        await sub.cancel();
        // ignore: avoid_print
        print('EFFECT_LIST_NOTIFS count=${notifs.length}');
        for (final n in notifs) {
          // ignore: avoid_print
          print('NOTIF $n');
        }
      } finally {
        await ble.disconnect(deviceId);
      }
    },
    timeout: const Timeout(Duration(minutes: 5)),
  );
}
