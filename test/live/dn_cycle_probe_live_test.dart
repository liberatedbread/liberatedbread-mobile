// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// PROBE for B (cycle WITHOUT a disconnect): store N solid frames, then step
// through them with play_effect{cid, slot} on a timer WHILE CONNECTED, and hold
// the connection. If the panel visibly cycles R->G->B under the webcam while
// still connected, app-driven cycling works and we don't need to disconnect.
//
// LB_LIVE_BLE=1 + LB_LIVE_BLE_ID; LB_LIVE_BLE_DIRECT=1 to skip the fbp scan.
// LB_CYCLE_MS=<ms per frame> (default 700). LB_CYCLE_SECS=<hold> (default 25).
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
];

void main() {
  test(
    'app-driven play_effect cycles the panel while connected (probe)',
    () async {
      final deviceId = Platform.environment['LB_LIVE_BLE_ID'];
      if (Platform.environment['LB_LIVE_BLE'] != '1' || deviceId == null) {
        markTestSkipped('live hardware run not requested');
        return;
      }
      final frameMs =
          int.tryParse(Platform.environment['LB_CYCLE_MS'] ?? '700') ?? 700;
      final holdSecs =
          int.tryParse(Platform.environment['LB_CYCLE_SECS'] ?? '25') ?? 25;
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

      try {
        // Store 3 solid frames.
        final base = 940000 + (DateTime.now().millisecondsSinceEpoch % 8000);
        final cids = <int>[];
        for (var i = 0; i < 3; i++) {
          final c = _palette[i];
          final cid = base + i;
          final plan = await codec.encodeStoredImage(
            specYaml: specYaml,
            width: _w,
            height: _h,
            rgb: _solid(c[0], c[1], c[2]),
            name: 'cyc $i',
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
          await done;
          cids.add(cid);
        }

        // Resolve each frame's device slot.
        final slotByCid = <int, int>{};
        final elSub = notify.listen((bytes) async {
          for (final e
              in await codec.decodeEffectList(specYaml: specYaml, bytes: bytes)) {
            slotByCid[e.cid] = e.slot;
          }
        });
        final el = await codec.encodeCommand(
            specYaml: specYaml,
            charUuid: _ddpWrite,
            commandName: 'effect_list',
            params: {'sn': nextSeq().toDouble()});
        await ble.writeCharacteristic(deviceId, _ddpService, _ddpWrite, el);
        await Future<void>.delayed(const Duration(seconds: 3));
        await elSub.cancel();
        final slots = [for (final c in cids) slotByCid[c] ?? 0];
        // ignore: avoid_print
        print('SLOTS ${[for (var i = 0; i < cids.length; i++) '${cids[i]}->${slots[i]}'].join(', ')}');

        // ignore: avoid_print
        print('CYCLING play_effect over ${cids.length} frames every ${frameMs}ms '
            'for ${holdSecs}s WHILE CONNECTED — watch the panel.');
        final until = DateTime.now().add(Duration(seconds: holdSecs));
        var i = 0;
        var logged = 0;
        while (DateTime.now().isBefore(until)) {
          final cid = cids[i % cids.length];
          final slot = slots[i % slots.length];
          final cmd = await codec.encodeCommand(
              specYaml: specYaml,
              charUuid: _ddpWrite,
              commandName: 'play_effect',
              params: {
                'effect_id': cid.toDouble(),
                'slot': slot.toDouble(),
                'sn': nextSeq().toDouble(),
              });
          if (logged < 3) {
            // ignore: avoid_print
            print('>> play_effect cid=$cid slot=$slot -> ${_hex(cmd)}');
            logged++;
          }
          await ble.writeCharacteristic(deviceId, _ddpService, _ddpWrite, cmd);
          await Future<void>.delayed(Duration(milliseconds: frameMs));
          i++;
        }
        // ignore: avoid_print
        print('DONE cycling. Disconnecting.');
      } finally {
        await notifySub.cancel();
        await ble.disconnect(deviceId);
      }
    },
    timeout: const Timeout(Duration(minutes: 6)),
  );
}
