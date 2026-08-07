// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/hex.dart';
import '../core/log.dart';
import '../services/spec_codec.dart';
import 'device_spec_provider.dart';
import 'spec_choice_provider.dart';
import 'spec_codec_provider.dart';

/// Argument for [matchedDeviceSpecProvider]. A class (not a record) so the
/// family key has value equality over [serviceUuids] — otherwise a fresh list
/// instance on every widget build would defeat the family cache.
@immutable
class SpecMatchRequest {
  /// The BLE device id, used to look up (and store) a per-device user spec
  /// choice. Part of the family key so two devices that happen to share a
  /// name and UUID set still resolve their own saved choices.
  final String deviceId;
  final String deviceName;
  final List<String> serviceUuids;

  const SpecMatchRequest({
    required this.deviceId,
    required this.deviceName,
    required this.serviceUuids,
  });

  @override
  bool operator ==(Object other) =>
      other is SpecMatchRequest &&
      other.deviceId == deviceId &&
      other.deviceName == deviceName &&
      listEquals(other.serviceUuids, serviceUuids);

  @override
  int get hashCode =>
      Object.hash(deviceId, deviceName, Object.hashAll(serviceUuids));
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

/// How the winning spec (if any) was chosen.
enum SpecChoiceSource {
  /// Ranking produced a single best candidate.
  auto,

  /// The user picked this spec earlier; the stored choice was honored.
  saved,

  /// Several specs tie: [SpecMatchOutcome.candidates] carries them and the UI
  /// should ask the user.
  prompt,

  /// Nothing matched.
  none,
}

/// The result of spec matching for one device: either a chosen spec, or the
/// tied [candidates] a user has to pick from, or nothing.
@immutable
class SpecMatchOutcome {
  final MatchedSpec? chosen;

  /// Non-empty only when [source] is [SpecChoiceSource.prompt]: the distinct
  /// specs that matched equally well.
  final List<MatchedSpec> candidates;
  final SpecChoiceSource source;

  const SpecMatchOutcome._(this.chosen, this.candidates, this.source);
  const SpecMatchOutcome.none() : this._(null, const [], SpecChoiceSource.none);
  const SpecMatchOutcome.auto(MatchedSpec spec)
      : this._(spec, const [], SpecChoiceSource.auto);
  const SpecMatchOutcome.saved(MatchedSpec spec)
      : this._(spec, const [], SpecChoiceSource.saved);
  const SpecMatchOutcome.needsChoice(List<MatchedSpec> candidates)
      : this._(null, candidates, SpecChoiceSource.prompt);

  bool get needsChoice => source == SpecChoiceSource.prompt;
}

/// Stable identity key for a spec, used to persist a user's choice across
/// launches and spec-pack refreshes. Name + manufacturer rather than a file
/// path or the full identity tuple: it survives the spec's UUID list or
/// name-prefix being refined upstream without orphaning the stored choice.
String specKeyFor(DeviceSpecDto spec) =>
    '${spec.deviceName}|${spec.manufacturer}';

/// Strength of the evidence behind one [MatchResult], strongest first.
///
/// The ordering encodes which axis is trustworthy on its own. A matched
/// 128-bit service UUID is a fact read from the connected device's GATT
/// database; an advertised-name prefix is often just two characters (SmartDawn
/// units are "DN*", cat printers "GB*"), which random unrelated devices can
/// collide with. So UUID evidence must never lose to a bare name match — a
/// name prefix only adds rank when it corroborates a UUID match (it then
/// distinguishes brands within a white-label family sharing one platform
/// service).
enum MatchEvidence { corroborated, uuidOnly, nameOnly }

/// Classify one match result. Pure so ranking is unit-testable.
MatchEvidence matchEvidenceOf(MatchResult match) =>
    match.matchedServiceUuids.isNotEmpty
        ? (match.matchedByNamePrefix
            ? MatchEvidence.corroborated
            : MatchEvidence.uuidOnly)
        : MatchEvidence.nameOnly;

/// Whether a name-only match is contradicted by the device's own GATT
/// database and must be dropped.
///
/// The comparison is against the spec's declared GATT **services** — NOT its
/// `identification.service_uuids`. Identification UUIDs are advertisement
/// data, and for several bundled specs (Govee H5075, Mi Flora) they are
/// service-data UUIDs that never appear in a GATT table, so keying on them
/// would reject those devices' perfectly good name matches. The GATT services
/// block is the honest test: if the spec describes services and the connected
/// device (whose discovery is non-empty) carries none of them, the name
/// prefix is a coincidence — the spec's typed controls could not work anyway.
/// This is what keeps a short prefix like "DN" from claiming random devices
/// whose names merely start with those letters.
///
/// A spec that declares no GATT services keeps its name match (the name is
/// its only usable axis here), as does any match when the discovered list is
/// empty (no evidence either way).
bool isContradictedNameOnlyMatch(
  MatchResult match, {
  required List<String> discoveredUuids,
}) {
  if (match.matchedServiceUuids.isNotEmpty) return false;
  if (discoveredUuids.isEmpty) return false;
  final specGattUuids = {
    for (final service in match.spec.services) normalizeUuid(service.uuid),
  };
  if (specGattUuids.isEmpty) return false;
  return !discoveredUuids
      .any((uuid) => specGattUuids.contains(normalizeUuid(uuid)));
}

/// Filter and rank raw matcher output: contradicted name-only matches are
/// dropped, then candidates sort by [MatchEvidence] tier and, within a tier,
/// by how many service UUIDs matched. Pure so the policy is unit-testable
/// without providers or the FFI codec.
List<MatchResult> rankSpecMatches(
  List<MatchResult> matches, {
  required List<String> discoveredUuids,
}) {
  final kept = matches
      .where((m) =>
          !isContradictedNameOnlyMatch(m, discoveredUuids: discoveredUuids))
      .toList()
    ..sort((a, b) {
      final tier = matchEvidenceOf(a).index.compareTo(matchEvidenceOf(b).index);
      if (tier != 0) return tier;
      return b.matchedServiceUuids.length
          .compareTo(a.matchedServiceUuids.length);
    });
  return kept;
}

/// The leading run of [ranked] that ties with its first element (same
/// evidence tier, same matched-UUID count). More than one element means
/// ranking cannot separate them and the user should choose. Pure for tests;
/// assumes [ranked] came from [rankSpecMatches].
List<MatchResult> topTiedSpecMatches(List<MatchResult> ranked) {
  if (ranked.isEmpty) return const [];
  final top = ranked.first;
  return ranked
      .where((m) =>
          matchEvidenceOf(m) == matchEvidenceOf(top) &&
          m.matchedServiceUuids.length == top.matchedServiceUuids.length)
      .toList();
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

/// Resolves the device spec(s) matching a connected device. Matching uses the
/// device name prefix and the discovered service UUIDs (an [IoTDevice] does
/// not carry advertised UUIDs), ranked by [rankSpecMatches]. A stored user
/// choice (see [specChoicesProvider]) wins whenever its spec still matches;
/// otherwise a unique top candidate is chosen automatically, and a tie is
/// returned as [SpecMatchOutcome.needsChoice] for the UI to resolve.
final matchedDeviceSpecProvider =
    FutureProvider.family<SpecMatchOutcome, SpecMatchRequest>((ref, req) async {
  final codec = ref.watch(specCodecProvider);
  // Watched (not read) so saving a choice recomputes this match in place —
  // but select()ed down to THIS device's entry, so answering the chooser for
  // one device doesn't invalidate every other device's cached match (each
  // recompute re-marshals the whole parsed catalogue over FFI, and the
  // transient AsyncLoading would blank other panels' typed controls).
  final savedKey =
      ref.watch(specChoicesProvider.select((m) => m[req.deviceId]));
  final parsed = await ref.watch(parsedDeviceSpecsProvider.future);
  if (parsed.isEmpty) {
    Log.spec.info('no parseable specs; ${req.deviceName} gets raw controls '
        '(is the native codec loaded?)');
    return const SpecMatchOutcome.none();
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
    return const SpecMatchOutcome.none();
  }

  final ranked = rankSpecMatches(matches, discoveredUuids: req.serviceUuids);
  if (ranked.isEmpty) {
    // Name the inputs, not just their counts: "which UUIDs did matching
    // actually see" is the first question when a device that should match
    // renders as generic raw controls. (A device that never got this far —
    // e.g. service discovery returned nothing — is logged by the BLE layer;
    // matching only runs once there are discovered services.) Dropped
    // matches are called out: a name-prefix collision that was rejected
    // because the device lacks the spec's GATT service looks identical to
    // "no match" otherwise.
    final dropped = matches.length - ranked.length;
    Log.spec.info('no spec matched ${req.deviceName}; raw controls only '
        '(${parsed.length} spec(s) considered'
        '${dropped > 0 ? '; $dropped name-only match(es) dropped as '
            'contradicted by the discovered services' : ''}'
        '; discovered service uuid(s): '
        '${req.serviceUuids.isEmpty ? 'none' : req.serviceUuids.join(', ')})');
    return const SpecMatchOutcome.none();
  }

  // Recover the source YAML for each candidate spec. matchDeviceToSpec
  // round-trips DTOs through Rust/FRB, and the generated `DeviceSpecDto ==`
  // compares its List fields by reference — so a plain `==` against the
  // returned spec is unreliable when multiple specs are bundled. Compare
  // identifying fields by value, and return the locally-parsed (spec, yaml)
  // pair so both are guaranteed to come from the same source.
  // Use lastWhere so remote specs (loaded after bundled) take precedence
  // when both share the same identity.
  MatchedSpec resolve(MatchResult match) {
    final source = parsed.lastWhere(
      (p) => _sameSpecIdentity(p.spec, match.spec),
      orElse: () => parsed.first,
    );
    return MatchedSpec(spec: source.spec, yaml: source.yaml);
  }

  String evidenceOf(MatchResult match) => [
        // Plural: a family sold under several rebadged names declares each of
        // them, and MatchResult does not say which one hit, so name them all
        // rather than pick one and imply it was the one that matched.
        if (match.matchedByNamePrefix)
          'name prefix ${match.spec.localNamePrefixes.map((p) => '"\$p"').join(' or ')}',
        if (match.matchedServiceUuids.isNotEmpty)
          'service uuid(s) ${match.matchedServiceUuids.join(', ')}',
      ].join(' + ');

  // A stored user choice beats ranking as long as its spec still matches at
  // all: the user asserted what the device is, and heuristics must not
  // overrule that on the next connect. A stale key (spec renamed/removed, or
  // the device no longer matches it) falls through to the normal flow.
  if (savedKey != null) {
    final savedMatch =
        ranked.where((m) => specKeyFor(m.spec) == savedKey).firstOrNull;
    if (savedMatch != null) {
      final saved = resolve(savedMatch);
      Log.spec.info('using spec "${saved.spec.deviceName}" for '
          '${req.deviceName}: saved user choice');
      return SpecMatchOutcome.saved(saved);
    }
    Log.spec.warning('saved spec choice "$savedKey" for ${req.deviceName} '
        'no longer matches; falling back to ranking');
  }

  // Ties (by evidence tier and matched-UUID count, over distinct spec
  // identities) go to the user: white-label families share GATT platforms,
  // and guessing the brand silently would pin wrong names/commands to the
  // device with no way to notice.
  final tiedByKey = <String, MatchResult>{};
  for (final m in topTiedSpecMatches(ranked)) {
    // First occurrence wins, keeping candidates in rank order; duplicate
    // identities (a bundled spec shadowed by a remote refresh) collapse to
    // one choice.
    tiedByKey.putIfAbsent(specKeyFor(m.spec), () => m);
  }
  if (tiedByKey.length > 1) {
    final candidates = tiedByKey.values.map(resolve).toList();
    Log.spec.info('${candidates.length} specs match ${req.deviceName} '
        'equally well '
        '(${candidates.map((c) => '"${c.spec.deviceName}"').join(', ')}); '
        'asking the user');
    return SpecMatchOutcome.needsChoice(candidates);
  }

  final best = ranked.first;
  final winner = resolve(best);
  // The one place "this device is using spec X" is recorded — typed controls,
  // readings and command encoding all follow from this match. Spell out the
  // evidence (name prefix and/or the concrete UUIDs) so a wrong match is
  // debuggable from the log alone.
  Log.spec.info('using spec "${winner.spec.deviceName}" for '
      '${req.deviceName}: matched by ${evidenceOf(best)} '
      '(${matches.length} of ${parsed.length} spec(s) matched)');
  return SpecMatchOutcome.auto(winner);
});

/// Whether two specs identify the same device, compared by value. The generated
/// `DeviceSpecDto ==` uses referential equality for its List fields, which does
/// not survive the FFI round-trip, so we compare the identifying fields here.
bool _sameSpecIdentity(DeviceSpecDto a, DeviceSpecDto b) =>
    a.deviceName == b.deviceName &&
    a.manufacturer == b.manufacturer &&
    listEquals(a.localNamePrefixes, b.localNamePrefixes) &&
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
