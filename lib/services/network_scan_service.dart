// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// Abstract local-network discovery. Implementations:
//   - RealNetworkScanService (mDNS via multicast_dns, SSDP via raw UDP)
//   - MockNetworkScanService (simulated devices for demo mode)

import '../core/error_text.dart';
import '../models/network_device.dart';

/// Raised on the [NetworkScanService.scan] stream when the OS refused local
/// network access.
///
/// iOS 14+ gates multicast and local-network traffic behind a permission that
/// the system prompts for on first use; a denial there is silent — sockets
/// simply receive nothing — so this is raised when a scan finds literally
/// nothing on a platform where that gate exists. It is a distinct type so the
/// UI can point at the right settings page rather than showing an empty state
/// that looks like "you have no devices".
class LocalNetworkDeniedException implements UserFacingException {
  @override
  final String message;
  const LocalNetworkDeniedException(
      [this.message = 'Local network access is needed to find Wi-Fi devices. '
          'Allow it for Liberated Bread in Settings, then scan again.']);

  @override
  String toString() => message;
}

/// Raised when there is no usable network to scan — no Wi-Fi, or an interface
/// with no multicast route.
class NetworkUnavailableException implements UserFacingException {
  @override
  final String message;
  const NetworkUnavailableException(
      [this.message = 'No Wi-Fi network. Join one, then scan again.']);

  @override
  String toString() => message;
}

/// Discovery of devices on the local network.
abstract class NetworkScanService {
  /// Discover devices, emitting each as it is found (and again as more is
  /// learned about it, the same way the BLE scan re-emits on change).
  ///
  /// Passive in the sense that matters: it sends multicast queries that any
  /// device may answer, and never opens a connection to a specific host.
  Stream<NetworkDevice> scan({Duration timeout});

  /// Stop an in-progress scan.
  Future<void> stopScan();
}
