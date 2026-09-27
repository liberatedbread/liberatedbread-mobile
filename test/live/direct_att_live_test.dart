// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// PROBES: the Linux Bluetooth stack exactly as the app runs it — the real
// flutter_blue_plus_linux (BlueZ) under the DirectAttRouter under
// RealBleService — against a real peripheral. Nothing is faked; this is the
// hand-over as a user meets it.
//
// Tagged `live_ble` and self-skipping unless LB_LIVE_BLE=1, target from
// LB_LIVE_BLE_ID. Keep the device advertising (awake) when a run starts: if
// bluetoothd has never seen it, the probe scans for it first. Each run
// starts with an empty device registry, so a device
// BlueZ cannot enumerate is met exactly as a first-time user meets it: about
// 32 s while bluetoothd waits out its probe, then the hand-over. Add
// LB_DIRECT_ATT=<same mac> to skip straight to the direct path.
//
// Any device — prints the GATT table and every readable value, through
// whichever path the router picks:
//   LB_LIVE_BLE=1 LB_LIVE_BLE_ID=AA:BB:CC:DD:EE:FF \
//     flutter test test/live/direct_att_live_test.dart --plain-name 'any device'
//
// The Johnson LDM330 laser meter — also subscribes, sends the init frame,
// answers the keep-alives and asks for a reading (press the meter's button
// during the window too):
//   LB_LIVE_BLE=1 LB_LIVE_BLE_ID=18:7A:93:12:DE:94 LB_LIVE_LDM330=1 \
//     flutter test test/live/direct_att_live_test.dart --plain-name LDM330
@Tags(['live_ble'])
library;

import 'dart:io';

import 'package:flutter_blue_plus/flutter_blue_plus.dart' show FlutterBluePlus;
import 'package:flutter_blue_plus_linux/flutter_blue_plus_linux.dart';
import 'package:flutter_blue_plus_platform_interface/flutter_blue_plus_platform_interface.dart'
    show FlutterBluePlusPlatform;
import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/core/log.dart';
import 'package:liberated_bread_mobile/services/direct_att/att_pdu.dart';
import 'package:liberated_bread_mobile/services/direct_att/direct_att_router.dart';
import 'package:liberated_bread_mobile/services/real_ble_service.dart';
import 'package:liberated_bread_mobile/services/settings_store.dart';

import '../fakes/in_memory_settings_store.dart';

final _f150 = uuid16ToString(0xf150);
final _f151 = uuid16ToString(0xf151);
final _f154 = uuid16ToString(0xf154);

const _init = [0x03, 0x0D, 0x0A, 0x03, 0x0D, 0x0A];

/// `#` LF `command` NUL-padded to 12 bytes, then the 8-bit sum of it all
/// (vendor/protocol-specs/device-specs/devices/jlx-laser-distance-meter.yaml).
List<int> _command(String command) {
  final frame = [0x23, 0x0A, ...command.codeUnits];
  while (frame.length < 12) {
    frame.add(0);
  }
  return [...frame, frame.fold<int>(0, (a, b) => a + b) & 0xFF];
}

String _show(List<int> b) => b
    .map(
      (x) => x >= 0x20 && x < 0x7f
          ? String.fromCharCode(x)
          : '\\x${x.toRadixString(16).padLeft(2, '0')}',
    )
    .join();

/// The device under test, in BlueZ's (upper-case) spelling, or null (and
/// the test marked skipped).
String? _target() {
  final id = Platform.environment['LB_LIVE_BLE_ID'];
  if (Platform.environment['LB_LIVE_BLE'] != '1' || id == null) {
    markTestSkipped(
      'live hardware run not requested '
      '(set LB_LIVE_BLE=1 and LB_LIVE_BLE_ID=<mac>)',
    );
    return null;
  }
  return id.trim().toUpperCase();
}

final _clock = Stopwatch()..start();

void _say(String line) => stderr.writeln(
  '[${(_clock.elapsedMilliseconds / 1000).toStringAsFixed(1)}s] $line',
);

/// The app's stack, built ONCE per process like the app's: flutter_blue_plus
/// binds to the platform it first meets and never re-binds, so a second
/// router in the same run would be one it never listens to.
Future<RealBleService>? _stack;
Future<RealBleService> _appStack() => _stack ??= _buildStack();

/// BlueZ registered as at startup, the router slid under flutter_blue_plus as
/// bleServiceProvider does, and the service.
Future<RealBleService> _buildStack() async {
  // Every BLE log line, however fine: this is the diagnosis if it fails.
  Log.setCategoryLevel(Log.ble, LogLevel.debug);
  Log.sink = (r) => stderr.writeln(
    '  ${r.level.name} [${r.category}] ${r.message}'
    '${r.error == null ? '' : ' (${r.error})'}',
  );
  FlutterBluePlusLinux.registerWith();
  final router = installDirectAttRouter(
    Future<SettingsStore>.value(InMemorySettingsStore()),
  );
  expect(router, isNotNull, reason: 'the router installs on Linux');
  expect(FlutterBluePlusPlatform.instance, same(router));
  return RealBleService();
}

/// Make sure bluetoothd knows [id] before connecting to it. Connecting goes
/// through BlueZ unless the device is routed direct, and BlueZ can only
/// connect a device it has a Device1 for — which, on a host that has never
/// scanned it, takes a scan. (Once connected through BlueZ, bluetoothd keeps
/// the device, and flutter_blue_plus_linux never reports a kept device in a
/// scan again; this checks what BlueZ knows first for that reason.)
Future<void> _makeKnown(RealBleService ble, String id) async {
  final forced = (Platform.environment['LB_DIRECT_ATT'] ?? '')
      .toUpperCase()
      .split(',')
      .map((s) => s.trim());
  if (forced.contains(id)) return;
  final known = await FlutterBluePlus.systemDevices(const []);
  if (known.any((d) => d.remoteId.str.toUpperCase() == id)) return;
  _say('bluetoothd does not know $id yet; scanning for it (up to 45 s)');
  await ble
      .scan(timeout: const Duration(seconds: 45))
      .firstWhere((d) => d.id.toUpperCase() == id);
  await ble.stopScan();
  _say('found $id');
}

void main() {
  test(
    'any device: GATT table and readable values through the app stack (probe)',
    () async {
      final id = _target();
      if (id == null) return;
      final ble = await _appStack();
      await _makeKnown(ble, id);
      _say('connecting to $id');
      await ble.connect(id);
      _say(
        'connected; discovering (a device BlueZ cannot enumerate takes ~32 s)',
      );
      final services = await ble.discoverServices(id);
      _say('${services.length} service(s)');
      for (final s in services) {
        _say('  service ${s.uuid}');
        for (final c in s.characteristics) {
          var line =
              '    ${c.uuid} '
              '${c.canRead ? 'r' : '-'}${c.canWriteWithResponse ? 'w' : '-'}'
              '${c.canWriteWithoutResponse ? 'W' : '-'}'
              '${c.canNotify ? 'n' : '-'}';
          if (c.canRead) {
            try {
              line +=
                  ' = ${_show(await ble.readCharacteristic(id, s.uuid, c.uuid))}';
            } catch (e) {
              line += ' ! $e';
            }
          }
          _say(line);
        }
      }
      _say('mtu ${await ble.mtu(id)}');
      await ble.disconnect(id);
      _say('disconnected');
      expect(services, isNotEmpty);
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test(
    'LDM330: subscribe, init, keep-alives and a reading through the app stack '
    '(probe)',
    () async {
      final id = _target();
      if (id == null) return;
      if (Platform.environment['LB_LIVE_LDM330'] != '1') {
        markTestSkipped('set LB_LIVE_LDM330=1 to drive a laser meter');
        return;
      }
      final ble = await _appStack();
      await _makeKnown(ble, id);
      _say('connecting to $id');
      await ble.connect(id);
      final services = await ble.discoverServices(id);
      _say(
        '${services.length} service(s): '
        '${services.map((s) => s.uuid.substring(4, 8)).join(' ')}',
      );
      expect(services.map((s) => s.uuid), contains(_f150));

      final frames = <String>[];
      final sub = ble.subscribeCharacteristic(id, _f150, _f154).listen((
        value,
      ) async {
        final text = _show(value);
        frames.add(text);
        _say('<- $text');
        // Answer the handshake and every keep-alive, or the meter says
        // Zbleoff and drops the link ~44 s in.
        if (text.startsWith('Ztest01')) {
          await ble.writeCharacteristic(id, _f150, _f151, _init);
        } else if (text.startsWith('Ztest02')) {
          await ble.writeCharacteristic(id, _f150, _f151, _command('Link'));
        }
      });
      await Future<void>.delayed(const Duration(milliseconds: 300));
      await ble.writeCharacteristic(id, _f150, _f151, _init);
      _say('-> init');
      await Future<void>.delayed(const Duration(seconds: 2));
      await ble.writeCharacteristic(id, _f150, _f151, _command('m'));
      _say('-> m (measure); press the button on the meter too');
      await Future<void>.delayed(const Duration(seconds: 25));
      await sub.cancel();
      await ble.disconnect(id);
      _say('disconnected; ${frames.length} frame(s)');
      expect(frames, isNotEmpty, reason: 'the meter answers with Ztest01/02');
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
