// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// A connect with a deadline that does not leak the connect it gives up on.

import 'dart:async';

import '../core/log.dart';
import 'ble_service.dart';

/// [BleService.connect] to [deviceId], giving up after [timeout] with a
/// [TimeoutException] — without abandoning the connect it stopped waiting
/// for.
///
/// `Future.timeout` stops the wait, not the connect. A connect that landed
/// after its caller had given up took a connection claim nobody would
/// release, so the peripheral stayed connected (and stopped advertising)
/// until the app died, and every later owner's release only decremented
/// that orphan claim. So on timeout this:
///
/// * releases the claim if the connect lands anyway — exactly the one it
///   took, so another owner's link is only torn down when it was the last;
/// * asks a [BleConnectCanceller] to cancel it, which it does only when
///   this is the device's sole pending connect, never someone else's.
///
/// The caller holds a claim only when this returns normally, so it must
/// call [BleService.disconnect] then and only then: a release for a connect
/// that never resolved used to cancel whichever connect was running.
Future<void> connectWithin(
  BleService ble,
  String deviceId,
  Duration timeout,
) async {
  // Re-typed: RealBleService.connect's future is a Future<Null> at run
  // time, which rejects a `Future<void> Function()` onTimeout with a
  // TypeError.
  final pending = ble.connect(deviceId).then<void>((_) {});
  await pending.timeout(
    timeout,
    onTimeout: () async {
      // Attached before the cancel is awaited, so a connect that lands
      // while the cancel is in flight is covered too.
      unawaited(
        pending.then((_) {
          Log.ble.info(
            'connect to $deviceId landed after its caller gave up; '
            'releasing it',
          );
          return ble.disconnect(deviceId).catchError((Object _) {});
        }, onError: (Object _) {}),
      );
      if (ble is BleConnectCanceller) {
        try {
          await ble.cancelConnect(deviceId);
        } catch (error) {
          Log.ble.debug('cancelConnect($deviceId) threw', error: error);
        }
      }
      throw TimeoutException('connect to $deviceId', timeout);
    },
  );
}
