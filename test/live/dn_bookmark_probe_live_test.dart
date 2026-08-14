// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// PROBE / ITERATION HOOK for the curtain's cycling-stills animation. Stores N
// solid frames as type-3 stills, then runs the VENDOR'S ACTUAL on-wire playlist
// setup (smartdawn_longer2.pcapng frames 5977 -> 5995):
//
//   set_playlist(M_BOOKMARK_SAVE) -> play_next
//
// There is NO bookmark_clear and NO bookmark_enable in ANY of the four 2026-08
// captures — that sequence was a mis-reading of the decompiled H5. This logs
// every command's exact bytes AND the decoded 12-byte DDP header so the wire
// can be diffed against the capture (header must now be all-zero: len=0, osn=0,
// ts=0 — matching every vendor frame). It subscribes to the notify char ONCE
// (not per frame) to avoid the per-frame CCCD churn the app hit.
//
// WHAT TO WATCH ON THE PANEL after "SETUP DONE":
//   PASS  = the panel cycles ONLY the N solid colours it just stored, in order,
//           and keeps doing so after the probe disconnects.
//   FAIL  = it cycles other/older effects too (autorun not scoped), or freezes
//           on one colour, or goes dark.
// The colours are printed per frame (FRAME i cid=.. [r,g,b]) so you can name
// what you see.
//
// LB_LIVE_BLE=1 + LB_LIVE_BLE_ID; LB_LIVE_BLE_DIRECT=1 to skip the fbp scan.
// LB_PROBE_FRAMES=N (default 3) sets the frame count.
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

// A handful of distinct solid colours to fill N frames.
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
    'set_playlist(save) + play_next scopes a stored-stills loop (probe)',
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

      // ONE subscription to the notify char for the whole run — every upload
      // verdict AND the effect-list reply demux off this single stream, so we
      // never pay the per-frame subscribe/unsubscribe churn.
      final notify = ble
          .subscribeCharacteristic(deviceId, _ddpService, _ddpNotify)
          .asBroadcastStream();
      final notifySub = notify.listen((_) {});

      Future<void> write(
          String label, String svc, String chr, List<int> b) async {
        // ignore: avoid_print
        print('>> $label -> ${_hex(b)}');
        await ble.writeCharacteristic(deviceId, svc, chr, b);
      }

      try {
        // Mirror the app's _saveAnimationLoop: CLEAR existing diy effects first
        // so the device's autorun is scoped to just these frames (the device
        // autoruns EVERY stored diy effect).
        final inv = <int, int>{}; // cid -> diy
        final invSub = notify.listen((bytes) async {
          for (final e in await codec.decodeEffectList(
              specYaml: specYaml, bytes: bytes)) {
            inv[e.cid] = e.diy;
          }
        });
        final elClear = await codec.encodeCommand(
            specYaml: specYaml,
            charUuid: _ddpWrite,
            commandName: 'effect_list',
            params: {'sn': nextSeq().toDouble()});
        await write('effect_list(clear)', _ddpService, _ddpWrite, elClear);
        await Future<void>.delayed(const Duration(seconds: 3));
        await invSub.cancel();
        final diyCids = [
          for (final e in inv.entries)
            if (e.value == 1) e.key
        ];
        // ignore: avoid_print
        print('CLEARING ${diyCids.length} diy effect(s): $diyCids');
        for (final cid in diyCids) {
          final rm = await codec.encodeRemoveApp(
              specYaml: specYaml, cid: cid, sequence: nextSeq());
          await write('remove_app{$cid}', rm.serviceUuid,
              rm.write.characteristicUuid, rm.write.bytes);
          await Future<void>.delayed(const Duration(milliseconds: 200));
        }

        final base = 920000 + (DateTime.now().millisecondsSinceEpoch % 8000);
        final cids = <int>[];
        for (var i = 0; i < frameCount; i++) {
          final colour = _palette[i % _palette.length];
          final cid = base + i;
          final plan = await codec.encodeStoredImage(
            specYaml: specYaml,
            width: _w,
            height: _h,
            rgb: _solid(colour[0], colour[1], colour[2]),
            name: 'probe $i',
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

        // Resolve each frame's device slot from the effect list.
        final slotByCid = <int, int>{};
        final elDone = notify.listen((bytes) async {
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
        await write('effect_list', _ddpService, _ddpWrite, el);
        await Future<void>.delayed(const Duration(seconds: 4));
        await elDone.cancel();
        final slots = [for (final c in cids) slotByCid[c] ?? 0];
        // ignore: avoid_print
        print('SLOTS ${[
          for (var i = 0; i < cids.length; i++) '${cids[i]}->${slots[i]}'
        ].join(', ')}');

        // === The vendor's ACTUAL playlist setup: save → play_next ===
        final pl = await codec.encodeSetPlaylist(
          specYaml: specYaml,
          cids: cids,
          slots: slots,
          sequence: nextSeq(),
        );
        for (final wr in pl.writes) {
          await write('set_playlist(save)', pl.serviceUuid,
              wr.characteristicUuid, wr.bytes);
          // Wire layout: [frag:4][F0 04][sn:2][len:2][mt:2][ddp-header:12][pb].
          // The vendor sends len=0 and a 12-byte all-zero DDP header for every
          // command; flag it if ours differs (means the spec fix didn't take).
          final b = wr.bytes;
          if (b.length >= 24) {
            final len = (b[8] << 8) | b[9];
            final header = b.sublist(12, 24);
            final ok = len == 0 && header.every((x) => x == 0);
            // ignore: avoid_print
            print('   len=$len ddpHeader[12..24]=${_hex(header)} '
                '${ok ? "== vendor (len=0, all-zero) OK" : "!! DIFFERS from vendor"}');
          }
        }

        final pn = await codec.encodeCommand(
            specYaml: specYaml,
            charUuid: _ddpWrite,
            commandName: 'play_next',
            params: {'sn': nextSeq().toDouble()});
        await write('play_next', _ddpService, _ddpWrite, pn);

        // ignore: avoid_print
        print('SETUP DONE — WATCH THE PANEL for a $frameCount-frame cycle. '
            'Holding 20s connected, then disconnecting so disconnect behaviour '
            'can be observed.');
        for (var t = 0; t < 20; t++) {
          await Future<void>.delayed(const Duration(seconds: 1));
        }
      } finally {
        await notifySub.cancel();
        await ble.disconnect(deviceId);
      }
    },
    timeout: const Timeout(Duration(minutes: 6)),
  );
}
