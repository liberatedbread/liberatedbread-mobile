// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// VALIDATION: does a multi-frame animation play as a LOOPING PLAYLIST of stored
// single-frame microapps? Stores solid RED, GREEN, BLUE each as its own type-3
// AMX microapp (the path that renders), then sets them as a looping playlist,
// and holds so a webcam / eye can see whether the panel cycles R->G->B.
//
// LB_LIVE_BLE=1 + LB_LIVE_BLE_ID; LB_LIVE_BLE_DIRECT=1 to skip the fbp scan.
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
    'multi-frame animation plays as a looping playlist of stored frames',
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
        // Continuous scan (no per-pass timeout): fbp_linux surfaces this curtain
        // only intermittently, so keep scanning until it appears rather than
        // giving up after one 30s window.
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

      // Store one solid-colour frame as a type-3 AMX microapp and wait for the
      // device to commit it. Returns the cid.
      Future<int> storeFrame(String name, List<int> rgb, int cid) async {
        final plan = await codec.encodeStoredImage(
          specYaml: specYaml,
          width: _w,
          height: _h,
          rgb: rgb,
          name: name,
          cid: cid,
          timeSecs: 1, // short dwell; hope the playlist honours it
          scroll: 'none',
          speed: 5,
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
        final v = await verdictF;
        // ignore: avoid_print
        print('FRAME $name cid=$cid -> ${v.kind} (code ${v.code})');
        expect(v.kind, StoredUploadEventKind.complete);
        return cid;
      }

      try {
        final base = 910000 + (DateTime.now().millisecondsSinceEpoch % 8000);
        final r = await storeFrame('R', _solid(255, 0, 0), base);
        final g = await storeFrame('G', _solid(0, 255, 0), base + 1);
        final b = await storeFrame('B', _solid(0, 0, 255), base + 2);

        // Fetch the effect list to learn each frame's device-assigned SLOT —
        // the playlist resolves items by slot, and slot 0 did not cycle.
        final slotByCid = <int, int>{};
        final elSub = ble
            .subscribeCharacteristic(deviceId, _ddpService, _ddpNotify)
            .listen((bytes) async {
          for (final e in await codec.decodeEffectList(
              specYaml: specYaml, bytes: bytes)) {
            slotByCid[e.cid] = e.slot;
          }
        });
        final elCmd = await codec.encodeCommand(
            specYaml: specYaml,
            charUuid: _ddpWrite,
            commandName: 'effect_list',
            params: {'sn': nextSeq().toDouble()});
        await ble.writeCharacteristic(deviceId, _ddpService, _ddpWrite, elCmd);
        await Future<void>.delayed(const Duration(seconds: 5));
        await elSub.cancel();
        // ignore: avoid_print
        print('SLOTS r=$r->${slotByCid[r]} g=$g->${slotByCid[g]} '
            'b=$b->${slotByCid[b]}');

        // Set the three frames as a looping playlist, addressed by their real
        // device slots (0 fallback when the list didn't include one).
        final pl = await codec.encodeSetPlaylist(
          specYaml: specYaml,
          cids: [r, g, b],
          slots: [
            slotByCid[r] ?? 0,
            slotByCid[g] ?? 0,
            slotByCid[b] ?? 0,
          ],
          sequence: nextSeq(),
        );
        for (final w in pl.writes) {
          // ignore: avoid_print
          print('PLAYLIST write -> '
              '${w.bytes.map((x) => x.toRadixString(16).padLeft(2, '0')).join(' ')}');
          await ble.writeCharacteristic(
              deviceId, pl.serviceUuid, w.characteristicUuid, w.bytes);
        }
        // Kick playback off in case setting the playlist + loop mode does not
        // itself start it: play the first frame by cid.
        final startPlay = await codec.encodeStoredPlay(
            specYaml: specYaml, cid: r, sequence: nextSeq());
        await ble.writeCharacteristic(deviceId, startPlay.serviceUuid,
            startPlay.write.characteristicUuid, startPlay.write.bytes);
        // ignore: avoid_print
        print('PLAYLIST_SET+PLAY at ${DateTime.now().millisecondsSinceEpoch} '
            '— WATCH THE PANEL NOW for red/green/blue');

        // Hold ~50s connected so it can be watched cycling before disconnect.
        for (var t = 0; t < 50; t++) {
          await Future<void>.delayed(const Duration(seconds: 1));
        }
      } finally {
        await ble.disconnect(deviceId);
      }
    },
    timeout: const Timeout(Duration(minutes: 6)),
  );
}
