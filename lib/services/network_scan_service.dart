// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// Abstract local-network discovery. Implementations:
//   - RealNetworkScanService (mDNS via multicast_dns, SSDP via raw UDP)
//   - MockNetworkScanService (simulated devices for demo mode)

import '../core/error_text.dart';
import '../models/network_device.dart';

/// Raised on the [NetworkScanService.scan] stream when an Apple platform's
/// scan heard nothing at all.
///
/// iOS 14+ gates multicast and local-network traffic behind a permission the
/// system prompts for on first use, and a denial is invisible from inside the
/// app: the sockets bind, the queries go out, and the replies are filtered
/// away. So the observable fact is silence — not one mDNS record, not one SSDP
/// datagram — which on a real Wi-Fi network is close to impossible unless
/// something is dropping it.
///
/// Close to, not entirely: a genuinely empty network produces the same silence,
/// which is why the message leads with what was observed and offers the likely
/// cause rather than asserting a denial. The alternative — staying quiet — puts
/// a user whose permission really is off in front of an empty list with nothing
/// to act on, and that is the worse of the two failures.
///
/// A separate type from [NetworkUnavailableException] so the UI can offer the
/// settings path only where that gate exists.
class LocalNetworkDeniedException implements UserFacingException {
  @override
  final String message;
  const LocalNetworkDeniedException(
      [this.message = 'Nothing answered on this network. If Local Network '
          'access is off for Liberated Bread, the replies are blocked before '
          'they reach it — check Settings, then scan again.']);

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
  ///
  /// [extraSearchTargets] are vendor-specific SSDP search targets to query
  /// alongside the standard `ssdp:all`, deduplicated by the implementation.
  /// They exist because `ssdp:all` is not the whole story: a Roku answers
  /// M-SEARCH for `roku:ecp` and nothing else, so a scan that only asks the
  /// standard question never hears one. The caller supplies them from the
  /// spec catalogue's `ssdp_search_targets` — the scan layer itself knows no
  /// product names.
  Stream<NetworkDevice> scan({
    Duration timeout,
    List<String> extraSearchTargets,
  });

  /// Stop an in-progress scan.
  Future<void> stopScan();
}
