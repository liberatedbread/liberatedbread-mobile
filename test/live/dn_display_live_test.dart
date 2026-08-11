// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// The shipping pipeline against a REAL SmartDawn curtain: the vendored spec,
// the real Rust codec, RealBleService, and flutter_blue_plus_linux talking to
// the machine's own BlueZ — no emulation anywhere. The only thing a normal
// test run cannot prove is that a physical panel actually lights up; this is
// the harness for proving it deliberately, on a machine within sight of the
// device.
//
// Doubly guarded (see dart_test.yaml): tagged `live_ble` AND self-skipping
// unless LB_LIVE_BLE=1, with the target's MAC taken from LB_LIVE_BLE_ID so
// nothing here ever writes to an incidental bystander device.
//
// Run it like:
//   cargo build --manifest-path rust/Cargo.toml   # host codec, once
//   LB_LIVE_BLE=1 LB_LIVE_BLE_ID=98:88:E0:AA:BB:CC \
//     LD_LIBRARY_PATH=$PWD/rust/target/debug \
//     flutter test test/live/dn_display_live_test.dart
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
import 'package:liberated_bread_mobile/widgets/led_image_widget.dart';

import '../helpers/host_rust_lib.dart';

/// The JY25CUT curtain's panel, which reports its resolution at runtime; the
/// live-verified unit is 20x20.
const _width = 20;
const _height = 20;

void main() {
  test(
    'pushes the new default designs to a live DN curtain',
    () async {
      final deviceId = Platform.environment['LB_LIVE_BLE_ID'];
      if (Platform.environment['LB_LIVE_BLE'] != '1' || deviceId == null) {
        markTestSkipped('live hardware run not requested '
            '(set LB_LIVE_BLE=1 and LB_LIVE_BLE_ID=<mac>)');
        return;
      }
      expect(await initHostRustLib(), isTrue,
          reason: 'build rust/ for the host first');

      // The desktop app registers the Linux backend at startup; a test VM has
      // to do it itself or flutter_blue_plus falls back to a method channel
      // with nothing behind it.
      FlutterBluePlusLinux.registerWith();

      final specYaml = File(
              'vendor/protocol-specs/device-specs/devices/smartdawn-smart-lights.yaml')
          .readAsStringSync();
      const codec = RealSpecCodec();
      final ble = RealBleService();

      // Scan until the target advertises, exactly like the app: BlueZ only
      // lets a connect address devices in its discovery cache, and an idle
      // curtain drops out of it within minutes.
      final found = await ble
          .scan()
          .firstWhere((d) => d.id == deviceId)
          .timeout(const Duration(seconds: 45));
      expect(found.id, deviceId);
      await ble.stopScan();

      await ble.connect(deviceId);
      try {
        final services = await ble.discoverServices(deviceId);
        expect(
          services.map((s) => s.uuid),
          contains('00000074-1972-1925-3022-077119514e44'),
          reason: 'the DDP service must be there — is this really a SmartDawn?',
        );

        final payload = writePayloadForMtu(await ble.mtu(deviceId));
        expect(payload, greaterThan(20),
            reason: 'the Linux mtu quirk correction must have kicked in');

        final designs = defaultDesigns(_width, _height);
        // The sequence this branch adds: the bi flag proves a new stripe
        // design, the star animation proves multi-frame streaming, and the
        // trans flag leaves the curtain on a classic.
        final show = <(String, int)>[
          ('Bi flag', 0),
          ('Star animation', 3),
          ('Trans flag', 0),
        ];

        var frameIndex = 0;
        for (final (name, loops) in show) {
          final design = designs.firstWhere((d) => d.name == name);
          for (var loop = 0; loop <= loops; loop++) {
            for (final frame in design.buildFrames()) {
              final plan = await codec.encodeImageFrame(
                specYaml: specYaml,
                width: _width,
                height: _height,
                rgb: frame,
                frameIndex: frameIndex,
                maxPayloadPerWrite: payload,
              );
              for (final write in plan.writes) {
                await ble.writeCharacteristic(
                  deviceId,
                  plan.serviceUuid,
                  write.characteristicUuid,
                  write.bytes,
                );
              }
              frameIndex = plan.nextFrameIndex;
              await Future<void>.delayed(const Duration(milliseconds: 200));
            }
          }
          // A beat between designs so each one is seen, not blinked past.
          await Future<void>.delayed(const Duration(seconds: 2));
        }

        // The other half of the feature: persist a design on the device and
        // play it — the vendor's store-then-show, end to end on real
        // hardware, INCLUDING the wait for M_UPLOAD_COMPLETE that makes the
        // play work (playing before the device commits the cid is a silent
        // no-op — the original save-then-play bug).
        final trans = designs.firstWhere((d) => d.name == 'Trans flag');
        final cid = 900001 + (DateTime.now().millisecondsSinceEpoch % 90000);
        final stored = await codec.encodeStoredImage(
          specYaml: specYaml,
          width: _width,
          height: _height,
          rgb: trans.buildFrames().first,
          name: 'LB live store',
          cid: cid,
          timeSecs: 10,
          scroll: 'none',
          speed: 5,
        );
        expect(stored.playWrite, isNotNull,
            reason: 'the spec declares play_command — a save must then show');
        expect(stored.responseCharacteristicUuid, isNotNull,
            reason: 'the spec names where the device answers the upload');

        // Listen for the device's verdict BEFORE the first packet goes out.
        final verdictF = ble
            .subscribeCharacteristic(
              deviceId,
              stored.serviceUuid,
              stored.responseCharacteristicUuid!,
            )
            .asyncMap((bytes) =>
                codec.decodeStoredUploadEvent(specYaml: specYaml, bytes: bytes))
            .where((e) => e != null)
            .cast<StoredUploadEventDto>()
            .firstWhere((e) => e.kind != StoredUploadEventKind.progress)
            .timeout(const Duration(seconds: 20));

        for (final write in stored.uploadWrites) {
          await ble.writeCharacteristic(
            deviceId,
            stored.serviceUuid,
            write.characteristicUuid,
            write.bytes,
          );
        }

        // The REAL curtain must acknowledge the commit — this is the
        // hardware proof the whole wait-then-play mechanism stands on.
        final verdict = await verdictF;
        expect(verdict.kind, StoredUploadEventKind.complete,
            reason: 'the curtain rejected the upload (code ${verdict.code})');

        final play = stored.playWrite!;
        await ble.writeCharacteristic(
          deviceId,
          stored.serviceUuid,
          play.characteristicUuid,
          play.bytes,
        );
        // A beat so the playback is observable in the room.
        await Future<void>.delayed(const Duration(seconds: 3));

        // And the replay path the saved-designs list uses: address the item
        // by cid again, no re-upload.
        final replay =
            await codec.encodeStoredPlay(specYaml: specYaml, cid: cid);
        await ble.writeCharacteristic(
          deviceId,
          replay.serviceUuid,
          replay.write.characteristicUuid,
          replay.write.bytes,
        );
        await Future<void>.delayed(const Duration(seconds: 2));
      } finally {
        await ble.disconnect(deviceId);
      }
    },
    timeout: const Timeout(Duration(minutes: 5)),
  );
}
