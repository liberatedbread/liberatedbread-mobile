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
/// matched.
final networkGuessProvider =
    FutureProvider.family<ScanGuess?, NetworkIdentity>((ref, identity) async {
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
  if (matches.isEmpty) return null;

  final best = matches.first;
  return ScanGuess(
    deviceName: best.deviceName,
    manufacturer: best.manufacturer,
    confidence: best.confidence,
    otherMatches:
        matches.skip(1).where((m) => m.confidence == best.confidence).length,
  );
});

/// A network device paired with what the catalogue makes of it.
@immutable
class RankedNetworkDevice {
  final NetworkDevice device;
  final ScanGuess? guess;

  const RankedNetworkDevice({required this.device, this.guess});

  bool get isLikelySupported =>
      guess != null && guess!.confidence != MatchConfidence.possible;
}

/// Split network devices into the ones the catalogue recognises and the rest.
///
/// The same shape as `rankScannedDevices`, and the same reasoning, with one
/// difference: there is no signal strength to break ties on, so the fallback is
/// the device's display name. That keeps the list stable as a scan progresses,
/// which matters more here — mDNS and SSDP answer at wildly different speeds,
/// and rows must not shuffle under a finger.
({List<RankedNetworkDevice> likelySupported, List<RankedNetworkDevice> other})
    rankNetworkDevices(
  List<NetworkDevice> devices,
  ScanGuess? Function(NetworkDevice device) guessFor,
) {
  final ranked = [
    for (final device in devices)
      RankedNetworkDevice(device: device, guess: guessFor(device)),
  ];

  int byConfidenceThenName(RankedNetworkDevice a, RankedNetworkDevice b) {
    final aRank = a.guess?.confidence.index ?? -1;
    final bRank = b.guess?.confidence.index ?? -1;
    if (aRank != bRank) return bRank.compareTo(aRank);
    return a.device.displayName
        .toLowerCase()
        .compareTo(b.device.displayName.toLowerCase());
  }

  final likelySupported = ranked.where((r) => r.isLikelySupported).toList()
    ..sort(byConfidenceThenName);
  final other = ranked.where((r) => !r.isLikelySupported).toList()
    ..sort(byConfidenceThenName);
  return (likelySupported: likelySupported, other: other);
}
