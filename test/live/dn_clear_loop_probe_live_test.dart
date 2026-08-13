// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// PROBE: does clearing the device's stored diy effects make its post-disconnect
// autorun a TIGHT loop of only our frames? The webcam showed the device
// autoruns its WHOLE stored set (~31s rotation) with our R/G/B frames as one
// clean consecutive segment. Hypothesis: remove every diy effect first, store
// only N frames, and the device's autorun == just our loop.
//
// Steps: connect -> effect_list (log all cid/type/diy) -> remove each diy==1
// effect -> effect_list (confirm) -> store N solid frames -> effect_list
// (confirm only ours) -> disconnect. Then WATCH the panel: PASS = it cycles
// only the N solid colours; FAIL = built-ins/others still appear (autorun is
// not diy-only and clearing can't scope it).
//
// LB_LIVE_BLE=1 + LB_LIVE_BLE_ID; LB_PROBE_FRAMES=N (default 3).
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
    b.map((x) => x.toRadixString(16).padLeft(2, '0')).join(' ');

List<int> _solid(int r, int g, int b) {
  final f = Uint8List(_w * _h * 3);
  for (var i = 0; i < f.length; i += 3) {
    f[i] = r;
    f[i + 1] = g;
    f[i + 2] = b;
  }
  return f;
}

const _palette = [
  [255, 0, 0],
  [0, 255, 0],
  [0, 0, 255],
  [255, 255, 0],
  [255, 0, 255],
  [0, 255, 255],
  [255, 255, 255],
];

void main() {
  test(
    'clearing diy effects tightens autorun to only our frames (probe)',
    () async {
      final deviceId = Platform.environment['LB_LIVE_BLE_ID'];
      if (Platform.environment['LB_LIVE_BLE'] != '1' || deviceId == null) {
        markTestSkipped('live hardware run not requested');
        return;
      }
      final frameCount =
          int.tryParse(Platform.environment['LB_PROBE_FRAMES'] ?? '3') ?? 3;
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

      final notify = ble
          .subscribeCharacteristic(deviceId, _ddpService, _ddpNotify)
          .asBroadcastStream();
      final notifySub = notify.listen((_) {});

      Future<void> write(String label, List<int> b) async {
        // ignore: avoid_print
        print('>> $label -> ${_hex(b)}');
        await ble.writeCharacteristic(deviceId, _ddpService, _ddpWrite, b);
      }

      // Request the effect list and accumulate every entry the device streams
      // back over a short window.
      Future<Map<int, ({int slot, int type, int diy})>> readEffectList(
          String tag) async {
        final map = <int, ({int slot, int type, int diy})>{};
        final sub = notify.listen((bytes) async {
          for (final e in await codec.decodeEffectList(
              specYaml: specYaml, bytes: bytes)) {
            map[e.cid] = (slot: e.slot, type: e.type, diy: e.diy);
          }
        });
        final el = await codec.encodeCommand(
            specYaml: specYaml,
            charUuid: _ddpWrite,
            commandName: 'effect_list',
            params: {'sn': nextSeq().toDouble()});
        await write('effect_list($tag)', el);
        await Future<void>.delayed(const Duration(seconds: 4));
        await sub.cancel();
        // ignore: avoid_print
        print('EFFECT_LIST($tag): ${map.length} entries');
        for (final e in map.entries) {
          // ignore: avoid_print
          print('   cid=${e.key} slot=${e.value.slot} '
              'type=${e.value.type} diy=${e.value.diy}');
        }
        return map;
      }

      try {
        // 1) Inventory + clear every diy==1 effect.
        final before = await readEffectList('before');
        final diyCids =
            before.entries.where((e) => e.value.diy == 1).map((e) => e.key);
        for (final cid in diyCids) {
          final rm = await codec.encodeRemoveApp(
              specYaml: specYaml, cid: cid, sequence: nextSeq());
          await write('remove_app{$cid}', rm.write.bytes);
          await Future<void>.delayed(const Duration(milliseconds: 250));
        }
        await readEffectList('after-clear');

        // 2) Store N solid frames.
        final base = 930000 + (DateTime.now().millisecondsSinceEpoch % 8000);
        final cids = <int>[];
        for (var i = 0; i < frameCount; i++) {
          final colour = _palette[i % _palette.length];
          final cid = base + i;
          final plan = await codec.encodeStoredImage(
            specYaml: specYaml,
            width: _w,
            height: _h,
            rgb: _solid(colour[0], colour[1], colour[2]),
            name: 'clr $i',
            cid: cid,
            timeSecs: 1,
            scroll: 'none',
            speed: 5,
            sequence: nextSeq(),
          );
          final done = notify
              .asyncMap((b) =>
                  codec.decodeStoredUploadEvent(specYaml: specYaml, bytes: b))
              .where((e) => e != null)
              .cast<StoredUploadEventDto>()
              .firstWhere((e) =>
                  e.kind == StoredUploadEventKind.complete ||
                  e.kind == StoredUploadEventKind.failed ||
                  e.kind == StoredUploadEventKind.startRejected)
              .timeout(const Duration(seconds: 30));
          for (final wr in plan.uploadWrites) {
            await ble.writeCharacteristic(
                deviceId, plan.serviceUuid, wr.characteristicUuid, wr.bytes);
          }
          final v = await done;
          // ignore: avoid_print
          print('FRAME $i cid=$cid $colour -> ${v.kind}');
          cids.add(cid);
        }

        final after = await readEffectList('after-store');
        final ours = cids.where(after.containsKey).length;
        // ignore: avoid_print
        print('STORED $ours/$frameCount of our frames registered. '
            'Total effects on device now: ${after.length}.');
        // ignore: avoid_print
        print('SETUP DONE — disconnecting NOW so the device autoruns. '
            'WATCH: PASS = only the $frameCount solid colours cycle; '
            'FAIL = other effects still appear.');
      } finally {
        await notifySub.cancel();
        await ble.disconnect(deviceId);
      }
    },
    timeout: const Timeout(Duration(minutes: 6)),
  );
}
