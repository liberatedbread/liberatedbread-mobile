// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// The real thing, on real hardware: pride mode through the real GroupRunner,
// BLE stack and Rust encoder, using the vendored spec, onto a LOY SPACE panel.
// Watch the panel.
//
// LB_LIVE_BLE=1 LB_LIVE_BLE_NAME=YS525C110340
//   flutter test --tags live_ble test/live/popled_pride_live_test.dart
// LB_LIVE_FLAG_POSITION picks where in the alternation it starts.
@Tags(['live_ble'])
library;

import 'dart:io';

import 'package:flutter_blue_plus_linux/flutter_blue_plus_linux.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/core/group_actions.dart';
import 'package:liberated_bread_mobile/core/stop_signal.dart';
import 'package:liberated_bread_mobile/services/group_runner.dart';
import 'package:liberated_bread_mobile/services/panel_size_query.dart';
import 'package:liberated_bread_mobile/services/real_ble_service.dart';
import 'package:liberated_bread_mobile/services/real_spec_codec.dart';

import '../helpers/host_rust_lib.dart';

void main() {
  test(
    'pride mode reaches a real popled panel',
    () async {
      final name = Platform.environment['LB_LIVE_BLE_NAME'];
      if (Platform.environment['LB_LIVE_BLE'] != '1' || name == null) {
        markTestSkipped('live hardware run not requested');
        return;
      }
      expect(await initHostRustLib(), isTrue);
      FlutterBluePlusLinux.registerWith();

      final specYaml = File(
        'vendor/protocol-specs/device-specs/devices/autobaba-led-backpack.yaml',
      ).readAsStringSync();
      final codec = RealSpecCodec();
      final ble = RealBleService();
      final spec = await codec.loadDeviceSpec(specYaml);

      expect(spec.imageUpload?.encodable, isTrue);
      expect(spec.imageUpload?.animatedUpload, isTrue);
      expect(supportedGroupOps(spec), contains(GroupOp.prideMode));

      final found = await ble
          .scan(timeout: null)
          .firstWhere((d) => d.name == name)
          .timeout(const Duration(seconds: 60));
      await ble.stopScan();

      // The panel's own answer, which the run below relies on.
      await ble.connect(found.id);
      await ble.discoverServices(found.id);
      final size = await queryPanelSize(ble, codec, found.id, specYaml);
      stdout.writeln('panel says: $size');
      expect(size, isNotNull);
      await ble.disconnect(found.id);
      await Future<void>.delayed(const Duration(seconds: 3));

      final runner = GroupRunner(ble: ble, codec: codec);
      final position = int.parse(
        Platform.environment['LB_LIVE_FLAG_POSITION'] ?? '0',
      );
      final events = await runner
          .run(
            GroupOp.prideMode,
            [
              GroupMember(
                id: found.id,
                name: name,
                spec: spec,
                specYaml: specYaml,
              ),
            ],
            firstPosition: position,
            stop: StopSignal(),
          )
          .toList();
      for (final e in events) {
        stdout.writeln('${e.status.name}: ${e.detail ?? ''}');
      }
      expect(
        events.last.status,
        GroupDeviceStatus.ok,
        reason: events.last.detail,
      );
    },
    timeout: const Timeout(Duration(minutes: 4)),
  );
}
