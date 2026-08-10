// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show IconData;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/device_category.dart';
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

  /// What kind of thing the matched spec says this is, when every equally-good
  /// match agrees on one. Null when they disagree, when the spec states no
  /// category, or when this build has not met the category it states.
  ///
  /// Agreement is required for the same reason [manufacturerAgreed] exists: a
  /// shared OUI can tie four specs, and drawing the first one's icon would be
  /// the same confident guess in picture form. But agreement is a lower bar
  /// than [namesAProduct] — a UUID shared by ten of one vendor's lights cannot
  /// say which light, and can still say "light".
  final DeviceCategory? category;
  final MatchConfidence confidence;

  /// How many other specs also matched. Non-zero means the signals were not
  /// specific enough to pick one product — an OUI shared by a whole vendor's
  /// catalogue is the usual cause.
  final int otherMatches;

  /// Whether every equally-good match came from the same manufacturer.
  ///
  /// Separate from [otherMatches] because a tie between two of one vendor's
  /// products is a different thing from a tie between four vendors: the first
  /// still knows who made it, the second knows nothing but that something
  /// matched. Trivially true when nothing else matched.
  final bool manufacturerAgreed;

  const ScanGuess({
    required this.deviceName,
    required this.manufacturer,
    required this.confidence,
    required this.otherMatches,
    required this.manufacturerAgreed,
    this.category,
  });

  /// Reduce a matcher result to a guess, or null when nothing matched.
  ///
  /// The one place the "best match plus how contested it was" policy lives —
  /// both the BLE and Wi-Fi guess providers go through it, so `namesAProduct`
  /// can never mean different things on different tabs. Rust returns matches
  /// best-first; `otherMatches` counts only ties at the best confidence,
  /// because a Strong match is not made ambiguous by a trailing Possible one.
  static ScanGuess? fromMatches(List<ScanMatch> matches) {
    if (matches.isEmpty) return null;
    final best = matches.first;
    final tied =
        matches.skip(1).where((m) => m.confidence == best.confidence).toList();
    final category = DeviceCategory.parse(best.category);
    return ScanGuess(
      deviceName: best.deviceName,
      manufacturer: best.manufacturer,
      confidence: best.confidence,
      otherMatches: tied.length,
      manufacturerAgreed:
          tied.every((m) => m.manufacturer == best.manufacturer),
      category: tied.every((m) => DeviceCategory.parse(m.category) == category)
          ? category
          : null,
    );
  }

  /// Whether this guess is specific enough to put a product name in front of a
  /// user. A [MatchConfidence.possible] match is one shared OUI: it says the
  /// device is worth a look, not which device it is. Saying "Mi Flora" on the
  /// strength of a Xiaomi OUI would be a confident lie.
  bool get namesAProduct =>
      confidence != MatchConfidence.possible && otherMatches == 0;

  /// The icon to draw for this device: its class where the catalogue agrees on
  /// one, and [fallback] — the tab's own generic glyph — otherwise.
  ///
  /// A category only ever comes from a matched spec, never from a heuristic
  /// over the advertised name, so a row whose icon is not the fallback is one
  /// the catalogue actually placed. Names are suggestive ("LEDBlue-A1B2C3")
  /// and it is tempting to read them, but a guess drawn in the same glyph as a
  /// real match is a claim with its evidence stripped off — and
  /// [DeviceDescription] already says the true version of that, naming who
  /// made the device and what it offers, out of the registries.
  IconData iconOr(IconData fallback) => category?.icon ?? fallback;

  /// Short label for the scan list.
  ///
  /// The `possible` branch names the manufacturer only when the tied matches
  /// agree on one. Four specs from four vendors can match a single shared OUI,
  /// and reporting the first of them badged every one of those devices
  /// "Possibly Enphase Energy" — the same confident lie [namesAProduct] exists
  /// to prevent, one rung further down.
  String get label => switch (confidence) {
        MatchConfidence.strong =>
          namesAProduct ? deviceName : 'Supported device',
        MatchConfidence.likely =>
          namesAProduct ? 'Likely $deviceName' : 'Likely supported',
        MatchConfidence.possible =>
          manufacturerAgreed ? 'Possibly $manufacturer' : 'Possibly supported',
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
        category: p.spec.category,
        localNamePrefixes: p.spec.localNamePrefixes,
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
/// `autoDispose` because the family key is the device's identity, and BLE
/// privacy mode mints a fresh rotating address every few minutes: without it,
/// every identity ever seen stays cached for the life of the app. Visible rows
/// keep their entry alive by watching it.
final scanGuessProvider = FutureProvider.autoDispose
    .family<ScanGuess?, ScanIdentity>((ref, identity) async {
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
  return ScanGuess.fromMatches(matches);
});

/// A device paired with what the catalogue makes of it.
@immutable
class Ranked<T> {
  final T device;

  /// `null` while matching is still in flight, or when nothing matched.
  final ScanGuess? guess;

  const Ranked({required this.device, this.guess});

  /// Whether this belongs above the fold. A [MatchConfidence.possible] match
  /// does not: a shared OUI is not grounds for telling someone their device is
  /// supported, only for keeping it off the bottom of the pile.
  bool get isLikelySupported =>
      guess != null && guess!.confidence != MatchConfidence.possible;
}

/// A scanned BLE device paired with its guess.
typedef RankedDevice = Ranked<IoTDevice>;

/// Split devices into the ones the catalogue recognises and the rest.
///
/// A pure function of the devices and their guesses so the ordering rules can
/// be tested without a widget tree or a native library. Ordering within each
/// group is by confidence, then by the caller's tie-break — the one thing that
/// legitimately differs between the BLE and Wi-Fi tabs. Everything else (the
/// partition, and "possible never counts as supported") exists once, here.
({List<Ranked<T>> likelySupported, List<Ranked<T>> other}) rankDevices<T>(
  List<T> devices,
  ScanGuess? Function(T device) guessFor,
  int Function(Ranked<T> a, Ranked<T> b) tieBreak,
) {
  final ranked = [
    for (final device in devices)
      Ranked(device: device, guess: guessFor(device)),
  ];

  int byConfidenceThenTieBreak(Ranked<T> a, Ranked<T> b) {
    final aRank = a.guess?.confidence.index ?? -1;
    final bRank = b.guess?.confidence.index ?? -1;
    if (aRank != bRank) return bRank.compareTo(aRank);
    return tieBreak(a, b);
  }

  final likelySupported = ranked.where((r) => r.isLikelySupported).toList()
    ..sort(byConfidenceThenTieBreak);
  final other = ranked.where((r) => !r.isLikelySupported).toList()
    ..sort(byConfidenceThenTieBreak);
  return (likelySupported: likelySupported, other: other);
}

/// Split scanned BLE devices, breaking ties by freshness and then by signal
/// strength — a recognised device across the room still outranks an anonymous
/// one on the desk, because knowing what something is matters more here than
/// how close it is.
///
/// Freshness comes first within a group because a stale row's signal reading is
/// a memory, not a measurement: a device that fell silent while showing -40 dBm
/// would otherwise sit at the top of the list, above everything the scan can
/// actually still hear. [isStale] defaults to "nothing is stale", for callers
/// that do not track it.
({List<RankedDevice> likelySupported, List<RankedDevice> other})
    rankScannedDevices(
  List<IoTDevice> devices,
  ScanGuess? Function(IoTDevice device) guessFor, {
  bool Function(IoTDevice device)? isStale,
}) =>
        rankDevices(
          devices,
          guessFor,
          (a, b) {
            final aStale = isStale?.call(a.device) ?? false;
            final bStale = isStale?.call(b.device) ?? false;
            if (aStale != bStale) return aStale ? 1 : -1;
            return b.device.rssi.compareTo(a.device.rssi);
          },
        );
