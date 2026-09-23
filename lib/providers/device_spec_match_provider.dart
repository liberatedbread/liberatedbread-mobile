// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/hex.dart';
import '../core/log.dart';
import '../models/ble_discovered_service.dart';
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

  /// The canonical request for a device whose services have been discovered.
  ///
  /// Owns the cache key's construction: UUIDs normalized and sorted, so
  /// discovery order and casing cannot mint distinct family keys. Every
  /// post-discovery call site (the control panel, the device screen's match
  /// recorder, the group runner's resolver) builds through this factory —
  /// hand-rolling the key at any of them risks splitting the cache, which
  /// costs a second full-catalogue FFI match per connect and, worse, lets
  /// one site record a different outcome than another renders.
  SpecMatchRequest.forServices({
    required String deviceId,
    required String deviceName,
    required List<BleDiscoveredService> services,
  }) : this(
         deviceId: deviceId,
         deviceName: deviceName,
         serviceUuids: [for (final s in services) normalizeUuid(s.uuid)]
           ..sort(),
       );

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
    specKeyOf(spec.deviceName, spec.manufacturer);

/// [specKeyFor] for a caller that has the two fields but not a whole spec —
/// a catalogue entry, or a key being rebuilt from a saved record. One
/// definition of the key, two ways in.
String specKeyOf(String deviceName, String manufacturer) =>
    '$deviceName|$manufacturer';

/// The parsed catalogue indexed by [specKeyFor], for resolving stored keys
/// back to (spec, yaml) pairs.
///
/// Which of a matched spec's `device.variants[]` THIS device could be.
///
/// A family spec declares one entity per model, and until this existed the BLE
/// path handed every model's over at once — so seeblue and leds2rave4, which
/// each declare two lights with the SAME NAME on DIFFERENT command dialects,
/// were resolved by the panel's name dedupe keeping whichever came first. A
/// LEDGlowV2 was being driven with the Direct dialect's frames.
///
/// Variant names rather than surviving entity names, because those two lights
/// share a name: the entity's own `variants` is the only thing that tells them
/// apart.
///
/// Keyed by the same [SpecMatchRequest] the match itself uses, plus the yaml,
/// so it re-resolves when either changes and shares the family cache rather
/// than re-crossing the FFI on every rebuild. `autoDispose` for the reason the
/// match provider is: a device disconnected is a key nobody should hold.
final bleVariantNamesProvider = FutureProvider.autoDispose
    .family<Set<String>, ({SpecMatchRequest request, String yaml})>((
      ref,
      args,
    ) async {
      final codec = ref.watch(specCodecProvider);
      final names = await codec.bleVariantNamesForDevice(
        yaml: args.yaml,
        deviceName: args.request.deviceName,
        serviceUuids: args.request.serviceUuids,
      );
      return names.toSet();
    });

/// Insertion order makes duplicates resolve the way [matchedDeviceSpecProvider]
/// does: remote pack specs load after bundled ones, so on an identity
/// collision the pack entry wins. This is the ONE place that shadowing rule
/// is encoded for key lookups — consumers that need it (the group member
/// resolver) build the map here rather than re-implementing the scan.
Map<String, CatalogueSpec> specEntriesByKey(List<CatalogueSpec> parsed) => {
  for (final entry in parsed)
    specKeyOf(entry.deviceName, entry.manufacturer): entry,
};

/// Strength of the evidence behind one [SpecMatch], strongest first.
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
MatchEvidence matchEvidenceOf(SpecMatch match) =>
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
  SpecMatch match, {
  required List<String> discoveredUuids,
}) {
  if (match.matchedServiceUuids.isNotEmpty) return false;
  if (discoveredUuids.isEmpty) return false;
  final specGattUuids = {
    for (final uuid in match.entry.gattServiceUuids) normalizeUuid(uuid),
  };
  if (specGattUuids.isEmpty) return false;
  return !discoveredUuids.any(
    (uuid) => specGattUuids.contains(normalizeUuid(uuid)),
  );
}

/// Filter and rank raw matcher output: contradicted name-only matches are
/// dropped, then candidates sort by [MatchEvidence] tier and, within a tier,
/// by how many service UUIDs matched. Pure so the policy is unit-testable
/// without providers or the FFI codec.
List<SpecMatch> rankSpecMatches(
  List<SpecMatch> matches, {
  required List<String> discoveredUuids,
}) {
  final kept =
      matches
          .where(
            (m) => !isContradictedNameOnlyMatch(
              m,
              discoveredUuids: discoveredUuids,
            ),
          )
          .toList()
        ..sort((a, b) {
          final tier = matchEvidenceOf(
            a,
          ).index.compareTo(matchEvidenceOf(b).index);
          if (tier != 0) return tier;
          return b.matchedServiceUuids.length.compareTo(
            a.matchedServiceUuids.length,
          );
        });
  return kept;
}

/// The leading run of [ranked] that ties with its first element (same
/// evidence tier, same matched-UUID count). More than one element means
/// ranking cannot separate them and the user should choose. Pure for tests;
/// assumes [ranked] came from [rankSpecMatches].
List<SpecMatch> topTiedSpecMatches(List<SpecMatch> ranked) {
  if (ranked.isEmpty) return const [];
  final top = ranked.first;
  return ranked
      .where(
        (m) =>
            matchEvidenceOf(m) == matchEvidenceOf(top) &&
            m.matchedServiceUuids.length == top.matchedServiceUuids.length,
      )
      .toList();
}

/// The whole catalogue, parsed once and held by the codec.
///
/// Parsing is cached here rather than inside [matchedDeviceSpecProvider]
/// because that provider is a family: it would otherwise re-parse the whole
/// catalogue for every distinct device. With one bundled spec that was
/// invisible; the vendored catalogue is 200+ specs, so it would mean 200+ FFI
/// parses per connect. Specs that fail to parse (bad YAML, or the native
/// library unavailable) are skipped and named, so one bad spec can't take out
/// matching.
///
/// What this provider yields is the catalogue's LIGHT projection — identity
/// fields, the YAML, and the two fields the adopt and network paths select on
/// — not 200+ `DeviceSpecDto`s. It used to be the latter, and decoding them
/// on the UI isolate was a ~70-77 ms stall that landed, on a cold app,
/// exactly as the first scan results appeared. A screen that renders a spec
/// asks for its full DTO by index ([SpecCatalogue.specAt]).
final specCatalogueProvider = FutureProvider<SpecCatalogue>((ref) async {
  final codec = ref.watch(specCodecProvider);
  final specYamls = await ref.watch(deviceSpecsProvider.future);
  // R-081: timed through the shared helper rather than a local Stopwatch.
  // This is the load the whole handle redesign was about — it used to block
  // the calling isolate for the better part of a second — so "how long did it
  // take on this device" is a question worth being able to answer from a
  // diagnostics capture rather than only from a benchmark on a desk.
  final catalogue = await Log.spec.timed(
    'loading ${specYamls.length} spec(s)',
    () => codec.loadCatalogue(specYamls),
    level: LogLevel.info,
  );

  // Counted rather than logged per spec: when the native library is not up
  // (a host test that pumps the app before RustLib.init, or a device build
  // whose framework failed to load — main() carries on without it by
  // design) EVERY parse fails the same way, and 204 identical warnings
  // drowned the one line that mattered, and any genuinely malformed spec
  // with it. One error line for the bridge; per-spec warnings stay for
  // real parse failures.
  final bridgeDown = catalogue.failures
      .where((f) => isBridgeUninitialised(f.message))
      .length;
  if (bridgeDown > 0) {
    Log.spec.error(
      'native codec unavailable: $bridgeDown spec(s) skipped, '
      'so no device will match a spec until the Rust core loads',
    );
  }
  for (final failure in catalogue.failures) {
    if (isBridgeUninitialised(failure.message)) continue;
    // Skip this spec, but say so - a silent drop looks like a matching bug.
    Log.spec.warning('failed to parse spec ${failure.key}: ${failure.message}');
  }
  return catalogue;
});

/// Whether [error] is flutter_rust_bridge refusing a call because
/// `RustLib.init()` has not run (or failed) — the one failure that is the
/// same for every spec and worth reporting once.
// isBridgeUninitialised moved to services/spec_codec.dart: the codec is
// where the bridge is met, and it is what turns the failure into an empty
// catalogue now.

/// Resolves the device spec(s) matching a connected device. Matching uses the
/// device name prefix and the discovered service UUIDs (an [IoTDevice] does
/// not carry advertised UUIDs), ranked by [rankSpecMatches]. A stored user
/// choice (see [specChoicesProvider]) wins whenever its spec still matches;
/// otherwise a unique top candidate is chosen automatically, and a tie is
/// returned as [SpecMatchOutcome.needsChoice] for the UI to resolve.
/// R-070: `autoDispose`, which its sibling above already claimed it was. The
/// family key is (device id, name, discovered UUID set), so without it every
/// device ever connected in this run kept its match — and its resolved
/// `MatchedSpec`, which now holds a Rust-side parse — alive for the life of
/// the process. A device that is disconnected is a key nobody should hold.
final matchedDeviceSpecProvider = FutureProvider.autoDispose
    .family<SpecMatchOutcome, SpecMatchRequest>((ref, req) async {
      // Watched (not read) so saving a choice recomputes this match in place —
      // but select()ed down to THIS device's entry, so answering the chooser for
      // one device doesn't invalidate every other device's cached match (the
      // transient AsyncLoading would blank other panels' typed controls).
      final savedKey = ref.watch(
        specChoicesProvider.select((m) => m[req.deviceId]),
      );
      final catalogue = await ref.watch(specCatalogueProvider.future);
      if (catalogue.specs.isEmpty) {
        Log.spec.info(
          'no parseable specs; ${req.deviceName} gets raw controls '
          '(is the native codec loaded?)',
        );
        return const SpecMatchOutcome.none();
      }

      final List<SpecMatch> matches;
      try {
        matches = await catalogue.matchDevice(
          deviceName: req.deviceName,
          serviceUuids: req.serviceUuids,
        );
      } catch (e) {
        // Degrade to "no spec matched" (raw controls still work), but log why.
        Log.spec.warning('matching failed for ${req.deviceName}', error: e);
        return const SpecMatchOutcome.none();
      }

      final ranked = rankSpecMatches(
        matches,
        discoveredUuids: req.serviceUuids,
      );
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
        Log.spec.info(
          'no spec matched ${req.deviceName}; raw controls only '
          '(${catalogue.specs.length} spec(s) considered'
          '${dropped > 0 ? '; $dropped name-only match(es) dropped as '
                    'contradicted by the discovered services' : ''}'
          '; discovered service uuid(s): '
          '${req.serviceUuids.isEmpty ? 'none' : req.serviceUuids.join(', ')})',
        );
        return const SpecMatchOutcome.none();
      }

      // A match names an INDEX into the catalogue, so the winning spec's DTO
      // and the YAML behind it come from one entry rather than an identity
      // join over parsed specs — and (on the native codec) the parse the
      // catalogue already holds becomes this screen's, so its first
      // decodeValue ships a pointer rather than the spec's text.
      //
      // The one identity lookup that survives is the shadowing rule: an
      // installed pack carrying a corrected copy of a bundled spec loads
      // after it and must win, and only the identity key can say that two
      // entries are the same device. specEntriesByKey is last-wins, which is
      // exactly that rule, defined once.
      final entriesByKey = specEntriesByKey(catalogue.specs);
      Future<MatchedSpec> resolve(SpecMatch match) async {
        final entry =
            entriesByKey[specKeyOf(
              match.entry.deviceName,
              match.entry.manufacturer,
            )] ??
            match.entry;
        return MatchedSpec(
          spec: await catalogue.specAt(entry.index),
          yaml: entry.yaml,
        );
      }

      String evidenceOf(SpecMatch match) => [
        // Plural: a family sold under several rebadged names declares each of
        // them, and a match does not say which one hit, so name them all
        // rather than pick one and imply it was the one that matched.
        if (match.matchedByNamePrefix)
          'name prefix '
              '${match.entry.identity.localNamePrefixes.map((p) => '"$p"').join(' or ')}',
        if (match.matchedServiceUuids.isNotEmpty)
          'service uuid(s) ${match.matchedServiceUuids.join(', ')}',
      ].join(' + ');

      // A stored user choice beats ranking as long as its spec still matches at
      // all: the user asserted what the device is, and heuristics must not
      // overrule that on the next connect. A stale key (spec renamed/removed, or
      // the device no longer matches it) falls through to the normal flow.
      if (savedKey != null) {
        final savedMatch = ranked
            .where(
              (m) =>
                  specKeyOf(m.entry.deviceName, m.entry.manufacturer) ==
                  savedKey,
            )
            .firstOrNull;
        if (savedMatch != null) {
          final saved = await resolve(savedMatch);
          Log.spec.info(
            'using spec "${saved.spec.deviceName}" for '
            '${req.deviceName}: saved user choice',
          );
          return SpecMatchOutcome.saved(saved);
        }
        Log.spec.warning(
          'saved spec choice "$savedKey" for ${req.deviceName} '
          'no longer matches; falling back to ranking',
        );
      }

      // Ties (by evidence tier and matched-UUID count, over distinct spec
      // identities) go to the user: white-label families share GATT platforms,
      // and guessing the brand silently would pin wrong names/commands to the
      // device with no way to notice.
      final tiedByKey = <String, SpecMatch>{};
      for (final m in topTiedSpecMatches(ranked)) {
        // First occurrence wins, keeping candidates in rank order; duplicate
        // identities (a bundled spec shadowed by a remote refresh) collapse to
        // one choice.
        tiedByKey.putIfAbsent(
          specKeyOf(m.entry.deviceName, m.entry.manufacturer),
          () => m,
        );
      }
      if (tiedByKey.length > 1) {
        final candidates = <MatchedSpec>[
          for (final m in tiedByKey.values) await resolve(m),
        ];
        Log.spec.info(
          '${candidates.length} specs match ${req.deviceName} '
          'equally well '
          '(${candidates.map((c) => '"${c.spec.deviceName}"').join(', ')}); '
          'asking the user',
        );
        return SpecMatchOutcome.needsChoice(candidates);
      }

      final best = ranked.first;
      final winner = await resolve(best);
      // The one place "this device is using spec X" is recorded — typed controls,
      // readings and command encoding all follow from this match. Spell out the
      // evidence (name prefix and/or the concrete UUIDs) so a wrong match is
      // debuggable from the log alone.
      Log.spec.info(
        'using spec "${winner.spec.deviceName}" for '
        '${req.deviceName}: matched by ${evidenceOf(best)} '
        '(${matches.length} of ${catalogue.specs.length} spec(s) matched)',
      );
      return SpecMatchOutcome.auto(winner);
    });

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
