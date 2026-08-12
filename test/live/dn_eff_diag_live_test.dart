// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// DEFINITIVE: does a SINGLE .eff animation (all frames in one type-0 container,
// the vendor's model) render and animate? Uploads R/G/B as one .eff, waits for
// commit, DUMPS the effect list to prove whether the .eff registered as a
// playable effect and at what slot, then plays it and holds so it can be
// watched. Answers the question the playlist detour skipped.
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

List<int> _solid(int r, int g, int b) {
  final f = Uint8List(_w * _h * 3);
  for (var i = 0; i < f.length; i += 3) {
    f[i] = r;
    f[i + 1] = g;
    f[i + 2] = b;
  }
  return f;
}

void main() {
  test(
    'a single .eff animation registers and plays',
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

      var seq = 0;
      int nextSeq() {
        seq = (seq % 0xFFFF) + 1;
        return seq;
      }

      try {
        final frames = [
          _solid(255, 0, 0),
          _solid(0, 255, 0),
          _solid(0, 0, 255),
        ];
        final cid = 905000 + (DateTime.now().millisecondsSinceEpoch % 4000);
        // ignore: avoid_print
        print('EFF upload cid=$cid (0x${cid.toRadixString(16)}) '
            '${frames.length} frames as ONE .eff');
        final plan = await codec.encodeStoredAnimation(
          specYaml: specYaml,
          width: _w,
          height: _h,
          frames: frames,
          name: 'eff diag',
          cid: cid,
          frameMs: 500,
          sequence: nextSeq(),
        );
        // ignore: avoid_print
        print('EFF uploadWrites=${plan.uploadWrites.length} '
            'playWrite=${plan.playWrite != null}');

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
            .timeout(const Duration(seconds: 40));
        for (final w in plan.uploadWrites) {
          await ble.writeCharacteristic(
              deviceId, plan.serviceUuid, w.characteristicUuid, w.bytes);
        }
        final v = await verdictF;
        // ignore: avoid_print
        print('EFF VERDICT ${v.kind} code ${v.code}');

        // Does the .eff register as a playable effect? Dump the list.
        final slotByCid = <int, int>{};
        final sub = ble
            .subscribeCharacteristic(deviceId, _ddpService, _ddpNotify)
            .listen((bytes) async {
          for (final e in await codec.decodeEffectList(
              specYaml: specYaml, bytes: bytes)) {
            slotByCid[e.cid] = e.slot;
          }
        });
        final el = await codec.encodeCommand(
            specYaml: specYaml,
            charUuid: _ddpWrite,
            commandName: 'effect_list',
            params: {'sn': nextSeq().toDouble()});
        await ble.writeCharacteristic(deviceId, _ddpService, _ddpWrite, el);
        await Future<void>.delayed(const Duration(seconds: 4));
        await sub.cancel();
        // ignore: avoid_print
        print('EFF REGISTERED? cid=$cid slot=${slotByCid[cid]} '
            '(total effects seen: ${slotByCid.length})');

        // Play it by cid (slot 0, as the plan's play write does) and watch.
        final play = plan.playWrite!;
        // ignore: avoid_print
        print('EFF PLAY (slot 0) -> '
            '${play.bytes.map((x) => x.toRadixString(16).padLeft(2, '0')).join(' ')}');
        await ble.writeCharacteristic(
            deviceId, plan.serviceUuid, play.characteristicUuid, play.bytes);
        // ignore: avoid_print
        print('WATCH: does the panel cycle R/G/B (the .eff animating)?');
        await Future<void>.delayed(const Duration(seconds: 12));

        // If a slot was learned and differs, also try play_effect with the real
        // slot, in case .eff play needs the slot like the playlist did.
        final realSlot = slotByCid[cid];
        if (realSlot != null && realSlot != 0) {
          final bySlot = await codec.encodeCommand(
              specYaml: specYaml,
              charUuid: _ddpWrite,
              commandName: 'play_effect',
              params: {
                'sn': nextSeq().toDouble(),
                'effect_id': cid.toDouble(),
                'slot': realSlot.toDouble(),
              });
          // ignore: avoid_print
          print('EFF PLAY (real slot $realSlot)');
          await ble.writeCharacteristic(
              deviceId, _ddpService, _ddpWrite, bySlot);
          await Future<void>.delayed(const Duration(seconds: 12));
        }
      } finally {
        await ble.disconnect(deviceId);
      }
    },
    timeout: const Timeout(Duration(minutes: 6)),
  );
}
