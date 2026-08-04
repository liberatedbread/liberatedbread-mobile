// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/hex.dart';
import '../core/log.dart';
import '../services/spec_codec.dart';
import 'device_spec_provider.dart';
import 'spec_codec_provider.dart';

/// Argument for [matchedDeviceSpecProvider]. A class (not a record) so the
/// family key has value equality over [serviceUuids] — otherwise a fresh list
/// instance on every widget build would defeat the family cache.
@immutable
class SpecMatchRequest {
  final String deviceName;
  final List<String> serviceUuids;

  const SpecMatchRequest(
      {required this.deviceName, required this.serviceUuids});

  @override
  bool operator ==(Object other) =>
      other is SpecMatchRequest &&
      other.deviceName == deviceName &&
      listEquals(other.serviceUuids, serviceUuids);

  @override
  int get hashCode => Object.hash(deviceName, Object.hashAll(serviceUuids));
}

/// A device spec matched to a connected device. The raw [yaml] is retained
/// because [SpecCodec.encodeCommand]/[SpecCodec.decodeValue] take the YAML, not
/// the parsed DTO.
@immutable
class MatchedSpec {
  final DeviceSpecDto spec;
  final String yaml;

  const MatchedSpec({required this.spec, required this.yaml});
}

/// Every bundled spec, parsed once.
///
/// Parsing is cached here rather than inside [matchedDeviceSpecProvider]
/// because that provider is a family: it would otherwise re-parse the whole
/// catalogue for every distinct device. With one bundled spec that was
/// invisible; the vendored catalogue is 70+ specs, so it would mean 70+ FFI
/// parses per connect. Specs that fail to parse (bad YAML, or the native
/// library unavailable) are skipped, so one bad spec can't take out matching.
final parsedDeviceSpecsProvider =
    FutureProvider<List<({DeviceSpecDto spec, String yaml})>>((ref) async {
  final codec = ref.watch(specCodecProvider);
  final specYamls = await ref.watch(deviceSpecsProvider.future);

  final parsed = <({DeviceSpecDto spec, String yaml})>[];
  for (final entry in specYamls.entries) {
    try {
      parsed.add(
          (spec: await codec.loadDeviceSpec(entry.value), yaml: entry.value));
    } catch (e) {
      // Skip this spec, but say so - a silent drop looks like a matching bug.
      Log.spec.warning('failed to parse spec ${entry.key}', error: e);
    }
  }
  return parsed;
});

/// Resolves the best-matching device spec for a connected device, or `null`
/// when none match or the native codec is unavailable. Matching uses the device
/// name prefix and the discovered service UUIDs (an [IoTDevice] does not carry
/// advertised UUIDs).
final matchedDeviceSpecProvider =
    FutureProvider.family<MatchedSpec?, SpecMatchRequest>((ref, req) async {
  final codec = ref.watch(specCodecProvider);
  final parsed = await ref.watch(parsedDeviceSpecsProvider.future);
  if (parsed.isEmpty) {
    Log.spec.info('no parseable specs; ${req.deviceName} gets raw controls '
        '(is the native codec loaded?)');
    return null;
  }

  final List<MatchResult> matches;
  try {
    matches = await codec.matchDeviceToSpec(
      specs: [for (final p in parsed) p.spec],
      deviceName: req.deviceName,
      advertisedServiceUuids: req.serviceUuids,
    );
  } catch (e) {
    // Degrade to "no spec matched" (raw controls still work), but log why.
    Log.spec.warning('matching failed for ${req.deviceName}', error: e);
    return null;
  }
  if (matches.isEmpty) {
    Log.spec.info('no spec matched ${req.deviceName} '
        '(${parsed.length} considered, ${req.serviceUuids.length} service uuid(s))');
    return null;
  }

  // Rank: name-prefix matches first, then most matched service UUIDs. Sort a
  // copy — the list may be unmodifiable (a const fake, or a fixed-length list
  // from the FFI boundary).
  final ranked = [...matches]..sort((a, b) {
      if (a.matchedByNamePrefix != b.matchedByNamePrefix) {
        return a.matchedByNamePrefix ? -1 : 1;
      }
      return b.matchedServiceUuids.length
          .compareTo(a.matchedServiceUuids.length);
    });
  final best = ranked.first;

  // Recover the source YAML for the winning spec. matchDeviceToSpec round-trips
  // DTOs through Rust/FRB, and the generated `DeviceSpecDto ==` compares its
  // List fields by reference — so a plain `==` against the returned spec is
  // unreliable when multiple specs are bundled. Compare identifying fields by
  // value, and return the locally-parsed (spec, yaml) pair so both are
  // guaranteed to come from the same source.
  // Use lastWhere so remote specs (loaded after bundled) take precedence
  // when both share the same identity.
  final winner = parsed.lastWhere(
    (p) => _sameSpecIdentity(p.spec, best.spec),
    orElse: () => parsed.first,
  );
  Log.spec.info('matched ${req.deviceName} to "${winner.spec.deviceName}" '
      '(${best.matchedByNamePrefix ? 'name prefix' : 'service uuid'}, '
      '${best.matchedServiceUuids.length} uuid(s); '
      '${matches.length} candidate(s))');
  return MatchedSpec(spec: winner.spec, yaml: winner.yaml);
});

/// Whether two specs identify the same device, compared by value. The generated
/// `DeviceSpecDto ==` uses referential equality for its List fields, which does
/// not survive the FFI round-trip, so we compare the identifying fields here.
bool _sameSpecIdentity(DeviceSpecDto a, DeviceSpecDto b) =>
    a.deviceName == b.deviceName &&
    a.manufacturer == b.manufacturer &&
    a.localNamePrefix == b.localNamePrefix &&
    listEquals(a.serviceUuids, b.serviceUuids);

/// Find the [ServiceDto] in [spec] for a discovered service UUID, or null.
ServiceDto? findServiceForUuid(DeviceSpecDto spec, String uuid) {
  final target = normalizeUuid(uuid);
  for (final service in spec.services) {
    if (normalizeUuid(service.uuid) == target) return service;
  }
  return null;
}

/// Find the [CharacteristicDto] in [service] for a discovered characteristic
/// UUID, or null.
CharacteristicDto? findCharForUuid(ServiceDto service, String uuid) {
  final target = normalizeUuid(uuid);
  for (final char in service.characteristics) {
    if (normalizeUuid(char.uuid) == target) return char;
  }
  return null;
}
