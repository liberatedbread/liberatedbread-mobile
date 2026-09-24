// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/network_device.dart';
import '../services/saved_network_device_store.dart';
import '../services/tls_trust.dart';
import 'saved_device_provider.dart';

final savedNetworkDeviceStoreProvider = Provider<SavedNetworkDeviceStore>(
  (ref) => SavedNetworkDeviceStore(ref.watch(sharedPreferencesProvider)),
);

/// The user's saved network devices, newest-first — the Wi-Fi sibling of
/// [SavedDevicesNotifier], kept a separate notifier for the same reason the
/// models are separate classes: the two lists change on different events
/// (a BLE connect vs. opening a network control screen) and merging them
/// would rebuild every watcher on both.
class SavedNetworkDevicesNotifier
    extends StateNotifier<List<SavedNetworkDevice>> {
  final SavedNetworkDeviceStore _store;

  SavedNetworkDevicesNotifier(this._store) : super(_store.load());

  Future<void> save(SavedNetworkDevice device) async {
    state = await _store.save(device);
  }

  Future<void> remove(String id) async {
    state = await _store.remove(id);
  }

  /// Record a sighting the user acted on — opening the control screen is
  /// the network counterpart of a BLE connect. Refreshes the address cache
  /// and the recency stamp, and records the spec identity/category when the
  /// caller knows them.
  ///
  /// Every cached field MERGES rather than replaces, because sightings are
  /// not equally rich: the same device answers mDNS with a TXT map and no
  /// SSDP targets one session, and SSDP with targets and no TXT the next.
  /// Blind-overwriting lost whichever half the latest transport did not
  /// carry — an adopted robot's `blid` (unopenable from Saved Devices), or a
  /// Wemo's search targets (which is what narrows a family spec, so its
  /// controls stopped resolving). A sighting can therefore only ADD to what
  /// is known, or refresh a value it actually carries.
  Future<SavedNetworkDevice> touch(
    NetworkDevice device, {
    String? category,
    String? specKey,
    DateTime? seenAt,
  }) async {
    final existing = _existingFor(device);
    final record = SavedNetworkDevice(
      // The record keeps the id it was filed under. The sighting's own id is
      // only a proposal, and a thinner sighting proposes a weaker one (no
      // TXT, so no `mac:` rung): re-filing under it would leave two rows for
      // one device, the tapped one missing the credential. It would also
      // orphan the device's group memberships, which reference this id.
      id: existing?.id ?? SavedNetworkDevice.stableIdFor(device),
      // The name follows the merge rule every other field does: only what
      // the sighting actually carries. A thin sighting (a probe reply, a
      // nameless SSDP answer) has no name, only a hostname-or-IP fallback,
      // and must not rename a saved "Dorita" to an address.
      name: device.name.isNotEmpty
          ? device.name
          : (existing?.name ?? device.displayName),
      lastSeen: seenAt ?? DateTime.now(),
      // The address is the one field a fresh sighting always knows better:
      // it is where the device answered from just now.
      host: device.host,
      hostname: device.hostname ?? existing?.hostname,
      port: device.port ?? existing?.port,
      ssdpPort: device.ssdpPort ?? existing?.ssdpPort,
      ssdpDescriptionPath:
          device.ssdpDescriptionPath ?? existing?.ssdpDescriptionPath,
      ssdpTargets: device.ssdpTargets.isNotEmpty
          ? device.ssdpTargets
          : existing?.ssdpTargets ?? const [],
      serviceTypes: device.serviceTypes.isNotEmpty
          ? device.serviceTypes
          : existing?.serviceTypes ?? const [],
      answeredLanProtocols: device.answeredLanProtocols.isNotEmpty
          ? device.answeredLanProtocols
          : existing?.answeredLanProtocols ?? const [],
      server: device.server ?? existing?.server,
      pictogram: device.pictogram ?? existing?.pictogram,
      // The latest answer wins here rather than accumulating: these are what
      // the device answered on, and a device that has stopped answering SSDP
      // should stop claiming it. An empty set is not an answer, though — it
      // is a sighting that recorded none — so it leaves the last one standing.
      sources: device.sources.isNotEmpty
          ? device.sources
          : existing?.sources ?? const {},
      txt: _mergeTxt(existing?.txt, device.txt),
      category: category ?? existing?.category,
      specKey: specKey ?? existing?.specKey,
      // The identity the sender and screen key THIS sighting's credentials
      // and pins under, recorded so Remove can clear exactly what was
      // written. Strongest form wins on merge: a `mac:` identity is never
      // downgraded by a later thin sighting whose host is all it knows —
      // the mac-keyed pin would outlive the record's memory of it.
      credentialIdentity: _strongerIdentity(
        existing?.credentialIdentity,
        device.credentialIdentity,
      ),
      // Every identity this device's material was ever keyed under. The primary
      // above may flip when a host-only device changes host; retaining the old
      // keys here is what lets forget clear the pin/credentials left behind
      // under them, instead of orphaning them in secure storage forever.
      credentialIdentities: {
        ...?existing?.credentialIdentities,
        if (existing?.credentialIdentity != null) existing!.credentialIdentity!,
        device.credentialIdentity,
      },
    );
    await save(record);
    return record;
  }

  /// The saved record [device] is another sighting of, if there is one.
  ///
  /// The id the sighting proposes is tried first, and is usually the answer.
  /// The fallbacks exist because the ladder [SavedNetworkDevice.stableIdFor]
  /// climbs depends on what the sighting carries: a robot filed under
  /// `mac:…` (read out of its TXT) is proposed as `hn:…` by the next sighting
  /// over a transport with no TXT at all, and the record it belongs to would
  /// never be found. Only rungs that identify the DEVICE are matched —
  /// hostname, or a name at the same address — never the address alone,
  /// which a DHCP lease hands to a different device altogether.
  SavedNetworkDevice? _existingFor(NetworkDevice device) {
    final byId = state
        .where((d) => d.id == SavedNetworkDevice.stableIdFor(device))
        .firstOrNull;
    if (byId != null) return byId;
    final hostname = device.hostname;
    if (hostname != null && hostname.isNotEmpty) {
      final byHostname = state.where((d) => d.hostname == hostname).firstOrNull;
      if (byHostname != null) return byHostname;
    }
    // Last rung: a name at the same address. Weaker than the two above,
    // because one address can front more than one logical device — a hub, a
    // host running several services — and two of them sharing a display name
    // would fold into one record.
    //
    // What makes it safe enough to keep is the contradiction check rather
    // than a narrower match: a candidate that states an identity the sighting
    // also states, DIFFERENTLY, is a different device however much its
    // address and name agree. A candidate that simply says nothing (the case
    // this rung exists for — an SSDP sighting of a device first seen over
    // mDNS) still matches, because silence is not disagreement.
    final name = device.displayName;
    if (name.isEmpty) return null;
    final sightingMac = device.advertisedMac;
    return state
        .where((d) => d.host == device.host && d.name == name)
        .where((d) => !_contradicts(d.hostname, device.hostname))
        .where((d) => !_contradicts(_macOf(d.id), sightingMac))
        .firstOrNull;
  }

  /// Whether two statements of the same identity disagree. Either side being
  /// absent (or empty) is silence, not disagreement.
  static bool _contradicts(String? a, String? b) =>
      a != null && a.isNotEmpty && b != null && b.isNotEmpty && a != b;

  /// The MAC a saved record was filed under, when it was filed under one.
  static String? _macOf(String id) =>
      id.startsWith('mac:') ? id.substring('mac:'.length) : null;

  /// The cached TXT map after [sighting] is folded into [existing].
  ///
  /// A key the sighting does not carry survives, because the transport it
  /// answered over may simply have no TXT to give. A key it carries EMPTY
  /// also leaves the established value alone: a TXT record may hold a bare
  /// flag with no value, which the parser stores as `''`, and an empty `blid`
  /// or `mac` is not an identity — it is the absence of one wearing the
  /// shape of a key.
  static Map<String, String> _mergeTxt(
    Map<String, String>? existing,
    Map<String, String> sighting,
  ) {
    final merged = {...?existing};
    for (final entry in sighting.entries) {
      if (entry.value.isEmpty && (merged[entry.key]?.isNotEmpty ?? false)) {
        continue;
      }
      merged[entry.key] = entry.value;
    }
    return merged;
  }

  /// The stronger of two store identities: `mac:` beats `host:` (the mac is
  /// the handle that survives a lease), a fresh value of equal strength wins
  /// (the device re-observed is the device), and null fills from whatever is
  /// known.
  static String? _strongerIdentity(String? existing, String sighted) {
    if (sighted.startsWith('mac:')) return sighted;
    if (existing != null && existing.startsWith('mac:')) return existing;
    return sighted;
  }

  bool contains(String id) => state.any((d) => d.id == id);
}

final savedNetworkDevicesProvider =
    StateNotifierProvider<
      SavedNetworkDevicesNotifier,
      List<SavedNetworkDevice>
    >(
      (ref) => SavedNetworkDevicesNotifier(
        ref.watch(savedNetworkDeviceStoreProvider),
      ),
    );
