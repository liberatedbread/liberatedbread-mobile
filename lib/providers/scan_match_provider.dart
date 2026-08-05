// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/log.dart';
import '../models/iot_device.dart';
import '../services/spec_codec.dart';
import 'device_spec_match_provider.dart';
import 'spec_codec_provider.dart';

/// What a scanned device might be, according to the catalogue.
@immutable
class ScanGuess {
  /// The best-matching spec's device name, e.g. "Ember Mug".
  final String deviceName;
  final String manufacturer;
  final MatchConfidence confidence;

  /// How many other specs also matched. Non-zero means the signals were not
  /// specific enough to pick one product — an OUI shared by a whole vendor's
  /// catalogue is the usual cause.
  final int otherMatches;

  const ScanGuess({
    required this.deviceName,
    required this.manufacturer,
    required this.confidence,
    required this.otherMatches,
  });

  /// Whether this guess is specific enough to put a product name in front of a
  /// user. A [MatchConfidence.possible] match is one shared OUI: it says the
  /// device is worth a look, not which device it is. Saying "Mi Flora" on the
  /// strength of a Xiaomi OUI would be a confident lie.
  bool get namesAProduct =>
      confidence != MatchConfidence.possible && otherMatches == 0;

  /// Short label for the scan list.
  String get label => switch (confidence) {
        MatchConfidence.strong =>
          namesAProduct ? deviceName : 'Supported device',
        MatchConfidence.likely =>
          namesAProduct ? 'Likely $deviceName' : 'Likely supported',
        MatchConfidence.possible => 'Possibly $manufacturer',
      };
}

/// The identifying half of a scanned device — everything matching reads, and
/// nothing it doesn't.
///
/// A class rather than a record so the provider family key has value equality
/// over the lists: a fresh list instance on every advertisement would otherwise
/// defeat the family cache and re-run matching for each rssi tick.
@immutable
class ScanIdentity {
  final String name;
  final List<String> serviceUuids;
  final List<int> companyIds;
  final String? macAddress;

  const ScanIdentity({
    required this.name,
    required this.serviceUuids,
    required this.companyIds,
    required this.macAddress,
  });

  ScanIdentity.of(IoTDevice device)
      : name = device.name,
        serviceUuids = device.serviceUuids,
        companyIds = device.companyIds,
        macAddress = device.macAddress;

  @override
  bool operator ==(Object other) =>
      other is ScanIdentity &&
      other.name == name &&
      other.macAddress == macAddress &&
      listEquals(other.serviceUuids, serviceUuids) &&
      listEquals(other.companyIds, companyIds);

  @override
  int get hashCode => Object.hash(name, macAddress,
      Object.hashAll(serviceUuids), Object.hashAll(companyIds));
}

/// The catalogue reduced to its identifying fields, derived once.
///
/// The scan path asks about the whole catalogue for every newly seen device.
/// Passing full [DeviceSpecDto]s each time would push every service,
/// characteristic and entity across the FFI boundary per device; the identity
/// projection is a few strings per spec.
final specIdentitiesProvider =
    FutureProvider<List<SpecIdentityDto>>((ref) async {
  final parsed = await ref.watch(parsedDeviceSpecsProvider.future);
  return [
    for (final p in parsed)
      SpecIdentityDto(
        deviceName: p.spec.deviceName,
        manufacturer: p.spec.manufacturer,
        localNamePrefix: p.spec.localNamePrefix,
        serviceUuids: p.spec.serviceUuids,
        companyIds: p.spec.companyIds,
        macPrefixes: p.spec.macPrefixes,
        mdnsServiceType: p.spec.mdnsServiceType,
        ssdpSearchTargets: p.spec.ssdpSearchTargets,
        defaultPort: p.spec.defaultPort,
      ),
  ];
});

/// What the catalogue makes of one scanned device, or `null` when nothing
/// matched (or the native codec is unavailable).
///
/// Keyed on [ScanIdentity], not on the device id, so a device that keeps
/// advertising unchanged is matched once no matter how much its rssi moves.
final scanGuessProvider =
    FutureProvider.family<ScanGuess?, ScanIdentity>((ref, identity) async {
  final codec = ref.watch(specCodecProvider);
  final identities = await ref.watch(specIdentitiesProvider.future);
  if (identities.isEmpty) return null;

  final List<ScanMatch> matches;
  try {
    matches = await codec.matchScannedDevice(
      identities: identities,
      device: ScannedDeviceDto(
        name: identity.name,
        serviceUuids: identity.serviceUuids,
        companyIds: Uint16List.fromList(identity.companyIds),
        macAddress: identity.macAddress,
      ),
    );
  } catch (e) {
    // A scan must not fail because matching did. The device still lists, just
    // without a guess against its name.
    Log.spec.warning('scan matching failed for "${identity.name}"', error: e);
    return null;
  }
  if (matches.isEmpty) return null;

  // Rust returns these best-first.
  final best = matches.first;
  return ScanGuess(
    deviceName: best.deviceName,
    manufacturer: best.manufacturer,
    confidence: best.confidence,
    otherMatches:
        matches.skip(1).where((m) => m.confidence == best.confidence).length,
  );
});

/// A scanned device paired with what the catalogue makes of it.
@immutable
class RankedDevice {
  final IoTDevice device;

  /// `null` while matching is still in flight, or when nothing matched.
  final ScanGuess? guess;

  const RankedDevice({required this.device, this.guess});

  /// Whether this belongs above the fold. A [MatchConfidence.possible] match
  /// does not: a shared OUI is not grounds for telling someone their device is
  /// supported, only for keeping it off the bottom of the pile.
  bool get isLikelySupported =>
      guess != null && guess!.confidence != MatchConfidence.possible;
}

/// Split scanned devices into the ones the catalogue recognises and the rest.
///
/// A pure function of the devices and their guesses so the ordering rules can
/// be tested without a widget tree or a native library. Ordering within each
/// group is by confidence, then by signal strength — a recognised device across
/// the room still outranks an anonymous one on the desk, because knowing what
/// something is matters more here than how close it is.
({List<RankedDevice> likelySupported, List<RankedDevice> other})
    rankScannedDevices(
  List<IoTDevice> devices,
  ScanGuess? Function(IoTDevice device) guessFor,
) {
  final ranked = [
    for (final device in devices)
      RankedDevice(device: device, guess: guessFor(device)),
  ];

  int byConfidenceThenSignal(RankedDevice a, RankedDevice b) {
    final aRank = a.guess?.confidence.index ?? -1;
    final bRank = b.guess?.confidence.index ?? -1;
    if (aRank != bRank) return bRank.compareTo(aRank);
    return b.device.rssi.compareTo(a.device.rssi);
  }

  final likelySupported = ranked.where((r) => r.isLikelySupported).toList()
    ..sort(byConfidenceThenSignal);
  final other = ranked.where((r) => !r.isLikelySupported).toList()
    ..sort(byConfidenceThenSignal);
  return (likelySupported: likelySupported, other: other);
}
