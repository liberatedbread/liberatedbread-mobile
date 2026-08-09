// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:io';

import 'package:flutter/services.dart';

import '../core/log.dart';

/// Holds Android's multicast lock for the duration of a local-network scan.
///
/// Android's Wi-Fi driver filters multicast and broadcast packets that are not
/// addressed to the device, so mDNS and SSDP replies never reach the app unless
/// a `WifiManager.MulticastLock` is held. The failure is silent and total: the
/// queries go out, nothing comes back, and the Wi-Fi tab looks like a network
/// with no devices on it.
///
/// A no-op everywhere else. iOS and desktop platforms do not filter this way —
/// iOS gates the same traffic behind the local-network permission instead, which
/// is a user decision rather than something an app can take a lock for.
class MulticastLock {
  /// Matches `CHANNEL` in android/app/src/main/kotlin/.../MainActivity.kt.
  static const MethodChannel channel =
      MethodChannel('ca.pigscanfly.liberatedbread/multicast');

  /// Whether this platform needs (and has) the lock. Kept as a field rather
  /// than read from [Platform] at each call so tests can drive both paths.
  final bool isSupported;

  MulticastLock({bool? isSupported})
      : isSupported = isSupported ?? Platform.isAndroid;

  /// Take the lock, or do nothing on a platform that has none.
  ///
  /// Never throws. A scan that cannot take the lock is a scan that may come
  /// back empty; a scan that fails outright because of it is strictly worse, so
  /// the failure is logged and the scan proceeds.
  Future<void> acquire() => _invoke('acquire');

  /// Release the lock. Safe to call when it was never taken — the platform side
  /// is idempotent — so teardown paths do not need to track whether they got it.
  Future<void> release() => _invoke('release');

  Future<void> _invoke(String method) async {
    if (!isSupported) return;
    try {
      await channel.invokeMethod<void>(method);
    } catch (e) {
      Log.net.warning('multicast lock $method failed', error: e);
    }
  }
}
