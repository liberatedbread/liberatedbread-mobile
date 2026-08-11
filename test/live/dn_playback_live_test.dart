// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// Focused hardware proof for the playback fixes: power on/off as framed DDP
// commands, store-then-show for an ANIMATION (the path the user reported broken)
// with the wait-for-commit that makes play work, and a double replay proving
// the rolling sequence restarts a design instead of being de-duped.
//
// Same double guard as dn_display_live_test.dart: tagged `live_ble` and
// self-skipping unless LB_LIVE_BLE=1, target MAC from LB_LIVE_BLE_ID.
//
// Run it (with a webcam pointed at the panel to watch it change):
//   cargo build --manifest-path rust/Cargo.toml
//   LB_LIVE_BLE=1 LB_LIVE_BLE_ID=98:88:E0:AA:BB:CC \
//     LD_LIBRARY_PATH=$PWD/rust/target/debug \
//     flutter test test/live/dn_playback_live_test.dart
@Tags(['live_ble'])
library;

import 'dart:io';

import 'package:flutter_blue_plus_linux/flutter_blue_plus_linux.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/services/real_ble_service.dart';
import 'package:liberated_bread_mobile/services/real_spec_codec.dart';
import 'package:liberated_bread_mobile/services/spec_codec.dart'
    show StoredUploadEventDto, StoredUploadEventKind;
import 'package:liberated_bread_mobile/widgets/led_designs.dart';

import '../helpers/host_rust_lib.dart';

const _width = 20;
const _height = 20;
const _ddpService = '00000074-1972-1925-3022-077119514e44';
const _ddpWrite = '01020074-1972-1925-3022-077119514e44';

void main() {
  test(
    'power, store-animation-then-play, and double replay on a live DN curtain',
    () async {
      final deviceId = Platform.environment['LB_LIVE_BLE_ID'];
      if (Platform.environment['LB_LIVE_BLE'] != '1' || deviceId == null) {
        markTestSkipped('live hardware run not requested '
            '(set LB_LIVE_BLE=1 and LB_LIVE_BLE_ID=<mac>)');
        return;
      }
      expect(await initHostRustLib(), isTrue,
          reason: 'build rust/ for the host first');
      FlutterBluePlusLinux.registerWith();

      final specYaml = File(
              'vendor/protocol-specs/device-specs/devices/smartdawn-smart-lights.yaml')
          .readAsStringSync();
      const codec = RealSpecCodec();
      final ble = RealBleService();

      // flutter_blue_plus_linux can miss the DN curtain's sparse advertising in
      // a headless run even though BlueZ itself sees it. When LB_LIVE_BLE_DIRECT
      // is set, skip the discovery firstWhere and connect straight to the
      // address — the caller keeps a `bluetoothctl scan on` running so BlueZ has
      // it cached, which is all connect needs.
      if (Platform.environment['LB_LIVE_BLE_DIRECT'] == '1') {
        // ignore: avoid_print
        print('direct connect (skipping fbp scan) to $deviceId');
      } else {
        final found = await ble
            .scan()
            .firstWhere((d) => d.id == deviceId)
            .timeout(const Duration(seconds: 45));
        expect(found.id, deviceId);
        await ble.stopScan();
      }
      await ble.connect(deviceId);

      // A monotonically rising sequence, exactly as the app's provider hands
      // out — every framed write below takes the next value.
      var seq = 0;
      int nextSeq() {
        seq = (seq % 0xFFFF) + 1;
        return seq;
      }

      Future<void> sendCommand(String command) async {
        final bytes = await codec.encodeCommand(
          specYaml: specYaml,
          charUuid: _ddpWrite,
          commandName: command,
          params: {'sn': nextSeq().toDouble()},
        );
        // ignore: avoid_print
        print('CMD $command -> '
            '${bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ')}');
        await ble.writeCharacteristic(deviceId, _ddpService, _ddpWrite, bytes);
      }

      try {
        // 1) POWER: off, then on. Watch the panel go dark and relight.
        // ignore: avoid_print
        print('--- power_off ---');
        await sendCommand('power_off');
        await Future<void>.delayed(const Duration(seconds: 3));
        // ignore: avoid_print
        print('--- power_on ---');
        await sendCommand('power_on');
        await Future<void>.delayed(const Duration(seconds: 2));

        // 2) STORE AN ANIMATION then show it — the reported-broken path.
        final star = defaultDesigns(_width, _height)
            .firstWhere((d) => d.name == 'Star animation');
        final frames = star.buildFrames().map((f) => f.toList()).toList();
        final cid = 900001 + (DateTime.now().millisecondsSinceEpoch % 90000);
        final playSeq = nextSeq();
        final plan = await codec.encodeStoredAnimation(
          specYaml: specYaml,
          width: _width,
          height: _height,
          frames: frames,
          name: 'LB live anim',
          cid: cid,
          frameMs: 120,
          sequence: playSeq,
        );
        expect(plan.playWrite, isNotNull);
        expect(plan.responseCharacteristicUuid, isNotNull,
            reason: 'the fix restores the response characteristic');

        final verdictF = ble
            .subscribeCharacteristic(
                deviceId, plan.serviceUuid, plan.responseCharacteristicUuid!)
            .map((bytes) {
              // ignore: avoid_print
              print('UPLOAD notify: '
                  '${bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ')}');
              return bytes;
            })
            .asyncMap((bytes) =>
                codec.decodeStoredUploadEvent(specYaml: specYaml, bytes: bytes))
            .where((e) => e != null)
            .cast<StoredUploadEventDto>()
            .firstWhere((e) =>
                e.kind == StoredUploadEventKind.complete ||
                e.kind == StoredUploadEventKind.failed ||
                e.kind == StoredUploadEventKind.startRejected)
            .timeout(const Duration(seconds: 25));

        for (final write in plan.uploadWrites) {
          await ble.writeCharacteristic(
              deviceId, plan.serviceUuid, write.characteristicUuid, write.bytes);
        }
        final verdict = await verdictF;
        // ignore: avoid_print
        print('ANIMATION verdict: ${verdict.kind} (code ${verdict.code})');
        expect(verdict.kind, StoredUploadEventKind.complete,
            reason: 'the curtain must commit the animation (code ${verdict.code})');

        // Vendor's refresh-then-show, then play.
        await sendCommand('effect_list');
        final play = plan.playWrite!;
        await ble.writeCharacteristic(
            deviceId, plan.serviceUuid, play.characteristicUuid, play.bytes);
        // Let it animate long enough to see motion on the webcam.
        await Future<void>.delayed(const Duration(seconds: 5));

        // 3) DOUBLE REPLAY: two play-by-cid writes with DIFFERENT sequences.
        // A de-duping firmware would ignore a byte-identical repeat; these are
        // distinct, so the panel should restart both times.
        for (var i = 0; i < 2; i++) {
          final replay = await codec.encodeStoredPlay(
              specYaml: specYaml, cid: cid, sequence: nextSeq());
          // ignore: avoid_print
          print('REPLAY $i -> ${replay.write.bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ')}');
          await ble.writeCharacteristic(deviceId, replay.serviceUuid,
              replay.write.characteristicUuid, replay.write.bytes);
          await Future<void>.delayed(const Duration(seconds: 3));
        }
      } finally {
        await ble.disconnect(deviceId);
      }
    },
    timeout: const Timeout(Duration(minutes: 5)),
  );
}
