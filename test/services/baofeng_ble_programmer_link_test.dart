// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// The programmer's hold on the link, against a fake BleService: a connect
// that outlives the programmer's patience, and a notify setup that fails.
// Kept apart from baofeng_ble_programmer_test.dart, which drives the real
// service over an emulated adapter and cannot hold a connect open or fail
// only the CCCD write.

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/models/radio_profile.dart';
import 'package:liberated_bread_mobile/services/baofeng_ble_programmer.dart';
import 'package:liberated_bread_mobile/services/radio_programmer.dart';

import '../fakes/fake_ble_service.dart';
import '../helpers/host_rust_lib.dart';

const _deviceId = 'AA:BB:CC:DD:EE:99';

/// Keeps RealBleService's claim books: a connect that resolves takes a
/// claim whether or not anyone is still waiting for it.
class _ClaimBooksBle extends FakeBleService {
  _ClaimBooksBle({this.gate, super.notifyStream});

  final Completer<void>? gate;
  int claims = 0;

  @override
  Future<void> connect(String deviceId) async {
    final gate = this.gate;
    if (gate != null) await gate.future;
    claims++;
    return super.connect(deviceId);
  }

  @override
  Future<void> disconnect(String deviceId) async {
    if (claims > 0) claims--;
    return super.disconnect(deviceId);
  }
}

void main() {
  late bool rustReady;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    rustReady = await initHostRustLib();
  });

  test('a connect that lands after the timeout gives its claim back', () async {
    // The programmer stopped waiting, but the connect kept going; when it
    // landed it took a claim nothing released, so the radio stayed
    // connected — and stopped advertising — until the app died. Fails on
    // the old code: no cancel, and the claim is still held at the end.
    final gate = Completer<void>();
    final ble = _ClaimBooksBle(gate: gate);
    final programmer = BaofengBleProgrammer(
      ble,
      timing: const BleTiming(
        connect: Duration(milliseconds: 20),
        step: Duration(milliseconds: 300),
        settle: Duration.zero,
      ),
    );

    await expectLater(
      programmer.identify(deviceId: _deviceId, profile: uv5rMiniProfile),
      throwsA(isA<RadioTimeoutException>()),
    );
    expect(ble.events, ['cancel:$_deviceId']);

    gate.complete();
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);

    expect(ble.claims, 0);
    expect(ble.events, [
      'cancel:$_deviceId',
      'connect:$_deviceId',
      'disconnect:$_deviceId',
    ]);
  });

  test('a notify setup that fails is the error, not a silent radio', () async {
    // RealBleService reports a refused CCCD write on the notification
    // stream. With no onError the error went to the zone, and the session
    // sent each ident magic into a characteristic that would never
    // answer, then blamed the radio's programming mode. Fails on the old
    // code: an uncaught error, and the programming-mode message a step
    // later.
    if (!rustReady) return markTestSkipped('host Rust library unavailable');
    final refusal = StateError('CCCD write refused');
    final ble = _ClaimBooksBle(notifyStream: Stream<List<int>>.error(refusal));
    final programmer = BaofengBleProgrammer(
      ble,
      timing: const BleTiming(
        // Long enough that waiting it out would fail the timing check.
        step: Duration(seconds: 5),
        settle: Duration.zero,
      ),
    );

    final stopwatch = Stopwatch()..start();
    await expectLater(
      programmer.identify(deviceId: _deviceId, profile: uv5rMiniProfile),
      throwsA(same(refusal)),
    );
    expect(stopwatch.elapsed, lessThan(const Duration(seconds: 2)));
    // The session still lets go of the link it took.
    expect(ble.claims, 0);
  });
}
