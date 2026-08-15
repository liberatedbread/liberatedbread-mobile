// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:io';

import 'package:flutter/services.dart';

import '../core/log.dart';

/// The SSIDs the OS can currently see in the air, when it will tell us.
///
/// This exists for one small, honest job: the adopt flow wants to nudge the
/// user when a device's setup network (Wemo…, LIFX…) is actually visible, so
/// its icon can come alive instead of the screen asking them to go hunting in
/// system settings for a network that may not be there yet.
///
/// It is best-effort by nature and Android-only in practice:
///   * Android exposes `WifiManager.getScanResults()` — cached, throttled, and
///     gated behind the location permission the BLE scan already holds. We read
///     the cache rather than forcing scans, because forcing them is rate-limited
///     to near-uselessness on Android 9+ and drains battery for a hint.
///   * iOS has no public API to enumerate nearby Wi-Fi at all (only the SSID of
///     the network you are already on, behind an entitlement). So iOS returns
///     nothing, and the adopt flow simply does not animate — the same
///     platform-shaped no-op as [MulticastLock].
///
/// Never throws. A hint that cannot be produced is not an error worth breaking
/// a screen over; the failure is logged and an empty list is returned.
class WifiNetworkScanner {
  /// Matches `WIFI_SCAN_CHANNEL` in
  /// android/app/src/main/kotlin/.../MainActivity.kt.
  static const MethodChannel channel =
      MethodChannel('ca.pigscanfly.liberatedbread/wifi_scan');

  /// Whether this platform can enumerate nearby networks at all. Kept as a
  /// field rather than read from [Platform] at each call so tests can drive both
  /// paths without a platform override.
  final bool isSupported;

  WifiNetworkScanner({bool? isSupported})
      : isSupported = isSupported ?? Platform.isAndroid;

  /// The SSIDs the OS currently sees, de-duplicated and with blanks dropped.
  ///
  /// Returns an empty list on any platform that cannot answer, on a permission
  /// refusal, or on any platform-channel failure — the caller treats "we cannot
  /// see" and "nothing is there" the same way, because to a hint they are.
  Future<List<String>> visibleSsids() async {
    if (!isSupported) return const [];
    try {
      final result = await channel.invokeListMethod<String>('scanResults');
      if (result == null) return const [];
      // Hidden networks report an empty SSID; the OS may also list the same
      // network on several bands. Neither helps a prefix match.
      final seen = <String>{};
      final ssids = <String>[];
      for (final ssid in result) {
        final trimmed = ssid.trim();
        if (trimmed.isEmpty) continue;
        if (seen.add(trimmed)) ssids.add(trimmed);
      }
      return ssids;
    } catch (e) {
      Log.net.debug('wifi scan results unavailable: $e');
      return const [];
    }
  }
}
