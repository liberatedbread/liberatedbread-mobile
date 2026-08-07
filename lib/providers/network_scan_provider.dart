// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/log.dart';
import '../models/network_device.dart';
import '../services/mock_network_scan_service.dart';
import '../services/network_scan_service.dart';
import '../services/real_network_scan_service.dart';
import '../services/spec_codec.dart';
import 'ble_provider.dart' show isMockMode;
import 'scan_match_provider.dart';
import 'spec_codec_provider.dart';

/// Provides the local-network discovery implementation (real or mock).
final networkScanServiceProvider = Provider<NetworkScanService>((ref) {
  if (isMockMode) return MockNetworkScanService();
  final service = RealNetworkScanService();
  // Multicast sockets and the mDNS client outlive a widget if nobody closes
  // them, and a leaked bound socket keeps the radio awake.
  ref.onDispose(() => service.stopScan());
  return service;
});

/// The identifying half of a device found on the network.
///
/// Value-equal so the provider family caches per device rather than per
/// sighting — a host re-announcing the same records must not re-run matching.
@immutable
class NetworkIdentity {
  final String name;
  final String? hostname;
  final int? port;
  final List<String> serviceTypes;
  final List<String> ssdpTargets;

  const NetworkIdentity({
    required this.name,
    required this.hostname,
    required this.port,
    required this.serviceTypes,
    required this.ssdpTargets,
  });

  NetworkIdentity.of(NetworkDevice device)
      : name = device.name,
        hostname = device.hostname,
        port = device.port,
        serviceTypes = device.serviceTypes,
        ssdpTargets = device.ssdpTargets;

  @override
  bool operator ==(Object other) =>
      other is NetworkIdentity &&
      other.name == name &&
      other.hostname == hostname &&
      other.port == port &&
      listEquals(other.serviceTypes, serviceTypes) &&
      listEquals(other.ssdpTargets, ssdpTargets);

  @override
  int get hashCode => Object.hash(name, hostname, port,
      Object.hashAll(serviceTypes), Object.hashAll(ssdpTargets));
}

/// What the catalogue makes of one device on the network, or null when nothing
/// matched. The Wi-Fi twin of `scanGuessProvider`, sharing its reduction via
/// [ScanGuess.fromMatches] and its `autoDispose` reasoning — hosts come and go
/// with DHCP, and dead identities must not accumulate for the app's lifetime.
final networkGuessProvider = FutureProvider.autoDispose
    .family<ScanGuess?, NetworkIdentity>((ref, identity) async {
  final codec = ref.watch(specCodecProvider);
  final identities = await ref.watch(specIdentitiesProvider.future);
  if (identities.isEmpty) return null;

  final List<ScanMatch> matches;
  try {
    matches = await codec.matchNetworkDevice(
      identities: identities,
      device: NetworkDeviceDto(
        name: identity.name,
        hostname: identity.hostname,
        serviceTypes: identity.serviceTypes,
        ssdpTargets: identity.ssdpTargets,
        port: identity.port,
      ),
    );
  } catch (e) {
    // A scan must not fail because matching did.
    Log.spec.warning(
        'network matching failed for "${identity.hostname ?? identity.name}"',
        error: e);
    return null;
  }
  return ScanGuess.fromMatches(matches);
});

/// A network device paired with what the catalogue makes of it.
typedef RankedNetworkDevice = Ranked<NetworkDevice>;

/// Split network devices, breaking ties by display name: there is no signal
/// strength here, and a stable order matters more — mDNS and SSDP answer at
/// wildly different speeds, and rows must not shuffle under a finger.
({List<RankedNetworkDevice> likelySupported, List<RankedNetworkDevice> other})
    rankNetworkDevices(
  List<NetworkDevice> devices,
  ScanGuess? Function(NetworkDevice device) guessFor,
) =>
        rankDevices(
          devices,
          guessFor,
          (a, b) => a.device.displayName
              .toLowerCase()
              .compareTo(b.device.displayName.toLowerCase()),
        );
